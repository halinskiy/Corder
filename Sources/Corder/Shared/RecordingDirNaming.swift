import Foundation

/// Renames a recording's on-disk folder from the opaque `<meeting-id>` to a
/// human-readable `"<yyyy-MM-dd_HH-mm> <title>"` so the recordings directory is
/// browsable in Finder.
///
/// Safety model (this touches the user's real recordings, so every step is
/// defensive):
/// - The folder is CREATED as `<id>` and only renamed AFTER the title lands
///   (transcription finished → capture files closed), never during capture.
/// - `AppPaths.recordingDir` always prefers a folder that actually exists, so a
///   not-yet-renamed row, a half-finished rename, or a stale index all resolve
///   to a real folder — never a dangling path.
/// - The stored absolute `video_path` / `audio_path` are re-based in the SAME
///   DB write, because they're read directly in serving/transcription.
/// - If the DB write fails after the folder move, the move is reverted so disk
///   and DB never diverge.
enum RecordingDirNaming {
    /// Rename `meetingId`'s folder to the titled form. No-op if it's already
    /// correctly named, has no usable title, or its source folder is missing.
    static func renameToTitled(repo: MeetingRepository, meetingId: String) {
        guard let meeting = try? repo.meeting(id: meetingId) else { return }
        let fm = FileManager.default
        let desired = AppPaths.folderName(startedAtMs: meeting.startedAt, title: meeting.title)
        let currentName = meeting.dirName ?? meetingId
        // Already at the desired name (ignoring any " (2)" dedupe suffix already
        // applied) — nothing to do.
        if currentName == desired || currentName.hasPrefix(desired + " (") { return }

        let currentDir = AppPaths.recordingsDir.appendingPathComponent(currentName, isDirectory: true)
        guard fm.fileExists(atPath: currentDir.path) else { return }

        let finalName = AppPaths.uniqueFolderName(desired, excluding: currentName)
        let newDir = AppPaths.recordingsDir.appendingPathComponent(finalName, isDirectory: true)
        guard finalName != currentName else { return }

        do {
            try fm.moveItem(at: currentDir, to: newDir)
        } catch {
            FileLogger.log("RecordingDirNaming: move \(currentName) → \(finalName) failed: \(error)")
            return
        }

        // Re-base the stored absolute paths onto the new folder, keeping each
        // file's basename (mic.wav / video.mov) so serving/transcription follow.
        let videoBase = meeting.videoPath.isEmpty ? "video.mov" : (meeting.videoPath as NSString).lastPathComponent
        let audioBase = meeting.audioPath.isEmpty ? "mic.wav" : (meeting.audioPath as NSString).lastPathComponent
        let newVideo = newDir.appendingPathComponent(videoBase).path
        let newAudio = newDir.appendingPathComponent(audioBase).path
        do {
            try repo.setDirName(meetingId: meetingId, dirName: finalName, videoPath: newVideo, audioPath: newAudio)
            AppPaths.registerDirName(finalName, for: meetingId)
            FileLogger.log("RecordingDirNaming: \(meetingId) folder → \"\(finalName)\"")
        } catch {
            // DB write failed after the move — move it back so disk + DB stay
            // consistent (resolution keeps working under the old name).
            try? fm.moveItem(at: newDir, to: currentDir)
            FileLogger.log("RecordingDirNaming: DB update failed for \(meetingId), reverted move: \(error)")
        }
    }

    /// One-time launch pass: rename every recording that already has a title but
    /// whose folder is still the plain `<id>`. Runs AFTER `loadDirNameIndex` (so
    /// existing renames are known) and AFTER title backfill (so freshly
    /// backfilled titles get named this launch, not next).
    static func migrateExistingFolders(repo: MeetingRepository) {
        guard let ids = try? repo.meetingIdsNeedingFolderRename(), !ids.isEmpty else { return }
        FileLogger.log("RecordingDirNaming: migrating \(ids.count) recording folder(s) to titled names")
        for id in ids { renameToTitled(repo: repo, meetingId: id) }
    }
}
