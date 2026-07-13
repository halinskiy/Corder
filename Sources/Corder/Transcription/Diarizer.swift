import Foundation
import AVFoundation

/// Channel-gate over per-segment audio windows: which side (mic or
/// system) was louder over a given time range? Used by the cloud
/// transcription pipeline to decide which Gemini speaker label
/// corresponds to the local user.
///
/// We previously hosted a richer two-stage diarizer here, channel-gate
/// plus FluidAudio (CoreML pyannote 3.1 + WeSpeaker), that ran on the
/// local Whisper path. Whisper itself has been retired (see
/// CHANGELOG.md / ARCHITECTURE.md "Why no Whisper any more"), so the
/// FluidAudio dependency is gone too. Only the channel-gate survives,
/// because the cloud pipeline still needs it.
enum Diarizer {

    /// Per-segment vote: `true` means the local microphone was clearly
    /// louder than the system stream in that window, i.e. the local
    /// user was speaking. The cloud pipeline runs this for every Gemini
    /// turn and tallies the votes per speaker label; the label with the
    /// most "true" votes becomes the user, the rest stay "other-N".
    ///
    /// Hysteresis: ratio ≥ 2× and absolute mic floor ≥ 0.005. Both
    /// matter, without the floor we'd label total silence as "user"
    /// just because the system was even quieter; without the ratio
    /// we'd misclassify any time the mic picked up speaker bleed
    /// (peer's voice played through the user's speakers and back into
    /// the mic).
    static func userMicDominance(segments: [(start: Double, end: Double)],
                                 userPath: URL,
                                 otherPath: URL) throws -> [Bool] {
        let userSamples = try readSamples(at: userPath)
        let otherSamples = try readSamples(at: otherPath)
        return segments.map { seg in
            let u = rms(samples: userSamples.samples,
                        sampleRate: userSamples.sampleRate,
                        start: seg.start, end: seg.end)
            let o = rms(samples: otherSamples.samples,
                        sampleRate: otherSamples.sampleRate,
                        start: seg.start, end: seg.end)
            return micDominates(mic: u, sys: o)
        }
    }

    // MARK: - Channel gate math

    /// 6 dB hysteresis. RMS ratios in linear domain, 6 dB ≈ 2× louder.
    /// Plus a small absolute floor (mic > 0.005 RMS) so we don't mark
    /// silent-mic segments as "user" just because the system is also quiet.
    private static func micDominates(mic u: Float, sys o: Float) -> Bool {
        guard u > 0.005 else { return false }
        return u > o * 2.0
    }

    // MARK: - Audio I/O

    private struct SamplesAndRate {
        var samples: [Float]
        var sampleRate: Double
    }

    private static func readSamples(at url: URL) throws -> SamplesAndRate {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SamplesAndRate(samples: [], sampleRate: 16000)
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return SamplesAndRate(samples: [], sampleRate: format.sampleRate) }

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
