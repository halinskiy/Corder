import AppKit
import AVFoundation
import CoreGraphics
import UserNotifications
@preconcurrency import Supabase

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ note: Notification) {
        FileLogger.log("AppDelegate: applicationDidFinishLaunching")
        // Single-instance guard. THIS instance is the newest (a fresh
        // launch, a Sparkle update, or a CorderRelaunch), so reap any older
        // Corder still running — otherwise two processes race the same
        // loopback port (which OAuth pins) and the per-account SQLite DB.
        // (The code/NOTES.md long referred to a "duplicate-instance killer"
        // that never actually existed; this is it.)
        Self.terminateOtherInstances()
        // Multi-account local layout: if there's still a legacy
        // flat `corder.db` at supportRoot AND we already know
        // which user owns this Mac (email persisted from previous
        // sign-in), migrate the legacy files into that user's
        // account folder BEFORE any GRDB connection opens. Done
        // here so AppContext.shared.repo's lazy init reads from
        // the right path on the very first access. Idempotent —
        // re-runs notice the destination already has a corder.db
        // and bail out without touching anything.
        // Model storage moved from per-account to machine-wide (supportRoot/models)
        // so sign-in/sign-out never re-downloads the ~1.5 GB model. Move an
        // existing per-account model up + reclaim duplicate copies. Runs for
        // everyone (guest or signed-in), before any model load. See AppPaths.
        AppPaths.migrateModelToSharedIfNeeded()
        if let email = AppSettings.userEmail, !email.isEmpty {
            AppPaths.migrateLegacyIfNeeded(forEmail: email)
            // Drain any signed-out `_guest` recordings into this account so
            // sessions recorded before sign-in follow the user in (instead of
            // being stranded, invisible, in the guest bucket). Idempotent +
            // defensive; no-op when there's nothing to drain. Runs BEFORE the
            // account DB's shared connection opens (same as the legacy migrate).
            GuestMigration.drainIntoAccount(forEmail: email)
        }
        try? AppPaths.ensureExists()
        // Salvage recordings interrupted by a crash BEFORE the cleanup
        // below deletes them: any with usable audio on disk are flipped
        // to 'transcribing' (and picked up by the auto-resume pass), so
        // a crash mid-meeting no longer loses the recording.
        RecordingRecovery.run(repo: AppContext.shared.repo)
        // Delete the dirs of any orphaned silent pre-rolls (app died while a
        // call was being pre-rolled, before accept/decline) — then
        // resetStuckMeetings drops their rows. Pre-roll must leave nothing.
        if let prerollIds = try? AppContext.shared.repo.prerollMeetingIds() {
            for pid in prerollIds {
                try? FileManager.default.removeItem(at: AppPaths.recordingDir(for: pid))
            }
        }
        // Recover from prior crashes: drop orphan recording rows and flip
        // bare 'recording' state to failed. Transcribing rows are recovered
        // separately below — they get re-enqueued, not failed.
        try? AppContext.shared.repo.resetStuckMeetings()
        // Sweep any leftover demo rows from earlier builds that used
        // to ship a canned dashboard. Real users want an empty Library
        // on first launch, not someone else's "Daily standup" sample.
        DemoSeeder.removeAll(repo: AppContext.shared.repo)
        // If a transcription was in flight when the previous process died
        // (forced quit, rebuild during dev, machine sleep), pick it up
        // again automatically. The audio files (mic.wav / system.wav) are
        // preserved through transcription, so resume is cheap. User sees
        // the spinner banner come back, not a red "failed" card.
        // Recover stuck + failed-retriable meetings SEQUENTIALLY (await each
        // before starting the next). `enqueue` runs each meeting as its own
        // concurrent Task, so firing several at launch used to run two model
        // loads at once — for a whisperLocal user with >=2 recovered rows that
        // races Core ML / Metal (the documented concurrent-GPU-load SIGABRT).
        // Recovery is rare and runs in the background, so one-at-a-time costs
        // nothing the user feels and is safe for every provider.
        Task { @MainActor in
            if let stuck = try? AppContext.shared.repo.stuckTranscribingMeetingIds() {
                for id in stuck {
                    FileLogger.log("AppDelegate: auto-resuming transcription for \(id) (was stuck on prior launch)")
                    TranscriptionErrors.clear(meetingId: id)
                    await TranscriptionPipeline.shared.enqueue(meetingId: id).value
                }
            }
            // Also auto-retry meetings that hard-FAILED on a prior run, as long
            // as they're still under the retry budget (3 attempts). With the
            // per-chunk resume cache this is cheap — a transient failure
            // (network drop, killed app) recovers on its own instead of
            // leaving a red "failed" card the user must re-transcribe by hand.
            // A genuinely-broken row stops after 3 tries (no re-bill loop).
            if let retriable = try? AppContext.shared.repo.failedRetriableMeetingIds(maxAttempts: 3) {
                for id in retriable {
                    FileLogger.log("AppDelegate: auto-retrying failed transcription for \(id) (under retry budget)")
                    TranscriptionErrors.clear(meetingId: id)
                    await TranscriptionPipeline.shared.enqueue(meetingId: id).value
                }
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

        // Opt-in diagnostic telemetry: fires once per 24h when the
        // user has flipped the toggle in Settings. Default off; no
        // PII / no transcript content. See TelemetryService for
        // exactly what gets shipped.
        TelemetryService.tickIfDue()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in TelemetryService.tickIfDue() }
        }
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
            case .openURL(let url): NSWorkspace.shared.open(url)
            }
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        NotificationsService.requestAuthorizationIfNeeded()
        NewsPoller.start()
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

        // No global record hotkey: the shortcut feature was removed entirely.
        // Recording starts/stops from the menu-bar popover and the in-app
        // button only. (Carbon `RegisterEventHotKey` + the Settings capture
        // row are gone — there is intentionally no keyboard shortcut.)

        // Surface SOMETHING visible on launch. The "signed in?"
        // decision used to read the local `onboardingCompleted`
        // UserDefaults flag; now it asks Supabase for an active
        // session — that's the real source of truth once auth
        // moved server-side. The flag is still flipped by the
        // wizard for backward-compat with surfaces that haven't
        // been ported yet, but it's not the decision input here.
        //
        // Session restore is async (SDK reads disk + may refresh
        // the access token); we do the check inside a Task so the
        // launch path doesn't block.
        // No upfront gate. Permissions are requested ON-DEMAND when the user
        // actually records, and sign-in is OPTIONAL (the in-app SignInModal,
        // opened from Profile to Sign in). The app opens straight into the
        // Library and is fully usable signed-out with nothing granted. We
        // refresh the permission sticky-flags from the live TCC state (so the
        // record-time flow knows what to (re)request) but never open a
        // blocking wizard: the Welcome wizard was removed entirely.
        // `onboardingCompleted` is kept set true unconditionally so every
        // legacy "is the app set up?" guard (popover Start / MeetingDetector)
        // still passes.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AppSettings.setMicGrantedSticky(false)
        }
        if !CGPreflightScreenCaptureAccess() {
            AppSettings.setScreenGrantedSticky(false)
        }
        AppSettings.setOnboardingCompleted(true)
        LibraryWindow.shared.show(serverURL: AppContext.shared.server.baseURL)

        // Resolve any existing Supabase session in the BACKGROUND purely to
        // mirror the signed-in identity + backfill cloud meetings. Never
        // blocks the Library and never gates: signed-out is a fine state.
        Task { @MainActor in
            let session = try? await SupabaseClientHolder.shared.auth.session
            guard session != nil,
                  let user = SupabaseClientHolder.shared.auth.currentUser else {
                // Signed-out (guest): clear any stale admin/tier left over from
                // a previous signed-in session, so the profile avatar + theme
                // reflect "guest" (not the last user's role). Without this a
                // sticky is_admin=true showed the blue admin avatar to a
                // signed-out / non-admin user.
                AppSettings.setIsAdmin(false)
                AppSettings.setUserTier(.free)
                return
            }
            if let email = user.email, !email.isEmpty { AppSettings.setUserEmail(email) }
            let meta = user.userMetadata
            let name = (meta["full_name"]?.stringValue ?? meta["name"]?.stringValue) as String?
            if let name, !name.isEmpty { AppSettings.setUserName(name) }
            SupabaseTierSync.applyFromCurrentSession()
            AppSettings.setHasSignedInBefore(true)
            Task.detached {
                await SupabaseSync.backfillIfNeeded(repo: AppContext.shared.repo)
            }
        }
    }

    /// Returning to Corder (e.g. after completing a Paddle checkout in the
    /// browser) refreshes the Supabase session so a freshly-granted
    /// `app_metadata.tier` is picked up WITHOUT a relaunch — the user gets
    /// Pro the moment they switch back to the app. Throttled inside
    /// `refreshTier`, so frequent focus toggles are cheap.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in SupabaseTierSync.refreshTier() }
        // Renew the calendar feed if its 1h access token has gone stale.
        Task { @MainActor in await GoogleCalendar.refreshIfStale() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileLogger.log("AppDelegate: applicationShouldTerminate → .terminateNow")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        FileLogger.log("AppDelegate: applicationWillTerminate")
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
        // ⌘Q is the normal Quit shortcut. We route it through our
        // own selector instead of the stock `NSApplication.terminate`
        // so that pressing ⌘Q while the menu-bar popover is open
        // simply closes the popover (covers the "accidentally quit
        // while inviting" case). Anywhere else ⌘Q quits normally.
        let quitItem = NSMenuItem(title: "Завершить Corder",
                                  action: #selector(AppDelegate.quitOrClosePopover(_:)),
                                  keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
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

    /// ⌘Q handler. If the menu-bar popover is open, close it
    /// instead of terminating — Kostya was losing live recordings
    /// to accidental ⌘Q hits while the invite or recording-state
    /// popover was on screen. Outside of an open popover, ⌘Q
    /// behaves as the normal "Quit Corder".
    @objc func quitOrClosePopover(_ sender: Any?) {
        if let mbc = MenuBarController.shared, mbc.isPopoverShown {
            mbc.forceClosePopover()
            return
        }
        NSApp.terminate(sender)
    }

    fileprivate func openLibrary() {
        // No gate: the Library always opens (the Welcome wizard was removed;
        // permissions are requested on-demand at record time).
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

    /// Reap any OLDER Corder process still running (this instance is the
    /// newest). Graceful terminate first, force-kill stragglers after a
    /// beat. Prevents two processes fighting over the loopback port + DB.
    static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard !others.isEmpty else { return }
        for app in others {
            FileLogger.log("AppDelegate: reaping older Corder instance pid=\(app.processIdentifier)")
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for app in others where !app.isTerminated { app.forceTerminate() }
        }
    }

    // MARK: - Custom URL scheme (Supabase OAuth callback)

    /// `corder://auth/callback#…` lands here after Supabase finishes
    /// the Google OAuth exchange. The hash fragment carries the
    /// access + refresh tokens; Supabase's SDK parses them via
    /// `auth.session(from:)` and persists the session, after which
    /// `auth.currentUser` is non-nil and the Welcome wizard sees the
    /// signed-in state.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "corder" else { continue }
            FileLogger.log("AppDelegate: incoming URL \(url)")
            Task { @MainActor in
                do {
                    try await SupabaseClientHolder.shared.auth.session(from: url)
                    FileLogger.log("AppDelegate: Supabase session established from callback URL")
                    // Notify any UI observing the sign-in state. The
                    // wizard subscribes to this notification to flip
                    // its bottom-CTA from "Continue with Google" to a
                    // finished state and to call its own onSuccess.
                    NotificationCenter.default.post(name: .corderSupabaseSignedIn, object: nil)
                } catch {
                    FileLogger.log("AppDelegate: Supabase session(from:) failed — \(error)")
                }
            }
        }
    }
}

