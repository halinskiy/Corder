import AppKit
import SwiftUI
import AVFoundation
import CoreGraphics
import UserNotifications
@preconcurrency import Supabase

/// Welcome / onboarding window shown on first launch (and any later
/// launch where the user closed it before finishing). Five steps:
/// Welcome → Microphone permission → Screen Recording permission →
/// Paste licence key → Done.
///
/// Style notes (intentional, see Kostya's feedback):
///  - **No iconography.** Every step is text + buttons. SF Symbols
///    inside a tinted badge read as "early Apple sample app" rather
///    than Linear / Granola / Raycast.
///  - **Slide transitions** between steps. Each step enters from the
///    right, leaves to the left, with a soft opacity crossfade —
///    same "move on" cadence a paged onboarding has.
///  - Native SwiftUI rather than the WKWebView/Library route because
///    permission APIs are easier to call directly than through a JS
///    bridge.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    /// Wizard window sizing. 380 × 580 default; user can resize
    /// between min/max bounds.
    private static let kWidth: CGFloat = 380
    /// Single fixed height across every step + loading state.
    /// Removes the resizing-on-step-change flicker Kostya hated.
    private static let kHeight: CGFloat = 516
    private static let kDefaultContentSize = NSSize(width: kWidth, height: kHeight)
    private static let kMinContentSize     = NSSize(width: kWidth, height: kHeight)
    private static let kMaxContentSize     = NSSize(width: kWidth, height: kHeight)

    private var window: NSWindow?
    /// Shared state — observed/mutated by the wizard body.
    private let wizardState = WizardState()

    /// Auto-open the wizard if the user hasn't finished it yet.
    /// Called from `AppDelegate.applicationDidFinishLaunching` after
    /// the local server is up.
    func presentIfNeeded() {
        if AppSettings.onboardingCompleted { return }
        present()
    }

    /// Manual open — used by the menu-bar popover's "Show welcome…"
    /// item so the user can replay the flow (e.g. to paste a licence
    /// key bought after the first launch).
    func presentManually() { present() }

    private func present() {
        // Bootstrap the sticky permission flags from "previous use"
        // evidence: if there are any meetings in the local DB then
        // the user MUST have granted Screen Recording + Microphone
        // at some point — capture would have failed otherwise. This
        // covers the sign-out / re-install case where TCC remembers
        // the grant but `CGPreflightScreenCaptureAccess` (process-
        // cached) reports false until the first live capture call.
        //
        // IMPORTANT: only bootstrap when the live status agrees. If
        // priorMeetings > 0 BUT the live preflight reports denied/
        // notDetermined, TCC genuinely lost the grants (e.g. an
        // identity change between builds — self-signed → Developer ID,
        // Костя's case). Bootstrapping sticky=true here would put the
        // wizard on `.signin` step while LibraryWindow blocks on the
        // real live denial, looping forever.
        let priorMeetings = (try? AppContext.shared.repo.listMeetings())?.count ?? 0
        let bootstrapMicOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let bootstrapScreenOK = CGPreflightScreenCaptureAccess()
        if priorMeetings > 0 && bootstrapMicOK    && !AppSettings.micGrantedSticky    { AppSettings.setMicGrantedSticky(true) }
        if priorMeetings > 0 && bootstrapScreenOK && !AppSettings.screenGrantedSticky { AppSettings.setScreenGrantedSticky(true) }

        // Re-evaluate the right starting step EVERY time the wizard
        // surfaces (cold first run AND every sign-out re-open). The
        // shared `wizardState` keeps the previous step otherwise,
        // which was wrong after sign-out: the wizard would re-open
        // on `.permissions` even though the user had granted both
        // mic + screen back on their first install.
        let mic = currentMicStatus()
        let screen = currentScreenStatus()
        FileLogger.log("WelcomeWindow.present: mic=\(mic) screen=\(screen) priorMeetings=\(priorMeetings) savedStep=\(AppSettings.onboardingStep)")
        if mic == .granted, screen == .granted {
            wizardState.step = .signin
            AppSettings.setOnboardingStep(WizardStep.signin.rawValue)
        } else {
            wizardState.step = .permissions
            AppSettings.setOnboardingStep(WizardStep.permissions.rawValue)
        }

        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = WelcomeView(
            onFinish: { [weak self] result in
                AppSettings.setOnboardingCompleted(true)
                AppSettings.setOnboardingStep(0)
                // Persist the signed-in email so the profile popover
                // can show it under the display name (replaces the
                // hard-coded "Kostiantyn Halynskyi"). Sign-out clears
                // this in `accountSignOut`.
                if let email = result?.email, !email.isEmpty {
                    AppSettings.setUserEmail(email)
                }
                if let name = result?.displayName, !name.isEmpty {
                    AppSettings.setUserName(name)
                }
                FileLogger.log("WelcomeWindow: onboarding completed (provider=\(result?.provider ?? "n/a"))")
                // Multi-account local storage: each Supabase user
                // owns their own folder under `accounts/<email-hash>/`.
                // GRDB binds the DB path on first access and we
                // can't swap it live, so the only correct path on
                // sign-in is to relaunch — the new process boots
                // pointing at the right account folder, migrates
                // the legacy flat-layout files in if needed, and
                // pulls from cloud during AppDelegate launch.
                if let email = result?.email, !email.isEmpty {
                    AppPaths.migrateLegacyIfNeeded(forEmail: email)
                }
                self?.close()
                CorderRelaunch.now()
                return
                // Land the user in the main app: open the Library
                // window and fire a welcome toast. We do this on the
                // next runloop tick so the wizard's close animation
                // doesn't fight the new key window's z-order.
                DispatchQueue.main.async {
                    LibraryWindow.shared.show(
                        serverURL: AppContext.shared.server.baseURL)
                    if let result {
                        // Short, no em-dash. First sign-in this
                        // install ever saw gets a bare "Welcome";
                        // every later sign-in is "Welcome back".
                        // `wasFirstSignIn` was captured BEFORE the
                        // sign-in handler flipped the sticky flag.
                        let title = result.wasFirstSignIn ? "Welcome" : "Welcome back"
                        LibraryWindow.shared.postToast(
                            title: title, body: "", kind: "success")
                    }
                }
            },
            state: wizardState
        )
        // NSHostingView with `autoresizingMask` so the SwiftUI body
        // reflows when the user resizes the window between
        // `kMinContentSize` and `kMaxContentSize`.
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: Self.kDefaultContentSize)
        host.autoresizingMask = [.width, .height]

        // `.miniaturizable` so the user can hide the wizard with
        // the yellow titlebar button (or window menu) — earlier
        // build had no way to set it aside.
        // No `.fullScreenAuxiliary` in collectionBehavior below —
        // we want fullscreen apps (YouTube etc) to obscure the
        // wizard, not vice versa.
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.kDefaultContentSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        w.contentView = host
        w.title = "Welcome to Corder"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        // Window background = brand-green so any pixel-row that the
        // SwiftUI body doesn't paint at the very bottom (e.g. the
        // macOS rounded-corner clip area below the CTA slab) blends
        // with the green CTA instead of showing a white gap.
        // The top section is explicitly painted white inside the
        // VStack so this colour only ever shows through behind the
        // bottom edge.
        w.backgroundColor = NSColor(red: 0x1F / 255.0,
                                     green: 0x7A / 255.0,
                                     blue: 0x4F / 255.0,
                                     alpha: 1.0)
        // `.moveToActiveSpace` only — `.fullScreenAuxiliary` would
        // have let the wizard float over a fullscreen YouTube /
        // Safari, which Kostya saw as "the wizard is stuck and
        // I can't click out of it".
        w.collectionBehavior = [.moveToActiveSpace]
        // User-resize clamps. The min keeps the title from clipping
        // (320 width is enough for "Welcome to Corder" at 36 pt over
        // two lines); the max caps growth at the original 540 so the
        // hero doesn't sprawl on a 6K display.
        w.contentMinSize = Self.kMinContentSize
        w.contentMaxSize = Self.kMaxContentSize
        // Disable AppKit's frame autosave so a previous run that
        // happened to be larger (when kMaxContentSize allowed it)
        // doesn't leak into this one. Also force the content size
        // explicitly — `setContentSize` overrides any restored
        // frame from the system's window persistence.
        w.setFrameAutosaveName("")
        w.isRestorable = false
        w.setContentSize(NSSize(width: Self.kWidth, height: Self.kHeight))
        // Manual centring — `w.center()` uses AppKit's "golden
        // ratio" placement (a bit above true centre), which read
        // as "the window sits in the upper half". Centring on
        // `screen.visibleFrame.midXY` puts it dead-centre.
        if let screen = w.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            let origin = NSPoint(
                x: vis.midX - w.frame.width / 2,
                y: vis.midY - w.frame.height / 2
            )
            w.setFrameOrigin(origin)
        } else {
            w.center()
        }

        // Stepper removed — wizard is forward-only, the CTA carries
        // the navigation, no need for paging dots in the titlebar.

        // Shift the standard traffic-light buttons inward so their
        // left padding matches the content's horizontal inset (20 pt).
        // Default macOS leaves the close button ~7 pt from the edge,
        // which looks tight next to the 20-pt content gutter. We move
        // all three buttons together to preserve their spacing.
        Self.alignTrafficLights(in: w, leftInset: 20)

        // Bump activation policy to .regular so the wizard appears
        // in Cmd+Tab and the app gets a Dock icon while open. Revert
        // to whatever was prior on close (typically .accessory).
        promoteActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
        FileLogger.log("WelcomeWindow: presented frame=\(w.frame)")
    }

    // MARK: - NSWindowDelegate

    /// Hard-pin the wizard window to the fixed kDefaultContentSize.
    /// NSHostingView + SwiftUI sometimes asks AppKit to grow the
    /// window after a step swap (the confirmation card published a
    /// larger `intrinsicContentSize` and AppKit walked the window
    /// frame to it, ignoring contentMaxSize). Returning the constant
    /// size from `windowWillResize` traps any such attempt before it
    /// reaches the screen.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // frameSize is the WINDOW frame size (includes titlebar). We
        // want the CONTENT to stay kHeight, so compute the titlebar
        // chrome height and add it back.
        let chrome = sender.frame.height - sender.contentLayoutRect.height
        return NSSize(width: Self.kWidth, height: Self.kHeight + chrome)
    }

    /// Last-resort snap: if something programmatic still moved the
    /// frame past the cap, force it back the moment AppKit reports
    /// the resize done.
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        let chrome = w.frame.height - w.contentLayoutRect.height
        let target = NSSize(width: Self.kWidth, height: Self.kHeight + chrome)
        if w.frame.size != target {
            var f = w.frame
            f.size = target
            w.setFrame(f, display: true, animate: false)
        }
    }

    /// Shift the three standard titlebar buttons so the leftmost
    /// (close) sits `leftInset` pt from the window edge. The default
    /// AppKit layout pegs them ~7 pt in, which looks crowded against
    /// our 20-pt content gutter. We translate all three by the same
    /// delta so their inter-button spacing is preserved.
    private static func alignTrafficLights(in w: NSWindow, leftInset: CGFloat) {
        guard let close = w.standardWindowButton(.closeButton) else { return }
        let delta = leftInset - close.frame.origin.x
        guard delta != 0 else { return }
        for btn in [w.standardWindowButton(.closeButton),
                    w.standardWindowButton(.miniaturizeButton),
                    w.standardWindowButton(.zoomButton)] {
            guard let b = btn else { continue }
            var f = b.frame
            f.origin.x += delta
            b.setFrameOrigin(f.origin)
        }
    }

    /// Programmatic close.
    private func close() {
        window?.delegate = nil
        window?.close()
        window = nil
        demoteActivationPolicy()
    }

    // MARK: - Activation policy juggling

    private var savedPolicy: NSApplication.ActivationPolicy?

    private func promoteActivationPolicy() {
        if savedPolicy == nil { savedPolicy = NSApp.activationPolicy() }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func demoteActivationPolicy() {
        guard let prior = savedPolicy else { return }
        if NSApp.activationPolicy() != prior {
            NSApp.setActivationPolicy(prior)
        }
        savedPolicy = nil
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
            self.demoteActivationPolicy()
        }
    }
}

