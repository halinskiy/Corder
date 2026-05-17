import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ note: Notification) {
        FileLogger.log("AppDelegate: applicationDidFinishLaunching")
        // Salvage recordings interrupted by a crash BEFORE the cleanup
        // below deletes them: any with usable audio on disk are flipped
        // to 'transcribing' (and picked up by the auto-resume pass), so
        // a crash mid-meeting no longer loses the recording.
        RecordingRecovery.run(repo: AppContext.shared.repo)
        // Recover from prior crashes: drop orphan recording rows and flip
        // bare 'recording' state to failed. Transcribing rows are recovered
        // separately below — they get re-enqueued, not failed.
        try? AppContext.shared.repo.resetStuckMeetings()
        // If a transcription was in flight when the previous process died
        // (forced quit, rebuild during dev, machine sleep), pick it up
        // again automatically. The audio files (mic.wav / system.wav) are
        // preserved through transcription, so resume is cheap. User sees
        // the spinner banner come back, not a red "failed" card.
        if let stuck = try? AppContext.shared.repo.stuckTranscribingMeetingIds(), !stuck.isEmpty {
            for id in stuck {
                FileLogger.log("AppDelegate: auto-resuming transcription for \(id) (was stuck on prior launch)")
                TranscriptionErrors.clear(meetingId: id)
                TranscriptionPipeline.shared.enqueue(meetingId: id)
            }
        }
        // One-time cleanup of "ghost" speakers (rows with zero segments) —
        // legacy dual-track transcriptions used to insert "Speaker 1"
        // unconditionally even when the mic was silent, which skewed the
        // clarify banner's auto-default. Idempotent; safe to run on every
        // launch.
        if let purged = try? AppContext.shared.repo.purgeOrphanSpeakers(), purged > 0 {
            FileLogger.log("AppDelegate: purged \(purged) orphan speaker rows")
        }
        // Scrub Whisper hallucinations ("Субтитры сделал DimaTorzok", etc.) from
        // any pre-existing transcripts so the user sees a clean library on launch.
        TranscriptionPipeline.purgeKnownHallucinations(repo: AppContext.shared.repo)
        // Name recordings made before the auto-title feature (or whose
        // title pass failed) — generates titles in the background so the
        // sidebar stops showing bare dates for old transcripts.
        TranscriptionPipeline.backfillTitles(repo: AppContext.shared.repo)
        // Hard-delete archived meetings older than 7 days (DB row + local
        // recording dir + Dropbox files). Runs once per launch; missing
        // a launch just means the entries linger one extra day, which is
        // fine — the cap is "≥7 days, eventually wiped".
        purgeExpiredArchive()
        // Free disk: delete mic.wav + system.wav for meetings older than
        // 30 days that already have gemini_raw_turns cached. Re-transcribe
        // hits the cache and never needs the originals again.
        purgeStaleOriginals()
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
        // Wire UserNotifications: ask once for permission, route taps via
        // the lightweight delegate that opens the Library window.
        notificationDelegate.onAction = { [weak self] action in
            switch action {
            case .openLibrary: self?.openLibrary()
            }
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        NotificationsService.requestAuthorizationIfNeeded()
        // Auto-stop the recording when macOS is about to sleep / switch
        // sessions — SCStream silently dies through those transitions,
        // and a quiet abort with no notification is the worst UX of all.
        SleepWatchdog.shared.start()
        // Watch reachability so the user gets a banner when the network
        // drops during a recording, and so we can auto-retry meetings that
        // failed during an offline window once connectivity is back.
        NetworkMonitor.shared.start()
        // Watch for videoconference apps + a sustained mic-busy state on
        // the system; when both are true and we haven't already offered,
        // pop the invite capsule asking whether to record.
        MeetingDetector.shared.start()
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

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let closeWin = NSMenuItem(title: "Close Window",
                                  action: #selector(NSWindow.performClose(_:)),
                                  keyEquivalent: "w")
        fileMenu.addItem(closeWin)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

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

    /// Hard-delete every meeting whose `archived_at` is more than 7 days
    /// in the past. Wipes the local recording dir and best-effort kicks
    /// off Dropbox deletions for archived video/audio paths.
    private func purgeExpiredArchive() {
        let retentionMs: Int64 = 7 * 24 * 60 * 60 * 1000
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - retentionMs
        let repo = AppContext.shared.repo
        guard let ids = try? repo.archivedOlderThan(cutoff), !ids.isEmpty else { return }
        FileLogger.log("purgeExpiredArchive: hard-deleting \(ids.count) archived meeting(s) older than 7d")
        for id in ids {
            if let m = try? repo.meeting(id: id) {
                if let vp = m.dropboxVideoPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: vp) }
                }
                if let ap = m.dropboxAudioPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: ap) }
                }
            }
            let dir = AppPaths.recordingDir(for: id)
            try? FileManager.default.removeItem(at: dir)
            try? repo.deleteMeeting(id: id)
        }
    }

    /// Disk-pressure relief: for meetings transcribed >30 days ago whose
    /// raw Gemini turns are already cached, the original mic.wav and
    /// system.wav are dead weight. Re-transcribe (clarify-banner, pinned
    /// speaker count) reuses gemini_raw_turns and never touches the
    /// originals again. mix.wav stays — it's still served for playback.
    /// Idempotent: re-runs are no-ops when files have already been purged.
    private func purgeStaleOriginals() {
        let retentionMs: Int64 = 30 * 24 * 60 * 60 * 1000
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - retentionMs
        let repo = AppContext.shared.repo
        guard let ids = try? repo.transcribedWithCacheOlderThan(cutoff), !ids.isEmpty else { return }
        var freed: Int64 = 0
        var purged = 0
        for id in ids {
            let dir = AppPaths.recordingDir(for: id)
            for name in ["mic.wav", "system.wav"] {
                let url = dir.appendingPathComponent(name)
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
                    freed += size
                    purged += 1
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        if purged > 0 {
            let mb = Double(freed) / 1_048_576
            FileLogger.log(String(format: "purgeStaleOriginals: removed %d original tracks across %d cached meetings, freed %.1f MB",
                                  purged, ids.count, mb))
        }
    }
}

/// Standalone delegate so the AppDelegate can stay `@MainActor`-pure. The
/// new UserNotifications API delivers callbacks on a non-main queue;
/// hopping back via `Task { @MainActor }` lets us touch UI from here.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onAction: (@MainActor (NotificationsService.Action) -> Void)?

    /// Always show the banner, even if Corder is in the foreground —
    /// the user may be in another window watching the recording finish.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = (response.notification.request.content.userInfo["action"] as? String) ?? ""
        let action = NotificationsService.Action(rawValue: raw) ?? .openLibrary
        FileLogger.log("AppDelegate: notification activated (action=\(action.rawValue))")
        Task { @MainActor [weak self] in
            self?.onAction?(action)
            completionHandler()
        }
    }
}
