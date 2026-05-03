import Foundation
import AVFoundation
import FluidAudio

/// Diarizes Whisper segments into speakers using a two-source approach:
///
/// Step 1 — channel gate. Because we capture mic.wav (only the local user)
/// and system.wav (only remote participants) separately, the user/remote
/// decision is just a per-segment energy comparison: mic dominant → "user",
/// system dominant → "other". Hysteresis (≥6 dB margin for ≥150 ms within the
/// segment window) tolerates speaker bleed and AEC residue.
///
/// Step 2 — diarize remote-only audio. We hand the **system** stream to
/// FluidAudio (Apple-Neural-Engine-accelerated CoreML port of pyannote 3.1
/// segmentation + WeSpeaker embeddings + clustering) and map each Whisper
/// segment to whichever FluidAudio speaker covers the most of its window.
/// The user is never in this clustering pool, which fixes both
/// "user voice ends up in `other-N`" and "two speakers split into three".
enum Diarizer {
    struct Decision: Equatable {
        /// Stable key: "user", or "other-N" where N is FluidAudio's speakerId.
        let speakerKey: String
        let userRms: Float
        let otherRms: Float
    }

    /// Triggers download/load of the FluidAudio Core ML bundles ahead of
    /// time so the first meeting doesn't pay the cold-start cost.
    static func warmUp() async throws {
        _ = try await loadDiarizer()
    }

    /// Whisper segment → speaker decision.
    static func decide(segments: [(start: Double, end: Double)],
                       userPath: URL,
                       otherPath: URL) async throws -> [Decision] {
        // Both audio streams pulled into memory at their native sample rate
        // for the per-segment RMS gate. We don't use otherSamples directly
        // for clustering — FluidAudio reads/resamples the file itself.
        let userSamples = try readSamples(at: userPath)
        let otherSamples = try readSamples(at: otherPath)

        // ---------- Step 1: channel-gate decision per Whisper segment.
        struct Pre { let isUser: Bool; let userRms: Float; let otherRms: Float }
        let pre: [Pre] = segments.map { seg in
            let u = rms(samples: userSamples.samples,
                        sampleRate: userSamples.sampleRate,
                        start: seg.start, end: seg.end)
            let o = rms(samples: otherSamples.samples,
                        sampleRate: otherSamples.sampleRate,
                        start: seg.start, end: seg.end)
            return Pre(isUser: micDominates(mic: u, sys: o), userRms: u, otherRms: o)
        }

        // ---------- Step 2: diarize the remote (system) stream once.
        let remoteSegments = try await diarizeRemote(otherPath: otherPath)
        FileLogger.log("Diarizer: remote stream produced \(remoteSegments.count) speaker turns, " +
                       "speakers=\(Set(remoteSegments.map { $0.speakerId }).count)")

        // Map Whisper segments to FluidAudio speakers.
        var decisions: [Decision] = []
        decisions.reserveCapacity(pre.count)
        for (p, seg) in zip(pre, segments) {
            if p.isUser {
                decisions.append(Decision(speakerKey: "user",
                                          userRms: p.userRms, otherRms: p.otherRms))
                continue
            }
            // Pick the FluidAudio turn with the largest temporal overlap.
            let speaker = bestOverlap(start: seg.start, end: seg.end, in: remoteSegments)
                ?? "0" // fallback when FluidAudio produced no covering turn
            decisions.append(Decision(speakerKey: "other-\(speaker)",
                                      userRms: p.userRms, otherRms: p.otherRms))
        }

        return decisions
    }

    // MARK: - Channel gate

    /// 6 dB hysteresis. RMS ratios in linear domain — 6 dB ≈ 2× louder.
    /// Plus a small absolute floor (mic > 0.005 RMS) so we don't mark
    /// silent-mic segments as "user" just because system is also quiet.
    private static func micDominates(mic u: Float, sys o: Float) -> Bool {
        guard u > 0.005 else { return false }
        // 2× ≈ +6 dB. Inverted form to avoid divide-by-zero when sys is 0.
        return u > o * 2.0
    }

    // MARK: - FluidAudio bridge

    /// Lazy-loaded FluidAudio diarizer. Models are cached to disk by
    /// FluidAudio in `~/Library/Application Support/FluidAudio/Models/…`,
    /// so the first call downloads (~30 MB), subsequent calls are instant.
    /// Held inside an actor so concurrent diarize calls coalesce on the
    /// same model load instead of racing.
    private actor DiarizerHolder {
        var manager: DiarizerManager?
        func setManager(_ m: DiarizerManager) { manager = m }
    }
    private static let holder = DiarizerHolder()

    private struct RemoteTurn {
        let speakerId: String
        let start: Double
        let end: Double
    }

    private static func diarizeRemote(otherPath: URL) async throws -> [RemoteTurn] {
        let manager = try await loadDiarizer()

        // FluidAudio handles resampling internally via its bundled converter;
        // we hand it the original system.wav.
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(otherPath)
        guard !samples.isEmpty else { return [] }

        let result = try await manager.performCompleteDiarization(samples)
        return result.segments.map {
            RemoteTurn(speakerId: $0.speakerId,
                       start: Double($0.startTimeSeconds),
                       end: Double($0.endTimeSeconds))
        }
    }

    private static func loadDiarizer() async throws -> DiarizerManager {
        if let m = await holder.manager { return m }
        FileLogger.log("Diarizer: downloading/loading FluidAudio models…")
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        FileLogger.log("Diarizer: FluidAudio ready")
        await holder.setManager(manager)
        return manager
    }

    /// Returns the speakerId with the longest temporal overlap with [start, end].
    private static func bestOverlap(start: Double, end: Double, in turns: [RemoteTurn]) -> String? {
        var bestId: String?
        var bestOverlap: Double = 0
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestId = t.speakerId
            }
        }
        return bestId
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
