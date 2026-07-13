import AppKit
import AVFoundation
import CoreGraphics
import WebKit

/// Full-coverage (64 pt × entire window width) invisible overlay over
/// the React `.main-header` band. Drives:
///
/// 1. **Drag**: single mousedown + movement past `dragThreshold` (4 pt)
///    → `performDrag`, AppKit moves the window normally.
/// 2. **Click forwarding**: single mousedown + release without movement
///    → forward into the WKWebView via `elementFromPoint(x, y)` +
///    synthetic mousedown/mouseup/click. Breadcrumb click-to-rename
///    keeps working.
/// 3. **Double-click**: honour the user's "Double-click a window's
///    title bar to…" preference (Maximize / Minimize / Fill / nothing).
///
/// To preserve native hover + click on real interactive elements
/// (toolbar buttons, profile avatar, language picker), `hitTest`
/// returns `nil` whenever the point falls inside one of the live
/// element rects the page reports via the `headerHits` JS bridge. Those
/// events then propagate to the underlying WKWebView, exactly as if the
/// overlay wasn't there. Drag still works in every other pixel, over
/// breadcrumb text, between toolbar icons, above/below them, because
/// hover-less geometry is the only thing the overlay covers.
///
/// This replaces the earlier "L-shape + 28 pt button band carve-out"
/// approach, which left the gaps between toolbar buttons mute (no drag,
/// no hover). It also replaces the JS-bridge `postMessage('drag')` path
/// from the 0.11.0 line, which raced `NSApp.currentEvent` and silently
/// failed in most of the header.
private final class HeaderDragView: NSView {
    /// Bounding rects of every interactive element inside the React
    /// `.main-header`, in **window coordinates** (origin bottom-left).
    /// The page repopulates this on mount, resize, language switch,
    /// theme switch, and any DOM mutation inside `.main-header`.
    /// Read by `hitTest` to decide pass-through vs. drag.
    static var interactiveRects: [CGRect] = []

    weak var webView: WKWebView?
    private let dragThreshold: CGFloat = 4

