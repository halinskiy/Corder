import AppKit

/// Watches macOS power / session events and gracefully stops an in-flight
/// recording before the OS yanks the rug out from under SCStream.
///
/// SCStream + the bundled microphone tap have proven unreliable across
/// system sleeps and fast-user-switches, the stream sometimes resumes
/// silently producing nothing, and the writer never gets a `didStopWithError`
/// callback. Instead of trying to defend against that retroactively, we just
/// stop cleanly at the first sign of trouble: the user gets up to ~30 seconds
/// notice before macOS actually suspends the process, which is plenty for
/// `RecordingController.stopRecording()` to flush the audio files and flip
/// the meeting into the transcription queue.
///
/// Events we listen to (NSWorkspace publishes them all on the main thread):
///   - `willSleepNotification`             system going to suspend
///   - `screensDidSleepNotification`       display sleep, usually harmless,
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
        // React to BOTH a live recording AND a silent pre-roll. Pre-roll
        // (now default-ON, auto-armed when a meeting app grabs the mic) arms
        // a FULL capture, SCStream + Core-Audio tap + mic, so if the Mac
        // sleeps / the screen sleeps / the user switches accounts while an
        // unanswered invite-offer popover sits open, the OS would suspend the
        // process with capture still live (zombie capture, stuck privacy
        // indicator) exactly as it would for a real recording. Sleep events
        // fire routinely, so do nothing when nothing is in flight.
        switch AppContext.shared.recordingState {
        case .recording:
            FileLogger.log("SleepWatchdog: \(reason), auto-stopping recording")
            Task { @MainActor in
                await RecordingController.shared.stopRecording()
                NotificationsService.post(
                    title: L.notif("notif_stopped_title"),
                    body: message
                )
            }
        case .preroll:
            // Tear the pre-roll capture down silently, there's no committed
            // meeting to notify about, just a buffered offer in flight.
            FileLogger.log("SleepWatchdog: \(reason), discarding live pre-roll capture")
            Task { @MainActor in
                await RecordingController.shared.discardPreroll()
            }
        default:
            return
        }
    }
}
