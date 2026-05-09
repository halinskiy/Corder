import Foundation
import AVFoundation

/// Cloud transcription provider built on top of Gemini 2.5 Flash.
///
/// Pipeline contract:
///   1. Upload `audio.wav` to Google File API (inline base64 only works up
///      to ~20 MB, our hour-long meetings are bigger).
///   2. Poll the file resource until `state == "ACTIVE"`.
///   3. POST `:generateContent` with a system instruction asking for
///      structured JSON: speaker label + millisecond timestamps + text.
///   4. Decode and return.
///
/// We do NOT do diarization separately — Gemini already labels speakers in
/// arrival order (Speaker 1, Speaker 2…). The pipeline maps "is this user
/// or the remote side?" with our existing channel-gate (mic RMS vs system
/// RMS per segment), reusing logic from `Diarizer`.
enum GeminiTranscriber {

    enum GError: Error, LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case parse(String)
        case fileNeverActivated
        case quotaOrBilling(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:           return "Gemini API key is not configured."
            case .http(let s, let body):   return "Gemini API \(s): \(body.prefix(220))"
            // The raw JSON returned by Gemini can be tens of KB — never
            // dump it into a UI toast. The user only needs the headline;
            // the full body is in /tmp/corder.log.
            case .parse:                   return "Could not parse Gemini response."
            case .fileNeverActivated:      return "Gemini did not finish processing the uploaded audio."
            case .quotaOrBilling(let msg): return msg
            case .network(let msg):        return msg
            }
        }
    }

    struct Turn: Codable {
        /// Raw Gemini label, e.g. "Speaker 1". The pipeline decides what
        /// physical speaker this maps to (user vs other-N).
        let speakerLabel: String
        let startMs: Int64
        let endMs: Int64
        let text: String

        enum CodingKeys: String, CodingKey {
            case speakerLabel = "speaker"
            case startMs = "start_ms"
            case endMs = "end_ms"
            case text
        }
    }

    private static let model = "gemini-2.5-flash"
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta"

    /// Tells the prompt builder how to label speakers in the output.
    /// `single` — there's exactly one speaker (mic.wav of the local user).
    /// `diarize` — multiple speakers possible, label them in arrival order
    /// (system.wav of the remote side, where there might be 1, 2 or 5 people).
    enum TranscribeMode {
        case single
        case diarize
    }

    /// Above this duration we slice the audio into smaller pieces and
    /// transcribe each separately. Gemini 2.5 Flash caps output at 65 536
    /// tokens; a verbatim hour-long Russian/English transcript easily blows
    /// past that and the JSON returns truncated mid-segment, killing the
    /// parser. 9 minutes / chunk gives ~50–55 k tokens of segment JSON in
    /// the worst dense-talk case, leaving headroom.
    private static let maxSecondsPerChunk: Double = 9 * 60

    /// Below this savings ratio (compressed/original) the VAD pre-pass
    /// is a wash — extra disk I/O without meaningful API savings — and
    /// we just send the original. Tuned so that talk-heavy meetings
    /// fall through unchanged while idle mic tracks (lots of "I'm
    /// listening to my friend") get squeezed.
    private static let vadMinSavings: Double = 0.10
    /// If a file's total speech duration is below this, we don't even
    /// upload — just return zero turns. Catches "I forgot to talk into
    /// the mic" and "the system stream had no audible app".
    private static let vadEmptyFloorMs: Int64 = 500

    /// Whole-file transcription. Runs a VAD pre-pass to drop long silent
    /// stretches before upload (saves Gemini tokens), then delegates to
    /// the legacy single/chunked path on the speech-only audio. Returned
    /// turns are projected back onto the original timeline so callers
    /// see timestamps in their input file's frame, not the compressed one.
    ///
    /// Throws `GError.quotaOrBilling` for 402 / 429 / RESOURCE_EXHAUSTED,
    /// `GError.network` for connectivity drops.
    static func transcribe(audioURL: URL, mode: TranscribeMode = .diarize) async throws -> [Turn] {
        guard let key = apiKey else { throw GError.missingAPIKey }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw GError.parse("audio file missing at \(audioURL.path)")
        }

        let durationSec = (try? audioDurationSeconds(audioURL: audioURL)) ?? 0
        let durationMs = Int64(durationSec * 1000)
        FileLogger.log("GeminiTranscriber: \(audioURL.lastPathComponent) duration ≈ \(Int(durationSec))s, mode=\(mode)")

        // VAD pre-pass. On read failure we fall through to "transcribe the
        // original" rather than failing the meeting — VAD is an
        // optimisation, not a correctness requirement.
        let segments = VoiceActivityDetector.detect(audioURL: audioURL)
        let speechMs = segments.map { VoiceActivityDetector.totalSpeechMs($0) } ?? durationMs

        if let segs = segments, segs.isEmpty || speechMs < vadEmptyFloorMs {
            FileLogger.log("GeminiTranscriber: VAD found <\(vadEmptyFloorMs)ms of speech in \(audioURL.lastPathComponent), skipping upload")
            return []
        }

        // Decide whether to actually use VAD output. If the savings are
        // tiny (talk-heavy meeting), we'd be paying disk I/O for ~0% API
        // benefit — pass the original through.
        let savingsRatio = durationMs > 0 ? 1.0 - Double(speechMs) / Double(durationMs) : 0.0
        let useVad = (segments != nil) && savingsRatio >= vadMinSavings

        let workURL: URL
        let projection: VoiceActivityDetector.Projection?
        let tmpDir: URL?

        if useVad, let segs = segments {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("corder-vad-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let concat = dir.appendingPathComponent("speech.wav")
            do {
                let proj = try VoiceActivityDetector.concatenateSpeech(audioURL: audioURL, segments: segs, outURL: concat)
                workURL = concat
                projection = proj
                tmpDir = dir
                FileLogger.log(String(format: "GeminiTranscriber: VAD compressed %ds → %ds (%.0f%% saved, %d segments)",
                                      Int(durationSec), Int(speechMs / 1000), savingsRatio * 100, segs.count))
            } catch {
                // Concatenation failed — bail out of VAD, transcribe the
                // original. Disk full / quota race / corrupt frame read.
                try? FileManager.default.removeItem(at: dir)
                FileLogger.log("GeminiTranscriber: VAD concat failed (\(error)) — falling back to original")
                workURL = audioURL
                projection = nil
                tmpDir = nil
            }
        } else {
            if segments != nil {
                FileLogger.log(String(format: "GeminiTranscriber: VAD savings %.0f%% < threshold, sending original",
                                      savingsRatio * 100))
            } else {
                FileLogger.log("GeminiTranscriber: VAD read failed, sending original")
            }
            workURL = audioURL
            projection = nil
            tmpDir = nil
        }
        defer {
            if let dir = tmpDir {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        let workDuration = (try? audioDurationSeconds(audioURL: workURL)) ?? durationSec

        let rawTurns: [Turn]
        do {
            if workDuration <= maxSecondsPerChunk {
                rawTurns = try await transcribeSingle(audioURL: workURL, apiKey: key, offsetMs: 0, mode: mode)
            } else {
                rawTurns = try await transcribeChunked(audioURL: workURL, durationSec: workDuration, apiKey: key, mode: mode)
            }
        } catch let urlErr as URLError where Self.isNetworkError(urlErr) {
            throw GError.network("No internet — try again when you're online.")
        }

        // No projection needed when we sent the original through.
        guard let proj = projection else { return rawTurns }
        return rawTurns.map {
            Turn(speakerLabel: $0.speakerLabel,
                 startMs: proj.toOriginal(compressedMs: $0.startMs),
                 endMs: proj.toOriginal(compressedMs: $0.endMs),
                 text: $0.text)
        }
    }

    /// Single upload + generate pass. `offsetMs` is added to every turn's
    /// timestamps — used by the chunked path to shift sub-recordings back
    /// onto the original timeline.
    private static func transcribeSingle(audioURL: URL, apiKey: String, offsetMs: Int64, mode: TranscribeMode) async throws -> [Turn] {
        FileLogger.log("GeminiTranscriber: uploading \(audioURL.lastPathComponent)…")
        let fileURI = try await uploadFile(audioURL: audioURL, apiKey: apiKey)
        FileLogger.log("GeminiTranscriber: file uri=\(fileURI)")

        defer {
            // Best-effort delete so the file doesn't sit on Google for 48 h.
            Task.detached {
                try? await deleteFile(fileURI: fileURI, apiKey: apiKey)
            }
        }

        try await waitForActive(fileURI: fileURI, apiKey: apiKey)
        let turns = try await generate(fileURI: fileURI, apiKey: apiKey, mode: mode)
        FileLogger.log("GeminiTranscriber: produced \(turns.count) turns from \(audioURL.lastPathComponent)")
        guard offsetMs != 0 else { return turns }
        return turns.map {
            Turn(speakerLabel: $0.speakerLabel,
                 startMs: $0.startMs + offsetMs,
                 endMs: $0.endMs + offsetMs,
                 text: $0.text)
        }
    }

    /// Long-audio path: slice into ≤`maxSecondsPerChunk`-pieces,
    /// transcribe each, concatenate. Speaker labels stay per-Gemini-chunk
    /// ("Speaker 1", "Speaker 2") — we keep them as-is and rely on the
    /// upstream channel-gate (mic vs system RMS) per-segment to decide
    /// which label belongs to the local user. That heuristic is
    /// per-turn, so it doesn't matter whether two chunks both call the
    /// user "Speaker 1" or one calls them "Speaker 1" and another
    /// "Speaker 2".
    ///
    /// If a single chunk's response gets JSON-truncated (very dense
    /// speech, multiple speakers in 9 minutes — output blows past
    /// Gemini's 65 k-token cap mid-segment), we transparently split
    /// THAT chunk in half and retry. Recursion keeps halving until
    /// either success or `minSecondsPerChunk` — at which point we
    /// surface the parse error to the pipeline.
    private static func transcribeChunked(audioURL: URL, durationSec: Double, apiKey: String, mode: TranscribeMode) async throws -> [Turn] {
        let chunkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corder-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chunkDir) }

        let chunks = try sliceWav(audioURL: audioURL, into: chunkDir, chunkSeconds: maxSecondsPerChunk)
        FileLogger.log("GeminiTranscriber: sliced into \(chunks.count) chunks (×\(Int(maxSecondsPerChunk))s)")

        var all: [Turn] = []
        all.reserveCapacity(chunks.count * 200)
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            FileLogger.log("GeminiTranscriber: chunk \(i + 1)/\(chunks.count) (offset \(chunk.offsetMs)ms)…")
            let turns = try await transcribeChunkWithSplit(
                audioURL: chunk.url, offsetMs: chunk.offsetMs, apiKey: apiKey, depth: 0, mode: mode)
            all.append(contentsOf: turns)
        }
        FileLogger.log("GeminiTranscriber: stitched \(all.count) turns from \(chunks.count) chunks")
        return all
    }

    /// One chunk, with auto-halve-on-truncation. `depth` caps recursion
    /// so a hard parse failure on tiny chunks bubbles up instead of
    /// looping forever.
    private static let maxSplitDepth = 3
    private static let minSecondsPerSplit: Double = 60   // 1 min floor
    private static func transcribeChunkWithSplit(audioURL: URL, offsetMs: Int64, apiKey: String, depth: Int, mode: TranscribeMode) async throws -> [Turn] {
        do {
            return try await transcribeSingle(audioURL: audioURL, apiKey: apiKey, offsetMs: offsetMs, mode: mode)
        } catch let err as GError {
            // Only retry on the truncation pattern; quota / billing /
            // network errors should fail fast and propagate.
            guard case .parse = err else { throw err }
            let dur = (try? audioDurationSeconds(audioURL: audioURL)) ?? 0
            guard depth < maxSplitDepth, dur > minSecondsPerSplit * 2 else { throw err }

            FileLogger.log("GeminiTranscriber: parse error on \(Int(dur))s chunk @ depth \(depth), splitting in half…")
            let halfDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("corder-split-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: halfDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: halfDir) }
            let halves = try sliceWav(audioURL: audioURL, into: halfDir, chunkSeconds: dur / 2)
            var out: [Turn] = []
            for (i, h) in halves.enumerated() {
                try Task.checkCancellation()
                FileLogger.log("GeminiTranscriber: split \(i + 1)/\(halves.count) (depth \(depth + 1))…")
                let turns = try await transcribeChunkWithSplit(
                    audioURL: h.url, offsetMs: offsetMs + h.offsetMs, apiKey: apiKey, depth: depth + 1, mode: mode)
                out.append(contentsOf: turns)
            }
            return out
        }
    }

    private static func audioDurationSeconds(audioURL: URL) throws -> Double {
        let file = try AVAudioFile(forReading: audioURL)
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }

    /// Slice the input WAV into `chunkSeconds`-long pieces. The last piece
    /// may be shorter. Returns absolute file URLs paired with the time
    /// offset (in ms) the piece occupies on the original timeline.
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
            let chunkURL = dir.appendingPathComponent("chunk-\(idx).wav")
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

    /// Connection-loss URLErrors. Distinct from quota / billing so the UI
    /// can show "no internet" instead of "out of credits".
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

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        let path = ("~/.config/corder/gemini_key" as NSString).expandingTildeInPath
        if let data = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - File upload (resumable, single-chunk)

    private static func uploadFile(audioURL: URL, apiKey: String) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let displayName = audioURL.lastPathComponent

        // Step 1: open a resumable session.
        // The File API resumable endpoint sits under `/upload/v1beta/files`,
        // NOT `/v1beta/files`. Without the `/upload/` prefix and the
        // `Protocol: resumable` + `Command: start` header pair, Google
        // happily returns 200 with an empty body and no `X-Goog-Upload-URL`
        // header — the previous code path was failing here every time.
        let startURL = URL(string: "\(endpoint.replacingOccurrences(of: "/v1beta", with: "/upload/v1beta"))/files?key=\(apiKey)")!
        var startReq = URLRequest(url: startURL)
        startReq.httpMethod = "POST"
        startReq.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startReq.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startReq.setValue("\(size)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startReq.setValue("audio/wav", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let startBody: [String: Any] = ["file": ["display_name": displayName]]
        startReq.httpBody = try JSONSerialization.data(withJSONObject: startBody)

        let (startData, startResp) = try await URLSession.shared.data(for: startReq)
        try throwIfBilling(http: startResp, data: startData)
        guard let httpStart = startResp as? HTTPURLResponse,
              (200..<300).contains(httpStart.statusCode),
              let uploadURL = httpStart.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            let bodyPreview = String(data: startData, encoding: .utf8) ?? ""
            throw GError.http((startResp as? HTTPURLResponse)?.statusCode ?? 0,
                              "no X-Goog-Upload-URL — \(bodyPreview)")
        }

        // Step 2: upload bytes and finalize in one shot.
        let bytes = try Data(contentsOf: audioURL)
        var putReq = URLRequest(url: URL(string: uploadURL)!)
        putReq.httpMethod = "POST"
        putReq.setValue("\(size)", forHTTPHeaderField: "Content-Length")
        putReq.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        putReq.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        putReq.timeoutInterval = 600
        putReq.httpBody = bytes

        let (putData, putResp) = try await URLSession.shared.data(for: putReq)
        try throwIfBilling(http: putResp, data: putData)
        guard let httpPut = putResp as? HTTPURLResponse,
              (200..<300).contains(httpPut.statusCode) else {
            throw GError.http((putResp as? HTTPURLResponse)?.statusCode ?? 0,
                              String(data: putData, encoding: .utf8) ?? "")
        }

        // Response: { "file": { "name": "files/abc123", "uri": "https://...", "state": "PROCESSING", … } }
        guard let json = try JSONSerialization.jsonObject(with: putData) as? [String: Any],
              let file = json["file"] as? [String: Any],
              let uri = file["uri"] as? String else {
            throw GError.parse("upload response missing file.uri: \(String(data: putData, encoding: .utf8)?.prefix(220) ?? "")")
        }
        return uri
    }

    private static func waitForActive(fileURI: String, apiKey: String) async throws {
        // Poll the file resource. The fileURI we got back is the public download
        // URL, but the file resource for status lives under /files/{name} —
        // strip and rebuild.
        let name = (fileURI as NSString).lastPathComponent  // "abc123"
        let statusURL = URL(string: "\(endpoint)/files/\(name)?key=\(apiKey)")!

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            var req = URLRequest(url: statusURL)
            req.httpMethod = "GET"
            let (data, resp) = try await URLSession.shared.data(for: req)
            try throwIfBilling(http: resp, data: data)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = json["state"] as? String {
                if state == "ACTIVE" { return }
                if state == "FAILED" {
                    throw GError.parse("Gemini file processing FAILED")
                }
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 s
        }
        throw GError.fileNeverActivated
    }

    // MARK: - Generation

    private static func generate(fileURI: String, apiKey: String, mode: TranscribeMode) async throws -> [Turn] {
        let url = URL(string: "\(endpoint)/models/\(model):generateContent?key=\(apiKey)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        // Two prompt variants. The single-speaker one (mic.wav) is much
        // stricter about silence handling — it's the path that used to
        // hallucinate viticulture monologues during the user's quiet
        // moments. The diarize one is for the remote-side feed.
        let speakerRule: String
        switch mode {
        case .single:
            speakerRule = """
            - This audio is one person speaking — always label them "Speaker 1". Never invent additional speakers.
            """
        case .diarize:
            speakerRule = """
            - Identify each distinct speaker and label them in arrival order: "Speaker 1", "Speaker 2", "Speaker 3", and so on. Reuse the same label every time the same person speaks.
            """
        }
        let system = """
        You are a meeting transcription system. Listen to the audio and produce a verbatim transcript.
        \(speakerRule)
        - Preserve the original language of each segment. Russian stays Russian, English stays English. Do NOT translate.
        - Restore correct punctuation and capitalisation.
        - Drop only obvious filler / stutters (uh, um, ну, э-э) when they carry no meaning.
        - One segment per natural speech turn. Aim for 3-15 seconds per segment.
        - CRITICAL: If a stretch of audio contains no clearly intelligible speech — silence, breathing, mouse clicks, keyboard, music, traffic noise, fan hum, microphone bumps — output NO segment for that stretch. Do NOT invent text. Do NOT fill silence with poetry, weather, geography, viticulture, song lyrics, or anything else. Better to output an empty segments array than to hallucinate.
        - Output STRICT JSON only — no markdown, no prose around it.

        Output schema:
        {
          "segments": [
            {
              "speaker": "Speaker 1",
              "start_ms": 0,
              "end_ms": 4200,
              "text": "..."
            }
          ]
        }
        """

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": system]]
            ],
            "contents": [[
                "role": "user",
                "parts": [
                    ["fileData": [
                        "mimeType": "audio/wav",
                        "fileUri": fileURI
                    ]],
                    ["text": "Transcribe this recording following the schema above."]
                ]
            ]],
            "generationConfig": [
                "temperature": 0.1,
                // 65 536 is Gemini 2.5 Flash's documented output ceiling.
                // For hour-long meetings the JSON segment list can hit ~50k
                // tokens; the previous 32 768 cap truncated mid-segment and
                // the parser reported "no segments in JSON".
                "maxOutputTokens": 65536,
                "responseMimeType": "application/json"
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try throwIfBilling(http: resp, data: data)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GError.http((resp as? HTTPURLResponse)?.statusCode ?? 0,
                              String(data: data, encoding: .utf8) ?? "")
        }

        // Drill into candidates[0].content.parts[*].text and parse the JSON.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GError.parse("unexpected response shape: \(String(data: data, encoding: .utf8)?.prefix(220) ?? "")")
        }
        let raw = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let payloadData = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let segs = payload["segments"] as? [[String: Any]] else {
            throw GError.parse("no segments in JSON: \(raw.prefix(220))")
        }

        var out: [Turn] = []
        out.reserveCapacity(segs.count)
        for s in segs {
            let speaker = (s["speaker"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Speaker 1"
            let start = Self.intValue(s["start_ms"]) ?? 0
            let end = Self.intValue(s["end_ms"]) ?? start
            let text = (s["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            out.append(Turn(speakerLabel: speaker, startMs: Int64(start), endMs: Int64(end), text: text))
        }
        return out
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Int64 { return Int(n) }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func deleteFile(fileURI: String, apiKey: String) async throws {
        let name = (fileURI as NSString).lastPathComponent
        let url = URL(string: "\(endpoint)/files/\(name)?key=\(apiKey)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 402 / 429 / RESOURCE_EXHAUSTED / billing-related → surface as a typed
    /// error the UI layer can recognise to show a red "out of credits" toast.
    private static func throwIfBilling(http: URLResponse, data: Data) throws {
        guard let h = http as? HTTPURLResponse else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        if h.statusCode == 402 || h.statusCode == 429 {
            throw GError.quotaOrBilling("Gemini quota exhausted (\(h.statusCode)). Top up the API project's billing.")
        }
        if h.statusCode == 403 && body.contains("billing") {
            throw GError.quotaOrBilling("Gemini billing not enabled on this API project.")
        }
        if body.contains("RESOURCE_EXHAUSTED") {
            throw GError.quotaOrBilling("Gemini quota exhausted. Top up the API project's billing.")
        }
    }
}
