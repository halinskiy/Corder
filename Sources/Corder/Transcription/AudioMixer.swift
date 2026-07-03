import Foundation
import AVFoundation

enum AudioMixerError: Error, LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case bothStreamsMissing

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "Video has no audio track"
        case .readerFailed(let m): return "Audio reader failed: \(m)"
        case .bothStreamsMissing: return "Both system.wav and mic.wav are missing or unreadable"
        }
    }
}

/// Produces a 16 kHz mono PCM WAV file by mixing the standalone system audio
/// (system.wav captured live from SCStream) with the microphone audio (mic.wav).
/// The .mov is no longer required for transcription, so a corrupt video file
/// does not block the transcript.
enum AudioMixer {
    static func produceWhisperInput(systemURL: URL?, micURL: URL, outputURL: URL) async throws {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!

        // 1. Read whichever streams actually exist. Both are best-effort:
        //    - the recorder might crash before either gets a graceful close,
        //      leaving a WAV with a stub header that AVAudioFile refuses to
        //      open. We try patching the header in place and re-reading.
        //    - on really short captures one of the two streams might never
        //      have produced a single buffer, so the file is missing.
        //    If a stream is unrecoverable we substitute silence; the other
        //    stream still gets transcribed. Only if BOTH are gone do we
        //    bail with a typed error the pipeline can surface.
        let systemBuffer = readOrSilence(fileURL: systemURL, targetFormat: target)
        let micBuffer    = readOrSilence(fileURL: micURL,    targetFormat: target)

        let systemHasContent = systemBuffer.frameLength > 1
        let micHasContent    = micBuffer.frameLength > 1
        guard systemHasContent || micHasContent else {
            throw AudioMixerError.bothStreamsMissing
        }

        // 2. Mix sample-wise into a single buffer the length of whichever
        //    stream is longer.
        let mixed = mix(buffers: [systemBuffer, micBuffer], format: target)

        // 3. Write to outputURL as 16 kHz mono 16-bit PCM WAV. NOT Float32:
        // WKWebView's <audio> media element decodes PCM-INTEGER WAV but NOT
        // IEEE-float WAV (WAVE_FORMAT_IEEE_FLOAT, fmt=3). A float32 mix loaded
        // in the player but produced NO sound, NO duration and NO scrubbing
        // (the decoder silently rejected it). 16-bit PCM is universally
        // decodable and is an equally fine Whisper/Groq input. AVAudioFile
        // converts the float32 `mixed` buffer to int16 on write (file format =
        // int16 settings, processing format = float32).
        let outFile = try AVAudioFile(forWriting: outputURL,
                                      settings: Self.playbackInt16Settings(sampleRate: target.sampleRate,
                                                                           channels: target.channelCount),
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        try outFile.write(from: mixed)
    }

    /// Shrink a retained WAV to the exact format ASR and playback actually
    /// consume — 16 kHz MONO 16-bit PCM — reclaiming the disk the capture-time
    /// 44.1/48 kHz stereo Float32 originals waste (a 44.1k mono f32 mic.wav is
    /// ~176 KB/s; 16k mono int16 is 32 KB/s → ~5.5x smaller; a 48k STEREO f32
    /// system.wav is ~12x). Lossless for our purposes: Whisper/Groq downsample
    /// to 16k mono anyway, and the playback mix is already 16k mono. Idempotent
    /// (a file already 16 kHz/mono/int16 is skipped — the fast path), atomic
    /// (temp file then swap), best-effort (on ANY error the original is left
    /// exactly as it was, so a bulk pass can never corrupt a recording).
    @discardableResult
    static func compactToTranscriptionFormat(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let inFile = try? AVAudioFile(forReading: url) else { return false }
        let src = inFile.fileFormat
        // Already 16 kHz mono integer PCM → nothing to gain, skip.
        if src.sampleRate == 16_000, src.channelCount == 1, src.commonFormat != .pcmFormatFloat32 {
            return false
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        // readAndConvert resamples + downmixes to 16k mono float32 (same path,
        // and same memory profile, as the per-transcription playback mix).
        guard let buf = try? readAndConvert(fileURL: url, targetFormat: target),
              buf.frameLength > 1 else { return false }
        let base = url.deletingPathExtension().lastPathComponent
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).compact.\(UInt64(buf.frameLength)).tmp.wav")
        try? fm.removeItem(at: tmp)
        do {
            let out = try AVAudioFile(
                forWriting: tmp,
                settings: playbackInt16Settings(sampleRate: 16_000, channels: 1),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: buf)
        } catch {
            FileLogger.log("AudioMixer: compact failed for \(url.lastPathComponent): \(error)")
            try? fm.removeItem(at: tmp)
            return false
        }
        do { _ = try fm.replaceItemAt(url, withItemAt: tmp) }
        catch {
            try? fm.removeItem(at: url); try? fm.moveItem(at: tmp, to: url)
        }
        FileLogger.log("AudioMixer: compacted \(url.lastPathComponent) → 16 kHz mono 16-bit PCM")
        return true
    }

    /// 16-bit little-endian PCM WAV settings — the format WKWebView's <audio>
    /// element can actually decode (a float32 WAV cannot be played by the media
    /// element). Used for the playback mix and the float32→int16 rewrite.
    static func playbackInt16Settings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Rewrite a Float32 playback WAV in place as 16-bit PCM so WKWebView's
    /// <audio> can decode it. Idempotent: a file that's ALREADY PCM-integer is
    /// left untouched (fast path — one header read). Best-effort: on any error
    /// the original file is left exactly as it was. Streams in frame chunks so
    /// even a long recording doesn't balloon memory. Heals the existing
    /// installed base whose `audio.wav` was written as float32 before the fix.
    static func rewriteFloat32ToInt16IfNeeded(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let inFile = try? AVAudioFile(forReading: url) else { return }
        guard inFile.fileFormat.commonFormat == .pcmFormatFloat32 else { return }
        let proc = inFile.processingFormat
        let total = inFile.length
        guard total > 0 else { return }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("audio.int16.\(UInt64(total)).tmp.wav")
        try? fm.removeItem(at: tmp)
        do {
            let outFile = try AVAudioFile(
                forWriting: tmp,
                settings: playbackInt16Settings(sampleRate: proc.sampleRate, channels: proc.channelCount),
                commonFormat: proc.commonFormat,
                interleaved: proc.isInterleaved)
            let chunk: AVAudioFrameCount = 1 << 20   // ~1M frames per pass
            while inFile.framePosition < total {
                let remaining = AVAudioFrameCount(total - inFile.framePosition)
                let n = min(chunk, remaining)
                guard let buf = AVAudioPCMBuffer(pcmFormat: proc, frameCapacity: n) else { break }
                try inFile.read(into: buf, frameCount: n)
                if buf.frameLength == 0 { break }
                try outFile.write(from: buf)
            }
        } catch {
            FileLogger.log("AudioMixer: float32→int16 rewrite failed for \(url.lastPathComponent): \(error)")
            try? fm.removeItem(at: tmp)
            return
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: url)
            try? fm.moveItem(at: tmp, to: url)
        }
        FileLogger.log("AudioMixer: rewrote \(url.lastPathComponent) float32 → 16-bit PCM for WKWebView playback")
    }

