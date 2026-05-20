import AppKit
import UserNotifications

/// Thin wrapper around `UserNotifications.framework`. We dropped the legacy
/// `NSUserNotification` API (deprecated since macOS 11) for two reasons:
///   - Apple keeps eroding it in each release; banners stopped honouring
///     `shouldPresent` reliably on Sonoma.
///   - The new framework is the only path to interactive actions, sound
///     control, and persistent delivery.
///
/// Public surface is intentionally small: ask for permission once on launch,
/// post a banner, and let the delegate route taps back to the Library window.
@MainActor
enum NotificationsService {
    /// Identifier used for every banner Corder posts — there's only ever one
    /// "transcription ready" type at a time, so a fixed id is enough.
    static let categoryID = "corder.notification"

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error = error {
                        FileLogger.log("Notifications: requestAuthorization error: \(error)")
                    } else {
                        FileLogger.log("Notifications: authorization granted=\(granted)")
                    }
                }
            case .denied:
                FileLogger.log("Notifications: authorization is .denied — banners will be silent")
            default:
                break
            }
        }
    }

    /// Posts a banner with the given copy. `userInfo[.action]` is read by the
    /// app's UNUserNotificationCenterDelegate when the user clicks; the only
    /// supported action right now is `openLibrary`.
    static func post(title: String, body: String, action: Action = .openLibrary) {
        // Central kill-switch: the Settings "Notifications" toggle gates
        // every post site at the source (RecordingController, SleepWatchdog,
        // NetworkMonitor, …) so no call site can leak past it.
        guard AppSettings.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["action": action.rawValue]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                FileLogger.log("Notifications: post failed: \(error)")
            }
        }
    }

    enum Action: String {
        case openLibrary
    }
}
