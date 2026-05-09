import AppKit
import Foundation

@MainActor
final class RecordingController {
    static let shared = RecordingController()
    private init() {
        AppContext.shared.capture.delegate = self
    }

    func startRecording(source: CaptureSource) async {
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

        let id = UUID().uuidString.lowercased()
        let dir = AppPaths.recordingDir(for: id)
        let videoPath = dir.appendingPathComponent("video.mov").path
        let audioPath = dir.appendingPathComponent("mic.wav").path
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let meeting = Meeting(
            id: id,
            startedAt: now,
            videoPath: videoPath,
            audioPath: audioPath,
            status: .recording
        )

        do {
            try AppContext.shared.repo.insertMeeting(meeting)
            try await AppContext.shared.capture.start(meetingId: id, source: source)
            AppContext.shared.recordingState = .recording(meetingId: id, startedAt: Date())
            // Float Granola-style recording pill over every space so the
            // user always knows capture is alive (and can stop without
            // chasing the menu bar).
            RecordingHUDPanel.shared.show()
            FileLogger.log("RecordingController: started \(id)")
        } catch {
            FileLogger.log("RecordingController: start failed for \(id): \(error)")
            present(error: "Не удалось начать запись: \(error.localizedDescription)")
            try? AppContext.shared.repo.deleteMeeting(id: id)
            AppContext.shared.recordingState = .idle
        }
    }

    func stopRecording() async {
        guard case .recording(let id, let startedAt) = AppContext.shared.recordingState else { return }
        AppContext.shared.recordingState = .stopping
        RecordingHUDPanel.shared.hide()
        await AppContext.shared.capture.stop()

        let endedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationMs = Int64(Date().timeIntervalSince(startedAt) * 1000)

        do {
            if var meeting = try AppContext.shared.repo.meeting(id: id) {
                meeting.endedAt = endedAtMs
                meeting.durationMs = durationMs
                meeting.status = .transcribing
                try AppContext.shared.repo.updateMeeting(meeting)
            }
            NotificationsService.post(title: "Запись сохранена",
                                      body: "Расшифровка \(durationMs / 1000)с…")
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
            NotificationsService.post(title: "Расшифровка готова",
                                      body: "Открой библиотеку чтобы посмотреть.")
        }
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
