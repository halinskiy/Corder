import AppKit
import SwiftUI

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let onOpenLibrary: () -> Void

    init(onOpenLibrary: @escaping () -> Void) {
        self.onOpenLibrary = onOpenLibrary
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Corder")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 240, height: 200)
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(ctx: AppContext.shared) { [weak self] in
            self?.popover.performClose(nil)
            self?.onOpenLibrary()
        })
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
