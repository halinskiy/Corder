import AppKit
import Sparkle

/// Our own implementation of `SPUUserDriver` — the protocol Sparkle
/// asks an app to implement when it wants to take over the update UI
/// from `SPUStandardUpdaterController`. Sparkle calls these methods
/// on the main actor; we route everything through `UpdateState` /
/// `UpdateWindowController`.
@MainActor
final class CorderUpdateDriver: NSObject, SPUUserDriver {

    private var window: UpdateWindowController { UpdateWindowController.shared }
    private var state: UpdateState { window.state }

    // MARK: - Permission request

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(.init(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - User-initiated check

    private var pendingUserInitiatedCheck = false

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // The user hit "Check for Updates" — remember the click so the
        // "no update found" path can surface a confirmation instead of
        // silently ack'ing (which made it look like nothing happened).
        // Sparkle calls this BEFORE either `showUpdateFound:` or
        // `showUpdateNotFoundWithError:`.
        pendingUserInitiatedCheck = true
        _ = cancellation
    }

    // MARK: - Update found

    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingUserInitiatedCheck = false
        let s = self.state
        s.versionString = appcastItem.displayVersionString
        s.releaseNotes = htmlToPlain(appcastItem.itemDescription ?? "")
        switch updateState.stage {
        case .notDownloaded:    s.phase = .available
        case .downloaded:       s.phase = .readyToInstall
        case .installing:       s.phase = .installing
        @unknown default:       s.phase = .available
        }
        window.onPrimary = {
            switch s.phase {
            case .available:        s.phase = .downloading
            case .readyToInstall:   s.phase = .installing
            default: break
            }
            reply(.install)
        }
        window.onDismiss = { reply(.dismiss) }
        window.present()
    }

    // MARK: - Release notes

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let text = String(data: downloadData.data, encoding: .utf8) ?? ""
        state.releaseNotes = htmlToPlain(text)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        _ = error
    }

    // MARK: - No update found

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        _ = error
        // Silent scheduled check → just ack, no UI. User-initiated
        // check → show the modal in `.upToDate` state so the click
        // gets a confirmation ("you are on the latest version") +
        // an OK button to dismiss. Without this, the menu item
        // looked broken.
        guard pendingUserInitiatedCheck else { acknowledgement(); return }
        pendingUserInitiatedCheck = false
        let s = self.state
        s.versionString = ""
        s.releaseNotes = nil
        s.phase = .upToDate
        window.onPrimary = { [weak self] in
            acknowledgement()
            self?.window.close()
        }
        window.onDismiss = { [weak self] in
            acknowledgement()
            self?.window.close()
        }
        window.present()
    }

    // MARK: - Updater error

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        state.phase = .error(error.localizedDescription)
        window.onPrimary = { [weak self] in
            self?.state.phase = .available
            acknowledgement()
            self?.window.close()
        }
        window.onDismiss = { acknowledgement() }
        window.present()
    }

    // MARK: - Download

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        state.phase = .downloading
        state.receivedBytes = 0
        state.expectedBytes = 0
        state.progress = 0
        window.onDismiss = { cancellation() }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        state.expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        state.receivedBytes += length
        if state.expectedBytes > 0 {
            state.progress = min(1, Double(state.receivedBytes) / Double(state.expectedBytes))
        }
    }

    // MARK: - Extraction

    func showDownloadDidStartExtractingUpdate() {
        state.phase = .extracting
        state.progress = 0
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        state.progress = progress
    }

    // MARK: - Ready to install

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        state.phase = .readyToInstall
        state.progress = 1
        window.onPrimary = { [weak self] in
            self?.state.phase = .installing
            reply(.install)
        }
        window.onDismiss = { reply(.dismiss) }
    }

    // MARK: - Installing

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        state.phase = .installing
        _ = applicationTerminated
        _ = retryTerminatingApplication
    }

    // MARK: - Installed

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state.phase = .installed
        _ = relaunched
        acknowledgement()
        window.close()
    }

    // MARK: - Dismiss / focus

    func dismissUpdateInstallation() {
        window.close()
    }

    func showUpdateInFocus() {
        window.present()
    }

    // MARK: - Helpers

    /// Quick-and-dirty HTML → plain text. Sparkle ships release notes
    /// as `<![CDATA[ <h3>...</h3><p>...</p> ]]>`; we render them in a
    /// monochrome `Text` view so the tag noise has to go.
    private func htmlToPlain(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "</p>", with: "\n\n")
        s = s.replacingOccurrences(of: "<br>", with: "\n")
        s = s.replacingOccurrences(of: "<br/>", with: "\n")
        s = s.replacingOccurrences(of: "<br />", with: "\n")
        s = s.replacingOccurrences(of: "</h3>", with: "\n\n")
        s = s.replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
