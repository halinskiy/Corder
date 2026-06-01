import Foundation
import AppKit

/// Glue between Sparkle's `SPUUserDriver` callbacks and the React
/// update modal that lives inside the Library WKWebView. Owns the
/// "primary" / "dismiss" handlers registered by the driver in each
/// phase, and ships state snapshots to the WebView via
/// `window.corderUpdateState(...)`.
///
/// Why a separate bridge instead of letting the driver poke the
/// WebView directly: the React side needs ONE entry point that takes
/// a strongly-typed JSON payload; the Swift side needs ONE entry
/// point that lets WebView post `primary` / `dismiss` actions without
/// caring which driver phase is current. Keeping that pair on a
/// dedicated singleton means the rest of the codebase stays unaware.
@MainActor
final class UpdateBridge {
    static let shared = UpdateBridge()

    /// Closure run when the React modal posts a `primary` action
    /// (the big green CTA: Update / Install / Retry / OK). Driver
    /// rewires this on every phase transition.
    var onPrimary: () -> Void = {}
    /// Closure run when the React modal posts a `dismiss` action
    /// (the `Later` button or × in the overlay). Driver wires this
    /// to Sparkle's `.dismiss` reply.
    var onDismiss: () -> Void = {}

    private init() {}

    /// Push a fresh state snapshot to the WebView. Called every time
    /// the Sparkle driver enters a new phase or progress ticks.
    /// `visible=false` removes the modal from the DOM.
    func push(_ state: UpdateModalState) {
        guard let webView = LibraryWindow.shared.webViewRef else { return }
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        // `window.corderUpdateState` is installed by the React app on
        // mount (see `main.tsx`). If the WebView hasn't loaded yet we
        // just drop the call; React's first render will re-pull state
        // via a separate `corder-update-ready` message when ready.
        let js = "window.corderUpdateState && window.corderUpdateState(\(json))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Called by `LibraryWindow`'s message router when the React side
    /// posts a button press.
    func handle(action: String) {
        switch action {
        case "primary":  onPrimary()
        case "dismiss":  onDismiss()
        default:         break
        }
    }
}

/// Wire-format state sent to the React modal. Mirrors the SwiftUI
/// `UpdateState` model — same vocabulary so phases line up between
/// the two layers during the React migration.
struct UpdateModalState: Codable {
    var visible: Bool
    /// Raw phase tag. React maps it onto the button label + status
    /// line + progress visibility.
    var phase: String
    var version: String
    var releaseNotes: String?
    /// 0..1; React renders a determinate bar when `showsProgress`.
    var progress: Double
    var primaryLabel: String
    var primaryEnabled: Bool
    var phaseStatusLine: String?
    var showsProgress: Bool
    /// If non-nil, displayed as an error pill instead of the normal
    /// status line. Reserved for the `.error` phase.
    var errorMessage: String?
}
