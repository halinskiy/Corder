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

    /// One WhisperKit Core ML bundle the user can pick. Sizes are
    /// approximate (HuggingFace download size, decompressed Core ML
    /// packages on disk are a touch larger). The string raw value
    /// matches the directory WhisperKit creates under
    /// `<downloadBase>/argmaxinc/whisperkit-coreml/<repoName>/`.
    enum Variant: String, CaseIterable {
        /// Multilingual large-v3 turbo — current default, ~1.5 GB on
        /// disk, ≥10x real-time on M-series. Best quality / accuracy
        /// trade-off for "feels instant" on a 30-min meeting.
        case turbo = "openai_whisper-large-v3_turbo"
        /// Multilingual small — ~480 MB, faster decode than turbo,
        /// modest accuracy drop. Good middle-ground when the user
        /// doesn't want to ship 1.5 GB or wait on a slow link.
        case small = "openai_whisper-small"
        /// Multilingual base — ~150 MB. Decent for clean podcast/voice
        /// content, struggles with overlapping speech and noise.
        case base = "openai_whisper-base"
        /// Multilingual tiny — ~75 MB. The "kick the tyres" option;
        /// the model fits in memory anywhere but accuracy is noticeably
        /// worse than base. Useful for offline emergencies / metered
        /// connections more than for primary use.
        case tiny = "openai_whisper-tiny"

        /// Display name shown in the picker / download button.
        var label: String {
            switch self {
            case .turbo: return "Whisper Turbo"
            case .small: return "Whisper Small"
            case .base:  return "Whisper Base"
            case .tiny:  return "Whisper Tiny"
            }
        }
        /// Human-readable approximate download size (HuggingFace).
        var sizeLabel: String {
            switch self {
            case .turbo: return "1.5 GB"
            case .small: return "480 MB"
            case .base:  return "150 MB"
            case .tiny:  return "75 MB"
            }
        }
        /// Integer MB for sorting / UI conditionals.
        var sizeMB: Int {
            switch self {
            case .turbo: return 1500
            case .small: return 480
            case .base:  return 150
            case .tiny:  return 75
            }
        }
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

    /// Default variant chosen on a fresh install. Multilingual large-v3
    /// turbo is the right "feels instant" floor for a 30-min meeting on
    /// M-series, but ~1.5 GB on disk — the picker lets the user trade
    /// quality for download size.
    nonisolated static let defaultVariant: Variant = .turbo

    /// VAD pre-pass thresholds, mirror cloud Whisper. Talk-heavy meetings
    /// sail through unchanged; idle mic tracks get squeezed.
    private static let vadMinSavings: Double = 0.10
    private static let vadEmptyFloorMs: Int64 = 500

    /// Lazily-initialised WhisperKit instance plus the variant it was
    /// loaded for, so a variant switch tears down the old pipe and
    /// reloads. Kept alive for the process lifetime per variant so we
    /// don't pay the Core ML compile cost twice for the same model.
    private static var pipe: WhisperKit?
    private static var pipeVariant: Variant?

    /// Per-variant in-flight download progress (0.0…1.0). Read by the
    /// HTTP `/api/whisper-local/status` poll so the React DownloadButton
    /// can paint the green progress fill. Absent key = not downloading.
    /// `nonisolated(unsafe)` because the swifter routes (background
    /// thread) only READ this; writes are funnelled through `MainActor`
    /// in `ensureModelReady`.
    nonisolated(unsafe) private static var inflightProgress: [String: Double] = [:]
    nonisolated(unsafe) private static var inflightLock = NSLock()

    nonisolated static func currentProgress(_ variant: Variant) -> Double? {
        inflightLock.lock(); defer { inflightLock.unlock() }
        return inflightProgress[variant.rawValue]
    }
    nonisolated static func allInflight() -> [String: Double] {
        inflightLock.lock(); defer { inflightLock.unlock() }
        return inflightProgress
    }
    nonisolated private static func setProgress(_ variant: Variant, _ value: Double?) {
        inflightLock.lock()
        if let v = value { inflightProgress[variant.rawValue] = v }
        else { inflightProgress.removeValue(forKey: variant.rawValue) }
        inflightLock.unlock()
    }

    // MARK: - Availability + model state

    /// Apple Silicon check. Core ML on Intel doesn't have the bf16 / ANE
    /// kernels these models rely on, so even if the package compiled the
    /// runtime cost would be unusable. Cheaper to fail fast. Marked
    /// `nonisolated` because it's a compile-time-constant arch check —
    /// no state, no I/O — so the off-MainActor Swifter handlers can
    /// read it without hopping for a thread context switch.
    nonisolated static func isAvailable() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Local existence check — true iff the variant's model directory
    /// contains the minimal set of files WhisperKit needs to load
    /// offline. We check for the audio encoder / text decoder Core ML
    /// packages by name; presence of the folder alone isn't enough
    /// because a partial download leaves the folder empty.
    nonisolated static func isModelDownloaded(_ variant: Variant) -> Bool {
        // 1. If a download is currently in flight, we are not "ready"
        // by definition — even if WhisperKit has already materialised
        // some of the required `.mlmodelc` folders, they may still be
        // empty/incomplete. The old logic flipped to true the instant
        // those folders appeared and bounced the UI to "ready" while
        // the bytes were still streaming in.
        if currentProgress(variant) != nil { return false }
        let dir = modelFolderURL(variant)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // 2. HuggingFace-Hub.swift writes `<file>.incomplete` markers
        // while it's downloading and removes them on success. If any
        // marker is still present anywhere in the model folder tree,
        // the download didn't finish.
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                if url.lastPathComponent.hasSuffix(".incomplete") { return false }
            }
        }
        // 3. Every variant publishes a full set of Core ML packages
        // and a config.json. Missing any of them = partial download.
        let required = [
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "config.json",
        ]
        for name in required {
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return false }
        }
        // 4. Each `.mlmodelc` package itself must contain its weights
        // / coremldata blobs — WhisperKit creates the package shell
        // first, then streams the bytes in. We assert the package is
        // non-empty as a final sanity check.
        for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            let pkg = dir.appendingPathComponent(name, isDirectory: true)
            let contents = (try? fm.contentsOfDirectory(atPath: pkg.path)) ?? []
            if contents.isEmpty { return false }
        }
        return true
    }

    /// Concrete on-disk URL for the variant's model folder under
    /// `<modelsDir>/models/argmaxinc/whisperkit-coreml/<variant>/`.
    /// WhisperKit's `download(...)` helper preserves the HuggingFace
    /// repo path AND adds an extra `models/` segment under whatever you
    /// pass as `downloadBase`, so the final folder lives **two** levels
    /// deeper than `downloadBase`, not one. Reflect that here so
    /// `isModelDownloaded` finds the bytes WhisperKit just wrote — the
    /// earlier single-segment path silently mis-reported every download
    /// as incomplete and bounced the UI back to "Download model" the
    /// instant the (no-op fast) re-download returned.
    nonisolated private static var downloadBaseURL: URL { AppPaths.modelsDir }
    nonisolated static func modelFolderURL(_ variant: Variant) -> URL {
        downloadBaseURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant.rawValue, isDirectory: true)
    }

    // MARK: - Public API

    /// Idempotent download + load for `variant`. Safe to call before
    /// every transcribe — when the model is already on disk it just
    /// spins up the WhisperKit instance (or no-ops if it's already
    /// running for THIS variant). Switching variants tears down the
    /// previous WhisperKit pipe and reloads. Progress is published to
    /// `currentProgress(variant)` so the React DownloadButton can poll.
    static func ensureModelReady(_ variant: Variant) async throws {
        guard isAvailable() else { throw LocalWhisperError.notAvailableOnIntel }
        try FileManager.default.createDirectory(at: AppPaths.modelsDir,
                                                withIntermediateDirectories: true)

        // Wait out any in-flight prewarm download for the same variant
        // before kicking our own — otherwise the launch-time prefetch
        // and a fast post-record transcribe end up calling
        // `WhisperKit.download` concurrently and racing on the same
        // model folder.
        if !isModelDownloaded(variant), currentProgress(variant) != nil {
            FileLogger.log("LocalWhisper: \(variant.rawValue) prewarm in flight — waiting")
            while currentProgress(variant) != nil {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        if !isModelDownloaded(variant) {
            FileLogger.log("LocalWhisper: model not on disk — downloading \(variant.rawValue) into \(downloadBaseURL.path)")
            setProgress(variant, 0.0)
            defer { setProgress(variant, nil) }
            do {
                _ = try await WhisperKit.download(
                    variant: variant.rawValue,
                    downloadBase: downloadBaseURL,
                    useBackgroundSession: false,
                    progressCallback: { progress in
                        let f = progress.totalUnitCount > 0
                            ? max(0.0, min(1.0, progress.fractionCompleted))
                            : 0.0
                        setProgress(variant, f)
                    }
                )
            } catch {
                FileLogger.log("LocalWhisper: download failed (\(variant.rawValue)) — \(error)")
                throw error
            }
            FileLogger.log("LocalWhisper: download complete (\(variant.rawValue))")
        }

        // Variant switch invalidates the cached WhisperKit instance.
        if pipe != nil, pipeVariant != variant {
            FileLogger.log("LocalWhisper: variant changed (\(pipeVariant?.rawValue ?? "?") → \(variant.rawValue)) — reloading")
            pipe = nil
            pipeVariant = nil
        }

        if pipe == nil {
            FileLogger.log("LocalWhisper: loading WhisperKit from \(modelFolderURL(variant).path)")
            // `download: true` so WhisperKit can fetch the tokenizer
            // sidecar (lives in the HF repo `openai/whisper-large-v3`,
            // not in `argmaxinc/whisperkit-coreml/<variant>` — they
            // ship the Core ML packages, not the text tokenizer).
            // Without it, init throws "Tokenizer configuration is
            // missing" on the very first transcribe. `WhisperKit.download`
            // is idempotent: model files already on disk are reused.
            let cfg = WhisperKitConfig(
                model: variant.rawValue,
                downloadBase: downloadBaseURL,
                modelFolder: modelFolderURL(variant).path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            do {
                pipe = try await WhisperKit(cfg)
                pipeVariant = variant
            } catch {
                throw LocalWhisperError.transcribeFailed("init failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pre-fetch a variant without immediately loading the WhisperKit
    /// instance. Used by the Settings UI's `Download model` button so
    /// the user can stage a model in the background while another
    /// variant is still active. Returns once the bytes are on disk;
    /// the actual WhisperKit init runs lazily on first transcribe.
    static func downloadOnly(_ variant: Variant) async throws {
        guard isAvailable() else { throw LocalWhisperError.notAvailableOnIntel }
        try FileManager.default.createDirectory(at: AppPaths.modelsDir,
                                                withIntermediateDirectories: true)
        if isModelDownloaded(variant) { return }
        setProgress(variant, 0.0)
        defer { setProgress(variant, nil) }
        FileLogger.log("LocalWhisper: pre-fetch \(variant.rawValue)")
        _ = try await WhisperKit.download(
            variant: variant.rawValue,
            downloadBase: downloadBaseURL,
            useBackgroundSession: false,
            progressCallback: { progress in
                let f = progress.totalUnitCount > 0
                    ? max(0.0, min(1.0, progress.fractionCompleted))
                    : 0.0
                setProgress(variant, f)
            }
        )
        FileLogger.log("LocalWhisper: pre-fetch complete (\(variant.rawValue))")
    }

    /// Whole-file transcription. Mirrors `WhisperTranscriber.transcribe`:
    /// VAD pre-pass → WhisperKit call → projection back onto the original
    /// timeline. Returns `[GeminiTranscriber.Turn]` so the rest of the
    /// pipeline stays provider-agnostic.
    static func transcribe(audioURL: URL,
                           mode: WMode,
                           variant: Variant,
                           initialPrompt: String?) async throws -> [GeminiTranscriber.Turn] {
        guard isAvailable() else { throw LocalWhisperError.notAvailableOnIntel }
        guard mode == .single else { throw LocalWhisperError.diarizeNotSupported }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw LocalWhisperError.missingFile(audioURL.path)
        }

        try await ensureModelReady(variant)
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
