import AppKit
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` plus a
/// small `SPUUpdaterDelegate` that mirrors "an update is available"
/// into `AppContext.availableUpdateVersion`. The Library window's
/// React UI polls that through `/api/update-status` and renders a
/// green pill in the toolbar.
///
/// Configuration lives in `Info.plist`:
///   • `SUFeedURL`  , `https://halinskiy.github.io/corder-updates/appcast.xml`
///   • `SUPublicEDKey`, EdDSA public key, paired with the Keychain-stored
///                       private half used by `sign_update` at release time.
///   • `SUEnableInstallerLauncherService`, required on hardened runtime.
///
/// Sparkle silently checks for updates in the background using its
/// default schedule (24h). The pill click and the legacy "Check for
/// Updates…" menu item both go through `checkForUpdates`.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let delegate = UpdaterDelegateBridge()
    private let userDriver = CorderUpdateDriver()
    private let updater: SPUUpdater

    private override init() {
        // We replaced `SPUStandardUpdaterController` with a hand-built
        // `SPUUpdater` so we can plug our own `SPUUserDriver` (the
        // Corder-branded update modal in `Update/UpdateView.swift`).
        // Sparkle still owns the appcast / download / installer
        // pipeline; only the visible chrome is ours.
        let bridge = self.delegate
        let driver = self.userDriver
        self.updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            delegate: bridge
        )
        super.init()
        do {
            try updater.start()
        } catch {
            FileLogger.log("UpdateController: SPUUpdater.start failed: \(error.localizedDescription)")
        }
        // Honour the user's "Automatic updates" preference (opt-in, default
        // off). When on, Sparkle silently downloads a found update and the
        // driver defers the install to the next quit (see CorderUpdateDriver).
        updater.automaticallyDownloadsUpdates = AppSettings.autoUpdate
        // Sparkle's scheduled check fires only after the configured
        // interval (24h) has elapsed since the last successful check
        // which means a freshly installed copy doesn't hit the appcast
        // until tomorrow. Force a silent check ~2 s after launch so the
        // pill can light up right away on a meaningful release cadence.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updater.checkForUpdatesInBackground()
        }
    }

    /// Hook a "Check for Updates…" menu item OR the React toolbar
    /// pill to this selector. Sparkle owns the rest of the UX.
    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    /// Silent re-check on demand (no "you're up to date" dialog), used
    /// by the React UI before deciding whether to render the pill.
    func checkInBackground() {
        updater.checkForUpdatesInBackground()
    }

    /// Re-apply the "Automatic updates" preference after the user flips the
    /// Settings toggle (POST /api/settings calls this). Also nudges a
    /// background check so a just-enabled auto-update can pick up a pending
    /// update without waiting for the next scheduled cycle.
    func syncAutoUpdatePreference() {
        updater.automaticallyDownloadsUpdates = AppSettings.autoUpdate
        if AppSettings.autoUpdate {
            updater.checkForUpdatesInBackground()
        }
    }
}

/// Sparkle's delegate API is `@objc`-bridged Objective-C and is not
/// `@MainActor`-isolated. We keep a thin NSObject bridge here that
/// mirrors any positive "update found" callback into
/// `AppContext.availableUpdateVersion`, the field the HTTP route and
/// (transitively) the React pill observe.
private final class UpdaterDelegateBridge: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            AppContext.shared.availableUpdateVersion = version
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            AppContext.shared.availableUpdateVersion = nil
        }
    }
}
