import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    /// Set in init so non-UI singletons (MeetingDetector) can drop the
    /// "Record this call?" offer into the menu-bar popover without
    /// threading a reference through every layer.
    static private(set) weak var shared: MenuBarController?

    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    /// True while any popover content (menu, invite, loading) is on
    /// screen. Used by `AppDelegate.quitOrClosePopover` to swallow
    /// ⌘Q when the popover is up.
    var isPopoverShown: Bool { popover.isShown }

    /// Force-close the popover regardless of `behavior`. `close()` is
    /// the AppKit-blessed synchronous teardown that ignores
    /// `.applicationDefined` stickiness; `performClose:` would honour
    /// it and leave the popover open.
    func forceClosePopover() {
        popover.behavior = .transient
        popover.close()
    }

    /// Global + local mouse-down monitors installed while the popover is
    /// up. NSPopover's own `.transient` dismissal is unreliable for a
    /// status-bar popover in an LSUIElement app (especially after the app
    /// was activated to present an invite): it sometimes "sticks" and
    /// ignores outside clicks (Костя's bug, the popover hangs and blocks
    /// the screen). These monitors guarantee ANY click outside the popover
    /// window closes it. Torn down in `popoverDidClose`.
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissPopoverFromOutsideClick()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // A click in one of our OWN windows (e.g. the Library) that
            // isn't the popover itself also dismisses it. Menu-bar clicks
            // (no event window) are handled by the status-item toggle and
            // the global monitor, so ignore those here.
            if let win = event.window, win !== self.popover.contentViewController?.view.window {
                self.dismissPopoverFromOutsideClick()
            }
            return event
        }
    }

    private func removeOutsideClickMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    private func dismissPopoverFromOutsideClick() {
        guard popover.isShown else { return }
        // An outside click on the invite = decline it (fire onDismiss so the
        // detector tears down any pre-roll); on the normal menu = just close.
        if popover.contentViewController !== menuHost {
            dismissInvite(fireDismiss: true)
        } else {
            forceClosePopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }
    private let onOpenLibrary: () -> Void
    private var cancellable: AnyCancellable?
    /// The normal popover content (menu). Stashed while the invite
    /// offer temporarily takes over the popover so we can restore it.
    private var menuHost: NSViewController?
    private var inviteDismissTimer: Timer?

    init(onOpenLibrary: @escaping () -> Void) {
        self.onOpenLibrary = onOpenLibrary
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Explicit isVisible = true, macOS Sequoia auto-hides
        // menu-bar items it considers overflow; forcing this on
        // (and persisting via `autosaveName`) prevents Corder
        // ending up in the hidden bucket.
        statusItem.isVisible = true
        statusItem.autosaveName = "CorderMenuBarItem"
        MenuBarController.shared = self
        FileLogger.log("MenuBarController: created, isVisible=\(statusItem.isVisible)")

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Never CLIP the icon: scale any image down to fit the menu-bar
            // height instead. This is the belt-and-suspenders fix for the
            // "ring periodically shows as ( )" report, when macOS re-lays-out
            // the status item (display sleep/wake, external-monitor connect/
            // disconnect, fullscreen transition) an image sitting at the height
            // limit was clipped top+bottom rather than scaled.
            // `.scaleProportionallyDown` guarantees it scales, never clips,
            // regardless of image size.
            button.imageScaling = .scaleProportionallyDown
        }

        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverContentView(ctx: AppContext.shared) { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenLibrary()
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        self.menuHost = host

        // Reflect recording state in the menu-bar icon: filled red circle
        // while recording, neutral outline circle otherwise.
        cancellable = AppContext.shared.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.updateIcon(for: state)
                // After invite/loading flow the popover content gets
                // swapped back to `menuHost`, but the behavior can
                // stick on `.applicationDefined` if `finishLoadingState`
                // raced this state change. Force `.transient` + restore
                // menu content unconditionally, same state recording
                // sees on a normal launch. UI is idempotent; nothing
                // breaks if it was already correct.
                switch state {
                case .recording, .stopping, .idle, .preroll:
                    if let menuHost = self.menuHost,
                       self.popover.contentViewController !== menuHost {
                        self.popover.contentViewController = menuHost
                    }
                    self.popover.behavior = .transient
                }
            }
        updateIcon(for: AppContext.shared.recordingState)
    }

    private func updateIcon(for state: RecordingState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle, .preroll:
            // FULL outline ring, hand-drawn, NOT the SF `circle` symbol.
            // The SF `circle` at menu-bar size rendered as a too-thin ring
            // whose top/bottom arcs sub-pixelled to nothing, so it read as
            // "( )" (clipped), the SAME SF-in-status-bar unreliability that
            // already forced `makeRedDot` (see that comment). Drawing the ring
            // ourselves with a controlled stroke + inset guarantees a full,
            // crisp ring. Template so it follows the menu bar's light/dark
            // tint. `.preroll` shows the SAME idle icon (silent pre-roll gives
            // no indicator).
            button.image = Self.makeRing(size: 14)
            button.contentTintColor = nil
            button.title = ""
        case .recording, .stopping:
            // Hand-drawn red disc. SF Symbol + contentTintColor proved
            // unreliable in the status bar (the image kept rendering as
            // empty space), so we draw a fixed-size NSImage ourselves.
            button.image = Self.makeRedDot(size: 14)
            button.contentTintColor = nil
            button.title = ""
        }
    }

    private static func makeRedDot(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false   // keep the actual red colour
        return img
    }

    /// Idle-state icon: a FULL outline ring, drawn ourselves so it renders
    /// crisply at menu-bar size instead of the too-thin SF `circle` that
    /// clipped to "( )". `lineWidth` gives it real presence; the inset is
    /// half the stroke + a hair so the whole ring (top AND bottom) stays
    /// inside the image bounds and never clips. Template so it adopts the
    /// menu bar's light/dark foreground tint, same as the SF symbol did.
    private static func makeRing(size: CGFloat) -> NSImage {
        let lineWidth: CGFloat = 1.6
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = lineWidth / 2 + 0.5
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            path.lineWidth = lineWidth
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true    // follow the menu-bar foreground tint
        return img
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            // A click on the icon while the invite is up = dismiss it
            // (and restore the normal menu for the next open).
            if popover.contentViewController !== menuHost {
                dismissInvite(fireDismiss: true)
                return
            }
            // Reset to `.transient` BEFORE close so a sticky
            // applicationDefined behavior (left over from an
            // interrupted invite/loading path) doesn't reject the
            // close. `popover.close()` (vs `performClose:`) is the
            // sync, behavior-ignoring variant, guaranteed to land.
            popover.behavior = .transient
            popover.close()
        } else {
            // Hard-reset to the default menu content + `.transient`
            // behaviour every normal open. The invite/loading paths
            // flip the popover to `.applicationDefined` and swap in
            // their own content view, and if any of those paths
            // crashed or returned early the popover could end up
            // sticky: clicks outside no longer dismiss it. Restoring
            // both knobs unconditionally before show guarantees the
            // user always gets the click-outside-to-dismiss behaviour
            // they expect from a menu-bar popover.
            if let menuHost { popover.contentViewController = menuHost }
            popover.behavior = .transient
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            installOutsideClickMonitors()
        }
    }

    // MARK: - "Record this call?" offer (replaces the old floating toast)

    private var inviteOnDismiss: (() -> Void)?

    /// Drop the call-record offer down from the menu-bar icon as a real
    /// NSPopover. Note: a status-bar popover is tied to the app, so it
    /// won't float over a fullscreen call on another Space, the user
    /// explicitly chose this native behaviour over the persistent
    /// floating panel. We activate the app so the popover can present
    /// even though Corder is LSUIElement and currently in the
    /// background, and use `.applicationDefined` so it stays put until
    /// the user answers (or the 25 s timeout fires) instead of vanishing
    /// on the first outside click.
    func showInviteOffer(appName: String,
                         onAccept: @escaping () -> Void,
                         onDismiss: @escaping () -> Void) {
        guard let button = statusItem.button else { return }
        inviteDismissTimer?.invalidate()
        inviteOnDismiss = onDismiss

        let host = NSHostingController(rootView: InviteOfferView(
            appName: appName,
            lang: AppContext.shared.language,
            onAccept: { [weak self] in
                self?.dismissInvite(fireDismiss: false)
                onAccept()
            },
            onDismiss: { [weak self] in
                self?.dismissInvite(fireDismiss: true)
            }
        ))
        host.sizingOptions = .preferredContentSize

        popover.behavior = .applicationDefined
        popover.contentViewController = host
        host.view.layoutSubtreeIfNeeded()

        NSApp.activate(ignoringOtherApps: true)
        if popover.isShown { popover.performClose(nil) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        inviteDismissTimer = Timer.scheduledTimer(withTimeInterval: 25,
                                                  repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissInvite(fireDismiss: true) }
        }
    }

    /// Public cancel, used when the user starts recording manually
    /// while a call-offer is still up, so a stale offer doesn't linger.
    /// No dismiss callback (the caller already took over).
    func cancelInviteOffer() {
        guard popover.contentViewController !== menuHost else { return }
        dismissInvite(fireDismiss: false)
    }

    private func dismissInvite(fireDismiss: Bool) {
        inviteDismissTimer?.invalidate()
        inviteDismissTimer = nil
        let cb = inviteOnDismiss
        inviteOnDismiss = nil
        if popover.isShown { popover.performClose(nil) }
        // Restore the regular menu content + transient behaviour for
        // the next normal open.
        if let menuHost = menuHost {
            popover.contentViewController = menuHost
        }
        popover.behavior = .transient
        if fireDismiss { cb?() }
    }

    // MARK: - "Starting recording…" loading state

    /// Show the warm-up spinner in the SAME popover (replaces the old
    /// floating loading capsule). Called from
    /// `RecordingController.startRecording` right before the SCStream +
    /// AVAudioEngine warm-up (~200-400 ms). On the auto-detect path the
    /// invite popover was just closed by `dismissInvite`; this re-opens
    /// the popover from the same status-item anchor so the user reads
    /// invite → loading → blob as one continuous element. On the manual
    /// Start path the menu popover may still be open from the click
    /// we just swap its content.
    func showLoadingState() {
        guard let button = statusItem.button else { return }
        inviteDismissTimer?.invalidate()
        let host = NSHostingController(rootView:
            LoadingStateView(lang: AppContext.shared.language))
        host.sizingOptions = .preferredContentSize
        popover.behavior = .applicationDefined
        popover.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        if popover.isShown { popover.performClose(nil) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Tear the loading state down and restore the normal menu. Used
    /// both on success (the blob takes over) and on the start-failure
    /// path so the user isn't left staring at a spinner that never
    /// resolves.
    func finishLoadingState() {
        if popover.isShown { popover.performClose(nil) }
        if let menuHost = menuHost {
            popover.contentViewController = menuHost
        }
        popover.behavior = .transient
    }
}

/// Warm-up spinner. Built from the exact same shell as
/// `InviteOfferView` / `PopoverContentView` (320 × padding-20 ×
/// windowBackground, rounded-8 hairline-bordered status card) so it
/// reads as one more state of the menu, not a separate toast.
private struct LoadingStateView: View {
    let lang: String
    var body: some View {
        VStack(alignment: .leading, spacing: PopoverShell.outerSpacing) {
            HStack(spacing: 12) {
                ProgressView().scaleEffect(0.7)
                Text(L.t("starting_recording", lang: lang))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
        .padding(PopoverShell.outerPadding)
        .frame(width: PopoverShell.width)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// "We noticed a call, record it?" offer. Built from the *exact* same
/// pieces as `PopoverContentView`: a bordered status card (mirrors
/// IdleStatus/RecordingStatus) + `FlatButtonStyle` buttons, same 320 ×
/// padding-20 × windowBackground shell. So it reads as one more state
/// of the menu, not a separate toast pretending to be it.
private struct InviteOfferView: View {
    let appName: String
    let lang: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // Geometry tokens live on `PopoverShell` so the main popover
        // (PopoverContentView) and this invite surface stay byte-
        // identical when a number moves. Don't reintroduce literals
        // here.
        VStack(alignment: .leading, spacing: PopoverShell.outerSpacing) {
            VStack(alignment: .leading, spacing: PopoverShell.sectionSpacing) {
                // Status card, same metrics as IdleStatus
                // (h16 / v14, rounded-8, primary.opacity(0.10) border).
                VStack(alignment: .leading, spacing: 1) {
                    Text(appName)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.red)
                    Text(L.t("invite_question", lang: lang))
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )

                // Primary, identical to the menu's idle "Start
                // recording" (red dot + FlatButtonStyle .primary).
                Button(action: onAccept) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(L.t("start", lang: lang))
                    }
                }
                .buttonStyle(FlatButtonStyle(role: .primary))
            }

            // Hairline, same as the menu's primary↔library divider.
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 2)

            // Secondary, same treatment as "Open library".
            Button(action: onDismiss) {
                Text(L.t("invite_not_now", lang: lang))
            }
            .buttonStyle(FlatButtonStyle(role: .secondary))
        }
        .padding(PopoverShell.outerPadding)
        .frame(width: PopoverShell.width)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
