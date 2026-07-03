import AVFoundation
import Foundation

/// Salvages recordings interrupted by a crash / forced quit / power loss.
///
/// A row left in `.recording` means the stop path never ran. The audio is
/// written incrementally (AVAudioFile, per-buffer), so the SAMPLES up to the
/// crash are all on disk — but the WAV HEADER is not: `AVAudioFile` only
/// writes the `data`/RIFF chunk sizes on close, so a hard-killed file reports
/// ZERO frames to every reader and looks empty. `WavHeaderRepair` patches the
/// header from the real file length first, THEN we reconstruct
/// `endedAt`/`durationMs` from the (now-readable) file and flip the row to
/// `.transcribing`, so the launch auto-resume transcribes it like any normal
/// recording instead of the user losing the meeting. Repairing the file in
/// place also makes it playable + transcribable downstream (the pipeline reads
/// the same `mic.wav`/`system.wav`).
///
/// Must run BEFORE `resetStuckMeetings()` (which deletes duration-less
/// `.recording` rows): salvageable rows become `.transcribing` first and
/// survive that cleanup; only genuinely empty captures fall through to
/// be dropped.
enum RecordingRecovery {
    /// Below this the file is just a WAV header / a fraction of a second
    /// of noise — not worth resurrecting.
    private static let minSalvageMs: Int64 = 1500

    static func run(repo: MeetingRepository) {
        let rows = (try? repo.meetingsInRecordingState()) ?? []
        guard !rows.isEmpty else { return }

        for var m in rows {
            let dir = AppPaths.recordingDir(for: m.id)
            let candidates = ["audio.wav", "system.wav", "mic.wav"]
                .map { dir.appendingPathComponent($0) }

            var bestMs: Int64 = 0
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                // Fix the never-finalized WAV header (data/RIFF size = 0 after a
                // hard kill) BEFORE measuring — otherwise every file reads as
                // 0 ms and a real recording is wrongly dropped as unsalvageable.
                WavHeaderRepair.repairIfTruncated(at: url)
                bestMs = max(bestMs, durationMs(of: url))
            }

            guard bestMs >= minSalvageMs else {
                // Nothing usable — leave it for resetStuckMeetings() to drop.
                FileLogger.log("RecordingRecovery: \(m.id) unsalvageable (\(bestMs)ms), leaving for cleanup")
                continue
            }

            m.durationMs = bestMs
            m.endedAt = m.startedAt + bestMs
            m.status = .transcribing
            do {
                try repo.updateMeeting(m)
                FileLogger.log("RecordingRecovery: salvaged \(m.id) (\(bestMs)ms) → transcribing")
            } catch {
                FileLogger.log("RecordingRecovery: failed to salvage \(m.id): \(error)")
            }
        }
    }

    private static func durationMs(of url: URL) -> Int64 {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = f.fileFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Int64((Double(f.length) / sr) * 1000.0)
    }
}
