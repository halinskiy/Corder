import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let onOpenLibrary: () -> Void
    private var cancellable: AnyCancellable?

    init(onOpenLibrary: @escaping () -> Void) {
        self.onOpenLibrary = onOpenLibrary
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        let host = NSHostingController(rootView: PopoverContentView(ctx: AppContext.shared) { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenLibrary()
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        // Reflect recording state in the menu-bar icon: filled red circle
        // while recording, neutral outline circle otherwise.
        cancellable = AppContext.shared.$recordingState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
        updateIcon(for: AppContext.shared.recordingState)
    }

    private func updateIcon(for state: RecordingState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            // Outline circle, template-rendered so it follows light/dark
            // menu-bar appearance.
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let img = NSImage(systemSymbolName: "circle", accessibilityDescription: "Corder")?
                .withSymbolConfiguration(config)
            img?.isTemplate = true
            button.image = img
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

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Force SwiftUI to compute its preferred size before anchoring,
            // otherwise the popover sometimes appears mid-screen.
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
