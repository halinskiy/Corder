import Foundation
import AVFoundation

/// Decides per-segment whether the speaker was the user (microphone)
/// or "other" (system audio from the call).
///
/// This is intentionally simple: we record mic and system on separate streams,
/// so we can compare RMS energy in each segment window.
/// Multi-other-speaker resolution would require a real speaker-embedding
/// model — that's Plan 3.5.
enum Diarizer {
    struct Decision {
        let isUser: Bool
        let userRms: Float
        let otherRms: Float
    }

    /// Returns a decision per segment. `userPath` and `otherPath` should be PCM WAV
    /// or any format `AVAudioFile` can read.
    static func decide(segments: [(start: Double, end: Double)],
                       userPath: URL,
                       otherPath: URL) throws -> [Decision] {
        let userSamples = try readSamples(at: userPath)
        let otherSamples = try readSamples(at: otherPath)

        return segments.map { seg in
            let u = rms(samples: userSamples.samples,
                        sampleRate: userSamples.sampleRate,
                        start: seg.start, end: seg.end)
            let o = rms(samples: otherSamples.samples,
                        sampleRate: otherSamples.sampleRate,
                        start: seg.start, end: seg.end)
            // 1.5× threshold so soft typing / breathing on mic doesn't dominate.
            return Decision(isUser: u > o * 1.5, userRms: u, otherRms: o)
        }
    }

    private struct SamplesAndRate {
        var samples: [Float]
        var sampleRate: Double
    }

    private static func readSamples(at url: URL) throws -> SamplesAndRate {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return SamplesAndRate(samples: [], sampleRate: format.sampleRate) }

        // Convert to mono Float32 at native sample rate.
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: format.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        try file.read(into: inBuf)

        if format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32 {
            let p = inBuf.floatChannelData![0]
            return SamplesAndRate(samples: Array(UnsafeBufferPointer(start: p, count: Int(inBuf.frameLength))),
                                   sampleRate: format.sampleRate)
        }

        guard let converter = AVAudioConverter(from: format, to: target) else {
            // best-effort fallback
            let p = inBuf.floatChannelData![0]
            return SamplesAndRate(samples: Array(UnsafeBufferPointer(start: p, count: Int(inBuf.frameLength))),
                                   sampleRate: format.sampleRate)
        }
        let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames)!
        var error: NSError?
        var fed = false
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        let p = outBuf.floatChannelData![0]
        return SamplesAndRate(samples: Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength))),
                               sampleRate: target.sampleRate)
    }

    private static func rms(samples: [Float], sampleRate: Double, start: Double, end: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let s = max(0, Int(start * sampleRate))
        let e = min(samples.count, Int(end * sampleRate))
        guard s < e else { return 0 }
        var sum: Float = 0
        for i in s..<e { sum += samples[i] * samples[i] }
        let n = Float(e - s)
        return (sum / n).squareRoot()
    }
}
