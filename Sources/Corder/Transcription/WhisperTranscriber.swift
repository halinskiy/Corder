import Foundation
import AVFoundation

/// Cloud transcription provider built on top of OpenAI's audio API.
///
/// Stage 1 of the Whisper integration: cloud-only, no local MLX-Whisper
/// fallback yet. Drops in alongside `GeminiTranscriber` and produces the
/// same `[GeminiTranscriber.Turn]` shape, so the rest of the pipeline
/// (forced alignment, diarize-first re-labeling, mapping) is unchanged.
///
/// Why two endpoints depending on `mode`:
///   • `.single` uses `gpt-4o-mini-transcribe` — cheap, fast, no
///     diarization. Mic track + the in-person `.diarize` system case
///     (where on-device FluidAudio decides WHO) both ride this path.
///     The function still accepts `.diarize` to mirror the Gemini API
///     surface; in the current pipeline FluidAudio handles WHO, so the
///     pipeline always asks for `.single` regardless of provider.
///   • `.diarize` uses `gpt-4o-transcribe-diarize` — same endpoint, same
///     `verbose_json`, but the model emits speaker labels per segment.
///     Kept here as a forward-compatible option for a future "no
///     on-device diarizer" build.
///
/// Constraints we work around:
///   • OpenAI audio API caps single uploads at 25 MB. At 16 kHz mono
///     16-bit PCM that's ~13 minutes per chunk, so meetings longer than
///     that are split into ≤ 12-minute pieces and transcribed in series.
///   • The response shape is `segments: [{start, end, text, …}]` with
///     seconds (Double). We convert to (startMs, endMs) Int64 to match
///     `GeminiTranscriber.Turn`.
@MainActor
enum WhisperTranscriber {

    enum WMode {
        case single   // one speaker label "user"
        case diarize  // speaker-N labels via gpt-4o-transcribe-diarize
    }

    /// Backend that fulfils the upload. `openai` is the historical
    /// route (api.openai.com or our /transcribe/whisper proxy, whisper-1
    /// model, followed by gpt-4o-mini polish). `groq` swaps in Groq's
    /// hosted Whisper-large-v3-turbo at ~10× lower per-minute cost; the
    /// response shape is identical (OpenAI-compatible verbose_json),
    /// so chunking / VAD / parse logic stays unchanged — only the
    /// endpoint URL and model name flip.
    enum Backend {
        case openai
        case groq

        fileprivate var proxyPath: String {
            switch self {
            case .openai: return "https://corder-api.empqwork.workers.dev/transcribe/whisper"
            case .groq:   return "https://corder-api.empqwork.workers.dev/transcribe/groq"
            }
        }

        fileprivate var directEndpoint: String {
            // Direct (no-Supabase) path. Only `openai` keeps a direct
            // fallback for dev shells; `groq` always routes through the
            // worker (we don't expose a `groq_key` local override).
            switch self {
            case .openai: return "https://api.openai.com/v1/audio/transcriptions"
            case .groq:   return "https://corder-api.empqwork.workers.dev/transcribe/groq"
            }
        }

        fileprivate var modelName: String {
            switch self {
            case .openai: return "whisper-1"
            case .groq:   return "whisper-large-v3-turbo"
            }
        }
    }

    enum WhisperError: Error, LocalizedError {
        case noKey
        case missingFile(String)
        case apiFailure(status: Int, body: String)
        case parse(String)
        case quotaOrBilling(String)
        case network(String)
        case splitFailed(String)
        /// Worker proxy refused this user: signed in but the JWT's
        /// `app_metadata.tier` is not `pro` or `max`. Distinct from
        /// `apiFailure` so the pipeline can fall back to local Whisper
        /// silently instead of treating it as a real failure.
        case tierRequired

        var errorDescription: String? {
            switch self {
            case .noKey:                       return "OpenAI API key is not configured."
            case .missingFile(let p):          return "Audio file missing at \(p)."
            case .apiFailure(let s, let body): return "OpenAI API \(s): \(body.prefix(220))"
            case .parse:                       return "Could not parse OpenAI response."
            case .quotaOrBilling(let msg):     return msg
            case .network(let msg):            return msg
            case .splitFailed(let msg):        return "Whisper split failed: \(msg)"
            case .tierRequired:                return "Cloud models need Pro or Max."
            }
        }
    }

    // MARK: - Tunables