    /// Pass-through hit test: if the point lands inside a known
    /// interactive element rect, AppKit routes the event past this
    /// overlay to the WKWebView (which then handles hover and click
    /// natively). Otherwise we claim the event so `mouseDown` can run
    /// the drag/click-forward logic.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        let windowPoint = sv.convert(point, to: nil)
        for rect in Self.interactiveRects {
            if rect.contains(windowPoint) {
                return nil
            }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize":
                window?.performMiniaturize(nil)
            case "Maximize", "Fill":
                window?.performZoom(nil)
            default:
                break
            }
            return
        }

        let startPoint = event.locationInWindow
        var dragged = false

        // Spin the run loop on the live mouse-tracking mode until the
        // user either moves past the threshold (drag) or releases (click).
        trackingLoop: while let next = window?.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch next.type {
            case .leftMouseUp:
                break trackingLoop
            case .leftMouseDragged:
                let dx = abs(next.locationInWindow.x - startPoint.x)
                let dy = abs(next.locationInWindow.y - startPoint.y)
                if dx > dragThreshold || dy > dragThreshold {
                    // performDrag takes over until the user releases.
                    window?.performDrag(with: event)
                    dragged = true
                    break trackingLoop
                }
            default:
                break
            }
        }

        if !dragged {
            forwardClick(at: startPoint)
        }
    }

    /// Synthesises a click into the WKWebView at the given window-space
    /// point so the React onClick (breadcrumb rename, anything else) fires
    /// even though AppKit swallowed the original mousedown.
    private func forwardClick(at windowPoint: NSPoint) {
        guard let wv = webView else { return }
        // WKWebView reports `isFlipped == true`, so `convert(_:from: nil)`
        // already yields CSS coordinates (top-left origin, Y grows down)
        // the SAME convention `headerHits` uses to build `interactiveRects`.
        // The old code then did `bounds.height - y`, an extra flip that sent
        // a header click to the bottom of the page (landing on a sidebar
        // meeting row → "jumps to a random session"). No manual flip now.
        let viewPoint = wv.convert(windowPoint, from: nil)
        let cssX = viewPoint.x
        let cssY = viewPoint.y
        // Defensive guard: only forward the synthesised click when the
        // target actually lives inside `.main-header`. The drag overlay only
        // ever covers the header, so a click that resolves to anything below
        // it (sidebar row, transcript) is a coordinate-mapping miss and must
        // NOT fire, otherwise an empty-header click could navigate sessions.
        let js = """
        (function() {
          var x = \(cssX), y = \(cssY);
          var el = document.elementFromPoint(x, y);
          if (!el || !el.closest('.main-header')) return;
          var opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 };
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
          el.dispatchEvent(new MouseEvent('click', opts));
        })();
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // We do our own tracking + performDrag so AppKit shouldn't also
    // treat this view as window-draggable background (would double-fire).
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Receives messages from JavaScript:
///   - "copy" with payload → copies the payload to NSPasteboard. WKWebView's
///     `navigator.clipboard.writeText` and `document.execCommand('copy')` are
///     both unreliable inside our window, so we route Copy through native.
///   - "openExternal" with URL → hands the URL to NSWorkspace.shared.open.
///   - "themeColor" with #rrggbb → recolours the window background.
///   - "blobVisible" with Bool → toggles the inline recording blob.
private final class WebBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var window: NSWindow?
    /// Toggles the inline recording blob. The blob is a native NSView
    /// stacked above the WKWebView, so a web-side fullscreen overlay
    /// (the video lightbox) can't paint over it, it would otherwise
    /// float on top of the dimmed video. The page calls
    /// `corderSetBlobVisible(false)` on open and `(true)` on close.
    var onBlobVisible: ((Bool) -> Void)?
    /// The native overlay covering `.main-header`. We update its frame
    /// and its `interactiveRects` from `headerHits` messages.
    weak var headerDragView: HeaderDragView?
    init(window: NSWindow?) { self.window = window }
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "blobVisible":
            let visible = (message.body as? Bool) ?? true
            DispatchQueue.main.async { [weak self] in
                self?.onBlobVisible?(visible)
            }
        case "headerHits":
            // Payload: { header: {x,y,w,h}, interactive: [{x,y,w,h}, ...] }
            // All values are in CSS pixels with origin top-left of the
            // WKWebView. We convert to window coordinates (origin
            // bottom-left of contentView) and hand the rect list to
            // HeaderDragView for its hit-test.
            guard let dict = message.body as? [String: Any],
                  let dragView = self.headerDragView,
                  let wv = dragView.webView,
                  let interactive = dict["interactive"] as? [[String: Any]] else {
                FileLogger.log("headerHits: bad payload \(type(of: message.body))")
                return
            }
            // WKWebView reports `isFlipped == true`, so its coordinate
            // system already matches CSS (top-left origin, Y grows
            // downward). Build the rect in WV-coords and let AppKit's
            // `convert(_:to:)` do the flip into window coords.
            func toWindowRect(_ raw: [String: Any]) -> CGRect? {
                guard let x = (raw["x"] as? NSNumber)?.doubleValue,
                      let y = (raw["y"] as? NSNumber)?.doubleValue,
                      let w = (raw["w"] as? NSNumber)?.doubleValue,
                      let h = (raw["h"] as? NSNumber)?.doubleValue else { return nil }
                let cssRect = NSRect(x: CGFloat(x), y: CGFloat(y),
                                     width: CGFloat(w), height: CGFloat(h))
                return wv.convert(cssRect, to: nil)
            }
            let rects = interactive.compactMap(toWindowRect)
            // Diagnostic log removed, this message used to fire on every
            // header DOM mutation (theme switch, route change, tooltip
            // open), filling `/tmp/corder.log` with hundreds of entries
            // per minute. The bridge itself stays; just don't narrate it.
            // Resize the drag overlay to match the page-reported header
            // height so the bottom-border row is never a dead pixel.
            var newHeaderHeight: CGFloat? = nil
            if let header = dict["header"] as? [String: Any],
               let h = (header["h"] as? NSNumber)?.doubleValue {
                newHeaderHeight = CGFloat(h)
            }
            DispatchQueue.main.async {
                HeaderDragView.interactiveRects = rects
                if let h = newHeaderHeight,
                   let win = dragView.window,
                   let contentView = win.contentView {
                    let contentH = contentView.bounds.height
                    let contentW = contentView.bounds.width
                    dragView.frame = NSRect(
                        x: 0,
                        y: contentH - h,
                        width: contentW,
                        height: h
                    )
                }
            }
        case "themeColor":
            // The page reports its resolved --bg (e.g. "#ffffff" /
            // "#161615") so the window backdrop follows the theme.
            guard let hex = message.body as? String,
                  let color = Self.nsColor(fromHex: hex) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.window?.backgroundColor = color
            }
        case "copy":
            guard let text = message.body as? String else { return }
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        case "openExternal":
            // Donate buttons + any other "open in default browser" affordances
            // route through here. WKWebView refuses to follow target=_blank
            // links without a UIDelegate, so we hand them to NSWorkspace.
            guard let raw = message.body as? String,
                  let url = URL(string: raw),
                  url.scheme == "http" || url.scheme == "https" else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
                // Opening the pricing / upgrade page → start a short tier
                // poll so a completed purchase flips the user to Pro within
                // seconds, with no manual action even if they never refocus
                // the app. No-op unless signed-in & Free.
                // Only the pricing / upgrade page, not every getcorder.com
                // link (privacy, terms, etc.).
                let isPricing = url.host?.contains("getcorder.com") == true
                    && (url.fragment == "pricing" || url.path.contains("pricing"))
                if isPricing {
                    Task { @MainActor in SupabaseTierSync.pollAfterUpgrade() }
                }
            }
        case "updateAction":
            // The React update modal posts "primary" / "dismiss" here.
            // We route into UpdateBridge which owns the current Sparkle
            // reply callbacks; the Swift driver wired them in.
            guard let action = message.body as? String else { return }
            DispatchQueue.main.async {
                UpdateBridge.shared.handle(action: action)
            }
        case "authAction":
            // The React sign-in modal posts a JSON action string here
            // (submit / google / checkEmail / dismiss). AuthController does
            // the real Supabase auth + pushes state back via corderAuthState.
            guard let json = message.body as? String else { return }
            Task { @MainActor in AuthController.shared.handle(json) }
        case "requestScreenRecording":
            // The recording panel's ghost-video CTA posts here. Enable screen
            // video so it's ready once the grant lands, register Corder with the
            // OS Screen Recording list (CGRequestScreenCaptureAccess prompts a
            // first-timer), and point the user at the Settings pane. macOS only
            // applies a new Screen Recording grant on the NEXT launch.
            Task { @MainActor in
                AppSettings.setCaptureVideo(true)
                if AppSettings.screenRecordingAsked {
                    // Already prompted once: macOS won't show the system sheet
                    // again, so take the user straight to the Settings pane.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    // First time: the native Screen Recording prompt (which has
                    // its own "Open System Settings" button) is enough. Don't
                    // stack a second dialog on top of it.
                    AppSettings.setScreenRecordingAsked(true)
                    _ = CGRequestScreenCaptureAccess()
                }
            }
        default:
            break
        }
    }

    /// "#rrggbb" → device sRGB NSColor. Returns nil for anything that
    /// isn't a clean 6-hex string (never throws).
    static func nsColor(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0,
                       alpha: 1.0)
    }
}

/// Turns navigations to Corder's file endpoints into real downloads.
/// WKWebView never honours `<a download>` on its own, without a
/// navigation/download delegate the click just navigates the web view
/// (text endpoints render raw, binary ones do nothing), which is why
/// "Transcript as Markdown" (and every other download row) saved
/// nothing. We intercept the response, force `.download`, and save
/// through a standard NSSavePanel.
/// Routes WKWebView's JavaScript dialogs (`alert`, `confirm`,
/// `prompt`) to native NSAlerts attached to the library window.
/// Without a UIDelegate, WKWebView silently swallows these calls
/// `confirm()` always returns false, which is what broke the
/// archive's "Delete forever" button (the user's OK click never
/// reached the JS handler, so nothing was deleted).
private final class WebUIDelegate: NSObject, WKUIDelegate {
    weak var window: NSWindow?
    init(window: NSWindow?) { self.window = window }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let w = window {
            alert.beginSheetModal(for: w) { _ in completionHandler() }
        } else {
            alert.runModal()
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let w = window {
            alert.beginSheetModal(for: w) { resp in
                completionHandler(resp == .alertFirstButtonReturn)
            }
        } else {
            let resp = alert.runModal()
            completionHandler(resp == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        tf.stringValue = defaultText ?? ""
        alert.accessoryView = tf
        if let w = window {
            alert.beginSheetModal(for: w) { resp in
                completionHandler(resp == .alertFirstButtonReturn ? tf.stringValue : nil)
            }
        } else {
            let resp = alert.runModal()
            completionHandler(resp == .alertFirstButtonReturn ? tf.stringValue : nil)
        }
    }
}

private final class WebDownloadDelegate: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    weak var window: NSWindow?
    init(window: NSWindow?) { self.window = window }

    /// Bounded auto-reload budget so a renderer that keeps dying (or a
    /// server that never comes up) doesn't spin in an endless reload loop.
    /// Reset on every successful load.
    private var reloadAttempts = 0
    private let maxReloads = 6

    /// True once the automatic retry budget is exhausted and we've stopped
    /// trying, the Library is now BLANK. Cleared on the next successful load.
    /// The window controller re-arms a retry when the window regains focus
    /// (see `windowDidChangeOcclusionState` → `reattemptIfGaveUp`), so a
    /// transient startup timeout can never strand the UI blank until relaunch.
    private var gaveUp = false

    /// The WKWebView content process crashed (OOM, GPU reset, sandbox kill).
    /// Without this the Library window is left permanently BLANK until the
    /// user quits + relaunches. Reload to respawn the renderer.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard reloadAttempts < maxReloads else {
            gaveUp = true
            FileLogger.log("LibraryWindow: WKWebView content process kept terminating (\(reloadAttempts)x), giving up (will retry on window focus)")
            return
        }
        reloadAttempts += 1
        FileLogger.log("LibraryWindow: WKWebView content process terminated, reloading (attempt \(reloadAttempts))")
        webView.reload()
    }

    /// Provisional navigation failed, typically the embedded server hadn't
    /// finished binding when the window first loaded, or its Swifter workers
    /// were briefly hogged by a blocking export/transcribe so the page load
    /// timed out. Bounded retry with linear backoff so a slow bind gets
    /// progressively more time instead of burning the budget in a burst.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard reloadAttempts < maxReloads else {
            gaveUp = true
            FileLogger.log("LibraryWindow: provisional navigation kept failing (\(reloadAttempts)x), giving up (will retry on window focus)")
            return
        }
        reloadAttempts += 1
        FileLogger.log("LibraryWindow: provisional navigation failed (\(error.localizedDescription)), retrying (attempt \(reloadAttempts))")
        let delay = 0.5 * Double(reloadAttempts)   // 0.5s, 1.0s, 1.5s …
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { webView.reload() }
    }

    /// A load succeeded, refresh the reload budget for any FUTURE crash.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        reloadAttempts = 0
        gaveUp = false
    }

    /// Called when the Library window regains visibility. If the automatic
    /// retry budget was already exhausted (window is BLANK), take a fresh
    /// budget and reload, the server that was busy at launch has almost
    /// certainly recovered by the time the user looks at the window again.
    /// No-op unless we'd actually given up, so normal focus changes are free.
    func reattemptIfGaveUp(_ webView: WKWebView) {
        guard gaveUp else { return }
        gaveUp = false
        reloadAttempts = 0
        FileLogger.log("LibraryWindow: window refocused while blank, reloading WKWebView")
        webView.reload()
    }

    private func isFileEndpoint(_ url: URL?) -> Bool {
        guard let p = url?.path else { return false }
        // The EXPORT endpoints only (audio.m4a / video-audio.mp4 / transcript.* /
        // bundle.zip). NOT the bare playback `/audio` `/video`, which must
        // render inline for the scrubber + video preview. The previous regex
        // matched `/audio`/`/video` but MISSED `/audio.m4a` + `/video-audio.mp4`,
        // so clicking Download → Audio navigated the main frame to the m4a and
        // WKWebView rendered it full-window with no way back.
        return p.range(
            of: #"/api/meetings/[^/]+/(audio\.m4a|video-audio\.mp4|transcript\.(txt|md|json)|bundle\.zip)$"#,
            options: .regularExpression) != nil
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Force a real DOWNLOAD (not an inline render) for exports. Primary
        // signal: the server marks every export with `Content-Disposition:
        // attachment`; the path check is a belt-and-braces fallback. Without
        // this a media export (audio.m4a / video-audio.mp4) was RENDERED by
        // WKWebView over the whole window, trapping the user.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased() ?? ""
        let forceDownload = disposition.contains("attachment")
            || isFileEndpoint(navigationResponse.response.url)
        decisionHandler(forceDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                   decideDestinationUsing response: URLResponse,
                   suggestedFilename: String,
                   completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.filename(for: response.url, fallback: suggestedFilename)
        panel.canCreateDirectories = true
        if let win = window {
            panel.beginSheetModal(for: win) { resp in
                completionHandler(resp == .OK ? panel.url : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        FileLogger.log("download failed: \(error.localizedDescription)")
    }

    /// `.../api/meetings/<id>/<thing>` → a friendly, extensioned name
    /// (the raw last path component is e.g. "audio" with no extension).
    private static func filename(for url: URL?, fallback: String) -> String {
        let comps = url?.pathComponents ?? []
        guard let last = comps.last, comps.count >= 2 else { return fallback }
        let short = String(comps[comps.count - 2].prefix(8))
        switch last {
        case "audio":           return "corder-\(short).wav"
        case "video":           return "corder-\(short).mov"
        case "transcript.txt":  return "corder-\(short).txt"
        case "transcript.md":   return "corder-\(short).md"
        case "transcript.json": return "corder-\(short).json"
        case "bundle.zip":      return "corder-\(short).zip"
        default:                return fallback
        }
    }
}

final class LibraryWindow: NSWindowController {
    static let shared = LibraryWindow()

    private var webView: WKWebView!
    /// Read-only handle for non-LibraryWindow code that needs to
    /// poke the WebView (currently: `UpdateBridge` for the in-Library
    /// update modal). Returns nil while the window hasn't initialised
    /// or has been deinit'd.
    var webViewRef: WKWebView? { webView }
    private var bridgeHandler: WebBridgeHandler?
    private var downloadDelegate: WebDownloadDelegate?
    private var uiDelegate: WebUIDelegate?
    /// Debounce for occlusion-driven HUD suppression. `occlusionState` can
    /// flap rapidly (overlapping panels, Space/animation transitions, the
    /// floating HUD itself ordering in/out over the window), and mirroring
    /// every flip straight onto the HUD made the pill visibly flicker /
    /// disappear during recording. We coalesce flaps and act on the SETTLED
    /// state after a short delay instead.
    private var occlusionDebounce: DispatchWorkItem?

    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "Corder"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        // Floor below which the three-column layout (sidebar + transcript +
        // right panel) stops being usable. The side columns are fixed-px and
        // only the transcript flexes, so the width must reserve room for it
        // even at the DEFAULT column widths: 240 sidebar + ~300 transcript +
        // 380 right panel (+ splitters) ≈ 920. The height keeps the header,
        // toolbar, a few transcript rows, and the right-panel audio/timeline
        // all visible (and clears the sign-in modal, which now scrolls if it
        // ever exceeds the viewport). Without this macOS let the window shrink
        // to AppKit's ~64x64 floor, crushing the UI (the resize complaint).
        win.contentMinSize = NSSize(width: 920, height: 600)
        // The web view is transparent (drawsBackground=false), so this
        // colour shows in the titlebar strip / overscroll. Light is the
        // default theme; the page posts its real --bg via the
        // "themeColor" bridge right after first paint and on every theme
        // switch, so this just needs a sane pre-paint value.
        win.backgroundColor = .white
        // Needed so the inline HUDHostingView (the blob in the bottom-
        // right corner) receives `mouseMoved` events. Without this,
        // AppKit silently drops them at the window level and our
        // cursor-update path on the blob never fires, leaving the
        // pointer stuck on the arrow even when SwiftUI hover registers.
        win.acceptsMouseMovedEvents = true
        win.center()
        super.init(window: win)

        win.delegate = self

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // Bridge: page can post {copy, openExternal, themeColor,
        // blobVisible} messages to native. The old "drag" channel was
        // removed, the header is fully native-draggable via
        // `HeaderDragView` now, no async JS round-trip needed.
        let handler = WebBridgeHandler(window: win)
        cfg.userContentController.add(handler, name: "themeColor")
        cfg.userContentController.add(handler, name: "copy")
        cfg.userContentController.add(handler, name: "openExternal")
        cfg.userContentController.add(handler, name: "blobVisible")
        cfg.userContentController.add(handler, name: "headerHits")
        cfg.userContentController.add(handler, name: "updateAction")
        cfg.userContentController.add(handler, name: "authAction")
        cfg.userContentController.add(handler, name: "requestScreenRecording")
        let bridgeJS = """
        (function() {
          // Header drag/hover hit-test: report the bounding rects of
          // every interactive element inside `.main-header` so the
          // native overlay knows which pixels should pass through to
          // the WKWebView. Anything not in this list becomes drag.
          // Re-runs on resize, language switch, theme switch, and any
          // DOM mutation inside the header. Debounced via rAF so a
          // burst of mutations only fires one report.
          var __headerHitsScheduled = false;
          function __reportHeaderHits() {
            var header = document.querySelector('.main-header');
            if (!header) return;
            var hRect = header.getBoundingClientRect();
            // Anything the user might want to click natively. We do
            // NOT include `.breadcrumb-rename`: it's draggable AND
            // click-to-rename, the native overlay forwards the click
            // via elementFromPoint when there's no drag movement.
            // ALSO the sidebar search row: it sits in the same top strip the
            // drag overlay covers (full window width), so without reporting its
            // input + the archive back button here, clicks on them land on the
            // overlay and get dropped (forwardClick only forwards `.main-header`
            // targets). That was the "archive back button does nothing" bug.
            var sel = '.main-header button, .main-header a, .main-header input, .main-header select, .main-header textarea, .main-header [role="button"], .sidebar-search input, .sidebar-search button';
            var els = document.querySelectorAll(sel);
            var interactive = [];
            for (var i = 0; i < els.length; i++) {
              var r = els[i].getBoundingClientRect();
              if (r.width > 0 && r.height > 0) {
                interactive.push({ x: r.left, y: r.top, w: r.width, h: r.height });
              }
            }
            window.webkit.messageHandlers.headerHits.postMessage({
              header: { x: hRect.left, y: hRect.top, w: hRect.width, h: hRect.height },
              interactive: interactive
            });
          }
          function __scheduleHeaderHits() {
            if (__headerHitsScheduled) return;
            __headerHitsScheduled = true;
            requestAnimationFrame(function() {
              __headerHitsScheduled = false;
              __reportHeaderHits();
            });
          }
          window.addEventListener('load', __scheduleHeaderHits);
          window.addEventListener('resize', __scheduleHeaderHits);
          // Initial report once React has had a chance to render.
          setTimeout(__scheduleHeaderHits, 50);
          setTimeout(__scheduleHeaderHits, 250);
          setTimeout(__scheduleHeaderHits, 1000);
          // Live updates: a MutationObserver on body picks up route
          // changes (Dashboard ↔ MeetingView swap the breadcrumb +
          // toolbar contents), theme switch, language switch, etc.
          try {
            new MutationObserver(__scheduleHeaderHits).observe(document.body, {
              subtree: true, childList: true, attributes: true, characterData: false
            });
          } catch (_) {}

          // Copy: page calls window.corderCopy(text) and we route through native
          // pasteboard, bypassing WKWebView's flaky clipboard support.
          window.corderCopy = function(text) {
            try {
              window.webkit.messageHandlers.copy.postMessage(String(text));
              return true;
            } catch (e) { return false; }
          };

          // Open external URL in the default browser. target="_blank" links
          // never open in WKWebView without a UIDelegate, so any UI that
          // wants to send the user to the web (donate buttons, etc.) calls
          // this and we hand the URL to AppKit's NSWorkspace.
          window.corderOpenExternal = function(url) {
            try {
              window.webkit.messageHandlers.openExternal.postMessage(String(url));
              return true;
            } catch (e) { return false; }
          };

          // Ghost-video CTA: ask macOS for Screen Recording (and enable screen
          // video). Native side enables the setting, registers Corder with the
          // OS, and opens the Settings pane.
          window.corderRequestScreenRecording = function() {
            try {
              window.webkit.messageHandlers.requestScreenRecording.postMessage(1);
              return true;
            } catch (e) { return false; }
          };

          // Show/hide the native inline recording blob. Called by the
          // video fullscreen lightbox so the blob (a native view above
          // the web layer) doesn't float on top of the dimmed video.
          window.corderSetBlobVisible = function(v) {
            try {
              window.webkit.messageHandlers.blobVisible.postMessage(!!v);
              return true;
            } catch (e) { return false; }
          };

          // Cmd+C on a text selection: WKWebView in our config doesn't always
          // honour the system shortcut, so we listen ourselves and copy the
          // selection through the native bridge. We must preventDefault when we
          // handle it, otherwise AppKit looks for a `copy:` first responder,
          // doesn't find one (we have no Edit menu), and beeps.
          document.addEventListener('keydown', function(e) {
            if ((e.metaKey || e.ctrlKey) && e.key === 'c') {
              // Let inputs/textareas use their built-in copy behaviour.
              const ae = document.activeElement;
              if (ae && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA' || ae.isContentEditable)) {
                return;
              }
              const sel = window.getSelection && window.getSelection().toString();
              if (sel && sel.length > 0) {
                window.webkit.messageHandlers.copy.postMessage(sel);
              }
              // Always swallow so AppKit doesn't beep on a missing copy: target.
              e.preventDefault();
              e.stopPropagation();
            }
          }, true);
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(
            source: bridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        self.bridgeHandler = handler

        let wv = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        let dl = WebDownloadDelegate(window: win)
        wv.navigationDelegate = dl
        // `window.confirm()` / `window.alert()` from the JS side are
        // no-ops in WKWebView unless we provide a UIDelegate, `confirm`
        // silently returns `false`, which is why the Archive's
        // "Delete forever" button looked dead. UIDelegate translates
        // them into native NSAlerts and feeds the user's choice back.
        let ui = WebUIDelegate(window: win)
        wv.uiDelegate = ui
        self.uiDelegate = ui
        self.downloadDelegate = dl
        win.contentView?.addSubview(wv)
        self.webView = wv

        // Single full-width native overlay across the React
        // `.main-header` band. `hitTest` returns nil when the point
        // lands inside one of the live interactive rects the page
        // posts via the `headerHits` bridge, those events propagate
        // to the WKWebView so buttons keep hover + click. Everywhere
        // else (over breadcrumb text, between buttons, above/below
        // them, all the way down to the bottom border) the overlay
        // claims the event and drives drag/click-forward.
        //
        // The overlay's frame is also re-fit to the page's reported
        // header rect on every "headerHits" message, guarantees the
        // bottom border row isn't a dead pixel.
        let initialHeaderHeight: CGFloat = 64
        let contentH = win.contentView!.bounds.height
        let contentW = win.contentView!.bounds.width
        let dragView = HeaderDragView(frame: NSRect(
            x: 0,
            y: contentH - initialHeaderHeight,
            width: contentW,
            height: initialHeaderHeight))
        dragView.webView = wv
        dragView.autoresizingMask = [.width, .minYMargin]
        win.contentView?.addSubview(dragView)
        handler.headerDragView = dragView

        // No in-window recording indicator. Per Костя, the level indicator
        // lives ONLY in the floating HUD (when Corder is minimised / not in
        // front); inside the window there is no blob and no replacement.
        // Recording is started/stopped from the menu-bar popover and the
        // global hotkey. `onBlobVisible` stays nil (the web lightbox's call
        // becomes a harmless no-op).
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(serverURL: URL) {
        // NO permission gate: the Library always opens. Permissions are
        // requested ON-DEMAND when the user actually records (Microphone via
        // AVAudioEngine; Screen Recording only when video capture is on), so
        // a fresh, nothing-granted install lands straight in the Library and
        // is fully usable. We still refresh the sticky TCC flags here so the
        // record-time flow knows what to (re)request, but we never block the
        // window or hand off to a wizard (the Welcome wizard was removed).
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AppSettings.setMicGrantedSticky(false)
        }
        if !CGPreflightScreenCaptureAccess() {
            AppSettings.setScreenGrantedSticky(false)
        }
        if webView.url == nil {
            webView.load(URLRequest(url: serverURL))
        }
        // Switch out of LSUIElement-only mode so the window appears in the Dock
        // and ⌘Tab. We flip back to .accessory when the window closes.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setWebActive(true)
        // The Library window is now on screen; its inline blob provides
        // the start/stop affordance, so the floating HUD would be a
        // redundant SECOND blob. Suppress it for as long as the window
        // is visible, NOT tied to key status (the user watching a call
        // in another app makes the Library resign key while it's still
        // fully visible, and the old key-based toggle then popped the
        // floating HUD back as a duplicate).
        RecordingHUDPanel.shared.setLibrarySuppressed(true)
    }

    /// The web app keeps polling (recording state, meeting list) on a
    /// timer. When the window is closed the page stays alive in the
    /// background, those polls are pure waste. Tell the page to pause
    /// while hidden and resume (with an immediate refresh) on show.
    private func setWebActive(_ active: Bool) {
        guard webView.url != nil else { return }
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('corder-window-active',{detail:\(active)}))",
            completionHandler: nil)
    }

    /// Push an in-app toast into the Library window's React shell.
    /// Mirrors the system Notification for events the user should see
    /// even when the window is open and frontmost (a system toast
    /// in that case ends up in Notification Center alone). Front-end
    /// listens on `window.addEventListener('corder-toast', ...)` and
    /// pipes through its existing toast queue.
    /// Close the Library window if it's currently open. Used by the
    /// sign-out flow + first-launch path so that nothing about the
    /// signed-in app is visible behind the Welcome wizard. Named
    /// `dismiss` rather than `close` to avoid colliding with the
    /// `NSObject`/`NSWindow` `close()` selector on the superclass
    /// chain (Swift's override resolver picks `close` to mean the
    /// NS one and complains about the override signature).
    func dismiss() {
        window?.close()
    }

    func postToast(title: String, body: String, kind: String = "info") {
        guard webView != nil, webView.url != nil else { return }
        let payload = ["title": title, "body": body, "kind": kind]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('corder-toast',{detail:\(json)}))",
            completionHandler: nil)
    }
}

