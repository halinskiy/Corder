import AppKit
import WebKit

/// Invisible 28pt-tall view at the top of the window that forwards mouseDown
/// to the window's drag handler. WKWebView normally swallows mouse events,
/// so isMovableByWindowBackground alone doesn't make the window draggable.
private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        // Double-click on the title-bar area: honour the user's
        // "Double-click a window's title bar to…" preference (Maximize /
        // Minimize / Fill / nothing). Without this branch our performDrag
        // call swallows the second click and the window never zooms.
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
        window?.performDrag(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point)
    }
}

/// Receives messages from JavaScript:
///   - "drag" → starts a window drag (mousedown on header background)
///   - "copy" with payload → copies the payload to NSPasteboard. WKWebView's
///     `navigator.clipboard.writeText` and `document.execCommand('copy')` are
///     both unreliable inside our window, so we route Copy through native.
private final class WebBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var window: NSWindow?
    /// Toggles the inline recording blob. The blob is a native NSView
    /// stacked above the WKWebView, so a web-side fullscreen overlay
    /// (the video lightbox) can't paint over it — it would otherwise
    /// float on top of the dimmed video. The page calls
    /// `corderSetBlobVisible(false)` on open and `(true)` on close.
    var onBlobVisible: ((Bool) -> Void)?
    init(window: NSWindow?) { self.window = window }
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "blobVisible":
            let visible = (message.body as? Bool) ?? true
            DispatchQueue.main.async { [weak self] in
                self?.onBlobVisible?(visible)
            }
        case "drag":
            // This handler is already delivered on the main thread.
            // The previous `DispatchQueue.main.async` hop deferred the
            // drag to a later run-loop turn, by which point
            // `NSApp.currentEvent` was usually no longer the live
            // mousedown — so `performDrag` was never called and only
            // the top native DragView strip (which drags synchronously
            // in its own `mouseDown`) actually moved the window. Acting
            // synchronously here, while the mousedown is still the
            // current event, makes the whole `.main-header` background
            // draggable, not just the top 28 px.
            guard let event = NSApp.currentEvent else { return }
            // `NSEvent.clickCount` ONLY exists on mouse-click events;
            // reading it on any other type throws
            // NSInternalInconsistencyException → SIGABRT. Gate the read
            // on the event type.
            let clickTypes: Set<NSEvent.EventType> = [
                .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp,
            ]
            // Double-click on the header behaves like a real title bar:
            // honour the user's "Double-click a window's title bar to…"
            // preference. Without this the per-mousedown performDrag
            // swallows the gesture and the window never zooms.
            if clickTypes.contains(event.type), event.clickCount >= 2 {
                let action = UserDefaults.standard
                    .string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize":
                    self.window?.performMiniaturize(nil)
                case "Maximize", "Fill":
                    self.window?.performZoom(nil)
                default:
                    break
                }
                return
            }
            // performDrag is only valid for a mouse-drag/-down event;
            // ignore anything else rather than risk another throw.
            if clickTypes.contains(event.type) || event.type == .leftMouseDragged {
                self.window?.performDrag(with: event)
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
/// WKWebView never honours `<a download>` on its own — without a
/// navigation/download delegate the click just navigates the web view
/// (text endpoints render raw, binary ones do nothing), which is why
/// "Transcript as Markdown" (and every other download row) saved
/// nothing. We intercept the response, force `.download`, and save
/// through a standard NSSavePanel.
private final class WebDownloadDelegate: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    weak var window: NSWindow?
    init(window: NSWindow?) { self.window = window }

    private func isFileEndpoint(_ url: URL?) -> Bool {
        guard let p = url?.path else { return false }
        return p.range(
            of: #"/api/meetings/[^/]+/(audio|video|transcript\.(txt|md|json)|bundle\.zip)$"#,
            options: .regularExpression) != nil
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(isFileEndpoint(navigationResponse.response.url) ? .download : .allow)
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
    private var bridgeHandler: WebBridgeHandler?
    private var downloadDelegate: WebDownloadDelegate?

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
        // The web view is transparent (drawsBackground=false), so this
        // colour shows in the titlebar strip / overscroll. Light is the
        // default theme; the page posts its real --bg via the
        // "themeColor" bridge right after first paint and on every theme
        // switch, so this just needs a sane pre-paint value.
        win.backgroundColor = .white
        // Needed so the inline HUDHostingView (the blob in the bottom-
        // right corner) receives `mouseMoved` events. Without this,
        // AppKit silently drops them at the window level and our
        // cursor-update path on the blob never fires — leaving the
        // pointer stuck on the arrow even when SwiftUI hover registers.
        win.acceptsMouseMovedEvents = true
        win.center()
        super.init(window: win)

        win.delegate = self

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // Bridge: page can post {drag, copy} messages to native.
        let handler = WebBridgeHandler(window: win)
        cfg.userContentController.add(handler, name: "drag")
        cfg.userContentController.add(handler, name: "themeColor")
        cfg.userContentController.add(handler, name: "copy")
        cfg.userContentController.add(handler, name: "openExternal")
        cfg.userContentController.add(handler, name: "blobVisible")
        let bridgeJS = """
        (function() {
          // Drag: mousedown on header background → window.performDrag in Swift.
          document.addEventListener('mousedown', function(e) {
            const header = e.target.closest && e.target.closest('.main-header');
            if (!header) return;
            if (e.target.closest('button, input, select, textarea, a')) return;
            window.webkit.messageHandlers.drag.postMessage('drag');
          }, true);

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
          // handle it — otherwise AppKit looks for a `copy:` first responder,
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
        self.downloadDelegate = dl
        win.contentView?.addSubview(wv)
        self.webView = wv

        // Drag strip at the very top of the window. Sits above the WKWebView so
        // it gets the mouseDown first and can perform the window drag.
        let dragView = DragView(frame: NSRect(x: 0, y: win.contentView!.bounds.height - 28,
                                              width: win.contentView!.bounds.width, height: 28))
        dragView.autoresizingMask = [.width, .minYMargin]
        win.contentView?.addSubview(dragView)

        // Same SwiftUI blob the floating HUD uses, embedded directly in
        // the bottom-right of the Library window. Reused — not a copy.
        // Click toggles recording (start when idle, stop when recording);
        // the click target is state-aware, the visuals (hover spotlight,
        // morph, palette swap on audio activity) all come from the
        // unmodified RecordingHUDView.
        let blob = HUDHostingView(rootView:
            RecordingHUDView(onTap: {
                Task { @MainActor in
                    switch AppContext.shared.recordingState {
                    case .idle:
                        MeetingDetector.shared.userStartedRecordingManually()
                        await RecordingController.shared.startRecording(source: .fullDisplay)
                    case .recording:
                        await RecordingController.shared.stopRecording()
                    case .stopping:
                        return
                    }
                }
            })
        )
        let blobSize: CGFloat = 110
        let blobMargin: CGFloat = 8
        blob.frame = NSRect(
            x: win.contentView!.bounds.width - blobSize - blobMargin,
            y: blobMargin,
            width: blobSize, height: blobSize
        )
        // Anchor to bottom-right: distance to left grows when resized
        // (.minXMargin flexible), distance to top grows too (.maxYMargin).
        blob.autoresizingMask = [.minXMargin, .maxYMargin]
        win.contentView?.addSubview(blob)

        // Let the web video lightbox hide this native blob while it's
        // open (the blob is stacked above the WKWebView and would
        // otherwise punch through the dimmed fullscreen overlay).
        handler.onBlobVisible = { [weak blob] visible in
            blob?.isHidden = !visible
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(serverURL: URL) {
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
        // is visible — NOT tied to key status (the user watching a call
        // in another app makes the Library resign key while it's still
        // fully visible, and the old key-based toggle then popped the
        // floating HUD back as a duplicate).
        RecordingHUDPanel.shared.setLibrarySuppressed(true)
    }

    /// The web app keeps polling (recording state, meeting list) on a
    /// timer. When the window is closed the page stays alive in the
    /// background — those polls are pure waste. Tell the page to pause
    /// while hidden and resume (with an immediate refresh) on show.
    private func setWebActive(_ active: Bool) {
        guard webView.url != nil else { return }
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('corder-window-active',{detail:\(active)}))",
            completionHandler: nil)
    }
}

extension LibraryWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Return to menu-bar-only behaviour when the user closes the window.
        setWebActive(false)
        NSApp.setActivationPolicy(.accessory)
        // Window (and its inline blob) is going away — bring the
        // floating HUD back if a recording is in flight.
        RecordingHUDPanel.shared.setLibrarySuppressed(false)
    }

    // Suppression follows VISIBILITY, not key status. The inline blob
    // is on screen for as long as the window is un-minimised, so the
    // floating HUD stays hidden the whole time (no duplicate blob when
    // the user clicks into another app). When the window is minimised
    // its inline blob is gone, so the floating HUD must come back.
    func windowDidMiniaturize(_ notification: Notification) {
        RecordingHUDPanel.shared.setLibrarySuppressed(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        RecordingHUDPanel.shared.setLibrarySuppressed(true)
    }
}