    /// OpenAI rejects audio uploads > 25 MB outright. We aim for a
    /// generous safety margin (`maxBytesPerChunk`) and convert that into
    /// a duration budget at the source-file's actual byte-rate, rather
    /// than guessing seconds-per-chunk. Recordings are 16 kHz mono 16-bit
    /// PCM in practice, so ~12 minutes / chunk fits comfortably under
    /// the cap with WAV header overhead.
    private static let maxBytesPerChunk: Int64 = 24 * 1024 * 1024
    private static let maxSecondsPerChunk: Double = 12 * 60

    /// VAD pre-pass thresholds, mirror `GeminiTranscriber`. Talk-heavy
    /// meetings sail through unchanged; idle mic tracks get squeezed.
    private static let vadMinSavings: Double = 0.10
    private static let vadEmptyFloorMs: Int64 = 500

    private static let endpoint = "https://api.openai.com/v1/audio/transcriptions"
    private static let proxyEndpoint = "https://corder-api.empqwork.workers.dev/transcribe/whisper"

    /// Serialises every Whisper HTTP call across the whole process.
    /// Background: TranscriptionPipeline fires mic + system tracks in
    /// parallel via `async let`, and each track produces multiple
    /// audio chunks. That trivially fires 4-6 simultaneous requests at
    /// OpenAI, which on Tier 1 instantly blows the per-minute audio
    /// TPM cap and gets back `insufficient_quota`. Single-flight here
    /// is the cheapest correct fix — we trade a few seconds of wall
    /// time for never tripping the limiter. Cleanup after Tier 2
    /// (50,000 → 500,000 TPM): bump the value or remove the gate.
    private static let inflight = WhisperInflightLimiter(maxConcurrent: 1)
    /// `whisper-1` is the only OpenAI ASR that returns
    /// `verbose_json` (= segment-level timestamps we need to project
    /// turns onto the original timeline). The newer `gpt-4o-transcribe`
    /// family only emits `json` / `text`, no timestamps — fine for a
    /// one-shot transcript but useless for our dual-track flow. Cost
    /// trade-off: $0.006/min vs $0.003/min — still ~60× cheaper than
    /// Gemini, so the upgrade is worth the timestamps.
    private static let modelSingle  = "whisper-1"
    /// Diarization-aware variant. Kept distinct so a future "no on-device
    /// diarizer" code path can ask for speaker labels without forking
    /// the API surface here. `gpt-4o-transcribe-diarize` does emit
    /// speaker labels but without segment timestamps in verbose_json,
    /// so we route diarize through `whisper-1` too and let the
    /// downstream `SpeakerDiarizer` (FluidAudio) attach labels.
    private static let modelDiarize = "whisper-1"

    // MARK: - Public API

    /// Whole-file transcription. Mirrors `GeminiTranscriber.transcribe`:
    /// VAD pre-pass → optional chunking → projection back onto the
    /// original timeline. Returns `GeminiTranscriber.Turn` so the rest
    /// of `TranscriptionPipeline` stays provider-agnostic.
    /// `localFallbackVariant`: when set AND that WhisperKit model is
    /// already on disk, a per-chunk network failure is recovered by
    /// transcribing JUST that chunk on-device instead of aborting the
    /// whole meeting. The cloud + local results stitch on the same
    /// (compressed) timeline, so when the connection drops mid-run the
    /// transcript keeps going from exactly where the cloud left off and
    /// later chunks transparently return to the cloud once it's back.
    /// We require the model to be ALREADY downloaded — the network just
    /// died, so we can't fetch a missing model — otherwise we rethrow
    /// the network error and the meeting fails as before.
    static func transcribe(audioURL: URL,
                           mode: WMode,
                           initialPrompt: String?,
                           backend: Backend = .openai,
                           localFallbackVariant: LocalWhisperTranscriber.Variant? = nil) async throws -> [GeminiTranscriber.Turn] {
        // Signed-in users go through the Worker proxy (server-side
        // OpenAI key). Only when there's no Supabase session do we
        // require the legacy local key — keeps `swift test` / dev
        // shells running without a sign-in.
        let signedIn = await Self.hasSupabaseSession()
        let key = apiKey ?? ""
        if !signedIn && key.isEmpty { throw WhisperError.noKey }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw WhisperError.missingFile(audioURL.path)
        }

        let durationSec = (try? audioDurationSeconds(audioURL: audioURL)) ?? 0
        let durationMs = Int64(durationSec * 1000)
        FileLogger.log("WhisperTranscriber: \(audioURL.lastPathComponent) duration ≈ \(Int(durationSec))s, mode=\(mode), backend=\(backend)")