// MARK: - Sign-in result

/// Carries the outcome of a successful sign-in path (Google OAuth,
/// Apple SI, email-form submit) up to the wizard owner so it can
/// surface a confirmation toast and refocus the user on the Library.
struct SignInResult {
    let provider: String          // "google" | "apple" | "email"
    let displayName: String?      // Google `name` claim / Apple full name
    let email: String?
    /// True when this is the first sign-in this install has ever
    /// seen. Drives the post-onboarding toast copy ("Welcome" vs.
    /// "Welcome back") AND the welcome-email send gate (only fires
    /// when true). Snapshotted BEFORE we flip
    /// `AppSettings.hasSignedInBefore = true`.
    let wasFirstSignIn: Bool
}

// MARK: - Step enum

private enum WizardStep: Int, CaseIterable {
    /// Two-step flow:
    ///   • permissions — mic + screen recording (two cards)
    ///   • signin — email + password + Apple + Google
    /// The earlier welcome step was a hero blob with no real
    /// content — collapsed into the permissions step.
    case permissions, signin

    var index: Int { rawValue }
    static var total: Int { WizardStep.allCases.count }
}

// MARK: - Permission helpers

/// Wizard-local permission tri-state. We deliberately don't reuse
/// the top-level `PermissionStatus` in `PermissionsChecker.swift`
/// (which has `.notDetermined`) — the wizard wants "unknown"
/// semantics that include both "not asked yet" and "denied but we
/// haven't deep-link-prompted recently", which the existing enum
/// doesn't model.
private enum WizardPermission { case unknown, granted, denied }

private func currentMicStatus() -> WizardPermission {
    let live: WizardPermission
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:           live = .granted
    case .denied, .restricted:  live = .denied
    case .notDetermined:        live = .unknown
    @unknown default:           live = .unknown
    }
    // Snapshot grants so a re-install / sign-out cycle keeps
    // remembering "this user already said yes". Mic status is
    // usually reliable, but we sync the sticky flag for symmetry
    // with the screen path below.
    if live == .granted {
        AppSettings.setMicGrantedSticky(true)
        return .granted
    }
    if live == .denied {
        AppSettings.setMicGrantedSticky(false)
        return .denied
    }
    // `notDetermined` after a previous grant means the OS forgot
    // (rare). Trust the sticky snapshot if we have one.
    return AppSettings.micGrantedSticky ? .granted : .unknown
}

