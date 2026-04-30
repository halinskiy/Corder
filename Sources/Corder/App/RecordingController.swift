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
            present(error: "Screen Recording permission denied. Open System Settings → Privacy → Screen Recording.")
            PermissionsChecker.openScreenRecordingSettings()
            return
        case .notDetermined:
            // First call to SCShareableContent triggers the prompt; surface error and bail.
            present(error: "Screen Recording permission required. Approve in System Settings, then try again.")
            PermissionsChecker.openScreenRecordingSettings()
            return
        }
        switch await PermissionsChecker.checkMicrophone() {
        case .granted: break
        case .denied, .notDetermined:
            present(error: "Microphone permission required.")
            PermissionsChecker.openMicrophoneSettings()
            return
        }

        let id = UUID().uuidString.lowercased()
        let dir = AppPaths.recordingDir(for: id)
        let videoPath = dir.appendingPathComponent("video.mov").path
        let audioPath = dir.appendingPathComponent("mic.wav").path
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let meeting = Meeting(
            id: id, startedAt: now, endedAt: nil, durationMs: nil,
            videoPath: videoPath, audioPath: audioPath,
            transcribedAt: nil, status: .recording
        )

        do {
            try AppContext.shared.repo.insertMeeting(meeting)
            try await AppContext.shared.capture.start(meetingId: id, source: source)
            AppContext.shared.recordingState = .recording(meetingId: id, startedAt: Date())
        } catch {
            present(error: "Failed to start recording: \(error.localizedDescription)")
            try? AppContext.shared.repo.deleteMeeting(id: id)
            AppContext.shared.recordingState = .idle
        }
    }

    func stopRecording() async {
        guard case .recording(let id, let startedAt) = AppContext.shared.recordingState else { return }
        AppContext.shared.recordingState = .stopping
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
            postNotification(title: "Recording saved", body: "Transcribing \(durationMs / 1000)s…")
        } catch {
            present(error: "Failed to save meeting: \(error.localizedDescription)")
        }

        AppContext.shared.recordingState = .idle

        // Kick off transcription in the background.
        Task.detached(priority: .userInitiated) {
            await TranscriptionPipeline.shared.transcribe(meetingId: id)
            await MainActor.run {
                let n = NSUserNotification()
                n.title = "Transcription ready"
                n.informativeText = "Open the Library to view it."
                NSUserNotificationCenter.default.deliver(n)
            }
        }
    }

    private func present(error: String) {
        let alert = NSAlert()
        alert.messageText = "Corder"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func postNotification(title: String, body: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        NSUserNotificationCenter.default.deliver(n)
    }
}

extension RecordingController: CaptureEngineDelegate {
    func captureEngine(_ engine: CaptureEngine, didStartMeeting id: String) {}
    func captureEngine(_ engine: CaptureEngine, didStopMeeting id: String) {}
    func captureEngine(_ engine: CaptureEngine, didFailWithError error: Error) {
        present(error: "Capture failed: \(error.localizedDescription)")
        AppContext.shared.recordingState = .idle
    }
}