        // VAD pre-pass. Same trade-off as Gemini: skip the upload entirely
        // if there's less than half a second of speech; otherwise compress
        // only when the savings clear the 10 % floor.
        let segments = VoiceActivityDetector.detect(audioURL: audioURL)
        let speechMs = segments.map { VoiceActivityDetector.totalSpeechMs($0) } ?? durationMs

        if let segs = segments, segs.isEmpty || speechMs < vadEmptyFloorMs {
            FileLogger.log("WhisperTranscriber: VAD found <\(vadEmptyFloorMs)ms of speech in \(audioURL.lastPathComponent), skipping upload")
            return []
        }

        let savingsRatio = durationMs > 0 ? 1.0 - Double(speechMs) / Double(durationMs) : 0.0
        let useVad = (segments != nil) && savingsRatio >= vadMinSavings

        let workURL: URL
        let projection: VoiceActivityDetector.Projection?
        let tmpDir: URL?

        if useVad, let segs = segments {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("corder-whisper-vad-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let concat = dir.appendingPathComponent("speech.wav")
            do {
                let proj = try VoiceActivityDetector.concatenateSpeech(audioURL: audioURL, segments: segs, outURL: concat)
                workURL = concat
                projection = proj
                tmpDir = dir
                FileLogger.log(String(format: "WhisperTranscriber: VAD compressed %ds → %ds (%.0f%% saved, %d segments)",
                                      Int(durationSec), Int(speechMs / 1000), savingsRatio * 100, segs.count))
            } catch {
                try? FileManager.default.removeItem(at: dir)
                FileLogger.log("WhisperTranscriber: VAD concat failed (\(error)) — falling back to original")
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

        let rawTurns: [GeminiTranscriber.Turn]
        do {
            rawTurns = try await transcribeChunkedIfNeeded(audioURL: workURL,
                                                            apiKey: key,
                                                            mode: mode,
                                                            initialPrompt: initialPrompt,
                                                            backend: backend,
                                                            localFallbackVariant: localFallbackVariant)
        } catch let urlErr as URLError where Self.isNetworkError(urlErr) {
            throw WhisperError.network("No internet — try again when you're online.")
        }

        // Project compressed timestamps back onto the original timeline
        // if VAD chopped silence out. Identical to the Gemini path.
        guard let proj = projection else { return rawTurns }
        let projected = rawTurns.map {
            GeminiTranscriber.Turn(speakerLabel: $0.speakerLabel,
                                   startMs: proj.toOriginal(compressedMs: $0.startMs),
                                   endMs: proj.toOriginal(compressedMs: $0.endMs),
                                   text: $0.text)
        }
        // Same monotonic clamp + reverse pass as Gemini: a turn near the
        // tail can over-shoot the real duration after projection; collapsing
        // it back to a strictly-increasing schedule inside the duration
        // bound keeps clicking the last line from jumping past EOF.
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

    // MARK: - Chunking

    /// Decide whether the work file fits in one upload, slice into
    /// duration-budgeted pieces if not, and stitch chunk timestamps back
    /// onto the (compressed) timeline. `projection` (if any) is applied
    /// by the caller after this returns.
    private static func transcribeChunkedIfNeeded(audioURL: URL,
                                                   apiKey: String,
                                                   mode: WMode,
                                                   initialPrompt: String?,
                                                   backend: Backend,
                                                   localFallbackVariant: LocalWhisperTranscriber.Variant? = nil) async throws -> [GeminiTranscriber.Turn] {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let durationSec = (try? audioDurationSeconds(audioURL: audioURL)) ?? 0

        // Compute chunk-seconds from the actual byte rate so the API's
        // 25 MB cap is respected regardless of sample-rate / bit-depth.
        let bytesPerSecond = durationSec > 0 ? Double(fileSize) / durationSec : 0
        var perChunkSec = maxSecondsPerChunk
        if bytesPerSecond > 0 {
            let byteBudgetSec = Double(maxBytesPerChunk) / bytesPerSecond
            perChunkSec = min(maxSecondsPerChunk, byteBudgetSec)
        }

        let fitsInOnePost = fileSize <= maxBytesPerChunk && durationSec <= maxSecondsPerChunk
        if fitsInOnePost {
            do {
                return try await transcribeSingle(audioURL: audioURL, apiKey: apiKey,
                                                  offsetMs: 0, mode: mode,
                                                  initialPrompt: initialPrompt,
                                                  backend: backend)
            } catch let urlErr as URLError where Self.isNetworkError(urlErr) {
                guard let turns = try await localChunkFallback(
                    chunkURL: audioURL, offsetMs: 0, variant: localFallbackVariant,
                    initialPrompt: initialPrompt, label: "single") else { throw urlErr }
                return turns
            }
        }

        FileLogger.log(String(format: "WhisperTranscriber: %ds / %.1f MB > limits — slicing into ≤%.0fs chunks",
                              Int(durationSec),
                              Double(fileSize) / (1024 * 1024),
                              perChunkSec))

        let chunkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corder-whisper-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chunkDir) }

        let chunks: [(url: URL, offsetMs: Int64)]
        do {
            chunks = try sliceWav(audioURL: audioURL, into: chunkDir, chunkSeconds: perChunkSec)
        } catch {
            throw WhisperError.splitFailed(String(describing: error))
        }
        FileLogger.log("WhisperTranscriber: sliced into \(chunks.count) chunks")

        var all: [GeminiTranscriber.Turn] = []
        all.reserveCapacity(chunks.count * 100)
        // Provider/mode tag for the resume cache so a re-transcribe with a
        // different provider never replays another model's chunk text.
        let cacheTag = "\(backend):\(mode)"
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            // Resume: if this exact chunk was already transcribed on a
            // prior (interrupted) run, reuse it and skip the upload. The
            // key is content-addressed (MD5 of the sliced WAV), so the
            // deterministic re-slice on the retry lines up byte-for-byte.
            let cacheKey = ChunkTranscriptCache.key(forChunkAt: chunk.url, tag: cacheTag)
            if let key = cacheKey, let cached = ChunkTranscriptCache.get(key) {
                FileLogger.log("WhisperTranscriber: chunk \(i + 1)/\(chunks.count) — resume cache hit, skipping upload")
                all.append(contentsOf: cached)
                continue
            }

            FileLogger.log("WhisperTranscriber: chunk \(i + 1)/\(chunks.count) (offset \(chunk.offsetMs)ms)…")
            let turns: [GeminiTranscriber.Turn]
            var fromLocalFallback = false
            do {
                turns = try await transcribeSingle(audioURL: chunk.url,
                                                   apiKey: apiKey,
                                                   offsetMs: chunk.offsetMs,
                                                   mode: mode,
                                                   initialPrompt: initialPrompt,
                                                   backend: backend)
            } catch let urlErr as URLError where Self.isNetworkError(urlErr) {
                // Connection dropped on THIS chunk — finish it on-device
                // and carry on. The next chunk retries the cloud first,
                // so the run drifts back to cloud the moment it returns.
                guard let local = try await localChunkFallback(
                    chunkURL: chunk.url, offsetMs: chunk.offsetMs,
                    variant: localFallbackVariant, initialPrompt: initialPrompt,
                    label: "chunk \(i + 1)/\(chunks.count)") else { throw urlErr }
                turns = local
                fromLocalFallback = true
            }
            // Persist immediately so a kill AFTER this chunk resumes here —
            // but ONLY cloud results. A locally-recovered chunk is cached
            // under the CLOUD key (cacheTag is backend:mode), so a later
            // all-cloud run would replay the lower-quality on-device text
            // for a chunk the user is paying to get from the cloud. Leaving
            // it uncached means the resume re-fetches it (cloud if back),
            // which is the correct quality/cost trade-off.
            if let key = cacheKey, !fromLocalFallback { ChunkTranscriptCache.put(key, turns) }
            all.append(contentsOf: turns)
        }
        FileLogger.log("WhisperTranscriber: stitched \(all.count) turns from \(chunks.count) chunks")
        return all
    }

