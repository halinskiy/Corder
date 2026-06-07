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

    /// Stable identifier reused across every Corder banner. macOS
    /// Notification Center replaces an existing notification with the
    /// same identifier instead of stacking a new one — exactly what
    /// we want: Corder's banners are status updates ("transcription
    /// ready", "silent recording archived", "network lost"), each
    /// new one supersedes the previous, the Center shouldn't pile
    /// them up into a list of stale items the user has to clear.
    private static let bannerID = "corder.notification.live"

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
        // Softer notification tone than the macOS default "Funk" /
        // "Bottle" alert. `Glass.aiff` ships in /System/Library/Sounds/
        // on every macOS — short, gentle water-drop chime, much less
        // jarring than the default banner sound. Falls back to system
        // default if the file isn't where we expect (older macOS / a
        // user who deleted it).
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "Glass.aiff"))
        content.userInfo = ["action": action.rawValue]
        // `threadIdentifier` groups the banner in Notification Center
        // so even when iOS-like grouping is on, every Corder banner
        // lands in the same row instead of fanning out per identifier.
        content.threadIdentifier = bannerID

        let center = UNUserNotificationCenter.current()
        // Strip the previous Corder banner BEFORE adding the new one
        // so the Notification Center never carries two of ours at the
        // same time (`add` with the same identifier is documented to
        // replace, but Sonoma occasionally double-delivers if the
        // previous request was already in the queue with a different
        // pending content payload — the explicit remove avoids that).
        center.removeDeliveredNotifications(withIdentifiers: [bannerID])
        center.removePendingNotificationRequests(withIdentifiers: [bannerID])

        let request = UNNotificationRequest(
            identifier: bannerID,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error = error {
                FileLogger.log("Notifications: post failed: \(error)")
            }
        }
    }

    /// Per-banner action surfaced when the user clicks. `openLibrary`
    /// is the default fallback for app-internal notifications; `openURL`
    /// carries an external link as its payload (used by `NewsPoller`
    /// to send the reader to the news item's CTA in the browser).
    enum Action: RawRepresentable {
        case openLibrary
        case openURL(URL)

        var rawValue: String {
            switch self {
            case .openLibrary:      return "openLibrary"
            case .openURL(let u):   return "openURL:\(u.absoluteString)"
            }
        }

        init?(rawValue: String) {
            if rawValue == "openLibrary" { self = .openLibrary; return }
            if rawValue.hasPrefix("openURL:") {
                let s = String(rawValue.dropFirst("openURL:".count))
                if let u = URL(string: s) { self = .openURL(u); return }
            }
            return nil
        }
    }
}
