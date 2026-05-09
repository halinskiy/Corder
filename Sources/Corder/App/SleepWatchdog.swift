import AppKit

/// Watches macOS power / session events and gracefully stops an in-flight
/// recording before the OS yanks the rug out from under SCStream.
///
/// SCStream + the bundled microphone tap have proven unreliable across
/// system sleeps and fast-user-switches — the stream sometimes resumes
/// silently producing nothing, and the writer never gets a `didStopWithError`
/// callback. Instead of trying to defend against that retroactively, we just
/// stop cleanly at the first sign of trouble: the user gets up to ~30 seconds
/// notice before macOS actually suspends the process, which is plenty for
/// `RecordingController.stopRecording()` to flush the audio files and flip
/// the meeting into the transcription queue.
///
/// Events we listen to (NSWorkspace publishes them all on the main thread):
///   - `willSleepNotification`             system going to suspend
///   - `screensDidSleepNotification`       display sleep — usually harmless,
///                                          but combined with extended idle
///                                          it tends to silently kill mic
///   - `sessionDidResignActiveNotification` fast user switch / login window
@MainActor
final class SleepWatchdog {
    static let shared = SleepWatchdog()
    private init() {}

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        // The closures themselves are Sendable + nonisolated even though
        // NSWorkspace delivers on the main thread, so we hop into MainActor
        // explicitly via `Task { @MainActor }` to satisfy strict concurrency.
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                SleepWatchdog.shared.handle(reason: "system-sleep",
                                             message: "Recording stopped: Mac is going to sleep.")
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                SleepWatchdog.shared.handle(reason: "screen-sleep",
                                             message: "Recording stopped: display went to sleep.")
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                SleepWatchdog.shared.handle(reason: "session-switch",
                                             message: "Recording stopped: switching user account.")
            }
        })

        FileLogger.log("SleepWatchdog: observers installed")
    }

    private func handle(reason: String, message: String) {
        // Only react if we're actually recording. Sleep events fire
        // routinely; we don't want to spam notifications while the user
        // is just closing the lid with nothing in flight.
        guard case .recording = AppContext.shared.recordingState else { return }

        FileLogger.log("SleepWatchdog: \(reason) — auto-stopping recording")
        Task { @MainActor in
            await RecordingController.shared.stopRecording()
            NotificationsService.post(
                title: "Запись остановлена",
                body: message
            )
        }
    }
}
