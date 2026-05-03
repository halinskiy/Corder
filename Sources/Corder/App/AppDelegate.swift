import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ note: Notification) {
        FileLogger.log("AppDelegate: applicationDidFinishLaunching")
        // Recover from prior crashes: any meeting still marked recording/transcribing
        // belongs to a previous app run, so it can never finish — flag it failed.
        try? AppContext.shared.repo.resetStuckMeetings()
        // Scrub Whisper hallucinations ("Субтитры сделал DimaTorzok", etc.) from
        // any pre-existing transcripts so the user sees a clean library on launch.
        TranscriptionPipeline.purgeKnownHallucinations(repo: AppContext.shared.repo)
        startServer()
        _ = RecordingController.shared    // bootstrap delegate wiring
        // Kick off WhisperKit model download in the background so the first
        // recording transcribes immediately instead of waiting on a 800 MB pull.
        TranscriptionPipeline.shared.prewarm()
        installMainMenu()
        // Boot Sparkle's background updater. Reads SUFeedURL / SUPublicEDKey
        // from Info.plist; checks once on launch and then on Sparkle's
        // default 24h schedule. If feed/key are missing the controller
        // logs a Sparkle error and stays inert — it never crashes the app.
        _ = UpdateController.shared
        menuBar = MenuBarController { [weak self] in
            self?.openLibrary()
        }
        // Wire up notification clicks → open Library so "Show" actually does something.
        NSUserNotificationCenter.default.delegate = self
    }

    /// Builds an Edit menu so standard shortcuts (⌘C, ⌘X, ⌘V, ⌘A, ⌘Z) have
    /// real first-responder targets. Without this, an LSUIElement app with a
    /// regular window has no menu, and AppKit beeps when the user presses ⌘C
    /// because there's nowhere to dispatch the `copy:` action.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let updates = NSMenuItem(title: "Проверить обновления…",
                                 action: #selector(UpdateController.checkForUpdates(_:)),
                                 keyEquivalent: "")
        updates.target = UpdateController.shared
        appMenu.addItem(updates)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Скрыть Corder",
                                   action: #selector(NSApplication.hide(_:)),
                                   keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Завершить Corder",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undo  = NSMenuItem(title: "Отменить", action: Selector(("undo:")),  keyEquivalent: "z")
        let redo  = NSMenuItem(title: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        let cut   = NSMenuItem(title: "Вырезать",  action: #selector(NSText.cut(_:)),   keyEquivalent: "x")
        let copy  = NSMenuItem(title: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Вставить",  action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let all   = NSMenuItem(title: "Выделить всё", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        [undo, redo, NSMenuItem.separator(), cut, copy, paste, NSMenuItem.separator(), all].forEach { editMenu.addItem($0) }
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // Always show the notification banner, even when Corder is in the foreground.
    nonisolated func userNotificationCenter(_ center: NSUserNotificationCenter,
                                            shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    nonisolated func userNotificationCenter(_ center: NSUserNotificationCenter,
                                            didActivate notification: NSUserNotification) {
        FileLogger.log("AppDelegate: notification activated (type=\(notification.activationType.rawValue))")
        DispatchQueue.main.async { [weak self] in
            self?.openLibrary()
        }
    }

    private func startServer() {
        do {
            try AppContext.shared.server.start { httpServer in
                Routes.register(server: httpServer, repo: AppContext.shared.repo)
            }
            FileLogger.log("AppDelegate: server on \(AppContext.shared.server.baseURL)")
        } catch {
            FileLogger.log("AppDelegate: server failed to start: \(error)")
        }
    }

    fileprivate func openLibrary() {
        LibraryWindow.shared.show(serverURL: AppContext.shared.server.baseURL)
    }
}
