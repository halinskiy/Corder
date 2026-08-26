import Foundation
import FluidAudio

/// One speaker-labeled time span produced by on-device diarization.
/// `speakerId` is FluidAudio's globally-stable label for the whole
/// recording (e.g. "Speaker 1"), unlike Gemini's per-chunk relabeling,
/// the same physical voice keeps the same id across the entire file.
struct DiarizedSegment: Sendable {
    let speakerId: String
    let startMs: Int64
    let endMs: Int64
}

/// On-device speaker diarization (FluidAudio: pyannote community-1
/// segmentation + WeSpeaker embeddings + VBx clustering, all Core ML).
///
/// This replaces Gemini's single-mic diarization, which over-counted
/// speakers, drifted labels across long audio, and forced the crude
/// post-hoc top-N collapse in `mapInPersonTurns`. Here the
/// "how many people?" answer is fed as a HARD count constraint to the
/// clustering stage BEFORE it runs, the correct place for it.
///
/// `OfflineDiarizerManager` is a non-Sendable `final class`; we confine
/// it to this actor so concurrent meetings can't race its model state.
/// One prepared manager is kept warm per speaker-count constraint
/// (most users have a stable group size), keyed so the common case
/// skips the seconds-scale Core ML recompile.
actor SpeakerDiarizer {
    static let shared = SpeakerDiarizer()
    private init() {}

    /// Key: the resolved speaker count (0 = "auto / no constraint").
    /// `OfflineDiarizerConfig` bakes the count in at init, so a
    /// different count needs a different prepared manager.
    private var managers: [Int: OfflineDiarizerManager] = [:]

    /// Diarize a 16 kHz mono WAV. `numSpeakers`, when known from the
    /// clarify banner, is passed as an exact constraint. nil → let VBx
    /// estimate. Returns spans sorted by start time. Throws on missing
    /// models / no-network-first-run / no speech, callers fall back to
    /// the legacy Gemini-diarize path so a meeting never hard-fails
    /// worse than before this existed.
    func diarize(wavURL: URL, numSpeakers: Int?) async throws -> [DiarizedSegment] {
        let key = (numSpeakers ?? 0) >= 1 ? numSpeakers! : 0
        let manager: OfflineDiarizerManager
        if let warm = managers[key] {
            manager = warm
        } else {
            let config = key >= 1
                ? OfflineDiarizerConfig().withSpeakers(exactly: key)
                : OfflineDiarizerConfig()
            let mgr = OfflineDiarizerManager(config: config)
            // Downloads (~130 MB) only on the very first run ever;
            // afterwards loads from ~/Library/Application Support cache
            // (Core ML compile + prewarm, seconds).
            try await mgr.prepareModels()
            managers[key] = mgr
            manager = mgr
        }

        let result = try await manager.process(wavURL)
        var segs = result.segments
            .map {
                DiarizedSegment(
                    speakerId: $0.speakerId,
                    startMs: Int64($0.startTimeSeconds * 1000),
                    endMs: Int64($0.endTimeSeconds * 1000)
                )
            }
            .sorted { $0.startMs < $1.startMs }
        let estimated = Set(segs.map(\.speakerId)).count
        // Only the AUTO estimate gets the phantom sweep: an exact count from
        // the clarify banner is the user's word and is honoured as-is.
        if key == 0 {
            segs = Self.mergePhantomSpeakers(segs, embeddings: result.speakerDatabase)
        }
        FileLogger.log("SpeakerDiarizer: \(wavURL.lastPathComponent) → \(segs.count) spans, "
            + "\(Set(segs.map(\.speakerId)).count) speakers (constraint=\(key == 0 ? "auto" : String(key))"
            + (key == 0 && estimated != Set(segs.map(\.speakerId)).count ? ", \(estimated) before phantom merge)" : ")"))
        return segs
    }

    /// Fold "phantom" speakers back into the voice they split off from.
    ///
    /// VBx's auto-estimate errs by ±1-2 on real far-end audio (measured
    /// 2026-06-25: GT3→2, GT2→4, GT4→5), and the surplus cluster is almost
    /// always tiny: a handful of seconds of one real speaker whose embedding
    /// drifted (codec artefacts, a laugh, a shout). On a real 3-person call
    /// the phantom held 7 s of 832 s and showed the user a "Speaker 3" that
    /// did not exist. A cluster carrying less than max(5 s, 2.5 %) of the
    /// track's speech is merged into the remaining speaker whose centroid
    /// embedding is nearest (cosine); without embeddings, into the speaker
    /// with the most speech within ±30 s of the phantom's spans. Smallest
    /// first, never below one speaker. Pure value-in/value-out.
    static func mergePhantomSpeakers(_ segs: [DiarizedSegment],
                                     embeddings: [String: [Float]]?) -> [DiarizedSegment] {
        var totals: [String: Int64] = [:]
        for s in segs { totals[s.speakerId, default: 0] += max(0, s.endMs - s.startMs) }
        guard totals.count > 1 else { return segs }
        let total = totals.values.reduce(0, +)
        let threshold = max(5000, Int64(Double(total) * 0.025))

        func cosine(_ a: [Float], _ b: [Float]) -> Float {
            guard a.count == b.count, !a.isEmpty else { return -1 }
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
            let d = sqrtf(na) * sqrtf(nb)
            return d > 0 ? dot / d : -1
        }

        var mapping: [String: String] = [:]
        var remaining = totals
        for (spk, ms) in totals.sorted(by: { $0.value < $1.value }) {
            guard ms < threshold, remaining.count > 1 else { continue }
            let real = remaining.keys.filter { $0 != spk && (remaining[$0] ?? 0) >= threshold }
            let pool = real.isEmpty ? remaining.keys.filter { $0 != spk } : real
            guard !pool.isEmpty else { continue }
            var target: String? = nil
            var how = "neighbourhood"
            if let db = embeddings, let e = db[spk] {
                var best: (sim: Float, spk: String)? = nil
                for c in pool {
                    guard let f = db[c] else { continue }
                    let sim = cosine(e, f)
                    if best == nil || sim > best!.sim { best = (sim, c) }
                }
                if let b = best { target = b.spk; how = String(format: "cosine %.2f", b.sim) }
            }
            if target == nil {
                var score: [String: Int64] = [:]
                for p in segs where p.speakerId == spk {
                    for d in segs where pool.contains(d.speakerId)
                        && d.endMs > p.startMs - 30_000 && d.startMs < p.endMs + 30_000 {
                        score[d.speakerId, default: 0] += d.endMs - d.startMs
                    }
                }
                target = score.max { $0.value < $1.value }?.key
                    ?? pool.max { (remaining[$0] ?? 0) < (remaining[$1] ?? 0) }
            }
            guard let t = target else { continue }
            mapping[spk] = t
            remaining[t, default: 0] += ms
            remaining.removeValue(forKey: spk)
            FileLogger.log("SpeakerDiarizer: phantom \(spk) (\(ms / 1000)s of \(total / 1000)s) merged into \(t) by \(how)")
        }
        guard !mapping.isEmpty else { return segs }
        func resolve(_ s: String) -> String {
            var x = s, hops = 0
            while let m = mapping[x], hops < 8 { x = m; hops += 1 }
            return x
        }
        return segs.map { DiarizedSegment(speakerId: resolve($0.speakerId), startMs: $0.startMs, endMs: $0.endMs) }
    }
}
