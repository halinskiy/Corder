import Foundation
import AVFoundation

enum AudioMixerError: Error, LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "Video has no audio track"
        case .readerFailed(let m): return "Audio reader failed: \(m)"
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

        // 1. Read system audio if it exists. If the file is missing or empty
        //    (very short recordings, no system sound), fall back to silence.
        let systemBuffer: AVAudioPCMBuffer
        if let url = systemURL,
           FileManager.default.fileExists(atPath: url.path),
           ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) > 1024 {
            systemBuffer = try readAndConvert(fileURL: url, targetFormat: target)
        } else {
            systemBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1)!
        }

        // 2. Read mic.wav and convert to the same format.
        let micBuffer = try readAndConvert(fileURL: micURL, targetFormat: target)

        // 3. Mix sample-wise into a single buffer the length of whichever stream is longer.
        let mixed = mix(buffers: [systemBuffer, micBuffer], format: target)

        // 4. Write to outputURL as 16 kHz mono Float32 WAV.
        let outFile = try AVAudioFile(forWriting: outputURL,
                                      settings: target.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        try outFile.write(from: mixed)
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

    private static func mix(buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let maxFrames = buffers.map { Int($0.frameLength) }.max() ?? 0
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))!
        out.frameLength = AVAudioFrameCount(maxFrames)
        guard let dst = out.floatChannelData?[0] else { return out }

        // Zero-init
        for i in 0..<maxFrames { dst[i] = 0 }

        // Sum, then normalize by N to avoid clipping.
        for buf in buffers {
            guard let src = buf.floatChannelData?[0] else { continue }
            let n = Int(buf.frameLength)
            for i in 0..<n {
                dst[i] += src[i]
            }
        }
        let denom = Float(max(1, buffers.count))
        for i in 0..<maxFrames { dst[i] /= denom }
        return out
    }
}
