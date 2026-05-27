import Foundation
import AVFoundation
@preconcurrency import WhisperKit

/// Local on-device Whisper provider (stage 3 of the Whisper integration).
///
/// Uses Argmax's WhisperKit (Core ML under the hood) so a transcript costs
/// $0/hour after the one-time model download. Apple Silicon only — the
/// underlying Core ML packages don't have Intel-compatible artefacts and
/// rolling our own would defeat the point of "drop in WhisperKit and ship".
/// Intel callers get a graceful fallback at the pipeline level (see
/// `TranscriptionPipeline.geminiRawTurns`).
///
/// Contract mirrors `WhisperTranscriber.transcribe(audioURL:mode:initialPrompt:)`:
///   • Returns `[GeminiTranscriber.Turn]` so the rest of the pipeline
///     (forced alignment, diarize-first re-labeling) is provider-agnostic.
///   • Reuses the same `VoiceActivityDetector` pre-pass and hallucination
///     filter as the cloud Whisper provider.
///   • Mode `.single` labels every segment as "user" (mic track).
///   • Mode `.diarize` is NOT supported here — WhisperKit ships a CRF VAD
///     but no diarization. The pipeline already runs FluidAudio downstream
///     for WHO on the system track, so we hand back `.single` labels and
///     let the existing diarize-first re-labeling do its job.
///
/// Model: a multilingual ~1.5 GB Whisper turbo Core ML bundle, downloaded
/// on first use into `AppPaths.modelsDir`. Download is resumable (HTTP
/// range), so a partial fetch on a previous launch picks up where it left
/// off. Progress is broadcast via `downloadProgress` AsyncStream for the
/// (future) UI toast/modal.
@MainActor
enum LocalWhisperTranscriber {

    enum WMode {
        case single   // one speaker label "user" — only supported mode
        case diarize  // not supported locally (see file header)
    }