private func currentScreenStatus() -> WizardPermission {
    // `CGPreflightScreenCaptureAccess` reads a PROCESS-cached
    // value that the OS only refreshes after the first live
    // screen-capture call. On a fresh process for an already-
    // authorised bundle id (the typical "I re-installed Corder
    // and TCC remembers me" case), preflight returns false even
    // though the System Settings toggle is ON. That's why a sign-
    // out / re-install cycle was re-asking the user for a grant
    // they'd already given.
    //
    // Workaround: snapshot grants to UserDefaults the first time
    // preflight returns true (or the user finishes the wizard
    // having granted Screen Recording), then trust that snapshot
    // until we get a NEW preflight true reading. Snapshot only
    // gets cleared if the user explicitly invalidates it via
    // some other path (none today — System Settings revocation
    // doesn't notify us; the next failing capture will reveal it).
    if CGPreflightScreenCaptureAccess() {
        AppSettings.setScreenGrantedSticky(true)
        return .granted
    }
    if AppSettings.screenGrantedSticky {
        return .granted
    }
    return .unknown
}

/// Async helper isn't worth it for an opt-in card — Apple's
/// `getNotificationSettings` is async but cheap. We do a synchronous
/// snapshot via a semaphore (short, off the main render path), which
/// is fine for a one-shot read inside `@State` defaults / the
/// `didBecomeActive` re-sync. Returns `.granted` only when authorised
/// (provisional / ephemeral both count as banners visible).
private func currentNotificationStatus() -> WizardPermission {
    let sem = DispatchSemaphore(value: 0)
    var out: WizardPermission = .unknown
    UNUserNotificationCenter.current().getNotificationSettings { s in
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: out = .granted
        case .denied:                                out = .denied
        case .notDetermined:                         out = .unknown
        @unknown default:                            out = .unknown
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 0.5)
    return out
}

// Earlier drafts had a `liveScreenStatus()` helper that called
// `SCShareableContent.excludingDesktopWindows(…)` as a "more honest"
// recheck. That function, when the calling process LACKS the grant,
// ALSO triggers the system TCC prompt — same blocking sheet the user
// sees from `CGRequestScreenCaptureAccess()`. Calling it from
// `didBecomeActive` (the wizard's focus-refresh path) created an
// infinite prompt loop: SC-prompt up → user dismisses → focus returns
// → didBecomeActive fires → SC-prompt up again. The capture pipeline
// can use it safely because by then we have the grant. The wizard
// must stick to passive `CGPreflightScreenCaptureAccess()`.

// MARK: - Brand colour

/// Mirrors `--accent` in `Web/src/styles.css`. Keep these two in
/// sync — when the brand colour moves, both files change.
private let brandAccent = Color(red: 0x1F / 255.0,
                                green: 0x7A / 255.0,
                                blue: 0x4F / 255.0)

// MARK: - Transition between steps

/// Per-step crossfade animation. The actual transition (slide
/// direction) is owned by `SlideDirection.transition` since it has
/// to vary with the direction of travel.
private let stepAnimation: Animation = .easeInOut(duration: 0.32)

// MARK: - Shared wizard state

/// State that needs to be visible to BOTH the wizard body and the
/// titlebar-accessory stepper. Moved out of `WelcomeView`'s @State
/// so a separate SwiftUI view hosted in `NSTitlebarAccessoryViewController`
/// can observe and mutate the same source of truth.
@MainActor
fileprivate final class WizardState: ObservableObject {
    @Published var step: WizardStep
    /// Last direction the user moved through the steps. Drives the
    /// slide transition — moving forward swipes right-to-left,
    /// moving backward swipes left-to-right. The wizard is forward-
    /// only today, but the transition machinery stays direction-
    /// aware so a future Back path doesn't have to reintroduce it.
    @Published var lastDirection: SlideDirection = .forward
    /// Mirrors the BottomCTAButton's loading flag. Currently only
    /// ever read — the OAuth path closes the wizard before it would
    /// flip, and the email path is synchronous. Kept so future async
    /// sign-in paths have a wiring point that doesn't require a
    /// signature change to the CTA.
    @Published var signInLoading: Bool = false

    init() {
        let saved = WizardStep(rawValue: AppSettings.onboardingStep) ?? .permissions
        // If the user already has BOTH the mic + screen-recording
        // grants (typical re-install case where TCC entries survived
        // an `rm -rf /Applications/Corder.app`), skip the permissions
        // step entirely — there's nothing to ask for, and showing
        // two "Allow" cards next to system permissions the user
        // already gave once reads as "Corder forgot what I told it".
        if saved == .permissions,
           currentMicStatus() == .granted,
           currentScreenStatus() == .granted {
            self.step = .signin
            AppSettings.setOnboardingStep(WizardStep.signin.rawValue)
        } else {
            self.step = saved
        }
    }

    func advance(to next: WizardStep) {
        lastDirection = next.rawValue >= step.rawValue ? .forward : .backward
        withAnimation(stepAnimation) { step = next }
        AppSettings.setOnboardingStep(next.rawValue)
    }
}

/// Whether the email currently in the field maps to an existing
/// Supabase account. `.unknown` is the safe default (before the
/// user blurs, or while the lookup is in flight, or if the
/// `/check-email` call failed). The CTA label + the visibility of
/// the Confirm-password field are driven by this.
enum AuthMode {
    case unknown, signIn, signUp
}

enum SlideDirection {
    case forward, backward
    var transition: AnyTransition {
        switch self {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal:   .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }
}

// MARK: - Root wizard view

private struct WelcomeView: View {
    /// Closes the wizard. Optional `SignInResult` carries the
    /// provider/name/email from the OAuth or email path so the
    /// controller can surface a "Welcome, <name>" toast in the
    /// Library window.
    let onFinish: (SignInResult?) -> Void
    @ObservedObject var state: WizardState

    @State private var licenceInput: String = AppSettings.licenceKey ?? ""
    @State private var micStatus: WizardPermission = currentMicStatus()
    @State private var screenStatus: WizardPermission = currentScreenStatus()
    /// "Press" animation on the wizard title — mirrors the landing
    /// page's `.hero-rec-pill--squeeze` (scale 0.94, 100 ms each
    /// way, ease-in-out `cubic-bezier(.4,0,.2,1)`). Fires when the
    /// title text swaps Sign In ↔ Sign Up so the user sees that
    /// something actually changed.
    @State private var titleScale: CGFloat = 1

    /// Top section height — title + subtitle live inside this band;
    /// the divider sits at the bottom of it. 232 leaves ≈ 26 px
    /// from the subtitle baseline to the divider.
    private static let topSectionHeight: CGFloat = 232

