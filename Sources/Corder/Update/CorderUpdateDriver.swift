import AppKit
import Sparkle

/// Sparkle `SPUUserDriver` implementation that drives the React-side
/// update modal living inside the Library WKWebView. Every phase
/// builds a fresh `UpdateModalState` and pushes it through
/// `UpdateBridge`; the WebView posts back `primary` / `dismiss`
/// actions, which the bridge routes to the reply callbacks we stash
/// here.
@MainActor
final class CorderUpdateDriver: NSObject, SPUUserDriver {

    private var bridge: UpdateBridge { UpdateBridge.shared }
    private var pendingUserInitiatedCheck = false
    /// Cached version + release notes so we can keep the modal
    /// up-to-date through download / extract phases without losing
    /// the headline the user already saw.
    private var lastVersion: String = ""
    private var lastReleaseNotes: String? = nil

    // MARK: - Permission request

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(.init(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: - User-initiated check

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        pendingUserInitiatedCheck = true
        _ = cancellation
    }

    // MARK: - Update found

    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingUserInitiatedCheck = false
        lastVersion = appcastItem.displayVersionString
        lastReleaseNotes = htmlToPlain(appcastItem.itemDescription ?? "")

        let phase: String
        let primaryLabel: String
        switch updateState.stage {
        case .notDownloaded:
            phase = "available"
            primaryLabel = "Update"
        case .downloaded:
            phase = "readyToInstall"
            primaryLabel = "Install and relaunch"
        case .installing:
            phase = "installing"
            primaryLabel = "Installing…"
        @unknown default:
            phase = "available"
            primaryLabel = "Update"
        }

        bridge.onPrimary = { [weak self] in
            // Optimistically flip to "downloading" so the user gets
            // immediate feedback while Sparkle works.
            self?.pushPhase(phase == "readyToInstall" ? "installing" : "downloading",
                            primaryLabel: phase == "readyToInstall" ? "Installing…" : "Downloading…",
                            primaryEnabled: false)
            reply(.install)
        }
        bridge.onDismiss = { reply(.dismiss) }

        push(visible: true, phase: phase, primaryLabel: primaryLabel,
             primaryEnabled: true,
             statusLine: phase == "available"
                ? "Tap Update to download and install."
                : "Ready to install. We'll relaunch Corder.",
             showsProgress: false, progress: 0)
    }

    // MARK: - Release notes

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let text = String(data: downloadData.data, encoding: .utf8) ?? ""
        lastReleaseNotes = htmlToPlain(text)
        // Re-push so React picks up the freshly-loaded notes.
        push(visible: true, phase: "available",
             primaryLabel: "Update", primaryEnabled: true,
             statusLine: "Tap Update to download and install.",
             showsProgress: false, progress: 0)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { _ = error }

