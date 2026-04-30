import Foundation
import ScreenCaptureKit

enum AvailableSources {
    /// Returns capturable windows that have a non-empty title and reasonable size.
    /// Filters out our own app, menu bars, dock items, etc.
    static func windows() async throws -> [CaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ourBundle = Bundle.main.bundleIdentifier
        return content.windows.compactMap { win -> CaptureSource? in
            guard let title = win.title, !title.isEmpty else { return nil }
            guard win.frame.width >= 200, win.frame.height >= 200 else { return nil }
            if let owner = win.owningApplication, owner.bundleIdentifier == ourBundle { return nil }
            let owner = win.owningApplication?.applicationName ?? "Unknown"
            return .window(
                windowID: win.windowID,
                title: title,
                ownerName: owner,
                width: Int(win.frame.width),
                height: Int(win.frame.height)
            )
        }
    }
}

extension CaptureSource {
    /// Human-readable label for menus / pickers. Truncated so popover stays narrow.
    var displayLabel: String {
        switch self {
        case .fullDisplay:
            return "Full screen"
        case .window(_, let title, let owner, _, _):
            let combined = "\(owner) · \(title)"
            return combined.count > 38 ? String(combined.prefix(36)) + "…" : combined
        }
    }
}