    var body: some View {
        VStack(spacing: 0) {
            // White zone — header + divider + interactive zone live
            // inside this VStack on a hard white fill. Keeps the
            // brand-green window background from peeking through
            // any transparent pixels above the CTA.
            VStack(spacing: 0) {
                // Header band — stepper has moved to the titlebar
                // accessory (right of the traffic lights), so the
                // band carries only the title + subtitle column
                // now and can use the full width.
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentTitle)
                        .font(.system(size: 20, weight: .light))
                        .lineLimit(1)
                        .id(currentTitle)
                        .transition(.opacity)
                        .scaleEffect(titleScale, anchor: .leading)
                        .onChange(of: authMode) { _, _ in pulseTitle() }
                    Text(currentSubtitle)
                        // 14 pt to match the input fields — same
                        // type-scale as the body of the form.
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .padding(.bottom, 18)

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)

                ZStack {
                    interactiveContent
                        .transition(state.lastDirection.transition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.white)
            .layoutPriority(0)

            BottomCTAButton(label: currentCTA.label,
                            action: currentCTA.action,
                            disabled: currentCTA.disabled,
                            inactive: currentCTA.inactive,
                            loading: state.signInLoading)
                .frame(height: 60)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        // Re-check permission grants whenever the app comes back to
        // the foreground (user toggled Settings → switched back).
        // Strictly PASSIVE reads here — `currentMicStatus()` /
        // `currentScreenStatus()` only query TCC, they NEVER prompt.
        // An earlier version called `SCShareableContent.…` from this
        // path, which triggered the system Screen Recording prompt
        // every time the wizard regained focus — a denial of the
        // prompt re-fired `didBecomeActive`, creating an infinite
        // loop the user could only escape by force-quitting.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            let nextMic = currentMicStatus()
            if nextMic != micStatus { micStatus = nextMic }
            let nextScreen = currentScreenStatus()
            if nextScreen != screenStatus { screenStatus = nextScreen }
            // If the user has already advanced past the permissions
            // step and then revoked a grant in System Settings, snap
            // the wizard back to the permissions card. Otherwise the
            // sign-in step is reachable while the app no longer has
            // mic or screen recording, which is the exact case
            // popover-locking is supposed to prevent.
            if state.step != .permissions
                && (nextMic != .granted || nextScreen != .granted) {
                state.advance(to: .permissions)
            }
        }
    }

    // MARK: - Step data

    private var currentTitle: String {
        switch state.step {
        case .permissions: return "Allow Corder access"
        case .signin:      return authMode == .signUp ? "Sign Up" : "Sign In"
        }
    }

    private var currentSubtitle: String {
        switch state.step {
        case .permissions: return "Microphone + Screen Recording both sides of a call."
        case .signin:      return "Sign in to save your recordings and unlock Pro features."
        }
    }

    @ViewBuilder
    private var interactiveContent: some View {
        switch state.step {
        case .permissions:
            // Wrap in a ScrollView — three cards (Mic + Screen + Notifications)
            // don't fit the 380×516 wizard window, the bottom card and the
            // Continue button get clipped (Костя's screenshot of 0.13.32).
            ScrollView(.vertical, showsIndicators: false) {
                PermissionsCardsInteractive(
                    micStatus: $micStatus,
                    screenStatus: $screenStatus,
                    screenDidRequest: $screenDidRequest
                )
                // Bottom padding so the last card has breathing room
                // above the fixed Continue footer.
                .padding(.bottom, 12)
            }
        case .signin:
            SignInInteractive(
                email: $licenceInput,
                password: $passwordInput,
                confirmPassword: $confirmPasswordInput,
                inlineError: $signInError,
                emailError: $emailError,
                passwordError: $passwordError,
                confirmPasswordError: $confirmPasswordError,
                authMode: $authMode,
                onSubmit: { currentCTA.action() },
                onEmailBlur: { rawEmail in checkEmailExists(rawEmail) },
                onEmailChange: { resetAuthModeIfEmailChanged() },
                onSuccess: { result in onFinish(result) }
            )
        }
    }

    @State private var passwordInput: String = ""
    /// Inline validation message shown under the password field
    /// when the user hits "Sign in" with bad data. `nil` hides it.
    @State private var signInError: String? = nil
    /// Per-field validation errors raised when the user taps "Sign in
    /// with email" with bad input. Cleared the moment the corresponding
    /// field is edited so the message disappears as soon as the user
    /// starts fixing it.
    @State private var emailError: String? = nil
    @State private var passwordError: String? = nil
    @State private var confirmPasswordError: String? = nil
    /// Confirm-password input — only meaningful when `authMode == .signUp`.
    /// Hidden + cleared whenever the email changes so a typo in the
    /// email doesn't leave the confirm field stuck open with stale
    /// content.
    @State private var confirmPasswordInput: String = ""
    /// Drives the CTA label (Sign In vs Sign Up) and the Confirm-
    /// password field visibility. `.unknown` is the safe default — we
    /// treat the form as Sign In until the on-blur `/check-email`
    /// call comes back, but a `.unknown` submit ALSO tries Sign In
    /// first and only flips to Sign Up on `invalid_credentials` (no
    /// silent account creation).
    @State private var authMode: AuthMode = .unknown
    /// Normalised email string for which `authMode` was last set.
    /// Any change to the email field that diverges from this clears
    /// `authMode` back to `.unknown` and hides the Confirm field, so
    /// fixing a typo doesn't leave a stale Sign-Up state pinned.
    @State private var lastCheckedEmail: String = ""

    /// Thin shim — forwards to the shared state's `advance`. Local
    /// callers (CTA actions, permission grant flows) call this so
    /// the call sites don't have to type `state.advance(to:)`.
    private func advance(to next: WizardStep) { state.advance(to: next) }

    @State private var screenDidRequest: Bool = false

    /// Bottom CTA descriptor.
    /// • `disabled = true` greys out the slab AND blocks the click.
    /// • `inactive = true` greys out the slab but keeps the click
    ///   live — used to signal "not ready yet" on the sign-in step,
    ///   where the user is allowed to tap and see an inline error
    ///   instead of being locked out.
    private var currentCTA: (label: String, action: () -> Void, disabled: Bool, inactive: Bool) {
        switch state.step {
        case .permissions:
            let bothGranted = micStatus == .granted && screenStatus == .granted
            return ("Continue",
                    { if bothGranted { advance(to: .signin) } },
                    !bothGranted,
                    false)
        case .signin:
            return signInCTA
        }
    }

    /// Sign-in step CTA — always tappable. Invalid input doesn't
    /// disable the button OR grey it out; the slab is always the
    /// brand-green "ready" state and bad input surfaces as per-field
    /// inline errors instead. Avoids the "I tapped a dead button"
    /// confusion Kostya called out — every tap gets feedback. Label
    /// follows `authMode`: Sign Up when we've confirmed the email is
    /// new, Sign In otherwise.
    private var signInCTA: (label: String, action: () -> Void, disabled: Bool, inactive: Bool) {
        let trimmedEmail = licenceInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let label = (authMode == .signUp) ? "Sign up with email" : "Sign in with email"
        return (label, {
            let (eErr, pErr, cErr) = validateFields(
                email: trimmedEmail,
                password: passwordInput,
                confirmPassword: confirmPasswordInput,
                isSignUp: authMode == .signUp
            )
            emailError = eErr
            passwordError = pErr
            confirmPasswordError = cErr
            if eErr == nil && pErr == nil && cErr == nil {
                submitAuth(email: trimmedEmail)
            }
        }, false, false)
    }

