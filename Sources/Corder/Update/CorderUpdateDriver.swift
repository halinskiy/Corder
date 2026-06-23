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
        // ALWAYS give visible feedback the instant the pill is clicked. The
        // old no-op (just setting the flag) left the click silent whenever
        // Sparkle already had a cached / downloaded update and didn't
        // re-present it — the user just saw a pressed pill and nothing else.
        // We push a "checking" modal here; Sparkle then transitions it to
        // the real Install card (showUpdateFound) or "up to date"
        // (showUpdateNotFound). `onPrimary` stays a no-op until a real
        // update is reported (the Install button is disabled meanwhile).
        bridge.onDismiss = { cancellation() }
        bridge.onPrimary = { }
        push(visible: true, phase: "available", primaryLabel: "Install",
             primaryEnabled: false,
             statusLine: "Checking for updates…",
             showsProgress: false, progress: 0)
    }

    // MARK: - Update found

    func showUpdateFound(with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingUserInitiatedCheck = false
        lastVersion = appcastItem.displayVersionString
        lastReleaseNotes = htmlToPlain(appcastItem.itemDescription ?? "")
        FileLogger.log("UpdateDriver: showUpdateFound stage=\(updateState.stage.rawValue) version=\(appcastItem.displayVersionString)")

        // The button label is ALWAYS "Install" through the whole flow —
        // never a frozen "Installing…" verb. Progress is shown inside
        // the button (an in-button fill), not by swapping the text.
        let phase: String
        let readyToInstall: Bool
        switch updateState.stage {
        case .notDownloaded:
            phase = "available";       readyToInstall = false
        case .downloaded:
            phase = "readyToInstall";  readyToInstall = true
        case .installing:
            // A resumed install. Present it as a RESTING "ready to
            // install" card (enabled "Install", no spinner) — NOT an
            // in-progress one. The modal must not animate before the
            // user clicks; the click resumes the install. (Showing this
            // as "installing" made the progress bar fill on its own at
            // rest, which read as "it's doing something I didn't ask
            // for".)
            phase = "readyToInstall";  readyToInstall = true
        @unknown default:
            phase = "available";       readyToInstall = false
        }

        bridge.onPrimary = { [weak self] in
            FileLogger.log("UpdateDriver: onPrimary(showUpdateFound) phase=\(phase) → reply(.install)")
            // Reflect that work started (button shows the in-button
            // progress fill, label stays "Install", button disabled).
            self?.pushPhase(readyToInstall ? "installing" : "downloading",
                            primaryLabel: "Install", primaryEnabled: false)
            // Hand off to Sparkle. Sparkle drives download → extract →
            // install and terminates US via `showInstallingUpdate`
            // (proven to terminate + relaunch cleanly). We must NOT call
            // NSApp.terminate here too: a second termination races
            // Sparkle's install/relaunch handshake and wedges the update
            // at "Installing…" forever — that was the real hang.
            reply(.install)
        }
        bridge.onDismiss = { reply(.dismiss) }

        push(visible: true, phase: phase, primaryLabel: "Install",
             primaryEnabled: true,
             statusLine: phase == "available"
                ? "Tap Install to download and install."
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
        FileLogger.log("UpdateDriver: showReady(toInstallAndRelaunch)")
        bridge.onPrimary = { [weak self] in
            FileLogger.log("UpdateDriver: onPrimary(showReady) → reply(.install)")
            // Just reply .install; Sparkle calls showInstallingUpdate
            // next, which is the single place we terminate. No second
            // terminate here (see showUpdateFound for why).
            self?.pushPhase("installing", primaryLabel: "Install", primaryEnabled: false)
            reply(.install)
        }
        bridge.onDismiss = { reply(.dismiss) }
        pushPhase("readyToInstall", primaryLabel: "Install",
                  primaryEnabled: true,
                  statusLine: "Ready to install. We'll relaunch Corder.",
                  showsProgress: false, progress: 1)
    }

    // MARK: - Installing

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        FileLogger.log("UpdateDriver: showInstallingUpdate applicationTerminated=\(applicationTerminated)")
        pushPhase("installing", primaryLabel: "Install", primaryEnabled: false,
                  statusLine: "Installing. Corder will relaunch.", showsProgress: false, progress: 0)
        // THE single place we terminate. With a custom SPUUserDriver,
        // quitting the host so Sparkle's installer can swap the bundle is
        // our responsibility. Sparkle then relaunches the new version.
        // Verified end-to-end: this one terminate quits + relaunches in
        // ~1 s. Do NOT add a second terminate in the onPrimary handlers —
        // two terminations race the install/relaunch handshake and wedge
        // the update at "Installing…" forever. Nothing in this app vetoes
        // termination (applicationShouldTerminate returns .terminateNow).
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

    /// Quick HTML → plain text for the appcast description CDATA. The
    /// modal title already shows "Version X.Y.Z", so we strip the
    /// changelog's leading version heading and collapse the stray
    /// whitespace it leaves behind — the notes should read as plain
    /// text, not a sparse indented outline.
    private func htmlToPlain(_ html: String) -> String {
        var s = html
        // Drop every heading (the changelog prefixes each entry with the
        // version as <h3>); it only duplicates the title above.
        s = s.replacingOccurrences(of: "<h[1-6][^>]*>.*?</h[1-6]>",
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "</p>", with: "\n")
        s = s.replacingOccurrences(of: "<br>", with: "\n")
        s = s.replacingOccurrences(of: "<br/>", with: "\n")
        s = s.replacingOccurrences(of: "<br />", with: "\n")
        // List items → plain lines (NO bullet prefix — the notes must
        // read as plain text, no "•"/"-"/"·" markers).
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "</li>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Trim per-line indentation and collapse blank-line runs so a
        // single-bullet changelog renders as one tight line.
        let lines = s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines {
            if line.isEmpty && (out.last?.isEmpty ?? true) { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
