import AppKit
import WebKit

final class LibraryWindow: NSWindowController {
    static let shared = LibraryWindow()

    private var webView: WKWebView!

    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "Corder"
        win.titlebarAppearsTransparent = true
        win.center()
        super.init(window: win)

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let wv = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        win.contentView?.addSubview(wv)
        self.webView = wv
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(serverURL: URL) {
        if webView.url == nil {
            webView.load(URLRequest(url: serverURL))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
