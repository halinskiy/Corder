import Foundation
import FluidAudio

/// One recognised token with its real-timeline position, in ms.
/// Produced by on-device ASR over the ORIGINAL (uncompressed) track
/// so the times are acoustic ground truth, unlike Gemini's
/// VAD-compressed-then-projected guesses.
struct TimedToken: Sendable {
    let text: String
    let startMs: Int64
    let endMs: Int64
}

/// On-device forced-alignment time source.
///
/// FluidAudio's Parakeet TDT 0.6B v3 (Core ML, multilingual incl.
/// Russian/Ukrainian/English, auto language detection) transcribes the
/// raw audio and returns per-token timestamps on the true file
/// timeline. We DON'T use its text as the transcript (Gemini's
/// Russian quality is higher); we use only its token TIMINGS to anchor
/// Gemini's words to the moment they were actually spoken, replacing
/// the proportional placement that could only ever be "roughly right".
///
/// `AsrManager` is a non-Sendable class with mutable Core ML state, so
/// it's confined to this actor exactly like `SpeakerDiarizer` confines
/// the diarizer. The model set (~600 MB-class TDT, downloaded once to
/// `~/Library/Application Support/FluidAudio/`) is kept warm after the
/// first load so subsequent meetings skip the Core ML compile.
actor ForcedAligner {
    static let shared = ForcedAligner()
    private init() {}

    private var manager: AsrManager?

    /// Transcribe `wavURL` on-device and return its tokens with real
    /// start/end times (ms), sorted by start. Throws on missing models
    /// / no-network-first-run / no speech, callers fall back to the
    /// proportional placement so a meeting never hard-fails over this.
    func align(wavURL: URL) async throws -> [TimedToken] {
        let mgr: AsrManager
        if let warm = manager {
            mgr = warm
        } else {
            // Downloads parakeet-tdt-0.6b-v3 on the very first run ever;
            // afterwards loads from the on-disk cache (Core ML compile,
            // seconds). Same lifecycle as the diarizer models.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            manager = m
            mgr = m
        }

        // language: nil → Parakeet v3 auto-detects (the calls here are
        // RU/EN mixed; forcing a language would mis-handle code-switch).
        var decoderState = try TdtDecoderState()
        let result = try await mgr.transcribe(wavURL, decoderState: &decoderState, language: nil)

        let tokens = (result.tokenTimings ?? [])
            .map {
                TimedToken(
                    text: $0.token,
                    startMs: Int64($0.startTime * 1000),
                    endMs: Int64($0.endTime * 1000))
            }
            .filter { $0.endMs >= $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        FileLogger.log("ForcedAligner: \(wavURL.lastPathComponent) → \(tokens.count) timed tokens "
            + "(ASR \(Int(result.duration))s in \(String(format: "%.1f", result.processingTime))s)")
        return tokens
    }
}
