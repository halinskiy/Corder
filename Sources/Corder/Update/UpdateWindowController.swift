import AppKit
import SwiftUI

/// Hosts `UpdateView` inside a borderless `NSPanel`. Centred on the
/// current key screen, drag-by-background via window-server, fades
/// out on close. Single shared instance — only one Corder update
/// modal can be visible at a time.
@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()

    private var window: NSWindow?

    let state = UpdateState()
    /// Closure invoked when the user taps the big primary CTA. Replaced
    /// every time the Sparkle driver enters a new phase so the same
    /// button can mean "Download" → "Install" → "Retry" depending on
    /// the state machine.
    var onPrimary: () -> Void = {}
    /// Closure invoked on "Later" / close — driver typically replies
    /// `.dismiss` to Sparkle.
    var onDismiss: () -> Void = {}

    private init() {}

    func present() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let rootView = UpdateView(
            state: state,
            onPrimary: { [weak self] in self?.onPrimary() },
            onDismiss: { [weak self] in
                self?.onDismiss()
                self?.close()
            }
        )
        let host = NSHostingController(rootView: rootView)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let w = window else { return }
        // Brief fade-out so the modal doesn't snap away — matches the
        // entrance animation in `UpdateView`.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            w.orderOut(nil)
            Task { @MainActor in self?.window = nil }
        })
    }
}