    /// Per-field validation. Returns (emailError, passwordError,
    /// confirmError) — nil when the value is fine. Short strings on
    /// purpose so they fit under a 320-wide capsule without wrapping.
    /// `confirmError` is only ever populated when `isSignUp` is true
    /// (the Confirm field is hidden otherwise and shouldn't gate
    /// submit).
    private func validateFields(email: String, password: String, confirmPassword: String, isSignUp: Bool) -> (String?, String?, String?) {
        var emailIssue: String? = nil
        var passwordIssue: String? = nil
        var confirmIssue: String? = nil
        if email.isEmpty {
            emailIssue = "Enter your email."
        } else if !isValidEmailFormat(email) {
            emailIssue = "That doesn't look like an email."
        }
        if password.isEmpty {
            passwordIssue = "Enter a password."
        } else if password.count < 6 {
            passwordIssue = "At least 6 characters."
        }
        if isSignUp {
            if confirmPassword.isEmpty {
                confirmIssue = "Confirm your password."
            } else if confirmPassword != password {
                confirmIssue = "Passwords don't match."
            }
        }
        return (emailIssue, passwordIssue, confirmIssue)
    }

    /// Mode-aware submit:
    ///   • .signUp  → `signUp` directly (Confirm has already passed validation).
    ///   • .signIn  → `signIn`, surface a "Wrong password" inline error on fail.
    ///   • .unknown → try `signIn`; on `invalid credentials` flip
    ///     `authMode` to `.signUp` so the Confirm field slides in,
    ///     and ask the user to press the CTA again — no silent
    ///     account creation.
    private func submitAuth(email: String) {
        FileLogger.log("WelcomeWindow: auth submitted for \(email) mode=\(authMode)")
        let pw = passwordInput
        let mode = authMode
        Task { @MainActor in
            let client = SupabaseClientHolder.shared.auth
            switch mode {
            case .signUp:
                do {
                    _ = try await client.signUp(email: email, password: pw)
                } catch {
                    FileLogger.log("WelcomeWindow: signUp failed: \(error)")
                    signInError = "Couldn't create your account. Try again."
                    return
                }
                finishEmailFlow(email: email)
            case .signIn, .unknown:
                do {
                    _ = try await client.signIn(email: email, password: pw)
                    finishEmailFlow(email: email)
                } catch {
                    FileLogger.log("WelcomeWindow: signIn failed: \(error)")
                    if mode == .unknown {
                        authMode = .signUp
                        lastCheckedEmail = email
                        signInError = "We didn't find this email. Confirm your password to create an account."
                    } else {
                        passwordError = "Wrong password."
                    }
                }
            }
        }
    }

    private func finishEmailFlow(email: String) {
        let wasFirst = !AppSettings.hasSignedInBefore
        AppSettings.setUserEmail(email)
        AppSettings.setHasSignedInBefore(true)
        SupabaseTierSync.applyFromCurrentSession()
        onFinish(.init(provider: "email", displayName: nil, email: email,
                       wasFirstSignIn: wasFirst))
    }

    /// Called by `SignInInteractive` when the email field loses focus
    /// (and the value differs from `lastCheckedEmail`). Posts to the
    /// Worker's `/check-email` and updates `authMode`. On error we
    /// stay in `.unknown` so the submit fallback path still works.
    fileprivate func checkEmailExists(_ rawEmail: String) {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, isValidEmailFormat(email) else { return }
        guard email != lastCheckedEmail else { return }
        FileLogger.log("WelcomeWindow: checkEmailExists(\(email))")
        guard let url = URL(string: "https://corder-api.empqwork.workers.dev/check-email") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email], options: [])
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err {
                FileLogger.log("WelcomeWindow: /check-email error \(err)")
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = obj["ok"] as? Bool, ok,
                  let exists = obj["exists"] as? Bool else {
                FileLogger.log("WelcomeWindow: /check-email bad response")
                return
            }
            Task { @MainActor in
                // Only apply if the user hasn't edited the email out
                // from under us mid-request. Stale callbacks would
                // pin the wrong mode otherwise.
                let current = self.licenceInput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard current == email else { return }
                self.lastCheckedEmail = email
                withAnimation(.easeOut(duration: 0.18)) {
                    self.authMode = exists ? .signIn : .signUp
                }
                if !exists {
                    self.signInError = nil
                } else {
                    self.confirmPasswordInput = ""
                    self.confirmPasswordError = nil
                }
            }
        }.resume()
    }

    /// 100 ms squeeze-to-0.94, swap, then 100 ms expand-to-1. Matches
    /// the timing + easing of `.hero-rec-pill--squeeze` on the
    /// landing page (`cubic-bezier(.4,0,.2,1)`, the same curve
    /// SwiftUI's `.easeInOut` produces). The text crossfades on the
    /// peak of the squeeze because `Text(currentTitle).id(...)` lets
    /// SwiftUI treat each value as a separate view and applies the
    /// `.transition(.opacity)` modifier we attached.
    private func pulseTitle() {
        withAnimation(.easeInOut(duration: 0.1)) { titleScale = 0.94 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.1)) { titleScale = 1 }
        }
    }

    /// Called by SignInInteractive whenever the email field text
    /// changes. We reset `authMode` to `.unknown` and hide the
    /// Confirm field so a fresh email doesn't inherit the previous
    /// email's mode (fixing a typo would otherwise leave the form
    /// stuck on Sign Up).
    fileprivate func resetAuthModeIfEmailChanged() {
        let current = licenceInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if current != lastCheckedEmail {
            withAnimation(.easeOut(duration: 0.18)) {
                authMode = .unknown
            }
            confirmPasswordInput = ""
            confirmPasswordError = nil
        }
    }
}

// MARK: - Bottom CTA slab + Back button

/// 1/8-of-window full-width brand-green slab. Single text label on
/// the left + chevron arrow on the right, both centred horizontally
/// inside the slab. Hover lifts the background slightly and slides
/// the arrow a few pixels to the right — "bodry" feedback Kostya
/// asked for.
private struct BottomCTAButton: View {
    let label: String
    let action: () -> Void
    var disabled: Bool = false
    /// Grey-but-clickable. Same visual fill as `disabled`, but the
    /// tap still fires — the page can show an inline validation
    /// error instead of locking the user out.
    var inactive: Bool = false
    var loading: Bool = false

    @State private var hovered: Bool = false
    @State private var pressed: Bool = false

    var body: some View {
        // Two-layer Z stack: the bottom Rectangle owns the hover +
        // tap (full slab area, no gaps), the label is a hit-test-
        // disabled overlay on top.
        ZStack {
            Rectangle()
                .fill(background)
                .contentShape(Rectangle())
                .onHover { h in hovered = h && !disabled }
                .onTapGesture {
                    if !disabled && !loading { action() }
                }
                .pressEvents(onPress: { if !disabled { pressed = true } },
                             onRelease: { pressed = false })

            HStack(spacing: 8) {
                Text(label)
                    // 14 pt matches the input fields — keeps the
                    // hierarchy quiet, the slab itself carries
                    // the weight visually.
                    .font(.system(size: 14, weight: .regular))
                    .tracking(0.2)
                if loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .medium))
                        .offset(x: hovered && !disabled && !inactive ? 4 : 0)
                        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hovered)
                }
            }
            .foregroundColor(.white)
            .opacity(disabled ? 0.45
                     : (inactive ? 0.85
                        : (hovered ? 1.0 : 0.82)))
            .animation(.easeOut(duration: 0.18), value: hovered)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: Color {
        let greyed = Color(red: 0x9B / 255.0, green: 0xC4 / 255.0, blue: 0xAE / 255.0)
        if disabled { return greyed }
        if inactive { return greyed }
        if pressed  { return Color(red: 0x15 / 255.0, green: 0x57 / 255.0, blue: 0x3A / 255.0) }
        if hovered  { return Color(red: 0x1B / 255.0, green: 0x6B / 255.0, blue: 0x45 / 255.0) }
        return brandAccent
    }
}

