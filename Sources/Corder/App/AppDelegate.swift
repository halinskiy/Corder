import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ note: Notification) {
        startServer()
        menuBar = MenuBarController { [weak self] in
            self?.openLibrary()
        }
    }

    private func startServer() {
        do {
            try AppContext.shared.server.start { httpServer in
                Routes.register(server: httpServer, repo: AppContext.shared.repo)
            }
            NSLog("Corder server on \(AppContext.shared.server.baseURL)")
        } catch {
            NSLog("Server failed to start: \(error)")
        }
    }

    private func openLibrary() {
        LibraryWindow.shared.show(serverURL: AppContext.shared.server.baseURL)
    }
}