    enum LocalWhisperError: Error, LocalizedError {
        case notAvailableOnIntel
        case modelNotReady
        case missingFile(String)
        case diarizeNotSupported
        case transcribeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailableOnIntel:
                return "Local Whisper is only available on Apple Silicon Macs."
            case .modelNotReady:
                return "Local Whisper model isn't ready yet — it needs to download (~1.5 GB) first."
            case .missingFile(let p):
                return "Audio file missing at \(p)."
            case .diarizeNotSupported:
                return "Local Whisper doesn't support diarize mode — pipeline should route .diarize through Gemini."
            case .transcribeFailed(let msg):
                return "Local Whisper failed: \(msg)"
            }
        }
    }

    // MARK: - Tunables

    /// Multilingual large-v3 "turbo" Core ML bundle from
    /// `argmaxinc/whisperkit-coreml`. ~1.5 GB on disk, runs at ≥10x real
    /// time on M-series Macs. The non-turbo `openai_whisper-large-v3` is
    /// the same accuracy but ~2x slower decode; turbo is the right floor
    /// for "feels instant" on a 30-min meeting. If the model name ever
    /// goes stale, `WhisperKit.fetchAvailableModels` lists the live set
    /// from the HuggingFace repo.
    static let modelVariant = "openai_whisper-large-v3_turbo"

    /// VAD pre-pass thresholds, mirror cloud Whisper. Talk-heavy meetings
    /// sail through unchanged; idle mic tracks get squeezed.
    private static let vadMinSavings: Double = 0.10
    private static let vadEmptyFloorMs: Int64 = 500

    /// Lazily-initialised WhisperKit instance. Created the first time a
    /// transcribe call lands and the model is on disk; kept alive for the
    /// process lifetime so we don't pay the Core ML compile cost twice.
    private static var pipe: WhisperKit?

    /// `AsyncStream` continuation for download-progress UI. Multi-cast: a
    /// future React modal can subscribe and render a progress bar while the
    /// model is being fetched. `nil` between downloads.
    nonisolated(unsafe) private static var downloadProgressContinuation:
        AsyncStream<Double>.Continuation?

    /// Public progress stream. Each call returns a fresh stream that
    /// receives fractions in `0.0...1.0`; consumers should subscribe BEFORE
    /// calling `ensureModelReady()`. When download finishes (or wasn't
    /// needed) the stream completes.
    static var downloadProgress: AsyncStream<Double> {
        AsyncStream { continuation in
            downloadProgressContinuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in
                    if downloadProgressContinuation != nil {
                        downloadProgressContinuation = nil
                    }
                }
            }
        }
    }

    // MARK: - Availability + model state

    /// Apple Silicon check. Core ML on Intel doesn't have the bf16 / ANE
    /// kernels these models rely on, so even if the package compiled the
    /// runtime cost would be unusable. Cheaper to fail fast.
    static func isAvailable() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Local existence check — true iff the model directory contains the
    /// minimal set of files WhisperKit needs to load offline. We check for
    /// the audio encoder / text decoder Core ML packages by name; presence
    /// of the folder alone isn't enough because a partial download leaves
    /// the folder empty.
    static func isModelDownloaded() -> Bool {
        let dir = modelFolderURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // WhisperKit ships AudioEncoder.mlmodelc + TextDecoder.mlmodelc
        // (each is itself a directory). The presence of both is a good
        // proxy for "load won't fail on first try".
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        for name in required {
            let url = dir.appendingPathComponent(name, isDirectory: true)
            if !fm.fileExists(atPath: url.path) { return false }
        }
        return true
    }

    /// Concrete on-disk URL for the variant's model folder under
    /// `~/Library/Application Support/Corder/models/<variant>/`. WhisperKit
    /// downloads into `<downloadBase>/argmaxinc/whisperkit-coreml/<variant>/`
    /// (it preserves the HuggingFace repo path), so the actual folder we
    /// hand to `WhisperKitConfig.modelFolder` is one level deeper than the
    /// downloadBase.
    private static var downloadBaseURL: URL { AppPaths.modelsDir }
    private static var modelFolderURL: URL {
        downloadBaseURL
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelVariant, isDirectory: true)
    }

    // MARK: - Public API

    /// Idempotent download + load. Safe to call before every transcribe —
    /// when the model is already on disk it just spins up the WhisperKit
    /// instance (or no-ops if it's already running). Progress is published
    /// to `downloadProgress` while the actual HTTP fetch runs.
    static func ensureModelReady() async throws {
        guard isAvailable() else { throw LocalWhisperError.notAvailableOnIntel }
        try FileManager.default.createDirectory(at: AppPaths.modelsDir,
                                                withIntermediateDirectories: true)

        if !isModelDownloaded() {
            FileLogger.log("LocalWhisper: model not on disk — downloading \(modelVariant) into \(downloadBaseURL.path)")
            // ProgressCallback is `@Sendable (Progress) -> Void`; convert
            // the NSProgress fraction into a Double for our stream.
            let cont = downloadProgressContinuation
            _ = try await WhisperKit.download(
                variant: modelVariant,
                downloadBase: downloadBaseURL,
                useBackgroundSession: false,
                progressCallback: { progress in
                    // Foundation's Progress can report indeterminate
                    // (totalUnitCount <= 0); clamp to 0 in that case.
                    let f = progress.totalUnitCount > 0
                        ? max(0.0, min(1.0, progress.fractionCompleted))
                        : 0.0
                    cont?.yield(f)
                }
            )
            cont?.yield(1.0)
            cont?.finish()
            FileLogger.log("LocalWhisper: download complete (\(modelVariant))")
        }

        if pipe == nil {
            FileLogger.log("LocalWhisper: loading WhisperKit from \(modelFolderURL.path)")
            let cfg = WhisperKitConfig(
                model: modelVariant,
                // downloadBase doubles as the tokenizerFolder search root
                // when no explicit tokenizerFolder is set, so passing it
                // lets WhisperKit re-discover the tokenizer files that
                // landed alongside the model during our `download()` call
                // above. Without it tokenizer loading would try to fetch
                // from HuggingFace, defeating the whole point of
                // `download: false`.
                downloadBase: downloadBaseURL,
                modelFolder: modelFolderURL.path,
                verbose: false,
                logLevel: .error,
                // Pre-warm + load on init — first real transcribe call
                // then doesn't pay the Core ML compile cost. Costs ~2-3 s
                // up front, but the alternative is a 2-3 s freeze on the
                // user's first Stop press, which is much worse UX.
                prewarm: true,
                load: true,
                download: false
            )
            do {
                pipe = try await WhisperKit(cfg)
            } catch {
                throw LocalWhisperError.transcribeFailed("init failed: \(error.localizedDescription)")
            }
        }
    }

    /// Whole-file transcription. Mirrors `WhisperTranscriber.transcribe`:
    /// VAD pre-pass → WhisperKit call → projection back onto the original
    /// timeline. Returns `[GeminiTranscriber.Turn]` so the rest of the
    /// pipeline stays provider-agnostic.
    static func transcribe(audioURL: URL,
                           mode: WMode,
                           initialPrompt: String?) async throws -> [GeminiTranscriber.Turn] {
        guard isAvailable() else { throw LocalWhisperError.notAvailableOnIntel }
        guard mode == .single else { throw LocalWhisperError.diarizeNotSupported }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw LocalWhisperError.missingFile(audioURL.path)
        }

        try await ensureModelReady()
        guard let pipe = pipe else { throw LocalWhisperError.modelNotReady }

        let durationSec = (try? audioDurationSeconds(audioURL: audioURL)) ?? 0
        let durationMs = Int64(durationSec * 1000)
        FileLogger.log("LocalWhisperTranscriber: \(audioURL.lastPathComponent) duration ≈ \(Int(durationSec))s")

        // VAD pre-pass — same trade-off as Gemini / cloud Whisper: skip
        // the whole compute if there's <500 ms of speech, otherwise
        // compress only when the savings clear the 10 % floor.
        let segments = VoiceActivityDetector.detect(audioURL: audioURL)
        let speechMs = segments.map { VoiceActivityDetector.totalSpeechMs($0) } ?? durationMs

        if let segs = segments, segs.isEmpty || speechMs < vadEmptyFloorMs {
            FileLogger.log("LocalWhisperTranscriber: VAD <\(vadEmptyFloorMs)ms speech in \(audioURL.lastPathComponent), skipping")
            return []
        }

        let savingsRatio = durationMs > 0 ? 1.0 - Double(speechMs) / Double(durationMs) : 0.0
        let useVad = (segments != nil) && savingsRatio >= vadMinSavings

        let workURL: URL
        let projection: VoiceActivityDetector.Projection?
        let tmpDir: URL?

        if useVad, let segs = segments {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("corder-local-whisper-vad-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let concat = dir.appendingPathComponent("speech.wav")
            do {
                let proj = try VoiceActivityDetector.concatenateSpeech(
                    audioURL: audioURL, segments: segs, outURL: concat)
                workURL = concat
                projection = proj
                tmpDir = dir
                FileLogger.log(String(format: "LocalWhisperTranscriber: VAD compressed %ds → %ds (%.0f%% saved, %d segments)",
                                      Int(durationSec), Int(speechMs / 1000), savingsRatio * 100, segs.count))
            } catch {
                try? FileManager.default.removeItem(at: dir)
                FileLogger.log("LocalWhisperTranscriber: VAD concat failed (\(error)) — using original")
                workURL = audioURL
                projection = nil
                tmpDir = nil
            }
        } else {
            workURL = audioURL
            projection = nil
            tmpDir = nil
        }
        defer {
            if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        }

        // Vocabulary bias via promptTokens (same `prompt=` lever Whisper
        // cloud uses, but local Whisper needs us to tokenise first). The
        // tokenizer might be nil if the model hasn't been fully loaded
        // yet; in that case we just skip the prompt rather than blocking.
        var decodeOpts = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,                        // auto-detect — matches Gemini's behaviour
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )
        if let prompt = initialPrompt,
           !prompt.isEmpty,
           let tokenizer = pipe.tokenizer {
            decodeOpts.promptTokens = tokenizer.encode(text: " " + prompt)
        }

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioPath: workURL.path,
                                                 decodeOptions: decodeOpts,
                                                 callback: nil)
        } catch {
            throw LocalWhisperError.transcribeFailed(error.localizedDescription)
        }

        // WhisperKit's chunked transcribe returns an array of results, one
        // per window. Flatten segments across all windows; each segment
        // already carries absolute start/end in seconds (Float).
        var rawTurns: [GeminiTranscriber.Turn] = []
        rawTurns.reserveCapacity(results.reduce(0) { $0 + $1.segments.count })
        for r in results {
            for s in r.segments {
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard !Self.isHallucination(text) else {
                    FileLogger.log("LocalWhisperTranscriber: dropping hallucination: \(text)")
                    continue
                }
                rawTurns.append(GeminiTranscriber.Turn(
                    speakerLabel: "user",
                    startMs: Int64(Double(s.start) * 1000),
                    endMs: Int64(Double(s.end) * 1000),
                    text: text))
            }
        }
        FileLogger.log("LocalWhisperTranscriber: produced \(rawTurns.count) turns from \(audioURL.lastPathComponent)")

        // Project compressed timestamps back onto the original timeline
        // if VAD chopped silence out. Identical to the Gemini / cloud
        // Whisper paths.
        guard let proj = projection else { return rawTurns }
        let projected = rawTurns.map {
            GeminiTranscriber.Turn(speakerLabel: $0.speakerLabel,
                                   startMs: proj.toOriginal(compressedMs: $0.startMs),
                                   endMs: proj.toOriginal(compressedMs: $0.endMs),
                                   text: $0.text)
        }
        // Monotonic clamp pass — same as cloud Whisper. A turn near the
        // tail can over-shoot the real duration after projection;
        // collapsing it back to a strictly-increasing schedule inside the
        // duration bound keeps the last line from jumping past EOF.
        let origDurationMs = Int64(durationSec * 1000)
        var bound = origDurationMs
        var out = projected
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            let s = min(out[i].startMs, bound)
            let e = max(s, min(out[i].endMs, origDurationMs))
            out[i] = GeminiTranscriber.Turn(speakerLabel: out[i].speakerLabel,
                                            startMs: s, endMs: e, text: out[i].text)
            bound = max(0, s - 1)
        }
        return out
    }

    // MARK: - Hallucination filter

    /// Mirror of `WhisperTranscriber.hallucinationPatterns`. Same caveat —
    /// once we have a third consumer this should move to a shared helper.
    private static let hallucinationPatterns: [String] = [
        "субтитры сделал dimatorzok",
        "субтитры подготовил dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры подобрал dimatorzok",
        "субтитры от dimatorzok",
        "продолжение следует",
        "спасибо за просмотр",
        "спасибо за внимание",
        "не забудьте подписаться",
        "подписывайтесь на канал",
        "ставьте лайк",
    ]

    private static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()
        let stripped = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let normalised = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        for pat in hallucinationPatterns {
            if normalised.contains(pat) { return true }
        }
        return false
    }

    // MARK: - Helpers

    private static func audioDurationSeconds(audioURL: URL) throws -> Double {
        let file = try AVAudioFile(forReading: audioURL)
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }
}
