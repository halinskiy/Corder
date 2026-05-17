import AppKit
import Foundation

@MainActor
final class RecordingController {
    static let shared = RecordingController()
    private init() {
        AppContext.shared.capture.delegate = self
    }

    /// Start a new recording.
    ///
    /// `expectedOtherSpeakers` lets the caller seed the meeting with a
    /// known speaker count *before* transcription runs. The auto-detect
    /// path (MeetingDetector → `MenuBarController.showInviteOffer`) passes
    /// 1 because the vast majority of calls it catches are 1:1 — that
    /// keeps Gemini's over-counting (12-min audio sometimes diarized
    /// into 5 buckets for a single interlocutor) from showing up as a
    /// bogus "6 speakers" pill. The user can still flip to "3" or "4+"
    /// in the clarify banner and re-map without re-billing Gemini.
    /// Pass `nil` (the default, used by manual Start) to let Gemini
    /// pick the count.
    func startRecording(source: CaptureSource, expectedOtherSpeakers: Int? = nil) async {
        // Permissions
        switch await PermissionsChecker.checkScreenRecording() {
        case .granted: break
        case .denied:
            present(error: "Нет разрешения Screen Recording. Открой System Settings → Privacy → Screen Recording.")
            PermissionsChecker.openScreenRecordingSettings()
            return
        case .notDetermined:
            present(error: "Нужно разрешение Screen Recording. Подтверди в System Settings и попробуй снова.")
            PermissionsChecker.openScreenRecordingSettings()
            return
        }
        // Microphone permission: only block on explicit .denied. For .notDetermined
        // we let AVAudioEngine.start() in CaptureEngine trigger the real TCC prompt —
        // that path reliably registers the app in System Settings → Microphone,
        // whereas AVCaptureDevice.requestAccess can silently fail to surface a prompt.
        if PermissionsChecker.checkMicrophone() == .denied {
            present(error: "Нет доступа к микрофону. Открой System Settings → Privacy → Microphone и включи Corder.")
            PermissionsChecker.openMicrophoneSettings()
            return
        }

        // Disk-space preflight. A disk-full mid-recording is the
        // highest-severity failure (crash → zero-byte file). Refuse to
        // start under ~500 MB free instead of recording into a wall.
        if let free = Self.freeDiskBytes(), free < 500 * 1024 * 1024 {
            let mb = free / (1024 * 1024)
            present(error: "Мало места на диске (\(mb) МБ). Освободи место — запись не начата, чтобы не потерять её при заполнении диска.")
            return
        }

        // Per-recording session: zero the level meter so the post-stop
        // silence check reflects THIS recording only.
        RecordingLevelMeter.shared.reset()

        let id = UUID().uuidString.lowercased()
        let dir = AppPaths.recordingDir(for: id)
        let videoPath = dir.appendingPathComponent("video.mov").path
        let audioPath = dir.appendingPathComponent("mic.wav").path
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        var meeting = Meeting(
            id: id,
            startedAt: now,
            videoPath: videoPath,
            audioPath: audioPath,
            status: .recording
        )
        meeting.expectedOtherSpeakers = expectedOtherSpeakers

        do {
            try AppContext.shared.repo.insertMeeting(meeting)
            // Show the "Starting recording…" spinner inside the same
            // menu-bar popover the invite uses, so the user gets visible
            // feedback during the SCStream + AVAudioEngine warm-up
            // (~200-400 ms) on BOTH the manual Start and auto-detect
            // paths. The auto-detect path just closed the invite from
            // the same anchor, so invite → loading → blob reads as one
            // continuous element.
            MenuBarController.shared?.showLoadingState()
            try await AppContext.shared.capture.start(meetingId: id, source: source)
            AppContext.shared.recordingState = .recording(meetingId: id, startedAt: Date())
            // Capture is live — drop the loading popover. The floating
            // blob springs in from a tiny transparent dot (its own
            // entry animation), so the loading state never "morphs"
            // into it; it simply hands off.
            MenuBarController.shared?.finishLoadingState()
            // Float Granola-style recording pill over every space so the
            // user always knows capture is alive (and can stop without
            // chasing the menu bar).
            RecordingHUDPanel.shared.show()
            FileLogger.log("RecordingController: started \(id)")
        } catch {
            FileLogger.log("RecordingController: start failed for \(id): \(error)")
            // Tear down the loading popover so the user isn't left
            // staring at a spinner that never resolves.
            MenuBarController.shared?.finishLoadingState()
            present(error: "Не удалось начать запись: \(error.localizedDescription)")
            try? AppContext.shared.repo.deleteMeeting(id: id)
            AppContext.shared.recordingState = .idle
        }
    }

