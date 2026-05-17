import AVFoundation
import Foundation

/// Salvages recordings interrupted by a crash / forced quit / power loss.
///
/// A row left in `.recording` means the stop path never ran. The audio
/// is written incrementally (AVAudioFile, per-buffer), so whatever was
/// captured up to the crash is a valid, playable WAV on disk — only the
/// DB bookkeeping is missing. We reconstruct `endedAt`/`durationMs` from
/// the file itself and flip the row to `.transcribing`, so the launch
/// auto-resume transcribes it like any normal recording instead of the
/// user losing the meeting.
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
