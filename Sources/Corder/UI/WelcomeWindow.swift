import AppKit
import SwiftUI
import AVFoundation
import CoreGraphics

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
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = WelcomeView(
            onFinish: { [weak self] result in
                AppSettings.setOnboardingCompleted(true)
                AppSettings.setOnboardingStep(0)
                FileLogger.log("WelcomeWindow: onboarding completed (provider=\(result?.provider ?? "n/a"))")
                self?.close()
                // Land the user in the main app: open the Library
                // window and fire a welcome toast. We do this on the
                // next runloop tick so the wizard's close animation
                // doesn't fight the new key window's z-order.
                DispatchQueue.main.async {
                    LibraryWindow.shared.show(
                        serverURL: AppContext.shared.server.baseURL)
                    if let result {
                        let name = result.displayName
                            ?? AppSettings.userName
                            ?? result.email.flatMap { $0.split(separator: "@").first.map(String.init) }
                        let title: String
                        let body: String
                        if let name, !name.isEmpty {
                            title = "Welcome, \(name)!"
                            body  = "You're signed in to Corder."
                        } else {
                            title = "You're signed in"
                            body  = "Welcome to Corder."
                        }
                        LibraryWindow.shared.postToast(
                            title: title, body: body, kind: "success")
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
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:           return .granted
    case .denied, .restricted:  return .denied
    case .notDetermined:        return .unknown
    @unknown default:           return .unknown
    }
}

private func currentScreenStatus() -> WizardPermission {
    // `CGPreflightScreenCaptureAccess` returns the live grant state.
    // Unlike microphone, the OS doesn't expose a "not determined"
    // bucket here — preflight returns false both before the first
    // prompt and after a denial, so the UI defers a hard "denied"
    // label until we've actually invoked the request once.
    CGPreflightScreenCaptureAccess() ? .granted : .unknown
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
        let initial = WizardStep(rawValue: AppSettings.onboardingStep) ?? .permissions
        self.step = initial
    }

    func advance(to next: WizardStep) {
        lastDirection = next.rawValue >= step.rawValue ? .forward : .backward
        withAnimation(stepAnimation) { step = next }
        AppSettings.setOnboardingStep(next.rawValue)
    }
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
        case .signin:      return "Almost there"
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
            PermissionsCardsInteractive(
                micStatus: $micStatus,
                screenStatus: $screenStatus,
                screenDidRequest: $screenDidRequest
            )
        case .signin:
            SignInInteractive(
                email: $licenceInput,
                password: $passwordInput,
                inlineError: $signInError,
                onSubmit: { currentCTA.action() },
                onSuccess: { result in onFinish(result) }
            )
        }
    }

    @State private var passwordInput: String = ""
    /// Inline validation message shown under the password field
    /// when the user hits "Sign in" with bad data. `nil` hides it.
    @State private var signInError: String? = nil

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
    /// disable the button; it lights up an inline error message
    /// under the password field instead. Goes "inactive" (grey but
    /// still clickable) when both fields are empty so the page
    /// doesn't loudly invite a tap before there's anything to send.
    private var signInCTA: (label: String, action: () -> Void, disabled: Bool, inactive: Bool) {
        let trimmedEmail = licenceInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let inactive = trimmedEmail.isEmpty && passwordInput.isEmpty
        return ("Sign in with email", {
            if let issue = validationIssue(email: trimmedEmail, password: passwordInput) {
                signInError = issue
                return
            }
            signInError = nil
            submitSignIn(email: trimmedEmail)
        }, false, inactive)
    }

    /// Returns a human-readable error if the inputs aren't usable;
    /// nil when the form is ready to submit.
    private func validationIssue(email: String, password: String) -> String? {
        if email.isEmpty { return "Enter your email." }
        if !isValidEmailFormat(email) { return "That doesn't look like an email address." }
        if password.isEmpty { return "Enter a password." }
        if password.count < 6 { return "Password must be at least 6 characters." }
        return nil
    }

    /// POSTs the email to the backend signup endpoint and stores
    /// it locally. Endpoint TODO: `api.getcorder.com/signup` once
    /// the Cloudflare Worker is live — until then the call no-ops
    /// on network failure, the local persist still works so we
    /// have the value to retry later.
    private func submitSignIn(email: String) {
        AppSettings.setLicenceKey(email)
        FileLogger.log("WelcomeWindow: sign-in submitted for \(email)")

        // Fire-and-forget POST to /signup. We don't gate the user on
        // it — there's no backend yet, and even when there is, email
        // verification adds friction without protecting any local
        // function (records are on disk, Pro flows go through Paddle
        // which does its own email verification). Close the wizard
        // immediately; the POST resolves in the background.
        if let url = URL(string: "https://corder-api.empqwork.workers.dev/signup") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "email":    email,
                "password": passwordInput,
                "source":   "corder-mac-wizard",
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req) { _, resp, err in
                if let err = err {
                    FileLogger.log("WelcomeWindow: signup POST failed: \(err)")
                } else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    FileLogger.log("WelcomeWindow: signup POST status \(code)")
                }
            }.resume()
        }

        onFinish(.init(provider: "email", displayName: nil, email: email))
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

    var body: some View {
        VStack(spacing: 14) {
            permissionCard(
                title: "Microphone",
                description: "Record your side of the call.",
                status: micStatus,
                primaryLabel: micPrimaryLabel,
                onPrimary: micPrimaryAction
            )
            permissionCard(
                title: "Screen Recording",
                description: "Capture the other side's audio.",
                status: screenStatus,
                primaryLabel: screenPrimaryLabel,
                onPrimary: screenPrimaryAction
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        onPrimary: @escaping () -> Void
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
                        Text(title)
                            .font(.system(size: 18, weight: .light))
                            .lineSpacing(18 * 0.35)
                            .foregroundColor(.primary)
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
    /// Inline validation message shown beneath the password
    /// field. Bound to the WelcomeView so the CTA action can
    /// raise it and the field auto-clears it on input change.
    @Binding var inlineError: String?
    /// Fired when the user presses Return inside either field.
    /// Forwards to the bottom CTA's action.
    let onSubmit: () -> Void
    /// Carries the sign-in result up to the WelcomeWindowController
    /// so it can close the wizard, open the Library, and surface a
    /// "Welcome, <name>" toast.
    let onSuccess: (SignInResult) -> Void

    @FocusState private var focusedField: Field?
    @State private var emailHovered: Bool = false
    @State private var passwordHovered: Bool = false

    private enum Field { case email, password }

    var body: some View {
        // Vertically centred. Email + password on top (primary
        // path); "or" divider; OAuth providers underneath.
        VStack(spacing: 10) {
                Spacer(minLength: 0)

                emailField
                passwordField

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
            .onChange(of: email)    { _, _ in inlineError = nil }
            .onChange(of: password) { _, _ in inlineError = nil }
    }

    // MARK: - Provider buttons

    private var googleButton: some View {
        Button(action: openGoogleOAuth) {
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
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Email + password

    private var emailField: some View {
        TextField("you@example.com", text: $email)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .textContentType(.emailAddress)
            .disableAutocorrection(true)
            .focused($focusedField, equals: .email)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 320)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(emailBorderColour, lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { focusedField = .email }
            .onSubmit {
                // Return inside the email field jumps focus to
                // password; if password's already filled the
                // signin fires from there.
                if password.isEmpty { focusedField = .password }
                else                { onSubmit() }
            }
            .onHover { h in
                emailHovered = h
                if h { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
    }

    private var passwordField: some View {
        SecureField("Password", text: $password)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .textContentType(.password)
            .focused($focusedField, equals: .password)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 320)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(passwordBorderColour, lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { focusedField = .password }
            .onSubmit { onSubmit() }
            .onHover { h in
                passwordHovered = h
                if h { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
    }

    private var emailBorderColour: Color {
        if focusedField == .email { return brandAccent }
        if emailHovered { return Color.black.opacity(0.24) }
        return Color.black.opacity(0.12)
    }

    private var passwordBorderColour: Color {
        if focusedField == .password { return brandAccent }
        if passwordHovered { return Color.black.opacity(0.24) }
        return Color.black.opacity(0.12)
    }

    // MARK: - Google

    /// Kicks off the full Google Desktop OAuth flow — loopback
    /// listener + browser open + token exchange + userinfo. On
    /// success flips the wizard into the confirmation card; on
    /// failure logs and stays put.
    private func openGoogleOAuth() {
        FileLogger.log("WelcomeWindow: Google sign-in button tapped")
        Task { @MainActor in
            do {
                let res = try await GoogleOAuth.signIn()
                AppSettings.setLicenceKey(res.email)
                AppSettings.setUserName(res.name)
                postSignup(payload: [
                    "provider":       "google",
                    "google_user_id": res.googleUserId,
                    "email":          res.email,
                    "name":           res.name as Any,
                    "source":         "corder-mac-wizard",
                ])
                onSuccess(.init(
                    provider: "google",
                    displayName: res.name,
                    email: res.email
                ))
            } catch {
                FileLogger.log("GoogleOAuth: signIn failed: \(error)")
            }
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
/// rather than crashing.
private struct GoogleG: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "google-g",
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
