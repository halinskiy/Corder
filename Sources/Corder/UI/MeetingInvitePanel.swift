import AppKit
import SwiftUI

/// Floating panel that pops in when `MeetingDetector` thinks a call has
/// just started. Shows a blurred translucent capsule with the meeting
/// app name and a one-tap "Start recording" affordance. Right-edge
/// anchored to the same screen edge the blob HUD will appear on, so
/// when the user accepts and the invite shrinks-to-a-point, the blob's
/// bloom-from-a-point reads as one shape morphing in place.
@MainActor
final class MeetingInvitePanel {
    static let shared = MeetingInvitePanel()
    private init() {}

    private var window: NSPanel?
    private var dismissTimer: Timer?
    private var onDismiss: (() -> Void)?

    private static let panelWidth: CGFloat = 268
    /// Same height as the blob HUD so the two are vertically centred at
    /// roughly the same screen Y — the eye reads the morph as one
    /// continuous object even though they're two separate panels.
    private static let panelHeight: CGFloat = 110
    private static let autoDismissAfter: TimeInterval = 25

    func show(appName: String,
              onAccept: @escaping () -> Void,
              onDismiss: @escaping () -> Void) {
        // Replace any prior invite without firing its dismiss callback
        // (the caller already knows it's being replaced).
        hide(animated: false, fireDismiss: false)
        self.onDismiss = onDismiss

        let host = NSHostingController(rootView:
            InviteContentView(
                appName: appName,
                onAccept: { [weak self] in
                    self?.acceptedWithMorph()
                    onAccept()
                },
                onDismiss: { [weak self] in
                    self?.hide(animated: true, fireDismiss: true)
                }
            )
        )
        host.view.frame = NSRect(x: 0, y: 0,
                                 width: Self.panelWidth, height: Self.panelHeight)

        let panel = NSPanel(
            contentRect: host.view.bounds,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        // Anchor at the same bottom-right corner the blob HUD uses —
        // right edge 16 px from screen edge, bottom 16 px up. The blob
        // panel's right edge sits at exactly the same X, so on accept
        // the capsule shrinks toward that point and the blob blooms
        // from it without a visible jump.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: f.maxX - Self.panelWidth - 16,
                y: f.minY + 16
            ))
        }
        panel.orderFrontRegardless()
        window = panel

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.autoDismissAfter,
                                            repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide(animated: true, fireDismiss: true)
            }
        }
    }

    /// Programmatic dismiss. `fireDismiss=true` calls the caller's
    /// onDismiss; pass false from `show()` when replacing one invite
    /// with another (the caller already knows about the replacement).
    func hide(animated: Bool, fireDismiss: Bool = false) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let cb = onDismiss
        onDismiss = nil
        guard let panel = window else {
            if fireDismiss { cb?() }
            return
        }
        if !animated {
            panel.orderOut(nil)
            window = nil
            if fireDismiss { cb?() }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                self?.window = nil
                if fireDismiss { cb?() }
            }
        })
    }

    func hide(animated: Bool) {
        hide(animated: animated, fireDismiss: false)
    }

    /// Accepted path: the SwiftUI view morphs its capsule away to a
    /// point + blur as the blob HUD blooms from the same screen point.
    /// We post a notification the view subscribes to so the animation
    /// stays inside SwiftUI (driven by spring + easing), then drop the
    /// window once the morph window closes.
    private func acceptedWithMorph() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        onDismiss = nil
        guard let panel = window else { return }
        NotificationCenter.default.post(name: .meetingInviteMorphOut, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                self?.window = nil
            }
        }
    }
}

extension Notification.Name {
    static let meetingInviteMorphOut = Notification.Name("Corder.MeetingInvite.MorphOut")
}

// MARK: - View

private struct InviteContentView: View {
    let appName: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var morphingOut = false
    @State private var hovered = false

    var body: some View {
        capsule
            .scaleEffect(stateScale, anchor: .trailing)
            .opacity(stateOpacity)
            .blur(radius: stateBlur)
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: appeared)
            .animation(.easeInOut(duration: 0.32), value: morphingOut)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { appeared = true }
            .onReceive(NotificationCenter.default.publisher(for: .meetingInviteMorphOut)) { _ in
                morphingOut = true
            }
    }

    private var stateScale: CGFloat {
        if morphingOut { return 0.08 }
        return appeared ? 1.0 : 0.62
    }
    private var stateOpacity: CGFloat {
        if morphingOut { return 0.0 }
        return appeared ? 1.0 : 0.0
    }
    private var stateBlur: CGFloat {
        if morphingOut { return 12 }
        return appeared ? 0 : 18
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.06, green: 0.49, blue: 0.27))
                    .frame(width: 34, height: 34)
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Записать встречу?")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.10)))
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.06, green: 0.49, blue: 0.27)
                          .opacity(hovered ? 0.12 : 0.06))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(hovered ? 0.20 : 0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        .scaleEffect(hovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.18), value: hovered)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { onAccept() }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !hovered { hovered = true }
                NSCursor.pointingHand.set()
            case .ended:
                hovered = false
                NSCursor.arrow.set()
            }
        }
        .frame(width: 240, height: 64)
        .help("Нажми, чтобы начать запись")
    }
}