    /// Returns a 1-frame silent buffer when the file is missing, empty,
    /// or has a broken header that won't open even after a repair attempt.
    private static func readOrSilence(fileURL: URL?, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer {
        let silence = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1)!
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size > 1024 else {
            return silence
        }
        if let buf = try? readAndConvert(fileURL: url, targetFormat: targetFormat) {
            return buf
        }
        // Header is busted. Try to patch it (rewrites RIFF + data chunk
        // sizes from the actual file size on disk) and read again.
        if patchWavHeader(at: url),
           let buf = try? readAndConvert(fileURL: url, targetFormat: targetFormat) {
            FileLogger.log("AudioMixer: \(url.lastPathComponent) opened after WAV header repair")
            return buf
        }
        FileLogger.log("AudioMixer: \(url.lastPathComponent) unrecoverable, substituting silence")
        return silence
    }

    /// Walks through chunks of a WAV file until it finds `data`, then
    /// rewrites the RIFF size and the data chunk size based on the
    /// file's actual length on disk. Crash-recovery for the case where
    /// AVAudioFile didn't get to close the file gracefully (system
    /// sleep mid-recording, app SIGKILL, etc.).
    private static func patchWavHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let totalSize = (attrs[.size] as? NSNumber)?.int64Value, totalSize > 44 else {
            return false
        }