    /// On-device recovery for ONE chunk whose cloud call hit a network
    /// error. Returns `nil` — telling the caller to rethrow the network
    /// error and fail as before — when recovery is impossible: no
    /// variant requested, not Apple Silicon, or the model isn't already
    /// on disk (the connection just dropped, so we can't download it).
    /// On success the chunk-local timestamps are shifted by `offsetMs`
    /// to line up with the cloud chunks on the shared timeline.
    private static func localChunkFallback(chunkURL: URL,
                                           offsetMs: Int64,
                                           variant: LocalWhisperTranscriber.Variant?,
                                           initialPrompt: String?,
                                           label: String) async throws -> [GeminiTranscriber.Turn]? {
        guard let variant else { return nil }
        guard LocalWhisperTranscriber.isAvailable() else { return nil }
        guard LocalWhisperTranscriber.isModelDownloaded(variant) else {
            FileLogger.log("WhisperTranscriber: \(label) network-failed but local model "
                + "\(variant.rawValue) not on disk — can't fall back offline")
            return nil
        }
        FileLogger.log("WhisperTranscriber: \(label) cloud network-failed → on-device fallback (\(variant.rawValue))")
        // Graceful: if on-device init/transcribe itself fails (e.g. the
        // tokenizer was never cached and we can't fetch it offline), we
        // return nil so the caller rethrows the ORIGINAL network error —
        // the meeting fails exactly as it would have without this path,
        // never worse, and never with a confusing local-model error.
        let local: [GeminiTranscriber.Turn]
        do {
            try await LocalWhisperTranscriber.ensureModelReady(variant)
            local = try await LocalWhisperTranscriber.transcribe(
                audioURL: chunkURL, mode: .single, variant: variant, initialPrompt: initialPrompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            FileLogger.log("WhisperTranscriber: \(label) on-device fallback failed (\(error)) — rethrowing network error")
            return nil
        }
        guard offsetMs != 0 else { return local }
        return local.map {
            GeminiTranscriber.Turn(speakerLabel: $0.speakerLabel,
                                   startMs: $0.startMs + offsetMs,
                                   endMs: $0.endMs + offsetMs,
                                   text: $0.text)
        }
    }

    // MARK: - Single HTTP call

    /// One multipart POST to /v1/audio/transcriptions. `offsetMs` shifts
    /// every returned timestamp onto the parent file's timeline (used by
    /// the chunked path).
    private static func transcribeSingle(audioURL: URL,
                                          apiKey: String,
                                          offsetMs: Int64,
                                          mode: WMode,
                                          initialPrompt: String?,
                                          backend: Backend) async throws -> [GeminiTranscriber.Turn] {
        // Gate every chunk through the process-wide inflight limiter.
        // Tier 1 audio TPM cap is what burns us on parallel requests;
        // single-flight keeps the rate predictable.
        try await inflight.run {
            try await transcribeSingleUnguarded(audioURL: audioURL,
                                                 apiKey: apiKey,
                                                 offsetMs: offsetMs,
                                                 mode: mode,
                                                 initialPrompt: initialPrompt,
                                                 backend: backend)
        }
    }

    private static func transcribeSingleUnguarded(audioURL: URL,
                                                   apiKey: String,
                                                   offsetMs: Int64,
                                                   mode: WMode,
                                                   initialPrompt: String?,
                                                   backend: Backend) async throws -> [GeminiTranscriber.Turn] {
        // Groq exposes only one Whisper variant per request — the
        // diarize-aware OpenAI endpoint doesn't exist there, so we
        // pin the model by backend rather than by mode. The pipeline
        // currently always passes `.single` regardless of provider
        // (FluidAudio decides WHO), so this doesn't change behaviour.
        let model: String = (backend == .openai && mode == .diarize)
            ? modelDiarize
            : backend.modelName

        // Resolve routing: if we have an active Supabase session we
        // ship the audio to our Cloudflare Worker — it holds the
        // OpenAI / Groq key server-side and gates by `app_metadata.tier`.
        // Otherwise we hit OpenAI directly with the user's local
        // key (the legacy path; still used during sign-out / dev).
        let route = await Self.resolveRoute(apiKey: apiKey, backend: backend)

        let boundary = "----CorderWhisperBoundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: route.endpoint)!)
        req.httpMethod = "POST"
        req.setValue(route.authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Report this chunk's audio length so the Worker can meter monthly
        // cloud usage per tier. Best-effort: 0 means "don't count" — the
        // server fails open and never blocks on a missing/zero value.
        let chunkSec = (try? audioDurationSeconds(audioURL: audioURL)) ?? 0
        if chunkSec > 0 {
            req.setValue(String(Int(chunkSec.rounded())), forHTTPHeaderField: "X-Corder-Audio-Sec")
        }
        req.timeoutInterval = 600

        var body = Data()
        func appendFormField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        func appendFileField(name: String, filename: String, contentType: String, data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        let audioBytes = try Data(contentsOf: audioURL)
        appendFileField(name: "file",
                        filename: audioURL.lastPathComponent,
                        contentType: "audio/wav",
                        data: audioBytes)
        appendFormField(name: "model", value: model)
        appendFormField(name: "response_format", value: "verbose_json")
        // verbose_json sometimes omits segment-level breakdowns unless we
        // explicitly ask for them via timestamp_granularities.
        appendFormField(name: "timestamp_granularities[]", value: "segment")
        if let prompt = initialPrompt, !prompt.isEmpty {
            appendFormField(name: "prompt", value: prompt)
        }
        // Forced language (ISO-639-1) when the user pinned one. Empty =
        // let Whisper auto-detect. Read directly off AppSettings (a
        // nonisolated UserDefaults read) rather than threading it through
        // five chunking call-frames. Stops the Russian→Ukrainian drift.
        let forcedLang = AppSettings.transcriptionLanguage
        if !forcedLang.isEmpty {
            appendFormField(name: "language", value: forcedLang)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        // Retry rate-limit hits (429) with exponential backoff. OpenAI
        // Tier 1 limits audio API to 3 RPM; with two parallel tracks
        // and per-track chunking, our dual-track flow can fire 4-6
        // requests in one second and instantly trip the limiter. Real
        // billing exhaustion (402, or 429 with body.error.code
        // == "insufficient_quota") still throws immediately via
        // throwIfBilling so we don't waste retries on a dead key.
        var data = Data()
        var resp: URLResponse?
        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            let (d, r) = try await URLSession.shared.data(for: req)
            data = d
            resp = r
            let status = (r as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: d, encoding: .utf8) ?? ""
            let isRateLimit = (status == 429) && !bodyText.contains("insufficient_quota")
            // Transient upstream/proxy errors (Cloudflare Worker cold start,
            // OpenAI 5xx blip) were treated as PERMANENT and failed the
            // meeting. Retry them with the same backoff as 429.
            let isTransientServer = (status == 502 || status == 503 || status == 504)
                || (status == 500 && bodyText.isEmpty)
            if !isRateLimit && !isTransientServer { break }
            if attempt == maxAttempts { break }
            // Respect Retry-After header when present, otherwise
            // exponential backoff (1s, 2s, 4s, 8s).
            let headerWait = (r as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init) ?? 0
            let waitSec = max(headerWait, pow(2.0, Double(attempt - 1)))
            FileLogger.log("WhisperTranscriber: \(status) \(isRateLimit ? "rate-limit" : "transient server"), retry \(attempt)/\(maxAttempts - 1) after \(waitSec)s")
            try await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
        }
        try throwIfBilling(http: resp, data: data)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            FileLogger.log("WhisperTranscriber: HTTP \(status) — \(bodyText.prefix(300))")
            // Worker's tier-gate (403 + "tier required") is a known
            // expected condition for free-tier users who somehow ended
            // up with a cloud-provider preference (legacy account
            // downgrade, manual UserDefaults edit). Surface a dedicated
            // error case so the pipeline can fall back to whisperLocal
            // silently instead of treating it as a real failure.
            // Same silent-fallback path for the server-side monthly cap
            // backstop ("monthly_limit"): the Worker says this paid user is
            // over their hidden cloud-hours cap, so use the on-device model
            // for the rest of the month instead of failing the meeting.
            if status == 403 && (bodyText.lowercased().contains("tier required")
                                 || bodyText.lowercased().contains("monthly_limit")) {
                throw WhisperError.tierRequired
            }
            throw WhisperError.apiFailure(status: status, body: bodyText)
        }

        let parsed = try parseVerboseJSON(data: data, mode: mode)
        FileLogger.log("WhisperTranscriber: produced \(parsed.count) turns from \(audioURL.lastPathComponent)")
        guard offsetMs != 0 else { return parsed }
        return parsed.map {
            GeminiTranscriber.Turn(speakerLabel: $0.speakerLabel,
                                   startMs: $0.startMs + offsetMs,
                                   endMs: $0.endMs + offsetMs,
                                   text: $0.text)
        }
    }

    // MARK: - Response parsing

    /// Decode OpenAI's `verbose_json` into `[GeminiTranscriber.Turn]`.
    /// Shape (relevant fields):
    ///   { "text": "...", "segments": [
    ///       { "id": 0, "start": 0.0, "end": 4.2, "text": "...",
    ///         "speaker": "speaker-1" /* diarize only */ } ] }
    /// `start` / `end` are seconds (Double). We round to ms.
    /// For `.single` mode every speaker label is forced to `"user"`.
    /// For `.diarize` mode we trust whatever the model put in `speaker`,
    /// falling back to `"speaker-1"` so downstream label remapping
    /// always has something to key on.
    private static func parseVerboseJSON(data: Data, mode: WMode) throws -> [GeminiTranscriber.Turn] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperError.parse("non-JSON response")
        }
        // If `segments` is missing the model returned text-only verbose
        // JSON (no per-segment breakdown). Fall back to one turn covering
        // the whole clip so we don't silently lose the transcript.
        guard let segs = json["segments"] as? [[String: Any]] else {
            if let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                let durationSec = (json["duration"] as? Double) ?? 0
                let endMs = Int64(durationSec * 1000)
                FileLogger.log("WhisperTranscriber: response had no segments — collapsing to one turn")
                let label = (mode == .single) ? "user" : "speaker-1"
                return [.init(speakerLabel: label, startMs: 0, endMs: endMs, text: text)]
            }
            throw WhisperError.parse("response missing segments + text")
        }