    // MARK: - No update found

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        _ = error
        guard pendingUserInitiatedCheck else { acknowledgement(); return }
        pendingUserInitiatedCheck = false
        lastVersion = ""
        lastReleaseNotes = nil
        bridge.onPrimary = { [weak self] in
            acknowledgement()
            self?.hide()
        }
        bridge.onDismiss = { [weak self] in
            acknowledgement()
            self?.hide()
        }
        // No-update modal: title states the conclusion ("You're up to
        // date"), the status line just confirms with the current
        // version, and the only action is "OK" — there's nothing to
        // install, so the previous "Update available" / "Update now"
        // labels were straight-up misleading (Костя caught this).
        // No-update modal: just a confirmation card. Primary (Update
        // now / OK) is suppressed — there's literally nothing to do
        // here, so the only affordance is the secondary "Later" which
        // dismisses the dialog. Empty `primaryLabel` is the contract
        // the React side reads to hide the primary slot.
        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        push(visible: true, phase: "upToDate",
             primaryLabel: "", primaryEnabled: false,
             statusLine: current.isEmpty ? nil : "Corder \(current)",
             showsProgress: false, progress: 0,
             versionOverride: "You're up to date")
    }

    // MARK: - Updater error

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        bridge.onPrimary = { [weak self] in
            acknowledgement()
            self?.hide()
        }
        bridge.onDismiss = { [weak self] in
            acknowledgement()
            self?.hide()
        }
        push(visible: true, phase: "error",
             primaryLabel: "OK", primaryEnabled: true,
             statusLine: error.localizedDescription,
             showsProgress: false, progress: 0,
             errorMessage: error.localizedDescription)
    }

    // MARK: - Download

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        bridge.onDismiss = { cancellation() }
        pushPhase("downloading", primaryLabel: "Downloading…", primaryEnabled: false,
                  statusLine: "Downloading the update", showsProgress: true, progress: 0)
    }

    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        receivedBytes = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        let p = expectedBytes > 0 ? min(1.0, Double(receivedBytes) / Double(expectedBytes)) : 0
        let mb = expectedBytes > 0 ? Double(expectedBytes) / 1_048_576.0 : 0
        let line = expectedBytes > 0 ? String(format: "Downloading %.1f MB", mb) : "Downloading the update"
        pushPhase("downloading", primaryLabel: "Downloading…", primaryEnabled: false,
                  statusLine: line, showsProgress: true, progress: p)
    }

    // MARK: - Extraction

    func showDownloadDidStartExtractingUpdate() {
        pushPhase("extracting", primaryLabel: "Preparing…", primaryEnabled: false,
                  statusLine: "Unpacking the update", showsProgress: true, progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        pushPhase("extracting", primaryLabel: "Preparing…", primaryEnabled: false,
                  statusLine: "Unpacking the update", showsProgress: true, progress: progress)
    }

    // MARK: - Ready to install

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        bridge.onPrimary = { [weak self] in
            self?.pushPhase("installing", primaryLabel: "Installing…", primaryEnabled: false)
            reply(.install)
        }
        bridge.onDismiss = { reply(.dismiss) }
        pushPhase("readyToInstall", primaryLabel: "Install and relaunch",
                  primaryEnabled: true,
                  statusLine: "Ready to install. We'll relaunch Corder.",
                  showsProgress: false, progress: 1)
    }

    // MARK: - Installing

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        pushPhase("installing", primaryLabel: "Installing…", primaryEnabled: false,
                  statusLine: "Installing. Corder will relaunch.", showsProgress: false, progress: 0)
        // With a custom SPUUserDriver, terminating the app so Sparkle can
        // swap the bundle is OUR responsibility (the standard driver does
        // it too). Without this the install hangs forever at "Installing…"
        // because the updater is waiting for the host to quit. After we
        // terminate, Sparkle's installer swaps and relaunches the new
        // version. Nothing in this app blocks termination
        // (no applicationShouldTerminate).
        if !applicationTerminated {
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    // MARK: - Installed

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        _ = relaunched
        acknowledgement()
        hide()
    }

    // MARK: - Dismiss / focus

    func dismissUpdateInstallation() { hide() }
    func showUpdateInFocus() { /* WebView is already focused if Library is open */ }

    // MARK: - Helpers

    private func pushPhase(_ phase: String, primaryLabel: String, primaryEnabled: Bool,
                           statusLine: String? = nil, showsProgress: Bool = false,
                           progress: Double = 0) {
        push(visible: true, phase: phase, primaryLabel: primaryLabel,
             primaryEnabled: primaryEnabled,
             statusLine: statusLine, showsProgress: showsProgress, progress: progress)
    }

    private func push(visible: Bool, phase: String, primaryLabel: String,
                      primaryEnabled: Bool, statusLine: String?,
                      showsProgress: Bool, progress: Double,
                      versionOverride: String? = nil,
                      errorMessage: String? = nil) {
        let state = UpdateModalState(
            visible: visible,
            phase: phase,
            version: versionOverride ?? (lastVersion.isEmpty ? "Update available" : "Version \(lastVersion)"),
            releaseNotes: lastReleaseNotes,
            progress: progress,
            primaryLabel: primaryLabel,
            primaryEnabled: primaryEnabled,
            phaseStatusLine: statusLine,
            showsProgress: showsProgress,
            errorMessage: errorMessage
        )
        bridge.push(state)
    }

    private func hide() {
        let state = UpdateModalState(
            visible: false, phase: "available", version: "",
            releaseNotes: nil, progress: 0, primaryLabel: "",
            primaryEnabled: false, phaseStatusLine: nil,
            showsProgress: false, errorMessage: nil
        )
        bridge.push(state)
    }

    /// Quick HTML → plain text for the appcast description CDATA.
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