    func stopRecording() async {
        guard case .recording(let id, let startedAt) = AppContext.shared.recordingState else { return }
        AppContext.shared.recordingState = .stopping
        // Snapshot the silence verdict BEFORE hide(): when the floating
        // HUD is suppressed (Library window open — the normal "record a
        // call I'm watching" case) `hide()` takes its `window == nil`
        // branch and SYNCHRONOUSLY calls `RecordingLevelMeter.reset()`,
        // which zeroes sessionMax. Reading `capturedSilence` after that
        // always reported silence and fired a false "No audio captured"
        // alarm on perfectly good recordings. sessionMax already holds
        // the whole session's peak by now, so reading here is accurate.
        let capturedSilence = RecordingLevelMeter.shared.capturedSilence
        let maxMic = RecordingLevelMeter.shared.sessionMaxMic
        let maxSys = RecordingLevelMeter.shared.sessionMaxSystem
        RecordingHUDPanel.shared.hide()
        await AppContext.shared.capture.stop()

        // Tell the user *now* if nothing was actually captured (mic muted,
        // wrong input, permission silently lost) instead of letting them
        // discover an empty transcript after the meeting.
        if capturedSilence {
            FileLogger.log("stopRecording: \(id) captured silence (maxMic=\(maxMic) maxSys=\(maxSys))")
            NotificationsService.post(
                title: L.notif("notif_silent_title"),
                body: L.notif("notif_silent_body"))
        }

        let endedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationMs = Int64(Date().timeIntervalSince(startedAt) * 1000)

        do {
            if var meeting = try AppContext.shared.repo.meeting(id: id) {
                meeting.endedAt = endedAtMs
                meeting.durationMs = durationMs
                meeting.status = .transcribing
                try AppContext.shared.repo.updateMeeting(meeting)
            }
            NotificationsService.post(
                title: L.notif("notif_saved_title"),
                body: L.notif("notif_saved_body")
                    .replacingOccurrences(of: "{s}", with: "\(durationMs / 1000)"))
        } catch {
            present(error: "Не удалось сохранить запись: \(error.localizedDescription)")
        }

        AppContext.shared.recordingState = .idle

        // Kick off transcription. TranscriptionPipeline is @MainActor — running it
        // on the main actor (instead of a detached Task) keeps NSLog/FileLogger
        // emission consistent and prevents the in-flight task from being silently
        // dropped if the dispatch queue gets cleaned up under memory pressure.
        FileLogger.log("stopRecording: scheduling transcription for \(id)")
        Task { @MainActor in
            await TranscriptionPipeline.shared.enqueue(meetingId: id).value
            NotificationsService.post(
                title: L.notif("notif_ready_title"),
                body: L.notif("notif_ready_body"))
        }
    }

    /// Free space on the volume holding the recordings dir, in bytes.
    private static func freeDiskBytes() -> Int64? {
        let url = AppPaths.recordingDir(for: "probe").deletingLastPathComponent()
        let vals = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let v = vals?.volumeAvailableCapacityForImportantUsage { return v }
        // Fallback for volumes that don't report the "important usage" key.
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    private func present(error: String) {
        let alert = NSAlert()
        alert.messageText = "Corder"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension RecordingController: CaptureEngineDelegate {
    func captureEngine(_ engine: CaptureEngine, didStartMeeting id: String) {}
    func captureEngine(_ engine: CaptureEngine, didStopMeeting id: String) {}
    func captureEngine(_ engine: CaptureEngine, didFailWithError error: Error) {
        FileLogger.log("RecordingController: capture failed: \(error)")
        // Whatever meeting was being recorded is now toast — flip its DB
        // row to .failed so the UI never gets stuck on a green dot. The
        // app crash recovery (`resetStuckMeetings` on launch) covers the
        // scenario where the process dies before this delegate fires; this
        // path covers the scenario where the process stays up but SCStream
        // silently bails (most often: Screen Recording permission revoked
        // mid-session, or the user logged out and back in).
        if case .recording(let id, _) = AppContext.shared.recordingState {
            if var meeting = try? AppContext.shared.repo.meeting(id: id) {
                meeting.status = .failed
                try? AppContext.shared.repo.updateMeeting(meeting)
            }
        }
        RecordingHUDPanel.shared.hide()
        present(error: "Capture failed: \(error.localizedDescription)")
        AppContext.shared.recordingState = .idle
    }
}