/// Captures mouse-down / mouse-up via a SwiftUI gesture so the
/// `BottomCTAButton`'s "pressed" colour shift fires synchronously
/// instead of relying on SwiftUI's default ButtonStyle press state
/// (which doesn't expose `isPressed` to our `.plain` style here).
private extension View {
    func pressEvents(onPress: @escaping () -> Void,
                     onRelease: @escaping () -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded   { _ in onRelease() }
        )
    }
}

// MARK: - Interactive zones per state.step

/// Pragmatic email format check — "has @, has ., len ≥ 5". Real
/// validation happens server-side when the worker resolves the
/// email against Paddle.
func isValidEmailFormat(_ s: String) -> Bool {
    guard s.count >= 5 else { return false }
    guard let at = s.firstIndex(of: "@") else { return false }
    let local = s[..<at]
    let domain = s[s.index(after: at)...]
    return !local.isEmpty && domain.contains(".")
}

/// Permissions step — two stacked clarify-style cards, one per
/// permission (microphone, screen recording). Each card matches
/// the Library's `.clarify-banner` shell: white fill, 1 px outline,
/// title + description + a green primary button (`.clarify-btn.accent`
/// equivalent). Bottom CTA "Continue" stays disabled until BOTH
/// permissions are granted.
private struct PermissionsCardsInteractive: View {
    @Binding var micStatus: WizardPermission
    @Binding var screenStatus: WizardPermission
    @Binding var screenDidRequest: Bool

    /// Notifications is OPTIONAL — Continue does not gate on it.
    /// Local state so we don't have to thread another binding all
    /// the way back up to WelcomeShell.
    @State private var notifStatus: WizardPermission = currentNotificationStatus()
    @State private var notifDidRequest: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            permissionCard(
                title: "Microphone",
                description: "Record your side of the call.",
                status: micStatus,
                primaryLabel: micPrimaryLabel,
                onPrimary: micPrimaryAction,
                optional: false
            )
            permissionCard(
                title: "Screen Recording",
                description: "Capture the other side's audio.",
                status: screenStatus,
                primaryLabel: screenPrimaryLabel,
                onPrimary: screenPrimaryAction,
                optional: false
            )
            permissionCard(
                title: "Notifications",
                description: "Get a banner when a transcript is ready.",
                status: notifStatus,
                primaryLabel: notifPrimaryLabel,
                onPrimary: notifPrimaryAction,
                optional: true
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            notifStatus = currentNotificationStatus()
        }
    }

    /// Pixel-for-pixel match of the Library's
    /// `.trans-banner.clarify-banner` shell (RecordingBanner is the
    /// reference). CSS source-of-truth:
    ///   `.trans-banner`  border 1px var(--border-strong), radius 8,
    ///                    padding 14px 16px, white fill, flex column,
    ///                    gap 12.
    ///   `.clarify-body`  18px / weight 300 / line-height 1.35 / --fg.
    ///   `.dash-sub`      13.5px / line-height 1.5 / --fg-muted.
    ///   `.clarify-btn`   transparent fill, 1px --border-strong,
    ///                    radius 8, padding 13×16, 14px / 500.
    /// Granted state reuses `.clarify-btn.active` (filled accent).
    private func permissionCard(
        title: String,
        description: String,
        status: WizardPermission,
        primaryLabel: String,
        onPrimary: @escaping () -> Void,
        optional: Bool = false
    ) -> some View {
        // Two layouts:
        //   • granted → no CTA pill, just a small green checkmark
        //     pinned to the right of the text column. The card
        //     collapses to a single text row; the icon sits vertically
        //     centred relative to the title+description block.
        //   • not granted → text column + a secondary action button
        //     ("Allow" / "Open Settings") below, full-width.
        Group {
            if status == .granted {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        // Title turns brand-green in the granted
                        // state — pairs with the checkmark icon on
                        // the right so the "done" signal carries
                        // across the whole row, not just the corner.
                        Text(title)
                            .font(.system(size: 18, weight: .light))
                            .lineSpacing(18 * 0.35)
                            .foregroundColor(brandAccent)
                        Text(description)
                            .font(.system(size: 13.5))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(brandAccent)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 18, weight: .light))
                                .lineSpacing(18 * 0.35)
                                .foregroundColor(.primary)
                            if optional {
                                Text("Optional")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.black.opacity(0.06))
                                    )
                            }
                        }
                        Text(description)
                            .font(.system(size: 13.5))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Button(primaryLabel, action: onPrimary)
                        .buttonStyle(FlatButtonStyle(role: .secondary))
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    // ── Mic actions ─────────────────────────────────────────────

    private var micPrimaryLabel: String {
        switch micStatus {
        case .denied:  return "Open Settings"
        case .unknown: return "Allow"
        case .granted: return ""
        }
    }

    private func micPrimaryAction() {
        switch micStatus {
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .unknown:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    micStatus = granted ? .granted : .denied
                }
            }
        case .granted:
            break
        }
    }

    // ── Screen actions ──────────────────────────────────────────

    private var screenPrimaryLabel: String {
        if screenStatus == .granted { return "" }
        return screenDidRequest ? "Open Settings" : "Allow"
    }

    // ── Notifications actions (optional) ────────────────────────

    private var notifPrimaryLabel: String {
        switch notifStatus {
        case .denied:  return "Open Settings"
        case .unknown: return "Allow"
        case .granted: return ""
        }
    }

    private func notifPrimaryAction() {
        switch notifStatus {
        case .denied:
            let bundleID = Bundle.main.bundleIdentifier ?? "com.3mpq.Corder"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)") {
                NSWorkspace.shared.open(url)
            }
            notifDidRequest = true
        case .unknown:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    notifStatus = granted ? .granted : .denied
                    notifDidRequest = true
                }
            }
        case .granted:
            break
        }
    }

    private func screenPrimaryAction() {
        if screenStatus == .granted { return }
        if screenDidRequest {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // First click — fire the native TCC prompt. We intentionally
        // do NOT call `SCShareableContent.…` here: when there's no
        // grant it ALSO prompts, and combining the two stacks two
        // prompts back to back. CGRequestScreenCaptureAccess() is
        // the prompt-only API; the result lands in TCC asynchronously
        // and the post-grant relaunch picks it up.
        _ = CGRequestScreenCaptureAccess()
        screenDidRequest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            screenStatus = currentScreenStatus()
        }
    }
}

