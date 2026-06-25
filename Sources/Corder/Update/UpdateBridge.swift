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

    /// The most recent state pushed by the driver. Cached so it can be
    /// REPLAYED once the React modal host signals it's mounted ("ready").
    /// Without this, an update found while the Library WebView is closed
    /// (the common case: a background check finds it) pushes a modal that
    /// is dropped, Sparkle then sits waiting on the user's reply, and when
    /// the user later opens the Library + clicks the pill, a fresh
    /// `checkForUpdates()` is ignored because that session is still
    /// pending — so the pill "does nothing". Replaying the cached state on
    /// mount surfaces the modal so the user can actually click Install.
    private var lastState: UpdateModalState?

    /// Push a fresh state snapshot to the WebView. Called every time
    /// the Sparkle driver enters a new phase or progress ticks.
    /// `visible=false` removes the modal from the DOM.
    func push(_ state: UpdateModalState) {
        lastState = state
        guard let webView = LibraryWindow.shared.webViewRef else { return }
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        // `window.corderUpdateState` is installed by the React app on
        // mount (see `UpdateModalHost`). If the WebView hasn't loaded yet
        // the call is dropped, but the React host posts "ready" once it
        // mounts and we replay `lastState` then (see `handle`).
        let js = "window.corderUpdateState && window.corderUpdateState(\(json))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Re-push the last known state. Used when the React modal host has
    /// just mounted, so a state pushed before it existed isn't lost.
    func replayLastState() {
        FileLogger.log("UpdateBridge: replayLastState (\(lastState != nil ? "have pending state, re-pushing" : "nothing pending"))")
        if let state = lastState { push(state) }
    }

    /// Called by `LibraryWindow`'s message router when the React side
    /// posts a button press OR signals it's mounted.
    func handle(action: String) {
        switch action {
        case "primary":  onPrimary()
        case "dismiss":  onDismiss(); lastState = nil   // don't replay a modal the user closed
        case "ready":    replayLastState()
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
