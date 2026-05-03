import AppKit
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the
/// rest of the app doesn't have to import Sparkle.
///
/// Configuration lives in `Info.plist`:
///   • `SUFeedURL`   — `https://halinskiy.github.io/corder-updates/appcast.xml`
///   • `SUPublicEDKey` — EdDSA public key, paired with the Keychain-stored
///                       private half used by `sign_update` at release time.
///   • `SUEnableInstallerLauncherService` — required on hardened runtime.
///
/// Sparkle silently checks for updates in the background using its default
/// schedule (24h). The "Check for Updates…" menu item triggers an immediate
/// check via `checkForUpdates`.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController

    private override init() {
        // `startingUpdater: true` kicks off the background scheduler.
        // Delegates are nil — we accept Sparkle's defaults; if we need
        // custom UI ("you have to restart", "skip this version", …) we
        // can plug in `SPUUpdaterDelegate` / `SPUStandardUserDriverDelegate`.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    /// Hook a "Check for Updates…" menu item to this selector.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
