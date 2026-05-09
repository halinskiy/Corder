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

        // 3. Write to outputURL as 16 kHz mono Float32 WAV.
        let outFile = try AVAudioFile(forWriting: outputURL,
                                      settings: target.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        try outFile.write(from: mixed)
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
