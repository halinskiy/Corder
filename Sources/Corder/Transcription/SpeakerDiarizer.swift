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
        let segs = result.segments
            .map {
                DiarizedSegment(
                    speakerId: $0.speakerId,
                    startMs: Int64($0.startTimeSeconds * 1000),
                    endMs: Int64($0.endTimeSeconds * 1000)
                )
            }
            .sorted { $0.startMs < $1.startMs }
        FileLogger.log("SpeakerDiarizer: \(wavURL.lastPathComponent) → \(segs.count) spans, "
            + "\(Set(segs.map(\.speakerId)).count) speakers (constraint=\(key == 0 ? "auto" : String(key)))")
        return segs
    }
}
