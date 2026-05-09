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
    init(window: NSWindow?) { self.window = window }
    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        switch message.name {
        case "drag":
            DispatchQueue.main.async { [weak self] in
                if let event = NSApp.currentEvent {
                    self?.window?.performDrag(with: event)
                }
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
}

final class LibraryWindow: NSWindowController {
    static let shared = LibraryWindow()

    private var webView: WKWebView!
    private var bridgeHandler: WebBridgeHandler?

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
        win.backgroundColor = NSColor.white
        win.center()
        super.init(window: win)

        win.delegate = self

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // Bridge: page can post {drag, copy} messages to native.
        let handler = WebBridgeHandler(window: win)
        cfg.userContentController.add(handler, name: "drag")
        cfg.userContentController.add(handler, name: "copy")
        cfg.userContentController.add(handler, name: "openExternal")
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
        win.contentView?.addSubview(wv)
        self.webView = wv

        // Drag strip at the very top of the window. Sits above the WKWebView so
        // it gets the mouseDown first and can perform the window drag.
        let dragView = DragView(frame: NSRect(x: 0, y: win.contentView!.bounds.height - 28,
                                              width: win.contentView!.bounds.width, height: 28))
        dragView.autoresizingMask = [.width, .minYMargin]
        win.contentView?.addSubview(dragView)
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
    }
}

extension LibraryWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Return to menu-bar-only behaviour when the user closes the window.
        NSApp.setActivationPolicy(.accessory)
    }
}