/// Sign-in step. Two options:
///  • Continue with Google — system-browser OAuth via loopback.
///  • Email + password — local persist + best-effort POST to the
///    backend (no-ops when the backend isn't up yet).
///
/// On success any path calls `onSuccess` which closes the wizard.
/// We deliberately do NOT show a "check your inbox" confirmation
/// card any more — there's no real verification flow yet, and
/// adding one purely for theatre is friction without value.
private struct SignInInteractive: View {
    @Binding var email: String
    @Binding var password: String
    @Binding var confirmPassword: String
    /// Inline validation message shown beneath the password
    /// field. Bound to the WelcomeView so the CTA action can
    /// raise it and the field auto-clears it on input change.
    @Binding var inlineError: String?
    /// Per-field validation errors. Bound to the WelcomeView so the
    /// CTA can populate them on bad input and the field auto-clears
    /// them on edit. Field renders with a red border + an inline
    /// caption when its error is non-nil.
    @Binding var emailError: String?
    @Binding var passwordError: String?
    @Binding var confirmPasswordError: String?
    /// Drives Sign In ↔ Sign Up label swap + Confirm-password
    /// field visibility. Owned by WelcomeView; this view only reads
    /// it (and clears it indirectly via `onEmailChange`).
    @Binding var authMode: AuthMode
    /// Fired when the user presses Return inside any field.
    /// Forwards to the bottom CTA's action.
    let onSubmit: () -> Void
    /// Fired when the email field loses focus AND the value differs
    /// from the last checked email. The WelcomeView posts to
    /// `/check-email` and updates `authMode`.
    let onEmailBlur: (String) -> Void
    /// Fired on every email keystroke so WelcomeView can reset
    /// `authMode` (and hide the Confirm field) when the user starts
    /// editing a new email after we'd already classified one.
    let onEmailChange: () -> Void
    /// Carries the sign-in result up to the WelcomeWindowController
    /// so it can close the wizard, open the Library, and surface a
    /// "Welcome, <name>" toast.
    let onSuccess: (SignInResult) -> Void

    @FocusState private var focusedField: Field?
    @State private var emailHovered: Bool = false
    @State private var passwordHovered: Bool = false
    @State private var confirmHovered: Bool = false
    @State private var googleHovered: Bool = false

    private enum Field { case email, password, confirm }

    var body: some View {
        // Vertically centred. Email + password on top (primary
        // path); "or" divider; OAuth providers underneath.
        VStack(spacing: 10) {
                Spacer(minLength: 0)

                // Field + inline error are wrapped in a tight inner
                // VStack so the message hugs its capsule (4 pt gap)
                // instead of inheriting the 10 pt rhythm of the outer
                // form. Left padding (18 pt) lines the error text up
                // exactly with the placeholder inside the capsule:
                // the capsule has a 1 pt stroke + the TextField
                // carries `.padding(.horizontal, 18)` inside, so 18 pt
                // of leading padding on the caption hits the same
                // x-position as "you@example.com".
                VStack(alignment: .leading, spacing: 4) {
                    emailField
                    if let emailError {
                        Text(emailError)
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.85))
                            .padding(.leading, 18)
                    }
                }
                .frame(maxWidth: 320)

