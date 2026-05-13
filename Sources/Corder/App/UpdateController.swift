import AppKit
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` plus a
/// small `SPUUpdaterDelegate` that mirrors "an update is available"
/// into `AppContext.availableUpdateVersion`. The Library window's
/// React UI polls that through `/api/update-status` and renders a
/// green pill in the toolbar.
///
/// Configuration lives in `Info.plist`:
///   • `SUFeedURL`   — `https://halinskiy.github.io/corder-updates/appcast.xml`
///   • `SUPublicEDKey` — EdDSA public key, paired with the Keychain-stored
///                       private half used by `sign_update` at release time.
///   • `SUEnableInstallerLauncherService` — required on hardened runtime.
///
/// Sparkle silently checks for updates in the background using its
/// default schedule (24h). The pill click and the legacy "Check for
/// Updates…" menu item both go through `checkForUpdates`.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let delegate = UpdaterDelegateBridge()
    private let controller: SPUStandardUpdaterController

    private override init() {
        // `startingUpdater: true` kicks off the background scheduler.
        // We plug our own delegate so we get notified whenever the
        // appcast resolves a newer version; that signal feeds the pill
        // shown in the React toolbar.
        let bridge = self.delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bridge,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Hook a "Check for Updates…" menu item OR the React toolbar
    /// pill to this selector. Sparkle owns the rest of the UX.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// Silent re-check on demand (no "you're up to date" dialog) — used
    /// by the React UI before deciding whether to render the pill.
    func checkInBackground() {
        controller.updater.checkForUpdatesInBackground()
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