extension LibraryWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Return to menu-bar-only behaviour when the user closes the window.
        setWebActive(false)
        NSApp.setActivationPolicy(.accessory)
        // Window (and its inline blob) is going away, bring the
        // floating HUD back if a recording is in flight.
        RecordingHUDPanel.shared.setLibrarySuppressed(false)
    }

    // Suppression follows VISIBILITY, not key status. The inline blob
    // is on screen for as long as the window is un-minimised, so the
    // floating HUD stays hidden the whole time (no duplicate blob when
    // the user clicks into another app). When the window is minimised
    // its inline blob is gone, so the floating HUD must come back.
    func windowDidMiniaturize(_ notification: Notification) {
        FileLogger.log("LibraryWindow.windowDidMiniaturize")
        RecordingHUDPanel.shared.setLibrarySuppressed(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        FileLogger.log("LibraryWindow.windowDidDeminiaturize")
        RecordingHUDPanel.shared.setLibrarySuppressed(true)
    }

    /// AppKit fires this whenever the window's effective visibility on
    /// screen changes, including the case the user just hid the whole
    /// app via ⌘H or switched to another Space that doesn't include the
    /// window. The earlier suppression logic only listened to
    /// `windowWillClose` and `windowDidMiniaturize`, so a ⌘H left the
    /// window technically open AND occluded but with the floating HUD
    /// stuck hidden, that's the case Костя caught ("блоб не появился
    /// отдельным окном когда свернул кордер"). Reading the occlusion
    /// bit and mirroring it onto `librarySuppressed` covers ⌘H, hide
    /// via Dock, Space switches, and anything else AppKit considers a
    /// visibility change.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = self.window else { return }
        let visible = window.occlusionState.contains(.visible)
        FileLogger.log("LibraryWindow.windowDidChangeOcclusionState visible=\(visible)")
        // Self-heal a blank Library: if the WKWebView had given up loading (a
        // startup timeout that exhausted the retry budget), reload it now that
        // the user is looking at the window again. No-op unless we'd given up,
        // so ordinary focus flaps cost nothing.
        if visible, let wv = webView { downloadDelegate?.reattemptIfGaveUp(wv) }
        // DEBOUNCE: `occlusionState` can flap several times in a row (overlapping
        // panels, Space/animation transitions, the floating HUD ordering in/out
        // over the window). Mirroring every flip straight onto the HUD made the
        // pill flicker / vanish during recording. Coalesce: cancel any pending
        // decision and apply the SETTLED state ~350 ms later, so a burst of
        // changes collapses into one suppress/unsuppress.
        occlusionDebounce?.cancel()
        let work = DispatchWorkItem { [weak window] in
            // Re-read the live state at fire time, if it flapped back, this
            // reflects where it actually settled, not the value at schedule time.
            let settled = window?.occlusionState.contains(.visible) ?? false
            RecordingHUDPanel.shared.setLibrarySuppressed(settled)
        }
        occlusionDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