        var out: [GeminiTranscriber.Turn] = []
        out.reserveCapacity(segs.count)
        for s in segs {
            let text = (s["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            guard !Hallucinations.isHallucination(text) else {
                FileLogger.log("WhisperTranscriber: dropping hallucination: \(text)")
                continue
            }
            let startSec = (s["start"] as? Double) ?? 0
            let endSec = (s["end"] as? Double) ?? startSec
            let speaker: String
            switch mode {
            case .single:
                speaker = "user"
            case .diarize:
                speaker = (s["speaker"] as? String)?
                    .trimmingCharacters(in: .whitespaces).nilIfEmpty
                    ?? "speaker-1"
            }
            out.append(GeminiTranscriber.Turn(
                speakerLabel: speaker,
                startMs: Int64(startSec * 1000),
                endMs: Int64(endSec * 1000),
                text: text))
        }
        return out
    }

    // MARK: - Hallucination filter

    // Hallucination filtering lives in the shared `Hallucinations` helper.

    // MARK: - Audio helpers

    private static func audioDurationSeconds(audioURL: URL) throws -> Double {
        let file = try AVAudioFile(forReading: audioURL)
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }

    /// Same slice routine as `GeminiTranscriber.sliceWav`, copied locally
    /// to keep this provider self-contained (the Gemini one is private).
    /// Slices the input WAV into `chunkSeconds`-long pieces; the last
    /// piece may be shorter. Returns absolute file URLs paired with the
    /// time offset (in ms) on the original timeline.
    private static func sliceWav(audioURL: URL, into dir: URL, chunkSeconds: Double) throws -> [(url: URL, offsetMs: Int64)] {
        let inFile = try AVAudioFile(forReading: audioURL)
        let format = inFile.processingFormat
        let totalFrames = inFile.length
        let sampleRate = format.sampleRate
        let chunkFrames = AVAudioFramePosition(sampleRate * chunkSeconds)

        var out: [(url: URL, offsetMs: Int64)] = []
        var pos: AVAudioFramePosition = 0
        var idx = 0
        while pos < totalFrames {
            let remaining = totalFrames - pos
            let n = AVAudioFrameCount(min(chunkFrames, remaining))
            inFile.framePosition = pos
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            try inFile.read(into: buf, frameCount: n)
            let chunkURL = dir.appendingPathComponent("wchunk-\(idx).wav")
            let outFile = try AVAudioFile(forWriting: chunkURL,
                                          settings: format.settings,
                                          commonFormat: format.commonFormat,
                                          interleaved: format.isInterleaved)
            try outFile.write(from: buf)
            let offsetMs = Int64(Double(pos) / sampleRate * 1000.0)
            out.append((url: chunkURL, offsetMs: offsetMs))
            pos += AVAudioFramePosition(n)
            idx += 1
        }
        return out
    }

