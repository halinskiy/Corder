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

/// Produces a 16 kHz mono PCM WAV file by mixing system audio (extracted from a .mov)
/// with microphone audio (recorded separately). Output is what Whisper expects.
enum AudioMixer {
    static func produceWhisperInput(videoURL: URL, micURL: URL, outputURL: URL) async throws {
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!

        // 1. Pull system audio out of the .mov as 16 kHz mono Float32 buffers.
        let systemBuffers = try await readSystemAudioFromVideo(videoURL: videoURL, targetFormat: target)

        // 2. Read mic.wav and convert to the same format.
        let micBuffers = try readAndConvert(fileURL: micURL, targetFormat: target)

        // 3. Mix sample-wise into a single buffer the length of whichever stream is longer.
        let mixed = mix(buffers: [systemBuffers, micBuffers], format: target)

        // 4. Write to outputURL as 16 kHz mono Float32 WAV.
        let outFile = try AVAudioFile(forWriting: outputURL,
                                      settings: target.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
        try outFile.write(from: mixed)
    }

    // MARK: - System audio (.mov → AVAudioPCMBuffer in target format)

    private static func readSystemAudioFromVideo(videoURL: URL, targetFormat: AVAudioFormat) async throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            // Some recordings might genuinely have no system audio. Return silence.
            return AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1)!
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(trackOutput) else {
            throw AudioMixerError.readerFailed("cannot add track output")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw AudioMixerError.readerFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        var samples: [Float] = []
        while reader.status == .reading, let buf = trackOutput.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let p = dataPointer, length > 0 {
                let count = length / MemoryLayout<Float>.size
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: p.withMemoryRebound(to: Float.self, capacity: count) { $0 },
                    count: count))
            }
        }
        if reader.status == .failed {
            throw AudioMixerError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    // MARK: - mic.wav → target format

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