        do {
            // RIFF/WAVE preamble.
            try handle.seek(toOffset: 0)
            let preamble = try handle.read(upToCount: 12) ?? Data()
            guard preamble.count == 12,
                  preamble[0..<4] == Data("RIFF".utf8),
                  preamble[8..<12] == Data("WAVE".utf8) else { return false }

            // Walk chunks until we hit `data`.
            while true {
                let head = try handle.read(upToCount: 8) ?? Data()
                guard head.count == 8 else { return false }
                let chunkID = head[0..<4]
                let chunkSize = head[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
                if chunkID == Data("data".utf8) {
                    let dataStart = try handle.offset()
                    let expectedDataSize = UInt32(totalSize - Int64(dataStart))
                    if chunkSize == expectedDataSize { return true }
                    // 1) data chunk size lives at the 4 bytes *before* dataStart.
                    try handle.seek(toOffset: dataStart - 4)
                    var leData = expectedDataSize
                    try handle.write(contentsOf: withUnsafeBytes(of: &leData) { Data($0) })
                    // 2) RIFF size = total file size - 8.
                    var leRiff = UInt32(totalSize - 8)
                    try handle.seek(toOffset: 4)
                    try handle.write(contentsOf: withUnsafeBytes(of: &leRiff) { Data($0) })
                    return true
                }
                // Skip the chunk's payload (round odd sizes up by 1).
                let pad = UInt64(chunkSize) + UInt64(chunkSize & 1)
                let next = (try handle.offset()) + pad
                try handle.seek(toOffset: next)
            }
        } catch {
            return false
        }
    }

    // MARK: - audio file → target format

    private static func readAndConvert(fileURL: URL, targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat

        let frameCapacity = AVAudioFrameCount(file.length)
        guard frameCapacity > 0 else {
            return AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1)!
        }
        let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity)!
        try file.read(into: inBuffer)

        // If already in target format, skip conversion.
        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount
            && sourceFormat.commonFormat == targetFormat.commonFormat {
            return inBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return inBuffer
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
        let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)!

        var error: NSError?
        var feed = false
        converter.convert(to: outBuffer, error: &error) { _, status in
            if feed { status.pointee = .endOfStream; return nil }
            feed = true
            status.pointee = .haveData
            return inBuffer
        }
        if let e = error { throw e }
        return outBuffer
    }

    // MARK: - sample-wise mix

    /// Sample-wise sum of every buffer, then peak-normalised back into the
    /// [-1, +1] range *only if* the sum actually clipped. This is critical
    /// for ASR: dividing by N unconditionally (the obvious-but-wrong mix)
    /// loses 6 dB whenever the system stream is silent, and Whisper degrades
    /// noticeably on quiet input. With peak normalisation a "user speaking,
    /// remote silent" mix stays at full mic level.
    /// Internal (not private) so unit tests can exercise the gain path.
    static func mix(buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let maxFrames = buffers.map { Int($0.frameLength) }.max() ?? 0
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))!
        out.frameLength = AVAudioFrameCount(maxFrames)
        guard let dst = out.floatChannelData?[0] else { return out }

        for i in 0..<maxFrames { dst[i] = 0 }
        for buf in buffers {
            guard let src = buf.floatChannelData?[0] else { continue }
            let n = Int(buf.frameLength)
            for i in 0..<n {
                dst[i] += src[i]
            }
        }

        var peak: Float = 0
        for i in 0..<maxFrames {
            let abs = dst[i] < 0 ? -dst[i] : dst[i]
            if abs > peak { peak = abs }
        }
        // Headroom: aim peak at 0.98 instead of 1.0 to leave a sliver of
        // margin for downstream resampling overshoot.
        if peak > 0.98 {
            let gain: Float = 0.98 / peak
            for i in 0..<maxFrames { dst[i] *= gain }
        }
        return out
    }
}