    // MARK: - Errors / network

    private static func isNetworkError(_ err: URLError) -> Bool {
        switch err.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Surface 402 / "insufficient_quota" as a typed billing error
    /// so the UI can show "OpenAI quota exhausted" instead of a raw
    /// 4xx. Plain 429 is NOT billing (rate-limit, retried in
    /// `postChunk`). Only 402, 401, or a body whose `error.code`
    /// literally equals "insufficient_quota" trips this.
    private static func throwIfBilling(http: URLResponse?, data: Data) throws {
        guard let h = http as? HTTPURLResponse else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        if h.statusCode == 402 {
            FileLogger.log("WhisperTranscriber: 402 body — \(body.prefix(500))")
            throw WhisperError.quotaOrBilling("OpenAI quota exhausted (402). Top up the API project's billing.")
        }
        // Strict check — only treat body as billing when it carries the
        // OpenAI-defined error code "insufficient_quota". The previous
        // loose `body.contains(...)` matched help-text references to
        // the same string in unrelated errors.
        if isInsufficientQuotaBody(body) {
            FileLogger.log("WhisperTranscriber: insufficient_quota — \(body.prefix(500))")
            throw WhisperError.quotaOrBilling("OpenAI quota exhausted. Top up the API project's billing.")
        }
        if h.statusCode == 401 {
            FileLogger.log("WhisperTranscriber: 401 body — \(body.prefix(500))")
            throw WhisperError.quotaOrBilling("OpenAI API key rejected (401). Check ~/.config/corder/openai_key.")
        }
    }

    /// True iff the response JSON has `error.code == "insufficient_quota"`.
    /// Avoids false-positives from message text mentioning the literal.
    private static func isInsufficientQuotaBody(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let code = err["code"] as? String else {
            return false
        }
        return code == "insufficient_quota"
    }

    // MARK: - API key

    /// Legacy `~/.config/corder/openai_key` and `$OPENAI_API_KEY`
    /// reads are gone — production goes through the Cloudflare
    /// Worker proxy (`/transcribe/whisper`) with the user's Supabase
    /// JWT. Returning nil here funnels every direct-to-OpenAI code
    /// path into the existing noKey fallback that re-routes the run
    /// to `whisperLocal`. We keep the property so call-sites stay
    /// stable.
    static var apiKey: String? { nil }

    /// Route resolver: prefer the Cloudflare Worker proxy (server
    /// key, JWT auth, tier-gated) when the user is signed in.
    /// Otherwise the legacy direct-to-OpenAI path with whichever
    /// local key the caller already loaded.
    private struct Route {
        let endpoint: String
        let authHeader: String
    }
    private static func resolveRoute(apiKey: String, backend: Backend = .openai) async -> Route {
        let jwt = await Self.currentJWT()
        if !jwt.isEmpty {
            return Route(endpoint: backend.proxyPath, authHeader: "Bearer \(jwt)")
        }
        // No-session fallback: only `openai` keeps a direct path with a
        // user-supplied key. `groq` always goes through the worker —
        // we don't ship a local Groq-key field on purpose (key hygiene).
        return Route(endpoint: backend.directEndpoint, authHeader: "Bearer \(apiKey)")
    }

    /// Pulls the current Supabase access token off the main actor.
    /// The Supabase SDK's session accessor is async; we wrap in
    /// `try?` so a signed-out build just returns "".
    private static func currentJWT() async -> String {
        await MainActor.run { _currentJWTSync() }
    }
    @MainActor
    private static func _currentJWTSync() -> String {
        SupabaseClientHolder.shared.auth.currentSession?.accessToken ?? ""
    }
    private static func hasSupabaseSession() async -> Bool {
        await !Self.currentJWT().isEmpty
    }
}

/// Process-wide concurrency gate for Whisper API calls. OpenAI Tier 1
/// audio TPM ceiling is low enough that dual-track + chunking blows
/// it on the first burst of parallel requests. Serialising to one
/// in-flight at a time costs ~2 seconds per chunk but keeps every
/// chunk under the limiter. After the org auto-upgrades to Tier 2
/// (≥ $50 cumulative spend) the cap rises ~10× and this gate can be
/// relaxed or removed.
actor WhisperInflightLimiter {
    private let semaphore: AsyncSemaphore
    init(maxConcurrent: Int) {
        self.semaphore = AsyncSemaphore(value: maxConcurrent)
    }
    func run<T>(_ work: () async throws -> T) async rethrows -> T {
        await semaphore.wait()
        // Release the permit STRUCTURALLY (awaited), not in a detached
        // `Task`. The old `defer { Task { … } }` released asynchronously
        // after `run` returned, so a back-to-back caller could reach
        // `wait()` before the prior `signal()` Task was scheduled — briefly
        // exceeding maxConcurrent=1, the exact TPM gate this exists to hold.
        do {
            let result = try await work()
            await semaphore.signal()
            return result
        } catch {
            await semaphore.signal()
            throw error
        }
    }
}

/// Async-friendly counting semaphore.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(value: Int) { self.permits = value }
    func wait() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }
    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