extension Notification.Name {
    /// Fired after `SupabaseClient.auth.session(from:)` successfully
    /// consumes an OAuth callback URL and the user is signed in. The
    /// Welcome wizard listens for this to finish its sign-in step
    /// without polling `auth.currentUser`.
    static let corderSupabaseSignedIn = Notification.Name("CorderSupabaseSignedIn")
}

/// Quit + relaunch the app. Used after sign-in / sign-out so the
/// next process boots with the right per-account on-disk paths
/// (the GRDB connection in AppContext.shared.dbq is `lazy` and
/// binds to whatever `AppPaths.databaseURL` returned on first
/// access — there's no way to swap it in place without tearing
/// the SwiftUI/Swifter graph apart).
@MainActor
enum CorderRelaunch {
    static func now() {
        let path = Bundle.main.bundlePath
        // Terminate FIRST, relaunch AFTER. The old `open -n` forced a new
        // instance immediately while this one was still terminating, so two
        // Corder processes briefly raced for the same loopback port (which
        // the OAuth flow pins) and the same per-account SQLite DB. A shelled
        // `sleep 1; open` lets this process fully exit — releasing the port
        // and DB handle — before the replacement launches. No `-n`: we want
        // exactly one instance, and the old one is already on its way out.
        let p = Process()
        p.launchPath = "/bin/sh"
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        do { try p.run() }
        catch { FileLogger.log("CorderRelaunch: spawn failed — \(error)") }
        NSApp.terminate(nil)
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