                VStack(alignment: .leading, spacing: 4) {
                    passwordField
                    if let passwordError {
                        Text(passwordError)
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.85))
                            .padding(.leading, 18)
                    }
                }
                .frame(maxWidth: 320)

                if authMode == .signUp {
                    VStack(alignment: .leading, spacing: 4) {
                        confirmPasswordField
                        if let confirmPasswordError {
                            Text(confirmPasswordError)
                                .font(.system(size: 12))
                                .foregroundColor(.red.opacity(0.85))
                                .padding(.leading, 18)
                        }
                    }
                    .frame(maxWidth: 320)
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
                }

                if let inlineError {
                    Text(inlineError)
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.85))
                        .frame(maxWidth: 320, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
                    Text("or")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
                }
                .frame(maxWidth: 320)
                .padding(.vertical, 2)

                // Apple "Sign in with Apple" hidden in Developer ID
                // builds: Apple's native ASAuthorizationController
                // path requires the `com.apple.developer.applesignin`
                // entitlement, which Apple only embeds into Mac App
                // Store provisioning profiles — not Developer ID
                // Direct Distribution ones. The web-OAuth alternative
                // needs a Service ID + domain + JWT-signing backend
                // we don't have yet. When we either ship to MAS or
                // stand up a backend, restore `appleButton` here.
                googleButton

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Side padding so the rounded inputs/buttons don't glue
            // themselves to the window edges when the user stretches
            // the wizard wide. Inputs/buttons still cap at 320 pt via
            // their own `.frame(maxWidth:)`, so on a wide window they
            // centre as a 320-wide column instead of stretching.
            .padding(.horizontal, 20)
            // Inline validation clears as soon as the user edits
            // either field — they're trying to fix what we just
            // complained about.
            .onChange(of: email) { _, newValue in
                inlineError = nil
                emailError = nil
                onEmailChange()
            }
            .onChange(of: password) { _, _ in
                inlineError = nil
                passwordError = nil
                // Keep confirm validation honest as the primary
                // password changes — if the two diverge mid-typing,
                // the inline caption needs to clear once they line
                // up again.
                if authMode == .signUp { confirmPasswordError = nil }
            }
            .onChange(of: confirmPassword) { _, _ in confirmPasswordError = nil }
            .onChange(of: focusedField) { oldValue, newValue in
                // Email blur → ping /check-email so the form can
                // swap between Sign In and Sign Up before the user
                // submits.
                if oldValue == .email && newValue != .email {
                    onEmailBlur(email)
                }
            }
    }

    // MARK: - Provider buttons

    private var googleButton: some View {
        // Secondary-button hover treatment: hovered = a touch darker
        // fill + darker outline. Matches the `button:hover` rule in
        // the Web design system (`var(--bg-hover)` + `#b8b8b4`), the
        // visual reference Kostya pointed at for parity.
        let fill: Color   = googleHovered ? Color(white: 0.96) : .white
        let stroke: Color = googleHovered ? Color.black.opacity(0.24)
                                          : Color.black.opacity(0.12)
        return Button(action: openGoogleOAuth) {
            HStack(spacing: 10) {
                GoogleG()
                    .frame(width: 16, height: 16)
                Text("Continue with Google")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .frame(maxWidth: 320)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: googleHovered)
        }
        .buttonStyle(.plain)
        .onHover { h in
            googleHovered = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Email + password

    private var emailField: some View {
        // ZStack so the white capsule background catches taps across
        // the FULL pill area, not just the narrow strip where the
        // `TextField` itself paints. A native `IBeamCursorOverlay`
        // sits on top with `addCursorRect` so the I-beam appears
        // anywhere inside the pill (the SwiftUI `.onHover` +
        // `NSCursor.iBeam.push()` chain accumulates the cursor
        // stack and stops switching the cursor reliably after a
        // few in/out cycles).
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white)
                .overlay(Capsule().stroke(emailBorderColour, lineWidth: 1))
            TextField("you@example.com", text: $email)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .textContentType(.emailAddress)
                .disableAutocorrection(true)
                .focused($focusedField, equals: .email)
                .padding(.horizontal, 18)
                .onSubmit {
                    if password.isEmpty { focusedField = .password }
                    else                { onSubmit() }
                }
            IBeamCursorOverlay()
        }
        .frame(maxWidth: 320)
        .frame(height: 48)
        .contentShape(Capsule())
        .onTapGesture { focusedField = .email }
        .onHover { h in emailHovered = h }
    }

    private var passwordField: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white)
                .overlay(Capsule().stroke(passwordBorderColour, lineWidth: 1))
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .padding(.horizontal, 18)
                .onSubmit {
                    if authMode == .signUp && confirmPassword.isEmpty {
                        focusedField = .confirm
                    } else {
                        onSubmit()
                    }
                }
            IBeamCursorOverlay()
        }
        .frame(maxWidth: 320)
        .frame(height: 48)
        .contentShape(Capsule())
        .onTapGesture { focusedField = .password }
        .onHover { h in passwordHovered = h }
    }

    private var confirmPasswordField: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white)
                .overlay(Capsule().stroke(confirmBorderColour, lineWidth: 1))
            SecureField("Confirm password", text: $confirmPassword)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .textContentType(.newPassword)
                .focused($focusedField, equals: .confirm)
                .padding(.horizontal, 18)
                .onSubmit { onSubmit() }
            IBeamCursorOverlay()
        }
        .frame(maxWidth: 320)
        .frame(height: 48)
        .contentShape(Capsule())
        .onTapGesture { focusedField = .confirm }
        .onHover { h in confirmHovered = h }
    }

    private var emailBorderColour: Color {
        if emailError != nil { return Color.red.opacity(0.7) }
        if focusedField == .email { return brandAccent }
        if emailHovered { return Color.black.opacity(0.24) }
        return Color.black.opacity(0.12)
    }

    private var passwordBorderColour: Color {
        if passwordError != nil { return Color.red.opacity(0.7) }
        if focusedField == .password { return brandAccent }
        if passwordHovered { return Color.black.opacity(0.24) }
        return Color.black.opacity(0.12)
    }

    private var confirmBorderColour: Color {
        if confirmPasswordError != nil { return Color.red.opacity(0.7) }
        if focusedField == .confirm { return brandAccent }
        if confirmHovered { return Color.black.opacity(0.24) }
        return Color.black.opacity(0.12)
    }

    // MARK: - Google (via Supabase Auth)

    /// Kicks off Supabase's Google OAuth flow: ask the SDK for the
    /// authorize URL, open it in the user's default browser, then
    /// wait for `AppDelegate.application(_:open:)` to consume the
    /// `corder://auth/callback#…` redirect and post
    /// `.corderSupabaseSignedIn`. Replaces the older
    /// `GoogleOAuth.signIn` (loopback listener + manual token
    /// exchange + Cloudflare Worker /signup) — Supabase now owns
    /// the auth session, the welcome email, and the user row.
    private func openGoogleOAuth() {
        FileLogger.log("WelcomeWindow: Google sign-in button tapped")
        Task { @MainActor in
            do {
                // Loopback redirect to the in-app server's
                // `/auth/callback` route. Why not `corder://`:
                // browsers don't render a normal HTML page after a
                // custom-scheme redirect (they hand the URL to the
                // OS and leave the current tab on the previous URL),
                // so the user sees Google's chooser hanging with a
                // progress bar forever instead of "You're signed in".
                // The loopback URL renders our styled success page,
                // and the server-side route hands the code to
                // `auth.session(from:)` so the wizard still wakes up
                // via `.corderSupabaseSignedIn`.
                //
                // Supabase Dashboard → URL Configuration → Redirect
                // URLs must list `http://127.0.0.1:*` (or the specific
                // port) for this to pass the allowlist.
                let port = AppContext.shared.server.port
                let redirect = URL(string: "http://127.0.0.1:\(port)/auth/callback")!
                let url = try SupabaseClientHolder.shared.auth.getOAuthSignInURL(
                    provider: .google,
                    redirectTo: redirect
                )
                NSWorkspace.shared.open(url)
                // Wait for AppDelegate to post the signed-in
                // notification (fired after `auth.session(from:)`
                // succeeds in the URL callback). A real timeout
                // (60 s) so a user who cancels the browser tab
                // doesn't leave the wizard stuck.
                let signedIn = await Self.waitForSupabaseSignedIn(timeoutNanos: 60_000_000_000)
                guard signedIn else {
                    FileLogger.log("WelcomeWindow: Supabase Google sign-in timed out")
                    return
                }
                guard let user = SupabaseClientHolder.shared.auth.currentUser else {
                    FileLogger.log("WelcomeWindow: signed-in notification fired but currentUser is nil")
                    return
                }
                let email = user.email ?? ""
                let metadata = user.userMetadata
                let name = (metadata["full_name"]?.stringValue
                            ?? metadata["name"]?.stringValue) as String?
                if !email.isEmpty { AppSettings.setUserEmail(email) }
                if let name, !name.isEmpty { AppSettings.setUserName(name) }
                SupabaseTierSync.applyFromCurrentSession()
                let wasFirst = !AppSettings.hasSignedInBefore
                AppSettings.setHasSignedInBefore(true)
                onSuccess(.init(
                    provider: "google",
                    displayName: name,
                    email: email.isEmpty ? nil : email,
                    wasFirstSignIn: wasFirst
                ))
            } catch {
                FileLogger.log("WelcomeWindow: Supabase Google sign-in failed: \(error)")
            }
        }
    }

    /// Wait for the AppDelegate to post `.corderSupabaseSignedIn`
    /// (or hit the timeout). Returns true on signal, false on
    /// timeout. Uses a notification-listener task race so cancelling
    /// the wizard doesn't leak the observer.
    @MainActor
    private static func waitForSupabaseSignedIn(timeoutNanos: UInt64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in NotificationCenter.default.notifications(
                    named: .corderSupabaseSignedIn).prefix(1) {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Backend POST

    private func postSignup(payload: [String: Any]) {
        guard let url = URL(string: "https://corder-api.empqwork.workers.dev/signup") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: [])
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err = err {
                FileLogger.log("WelcomeWindow: signup POST failed: \(err)")
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            FileLogger.log("WelcomeWindow: signup POST status \(code)")
        }.resume()
    }

}

/// Google "G" — official 4-colour logo loaded from a bundled PNG
/// (`Sources/Corder/Resources/icons/google-g.png` + `@2x`).
/// Falls back to an empty view if the asset can't be found,
/// rather than crashing — and goes through `Bundle.corderResources`
/// instead of `Bundle.module`, which fatal-errors on every tester
/// Mac because its candidate path doesn't include `Contents/Resources/`.
private struct GoogleG: View {
    var body: some View {
        if let url = Bundle.corderResources?.url(forResource: "google-g",
                                                 withExtension: "png",
                                                 subdirectory: "icons"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }
}


/// Transparent NSView overlay that forces the I-beam cursor across
/// its entire bounds via an `NSTrackingArea` with `.cursorUpdate`.
/// Drop this on top of any SwiftUI input pill that needs the I-beam
/// to appear in the padding area too — not just inside the text
/// strip that `TextField`/`SecureField` paint.
///
/// Why not `addCursorRect`: cursor rects only fire while the view
/// is part of the hit-test chain. We deliberately return `nil` from
/// `hitTest(_:)` so clicks pass through to the SwiftUI tap-gesture
/// underneath (which moves focus into the field); with hit-test
/// returning nil, AppKit skips cursor rects. Tracking areas are
/// independent of hit-testing — `cursorUpdate(_:)` fires on
/// mouse-enter / mouse-move regardless.
struct IBeamCursorOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { IBeamView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class IBeamView: NSView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.iBeam.set() }
    override func mouseMoved(with event: NSEvent)   { NSCursor.iBeam.set() }
    override func mouseExited(with event: NSEvent)  { NSCursor.arrow.set() }

    /// Pass-through hit testing — clicks land on the SwiftUI tap
    /// gesture under the overlay (focus the field), not on this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

