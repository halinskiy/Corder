import Foundation
import GRDB
import Swifter
import AppKit
import UserNotifications
@preconcurrency import Supabase

enum Routes {
    static func register(server: HttpServer, repo: MeetingRepository) {
        // CSRF guard for the loopback API. The server binds 127.0.0.1 only,
        // but a malicious web page the user is browsing can still fire
        // "simple" cross-origin POSTs at http://127.0.0.1:<port>/api/... (the
        // OS-assigned port is guessable by probing) to trigger
        // start/stop/archive without ever reading the response. Such a
        // cross-origin request always carries a foreign `Origin` header; the
        // WKWebView app's own requests carry a loopback Origin (or none), and
        // native / MCP clients send no Origin at all. So: reject any
        // state-changing request whose Origin is present AND not loopback.
        // GET/HEAD pass through (the mcp-token GET is already SOP-protected by
        // sending no CORS headers, so a cross-origin page can't read it).
        server.middleware.append { req in
            let method = req.method.uppercased()
            guard method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE"
            else { return nil }
            guard let origin = req.headers["origin"], !origin.isEmpty else { return nil }
            let o = origin.lowercased()
            // An Origin is scheme+host[+:port] with NO path, so a loopback
            // origin is EXACTLY one of these bases or that base followed by
            // ":<port>". A bare `hasPrefix("http://127.0.0.1")` would also
            // match an attacker-registrable `http://127.0.0.1.evil.com`, so
            // require the next char to be a port separator or end-of-string.
            let loopbackBases = ["http://127.0.0.1", "http://localhost", "http://[::1]"]
            let loopback = loopbackBases.contains { o == $0 || o.hasPrefix($0 + ":") }
            if loopback { return nil }
            FileLogger.log("Routes: rejected cross-origin \(method) \(req.path) (Origin=\(origin))")
            return .raw(403, "Forbidden", nil, nil)
        }
        server.get["/"] = { _ in serveIndex() }
        server.get["/index.html"] = { _ in serveIndex() }
        server.get["/assets/:path"] = { req in serveAsset(path: req.params[":path"] ?? "") }
        // Vite-public assets land at the web root (avatar.jpg, icon.svg,
        // etc.) — not under /assets/. Map them explicitly so the
        // <img src="/avatar.jpg"> in ProfileMenu actually resolves.
        server.get["/avatar.jpg"] = { _ in serveRoot(name: "avatar.jpg") }
        server.get["/icon.svg"]   = { _ in serveRoot(name: "icon.svg") }
        server.get["/favicon.ico"] = { _ in serveRoot(name: "favicon.ico") }

        server.get["/api/meetings"] = { _ in listMeetings(repo: repo) }
        server.get["/api/meetings/:id"] = { req in
            meetingDetail(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/meetings/:id/transcript.txt"] = { req in
            transcriptText(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/meetings/:id/transcript.md"] = { req in
            transcriptExport(id: req.params[":id"] ?? "", repo: repo, kind: .md)
        }
        server.get["/api/meetings/:id/transcript.json"] = { req in
            transcriptExport(id: req.params[":id"] ?? "", repo: repo, kind: .json)
        }
        server.get["/api/meetings/:id/video"] = { req in
            serveMedia(id: req.params[":id"] ?? "", kind: .video, repo: repo, headers: req.headers)
        }
        server.get["/api/meetings/:id/audio"] = { req in
            serveMedia(id: req.params[":id"] ?? "", kind: .audio, repo: repo, headers: req.headers)
        }
        server.get["/api/meetings/:id/bundle.zip"] = { req in
            bundleZip(id: req.params[":id"] ?? "", repo: repo)
        }
        // Download chooser: compressed audio (AAC m4a) and the muxed
        // video+audio mp4. Generated on demand by MediaExporter, then
        // streamed to disk-saver. The silent raw video.mov is still
        // served at /video for the in-app preview player; it's just no
        // longer offered as a standalone download.
        server.get["/api/meetings/:id/audio.m4a"] = { req in
            serveExport(id: req.params[":id"] ?? "", kind: .audioM4A, repo: repo)
        }
        server.get["/api/meetings/:id/video-audio.mp4"] = { req in
            serveExport(id: req.params[":id"] ?? "", kind: .videoWithAudio, repo: repo)
        }
        server.post["/api/meetings/:id/speakers/:sid/rename"] = { req in
            renameSpeaker(req: req, repo: repo)
        }
        // Right-click transcript editing: change a segment's text,
        // reassign a segment to another speaker, or merge two speakers.
        server.post["/api/meetings/:id/segments/:segid/text"] = { req in
            editSegmentText(req: req, repo: repo)
        }
        server.post["/api/meetings/:id/segments/:segid/speaker"] = { req in
            reassignSegment(req: req, repo: repo)
        }
        server.post["/api/meetings/:id/speakers/:sid/merge"] = { req in
            mergeSpeaker(req: req, repo: repo)
        }
        server.post["/api/meetings/:id/rename"] = { req in
            renameMeeting(req: req, repo: repo)
        }
        server.post["/api/meetings/:id/retranscribe"] = { req in
            retranscribe(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/cancel-transcription"] = { req in
            cancelTranscription(id: req.params[":id"] ?? "")
        }
        server.post["/api/meetings/:id/expected-speakers"] = { req in
            setExpectedSpeakers(id: req.params[":id"] ?? "", req: req, repo: repo)
        }
        server.get["/api/meetings/:id/last-error"] = { req in
            lastError(id: req.params[":id"] ?? "")
        }
        server.post["/api/meetings/:id/summarize"] = { req in
            // `?force=1` regenerates the summary even if the row has a
            // cached one — used by the UI's "Regenerate" button.
            let force = req.queryParams.contains(where: { $0.0 == "force" && $0.1 == "1" })
            return summarize(id: req.params[":id"] ?? "", repo: repo, force: force)
        }
        server.post["/api/meetings/:id/chapters"] = { req in
            // On-demand Chapters generation. Same `?force=1` semantics
            // as `/summarize` — used by the ChaptersPane "Generate" /
            // "Regenerate" buttons when the user wants chapters on a
            // meeting that finished before auto-chapters was on.
            let force = req.queryParams.contains(where: { $0.0 == "force" && $0.1 == "1" })
            return chapters(id: req.params[":id"] ?? "", repo: repo, force: force)
        }
        server.get["/api/recording/state"] = { _ in recordingState() }
        server.post["/api/recording/start"] = { _ in startRecordingNow() }
        server.post["/api/recording/stop"] = { _ in stopRecordingNow() }
        server.get["/api/settings"] = { _ in settingsGet() }
        server.post["/api/settings"] = { req in settingsSet(req: req) }
        server.get["/api/usage"] = { _ in usageGet(repo: repo) }
        // Upcoming calendar meetings for the Dashboard "Upcoming" tab —
        // served from the GoogleCalendar cache (connected:false until the
        // user opts in via /connect).
        server.get["/api/calendar/upcoming"] = { _ in upcomingCalendar() }
        // Opt-in: kick off the incremental Google Calendar OAuth (separate
        // from sign-in). Returns immediately; the browser round-trip lands
        // on /auth/callback which harvests the token + caches events.
        server.post["/api/calendar/connect"] = { _ in
            Task { @MainActor in GoogleCalendar.startConnect() }
            return jsonResponse(["ok": true])
        }
        server.post["/api/submit-logs"] = { _ in submitLogs() }
        server.get["/api/has-bug-events"] = { _ in hasBugEvents() }
        server.post["/api/billing/test-set-tier"] = { req in setTestTier(req: req) }
        // Whisper Local model download — kicks off a background fetch
        // for the requested variant id (no body needed beyond `id`).
        // The /api/settings GET is the single source of truth for
        // progress / ready state; the React DownloadButton polls it
        // every ~1 s while a fetch is in flight.
        server.post["/api/whisper-local/download"] = { req in
            whisperLocalDownload(req: req)
        }
        server.get["/api/installed-apps"] = { _ in installedAppsGet() }
        server.get["/api/app-icon/:bundle"] = { req in
            appIcon(bundle: req.params[":bundle"] ?? "")
        }
        server.delete["/api/meetings/:id"] = { req in
            deleteMeeting(id: req.params[":id"] ?? "", repo: repo)
        }
        server.get["/api/archive"] = { _ in listArchived(repo: repo) }
        server.post["/api/meetings/:id/archive"] = { req in
            archive(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/restore"] = { req in
            restore(id: req.params[":id"] ?? "", repo: repo)
        }
        server.post["/api/meetings/:id/pin"] = { req in
            setPin(id: req.params[":id"] ?? "", repo: repo, pinned: true)
        }
        server.post["/api/meetings/:id/unpin"] = { req in
            setPin(id: req.params[":id"] ?? "", repo: repo, pinned: false)
        }
        server.get["/api/search"] = { req in
            let q = req.queryParams.first(where: { $0.0 == "q" })?.1 ?? ""
            return search(query: q, repo: repo)
        }
        server.get["/api/update-status"] = { _ in updateStatus() }
        server.post["/api/update-check"] = { _ in updateCheck() }
        // Opens the in-app sign-in MODAL (SignInModalHost in the Library
        // WebView), driven by AuthController. Used by the profile popover's
        // "Sign in" when signed-out. Replaces the old separate native sign-in
        // window — no jarring extra window, consistent with the update modal.
        server.post["/api/open-welcome"] = { _ in
            Task { @MainActor in AuthController.shared.present() }
            return .ok(.text("ok"))
        }
        // Reveal the recordings folder in Finder (all meeting subfolders, each
        // holding that meeting's mic/system/mix .wav + video.mov). Create it
        // first so a fresh account never fails to open.
        server.post["/api/open-recordings-folder"] = { _ in
            Task { @MainActor in
                let dir = AppPaths.recordingsDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
            return .ok(.text("ok"))
        }
        // Deep-link into System Settings → Notifications → Corder.
        // macOS denies re-request after the user said no, so the
        // only way back to "allow" is a trip through System Settings.
        // The `notifications?id=<bundle>` URL anchor pre-scrolls to
        // our row on macOS 13+.
        server.post["/api/open-notification-settings"] = { _ in
            Task { @MainActor in
                let bundleID = Bundle.main.bundleIdentifier ?? "com.3mpq.Corder"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)") {
                    NSWorkspace.shared.open(url)
                }
            }
            return .ok(.text("ok"))
        }
        // Used by the Settings notification row to render the
        // current macOS authorization status (allowed / denied /
        // not determined) without a private API. Reads from
        // `UNUserNotificationCenter`, which is async; we hop and
        // serialise to a flat string the React side switches on.
        server.get["/api/notification-status"] = { _ in
            let sem = DispatchSemaphore(value: 0)
            var status = "unknown"
            UNUserNotificationCenter.current().getNotificationSettings { s in
                switch s.authorizationStatus {
                case .authorized, .provisional, .ephemeral: status = "allowed"
                case .denied:                                status = "denied"
                case .notDetermined:                         status = "notDetermined"
                @unknown default:                            status = "unknown"
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2)
            return jsonResponse(["status": status])
        }
        server.post["/api/account/signout"] = { _ in accountSignOut() }
        server.post["/api/account/delete"] = { _ in accountDelete() }
        server.get["/api/account/mcp-token"] = { _ in mcpToken() }
        server.get["/api/account/usage"] = { _ in accountUsage(repo: repo) }
        // Supabase OAuth landing. The Welcome wizard configures
        // `redirectTo` pointed at this route on the local server, so
        // Google → Supabase → 302 → this page. We pull the `code`
        // out of the query, hand a synthesised `corder://auth/callback`
        // URL to `auth.session(from:)`, and serve the same styled
        // "You're signed in" page the loopback flow used to. The
        // browser shows the success page; Corder picks up the session
        // and the wizard closes itself via the
        // `.corderSupabaseSignedIn` notification.
        server.get["/auth/callback"] = { req in authCallback(req: req) }
    }

    /// Drop local account state. No server session to invalidate yet;
    /// this just clears the local UserDefaults keys the Welcome wizard
    /// reads on next launch. After the call the React app reloads, the
    /// menu-bar app sees `onboardingCompleted = false`, and the Welcome
    /// wizard re-opens. Pre-existing recordings are NOT touched.
    /// Reveal the signed-in user's Supabase access token so they can
    /// plug Corder into MCP clients (Claude Desktop / Cursor / etc.)
    /// or hit the public REST API directly. The token is the same
    /// JWT the Supabase SDK already has in memory — we just surface
    /// it to the UI. Expires ~1h; clients re-read this endpoint when
    /// they get a 401. Returns 401 itself when signed out.
    private static func mcpToken() -> HttpResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var token: String?
        Task { @MainActor in
            defer { semaphore.signal() }
            do {
                let session = try await SupabaseClientHolder.shared.auth.session
                token = session.accessToken
            } catch {
                FileLogger.log("mcpToken: no active session — \(error)")
            }
        }
        // Bound the wait like every other semaphore-bridged handler here
        // (notification-status, setTestTier, submitLogs): the @MainActor hop +
        // a slow token refresh could otherwise pin this Swifter worker thread.
        // A timeout leaves `token` nil → the 401 path below, which is correct.
        _ = semaphore.wait(timeout: .now() + 8)
        guard let token = token else {
            return .raw(401, "Unauthorized", ["Content-Type": "application/json"]) {
                try $0.write(Array(#"{"error":"not signed in"}"#.utf8))
            }
        }
        return jsonResponse(["token": token])
    }

    /// Supabase OAuth landing page (Google sign-in). Serves the
    /// styled "You're signed in" HTML and, in parallel, hands the
    /// callback URL to `Supabase.auth.session(from:)` so the wizard
    /// sees a live session. The browser stays on this tab showing
    /// the success page; the user closes it manually (⌘W).
    private static func authCallback(req: HttpRequest) -> HttpResponse {
        // Reconstruct the full URL the browser hit (Swifter strips it
        // into path + query params). The SDK only needs scheme, host,
        // path, and the query string in shape — we synthesise the
        // canonical `corder://auth/callback` URL with the same query
        // so the same code path used by the URL-scheme handler
        // (AppDelegate.application(_:open:)) finishes the exchange.
        var queryItems: [URLQueryItem] = req.queryParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        var comps = URLComponents()
        comps.scheme = "corder"
        comps.host = "auth"
        comps.path = "/callback"
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        if let url = comps.url {
            Task { @MainActor in
                do {
                    // Capture the live session BEFORE the swap: a calendar
                    // connect that lands on a different Google account must be
                    // rolled back (finishConnectIfPending restores this), so a
                    // connect can never change the Corder identity.
                    let prior = SupabaseClientHolder.shared.auth.currentSession
                    try await SupabaseClientHolder.shared.auth.session(from: url)
                    FileLogger.log("authCallback: Supabase session established")
                    // If this callback was an incremental calendar connect
                    // (not a plain sign-in), harvest the calendar-scoped
                    // provider token + cache events. No-op otherwise.
                    await GoogleCalendar.finishConnectIfPending(
                        priorAccessToken: prior?.accessToken,
                        priorRefreshToken: prior?.refreshToken)
                    NotificationCenter.default.post(
                        name: .corderSupabaseSignedIn, object: nil)
                } catch {
                    FileLogger.log("authCallback: session(from:) failed — \(error)")
                }
            }
        }
        _ = queryItems
        let html = signedInHTML
        return .raw(200, "OK", [
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
        ]) { try $0.write(Array(html.utf8)) }
    }

    /// Styled "You're signed in" page served from `/auth/callback`.
    /// Inline CSS + inline SVG so the page renders identically with
    /// no extra requests (Supabase Auth's callback tab is closed
    /// seconds later — not worth an asset). Brand row at the top
    /// (3mpq + Corder marks), green check + headline centred, ⌘W
    /// hint chip at the bottom.
    private static let signedInHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <title>Signed in to Corder</title>
      <meta name="viewport" content="width=device-width,initial-scale=1" />
      <style>
        :root {
          color-scheme: dark;
          --bg: #161616;
          --fg: #f5f5f5;
          --fg-muted: #9b9b9b;
          --accent: #1F7A4F;
          --border: rgba(255,255,255,0.10);
          --logo-3mpq: #ffffff;
        }
        html { height: 100%; background: var(--bg); }
        body {
          margin: 0; padding: 0;
          min-height: 100vh;
          background-color: var(--bg);
          background-image: radial-gradient(circle, #333 1px, transparent 1px);
          background-size: 24px 24px;
          background-attachment: fixed;
          color: var(--fg);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text",
            "Inter", "Helvetica Neue", sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        .brand {
          position: absolute;
          top: 40px; left: 0; right: 0;
          display: flex; justify-content: center; align-items: center;
          gap: 10px;
        }
        .brand a {
          display: inline-flex; align-items: center; justify-content: center;
          color: inherit; text-decoration: none;
          border-radius: 6px;
          transition: opacity 0.15s ease;
        }
        .brand a:hover { opacity: 0.75; }
        .brand a:focus-visible {
          outline: 2px solid var(--accent);
          outline-offset: 3px;
        }
        .brand .mark {
          width: 24px !important; height: 24px !important;
          flex: 0 0 24px !important;
          display: flex; align-items: center; justify-content: center;
          overflow: hidden; box-sizing: border-box;
        }
        .brand .mark.corder {
          background: #ffffff;
          border-radius: 5px;
          border: 1px solid var(--border);
          gap: 3px;
          box-shadow: 0 2px 6px rgba(0,0,0,0.10);
          margin-left: 2px;
        }
        .brand .mark.corder .bar {
          width: 3.5px; height: 12px;
          background: #111111; border-radius: 1.75px;
        }
        .brand .mark.three { color: var(--logo-3mpq); }
        .brand .mark.three svg {
          width: 24px !important; height: 24px !important;
          display: block;
        }
        .brand .mark.three svg path { fill: currentColor; }
        .brand .sep {
          width: 1px; height: 14px;
          background: currentColor; opacity: 0.18;
          color: var(--fg);
          flex: 0 0 1px;
        }
        .content {
          min-height: 100vh;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          padding: 48px 24px;
          box-sizing: border-box;
          text-align: center;
        }
        .check {
          width: 44px; height: 44px;
          border-radius: 50%;
          background: var(--accent);
          color: white;
          display: flex; align-items: center; justify-content: center;
          font-size: 22px; line-height: 1;
        }
        h1 {
          margin: 28px 0 0;
          font-size: 26px;
          font-weight: 300;
          letter-spacing: -0.01em;
        }
        p {
          margin: 8px 0 0;
          color: var(--fg-muted);
          font-size: 15px;
          line-height: 1.55;
          max-width: 340px;
        }
        .hint {
          position: absolute;
          left: 0; right: 0; bottom: 32px;
          text-align: center;
          font-size: 13px;
          color: var(--fg-muted);
        }
        kbd {
          font-family: inherit;
          background: var(--accent);
          color: #ffffff;
          padding: 2px 7px;
          border-radius: 5px;
          font-size: 12px;
          font-weight: 500;
          opacity: 1;
        }
      </style>
    </head>
    <body>
      <div class="brand">
        <a href="https://halinskiy.github.io/3mpq-studio/" target="_blank" rel="noopener" aria-label="3mpq Studio">
        <div class="mark three" aria-label="3mpq">
          <svg width="64" height="64" viewBox="0 0 536 536" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg">
            <path d="M447.208 451.089C460.632 466.532 473.891 481.802 487.488 497.41C471.374 507.65 455.935 517.385 439.822 527.621C432.773 519.063 425.892 510.669 419.012 502.448C414.817 497.245 410.285 492.207 406.258 486.836C403.906 483.649 401.558 483.649 398.202 484.993C378.395 491.874 358.091 497.41 336.944 498.249C285.589 500.264 241.279 484.825 205.869 446.224C203.015 443.036 202.513 440.853 204.524 436.991C216.944 414.001 229.028 390.839 241.785 366.504C261.419 421.552 300.02 440.853 356.244 428.938C344.832 415.342 333.756 402.251 322.175 388.49C337.783 378.418 352.888 368.519 368.496 358.282C379.234 370.867 389.643 383.119 400.213 395.539C408.944 385.804 413.978 374.729 416.495 362.811C422.034 336.967 421.027 311.456 412.131 286.615C398.202 247.512 362.788 225.192 321.336 228.885C319.321 229.05 317.306 229.219 314.287 229.387C323.014 212.604 331.404 196.828 339.798 180.884C340.468 179.542 341.307 178.367 341.978 177.024C349.195 163.43 349.195 163.43 364.634 166.619C440.493 182.731 493.361 248.351 494.031 327.232C494.368 373.051 480.772 413.832 449.725 448.239C448.886 448.741 448.216 449.58 447.208 451.089Z"/>
            <path d="M33.5054 499.428C33.5054 387.317 33.5054 276.048 33.5054 164.272C102.316 164.272 170.79 164.272 239.768 164.272C239.768 184.58 239.768 205.055 239.768 226.034C196.468 226.034 153.336 226.034 109.868 226.034C109.868 249.53 109.868 272.187 109.868 295.514C150.818 295.514 191.266 295.514 233.558 295.514C232.55 300.885 232.719 305.919 230.872 309.949C223.658 324.549 215.602 338.816 208.216 353.416C206.369 357.109 203.684 357.611 200.159 357.611C172.469 357.443 144.776 357.611 117.085 357.611C114.903 357.611 112.553 357.611 109.868 357.611C109.868 384.298 109.868 410.479 109.868 436.994C127.658 436.994 145.112 436.994 163.07 436.994C162.399 438.84 162.231 440.185 161.559 441.361C152.161 459.317 142.762 477.442 133.029 495.233C131.854 497.248 128.665 499.428 126.483 499.428C96.9449 499.765 67.407 499.597 37.7012 499.597C36.5262 499.765 35.3516 499.597 33.5054 499.428Z"/>
            <path d="M355.736 150.343C361.946 138.426 367.987 126.679 374.197 115.098C390.644 84.0497 407.259 52.8333 423.541 21.617C425.387 18.0928 427.234 16.75 431.26 16.75C452.408 16.9178 473.555 16.75 494.867 16.75C496.545 16.75 498.223 16.9178 499.901 17.0856C507.624 18.4284 509.635 23.7987 504.433 29.505C496.211 38.2321 487.653 46.6236 479.259 55.0151C452.07 82.2035 424.211 108.553 398.199 136.58C385.778 150.007 372.856 153.699 355.736 150.343Z"/>
            <path d="M79.4908 40.0757C106.008 40.0757 124.133 58.7048 124.133 86.2289C124.133 112.914 105.504 132.046 79.6586 132.214C53.8129 132.382 35.016 113.082 34.8479 86.3967C34.6801 59.376 53.3092 40.2435 79.4908 40.0757Z"/>
            <path d="M194.615 40.0757C220.797 40.0757 238.753 58.8726 238.753 86.061C238.753 113.249 220.126 132.214 193.776 132.214C168.098 132.214 149.469 112.578 149.469 86.061C149.469 59.2082 168.266 40.0757 194.615 40.0757Z"/>
          </svg>
        </div>
        </a>
        <div class="sep" aria-hidden="true"></div>
        <a href="https://getcorder.com/" target="_blank" rel="noopener" aria-label="Corder">
        <div class="mark corder" aria-label="Corder">
          <div class="bar"></div>
          <div class="bar"></div>
        </div>
        </a>
      </div>
      <div class="content">
        <div class="check" aria-hidden="true">✓</div>
        <h1>You're signed in</h1>
        <p>Corder picked up your Google account. You can close this tab and head back to the app.</p>
        <div class="hint">Press <kbd>⌘W</kbd> to close.</div>
      </div>
    </body>
    </html>
    """

    /// Hard-delete: wipe every row + every Storage object owned by
    /// the signed-in user, then sign out + relaunch. Triggered by
    /// the red "Delete account" button in the profile popover.
    /// GDPR-style: after this, there's no PII left under the
    /// user's id (the `auth.users` row remains as an empty shell;
    /// killing it requires the service-role key, which we don't
    /// ship in the client).
    private static func accountDelete() -> HttpResponse {
        Task { @MainActor in
            do {
                try await SupabaseSync.deleteEverything()
                FileLogger.log("accountDelete: cloud data wiped, signed out")
            } catch {
                FileLogger.log("accountDelete: failed — \(error)")
            }
            // Also clear local UserDefaults so the relaunched
            // process starts fresh (welcome wizard reopens).
            AppSettings.setLicenceKey(nil)
            AppSettings.setUserName(nil)
            AppSettings.setUserEmail(nil)
            AppSettings.setUserTier(.free)
            AppSettings.setIsAdmin(false)
            AppSettings.setOnboardingCompleted(false)
            AppSettings.setOnboardingStep(0)
            AppSettings.setHasSignedInBefore(false)
            LibraryWindow.shared.dismiss()
            CorderRelaunch.now()
        }
        return .ok(.text(#"{"ok":true}"#))
    }

    private static func accountSignOut() -> HttpResponse {
        Task { @MainActor in
            // Tell Supabase to invalidate the session AND clear the
            // local refresh token. Best-effort: if the network is
            // down the SDK still wipes the local session keys, which
            // is what gates the UI; the dangling server session can
            // expire on its own.
            do {
                try await SupabaseClientHolder.shared.auth.signOut()
            } catch {
                FileLogger.log("AccountAPI: Supabase signOut failed (\(error)) — clearing local state anyway")
            }
            AppSettings.setLicenceKey(nil)
            AppSettings.setUserName(nil)
            AppSettings.setUserEmail(nil)
            AppSettings.setUserTier(.free)
            AppSettings.setIsAdmin(false)
            AppSettings.setOnboardingCompleted(false)
            AppSettings.setOnboardingStep(0)
            FileLogger.log("AccountAPI: signed out — cleared identity + admin/tier; relaunching into guest Library")
            // Gate the rest of Corder behind sign-in: close the
            // Library window so the signed-in surface isn't visible
            // behind the wizard, then re-present the wizard so the
            // user can sign in again without restarting the app.
            LibraryWindow.shared.dismiss()
            // Relaunch so the next process picks up the `_guest`
            // account folder (empty DB), instead of staying bound
            // to the previous user's per-account GRDB connection.
            CorderRelaunch.now()
        }
        return .ok(.text(#"{"ok":true}"#))
    }

    // MARK: static

    /// Web-assets root, resolved from `Bundle.main` — NOT the
    /// SwiftPM-generated `Bundle.module`.
    ///
    /// `Bundle.module`'s accessor calls `fatalError` when it can't find
    /// `Corder_Corder.bundle`. Its candidate list is baked at compile
    /// time and includes the dev machine's `.build/release/` path, so a
    /// miss is invisible locally but a HARD CRASH on any other Mac — the
    /// friend's "open Library → SIGTRAP" was exactly this: the first
    /// HTTP request from the WKWebView hit `Bundle.module` init →
    /// assertionFailure. In a packaged .app the resource bundle lives at
    /// `Contents/Resources/Corder_Corder.bundle` (put there by
    /// build-app.sh), which `Bundle.main.resourceURL` points straight
    /// at. Resolve from there; on a genuine miss serve a clean 404
    /// instead of trapping the whole process.
    private static let webRootURL: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Corder_Corder.bundle"))
        }
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Corder_Corder.bundle"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("Corder_Corder.bundle"))
        }
        for bundle in candidates {
            let web = bundle.appendingPathComponent("web", isDirectory: true)
            if fm.fileExists(atPath: web.appendingPathComponent("index.html").path) {
                return web
            }
        }
        FileLogger.log("Routes: web assets not found in any Bundle.main candidate — serving 404 (resource bundle missing from .app)")
        return nil
    }()

    private static func serveIndex() -> HttpResponse {
        guard let url = webRootURL?.appendingPathComponent("index.html"),
              let data = try? Data(contentsOf: url) else {
            return .notFound
        }
        return .raw(200, "OK", ["Content-Type": "text/html; charset=utf-8"]) { writer in
            try writer.write(data)
        }
    }

    private static func serveAsset(path: String) -> HttpResponse {
        guard let webRoot = webRootURL else { return .notFound }
        let assets = webRoot.appendingPathComponent("assets").standardizedFileURL
        let target = assets.appendingPathComponent(path).standardizedFileURL
        // Path-traversal guard. `path` is the raw `:path` URL segment, and
        // Swifter percent-decodes it AFTER splitting on '/', so
        // `..%2f..%2f..%2fetc%2fpasswd` survives as one segment then decodes
        // to `../../../etc/passwd`. Without this check `Data(contentsOf:)`
        // would happily read ANY user-readable file (e.g. the Dropbox
        // app_secret + refresh_token in ~/.config/corder/dropbox.json).
        // standardizedFileURL resolves the `..`; require containment.
        guard target.path.hasPrefix(assets.path + "/") else { return .notFound }
        guard let data = try? Data(contentsOf: target) else { return .notFound }
        let mime = mimeType(for: target.pathExtension)
        return .raw(200, "OK", ["Content-Type": mime]) { try $0.write(data) }
    }

    /// Serves a file from the WEB ROOT (not the `/assets/` subfolder).
    /// Vite copies `Web/public/*` to the dist root, so the avatar /
    /// icon / favicon end up here, not under `assets/`.
    private static func serveRoot(name: String) -> HttpResponse {
        guard let webRoot = webRootURL else { return .notFound }
        let root = webRoot.standardizedFileURL
        let target = root.appendingPathComponent(name).standardizedFileURL
        // Same path-traversal containment as serveAsset (these routes are
        // fixed names today, but guard anyway so a future caller can't
        // reintroduce the hole).
        guard target.path.hasPrefix(root.path + "/") else { return .notFound }
        guard let data = try? Data(contentsOf: target) else { return .notFound }
        let mime = mimeType(for: target.pathExtension)
        return .raw(200, "OK", ["Content-Type": mime]) { try $0.write(data) }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    // MARK: api

    /// Guest session quota for the header "N left" counter. Signed-in users
    /// are unlimited (`is_guest=false` hides the counter); a guest may hold up
    /// to `limit` sessions, and `sessions_left` drives the badge. Cheap enough
    /// to poll. `repo` is the registration-captured handle (DatabaseQueue is
    /// thread-safe), so this stays a synchronous off-main read.
    private static func accountUsage(repo: MeetingRepository) -> HttpResponse {
        let signedIn = AppSettings.isSignedIn
        let limit = RecordingController.guestSessionLimit
        let held = signedIn ? 0 : ((try? repo.heldMeetingCount()) ?? 0)
        let left = max(0, limit - held)
        return jsonResponse([
            "is_guest": !signedIn,
            "sessions_used": held,
            "sessions_left": left,
            "limit": limit,
        ])
    }

    private static func listMeetings(repo: MeetingRepository) -> HttpResponse {
        do {
            // Single SQL query with correlated subselects — replaces the
            // old per-meeting segments + speakers fan-out that produced
            // ≥2N reads on every sidebar poll.
            let rows = try repo.listMeetingSummaries()
            let summaries: [DTO.MeetingSummary] = rows.map { r in
                DTO.MeetingSummary(
                    id: r.id,
                    started_at: r.startedAt,
                    ended_at: r.endedAt,
                    duration_ms: r.durationMs,
                    status: r.status,
                    title: r.title,
                    preview: r.preview,
                    speaker_count: r.speakerCount,
                    speaker_names: r.speakerNames,
                    pinned: r.pinnedAt != nil,
                    viewed: r.viewedAt != nil
                )
            }
            return jsonResponse(summaries)
        } catch {
            return .internalServerError
        }
    }

    private static func meetingDetail(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            // Mark the meeting as seen on first detail fetch. The repo
            // is a no-op if `viewed_at` is already set — once seen,
            // stays seen. We only stamp once the row is ready, so a
            // still-recording / still-transcribing meeting doesn't get
            // marked as seen prematurely (the user is "watching it
            // load", not reading the result).
            if m.status == .ready && m.viewedAt == nil {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                try? repo.markViewedIfNew(meetingId: id, atMs: nowMs)
            }
            let speakers = try repo.speakers(forMeeting: id)
            let segments = try repo.segments(forMeeting: id)
            let hasVideo = FileManager.default.fileExists(atPath: m.videoPath)
                || (m.dropboxVideoPath != nil)
            let dto = DTO.MeetingDetail(
                id: m.id, started_at: m.startedAt, duration_ms: m.durationMs,
                status: m.status.rawValue,
                title: m.title,
                summary: m.summary,
                speakers: speakers.map {
                    DTO.SpeakerDTO(id: $0.id, label: $0.label, custom_name: $0.customName, color_hex: $0.colorHex)
                },
                segments: segments.map {
                    DTO.SegmentDTO(id: $0.id ?? 0, speaker_id: $0.speakerId,
                                   start_ms: $0.startMs, end_ms: $0.endMs, text: $0.text,
                                   text_boost: $0.textBoost)
                },
                expected_other_speakers: m.expectedOtherSpeakers,
                has_video: hasVideo,
                chapters: m.chapters,
                transcribing_started_at: m.transcribingStartedAt,
                transcribe_progress: m.status == .transcribing
                    ? TranscriptionProgressStore.read(meetingId: id) : nil,
                // Surface the on-device model download while a transcription
                // waits on it (new free-tier user, ~1.5 GB first fetch). Gated
                // on the LIVE load flags, NOT on AppSettings.transcriptionProvider:
                // a cap-fallback or tier-gate-fallback run uses the on-device
                // model for THIS run while the stored preference is still a cloud
                // provider, and those users were seeing a frozen plain spinner
                // for the whole compile. currentProgress/isPreparing are only
                // ever non-nil while the on-device model is actively loading in
                // THIS process, so they're authoritative for any run regardless
                // of the persisted pick (a pure-cloud run never sets them → nil).
                model_download_progress: m.status == .transcribing
                    ? LocalWhisperTranscriber.currentProgress(AppSettings.whisperLocalVariant) : nil,
                // Silent post-download "preparing" (tokenizer + ANE compile)
                // phase — lets the UI swap the frozen 99% download bar for a
                // "Preparing model…" indeterminate state.
                model_preparing: m.status == .transcribing
                    ? LocalWhisperTranscriber.isPreparing(AppSettings.whisperLocalVariant) : nil
            )
            return jsonResponse(dto)
        } catch {
            return .internalServerError
        }
    }

    private static func transcriptText(id: String, repo: MeetingRepository) -> HttpResponse {
        do {
            let segments = try repo.segments(forMeeting: id)
            let speakers = try repo.speakers(forMeeting: id)
            let text = TranscriptFormatter.clipboardText(segments: segments, speakers: speakers)
            return .raw(200, "OK", ["Content-Type": "text/plain; charset=utf-8"]) {
                try $0.write([UInt8](text.utf8))
            }
        } catch {
            return .internalServerError
        }
    }

    /// Bundles whatever exists locally (video, mixed audio, transcript)
    /// into a single .zip. Shells out to /usr/bin/zip — ships with macOS,
    /// no dependency. Blocks the Swifter worker like the other media
    /// routes; the payload is small (a short meeting) to a few hundred MB.
    private static func bundleZip(id: String, repo: MeetingRepository) -> HttpResponse {
        guard let m = try? repo.meeting(id: id) else { return .notFound }

        let fm = FileManager.default
        let stage = fm.temporaryDirectory
            .appendingPathComponent("corder-bundle-\(id)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
        catch { return .internalServerError }

        // Transcript
        if let segs = try? repo.segments(forMeeting: id),
           let spks = try? repo.speakers(forMeeting: id), !segs.isEmpty {
            let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)
            try? text.data(using: .utf8)?
                .write(to: stage.appendingPathComponent("transcript.txt"))
        }
        // Video
        let videoURL = URL(fileURLWithPath: m.videoPath)
        if fm.fileExists(atPath: videoURL.path) {
            try? fm.copyItem(at: videoURL,
                             to: stage.appendingPathComponent("video." + videoURL.pathExtension))
        }
        // Audio — prefer the mixed audio.wav (both sides), else stored path.
        let mixURL = AppPaths.recordingDir(for: id).appendingPathComponent("audio.wav")
        let audioURL = fm.fileExists(atPath: mixURL.path)
            ? mixURL : URL(fileURLWithPath: m.audioPath)
        if fm.fileExists(atPath: audioURL.path) {
            try? fm.copyItem(at: audioURL,
                             to: stage.appendingPathComponent("audio.wav"))
        }

        let entries = (try? fm.contentsOfDirectory(atPath: stage.path)) ?? []
        guard !entries.isEmpty else { return .notFound }

        let zipURL = fm.temporaryDirectory
            .appendingPathComponent("corder-\(id)-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: zipURL) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = stage
        proc.arguments = ["-j", "-q", "-r", zipURL.path, "."]
        do { try proc.run(); proc.waitUntilExit() }
        catch { return .internalServerError }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: zipURL) else { return .internalServerError }

        let bytes = [UInt8](data)
        return .raw(200, "OK", [
            "Content-Type": "application/zip",
            "Content-Disposition": "attachment; filename=\"corder-\(id).zip\"",
            "Content-Length": String(bytes.count)
        ]) { try $0.write(bytes) }
    }

    private enum ExportKind { case md, json }
    private static func transcriptExport(id: String, repo: MeetingRepository,
                                         kind: ExportKind) -> HttpResponse {
        do {
            let segments = try repo.segments(forMeeting: id)
            let speakers = try repo.speakers(forMeeting: id)
            let m = try? repo.meeting(id: id)
            let title = (m?.title?.trimmingCharacters(in: .whitespaces)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Corder recording"
            let (body, ctype, fname): (String, String, String)
            switch kind {
            case .md:
                body = TranscriptFormatter.markdown(segments: segments, speakers: speakers, title: title)
                ctype = "text/markdown; charset=utf-8"
                fname = "\(id).md"
            case .json:
                body = TranscriptFormatter.json(segments: segments, speakers: speakers, title: title)
                ctype = "application/json; charset=utf-8"
                fname = "\(id).json"
            }
            return .raw(200, "OK", [
                "Content-Type": ctype,
                "Content-Disposition": "attachment; filename=\"corder-\(fname)\""
            ]) { try $0.write([UInt8](body.utf8)) }
        } catch {
            return .internalServerError
        }
    }

    private static func recordingState() -> HttpResponse {
        switch RecordingStateSnapshot.read() {
        // `.preroll` reads as inactive to the web — the silent pre-roll
        // must not surface a recording indicator anywhere.
        case .idle, .preroll:
            return jsonResponse(["active": false] as [String: Any])
        case .recording(let meetingId, let startedAt):
            return jsonResponse([
                "active": true,
                "meeting_id": meetingId,
                "started_at_ms": Int64(startedAt.timeIntervalSince1970 * 1000)
            ] as [String: Any])
        case .stopping:
            return jsonResponse(["active": true, "stopping": true] as [String: Any])
        }
    }

    private static func startRecordingNow() -> HttpResponse {
        // The inline blob in the Library window posts here. Same path as
        // the menu-bar Start button: tell the meeting detector to drop
        // any pending invite (we already know about the call), then
        // start a full-display capture.
        Task { @MainActor in
            MeetingDetector.shared.userStartedRecordingManually()
            await RecordingController.shared.startRecording(source: .fullDisplay)
        }
        return .ok(.text("starting"))
    }

    private static func stopRecordingNow() -> HttpResponse {
        Task { @MainActor in
            await RecordingController.shared.stopRecording()
        }
        return .ok(.text("stopping"))
    }

    /// Polled by the React toolbar (~once a minute). Returns the
    /// newest version Sparkle has resolved from the appcast, if any.
    /// Sparkle keeps re-checking on its own 24h schedule + at startup;
    /// we just expose the latest verdict.
    private static func updateStatus() -> HttpResponse {
        let v = AvailableUpdateSnapshot.read()
        // Opportunistically kick Sparkle's silent background check
        // when the React poll arrives and we don't yet have a
        // resolved update. Sparkle's own 24h scheduled check might
        // not have fired since install — without this nudge the
        // pill could take a full day to appear after a fresh release.
        // checkInBackground is a no-op if a check is already in
        // flight, so the polling cadence (60 s) can't double-fire it.
        if v == nil {
            Task { @MainActor in UpdateController.shared.checkInBackground() }
        }
        var payload: [String: Any] = ["available": v != nil]
        if let v = v { payload["version"] = v }
        return jsonResponse(payload)
    }

    /// Fire-and-forget: tells Sparkle to show its standard update UI
    /// (the "A new version of Corder is available" panel with the
    /// release notes from `appcast.xml`). Click on the green toolbar
    /// pill posts here.
    private static func updateCheck() -> HttpResponse {
        Task { @MainActor in
            // Surface any update modal that was already resolved but whose
            // push got dropped (e.g. found while the Library was closed) —
            // otherwise a fresh checkForUpdates() is ignored while that
            // Sparkle session is still pending, and the pill click looks
            // dead. Replaying shows the Install card so the click always
            // does something.
            UpdateBridge.shared.replayLastState()
            UpdateController.shared.checkForUpdates(nil)
        }
        return .ok(.text("checking"))
    }

    private static var geminiKeyPath: String {
        ("~/.config/corder/gemini_key" as NSString).expandingTildeInPath
    }

    private static func currentSettings() -> DTO.Settings {
        DTO.Settings(
            language: AppLanguage.current,
            vocabulary: AppVocabulary.current,
            gemini_key: nil,        // never echo the key back
            gemini_key_set: FileManager.default.fileExists(atPath: geminiKeyPath),
            notifications: AppSettings.notificationsEnabled,
            capture_video: AppSettings.captureVideo,
            screen_recording_granted: CGPreflightScreenCaptureAccess(),
            capture_audio: AppSettings.captureAudio,
            auto_transcribe: AppSettings.autoTranscribe,
            auto_title: AppSettings.autoTitle,
            auto_summary: AppSettings.autoSummary,
            auto_chapters: AppSettings.autoChapters,
            launch_at_login: AppSettings.launchAtLogin,
            telemetry: AppSettings.telemetryEnabled,
            stats_enabled: AppSettings.statsEnabled,
            preroll: AppSettings.prerollEnabled,
            meeting_whitelist: AppSettings.meetingWhitelist,
            meeting_blacklist: AppSettings.meetingBlacklist,
            detected_mic_apps: MicAppsSnapshot.read(),
            mic_device_uid: AppSettings.micDeviceUID,
            audio_input_devices: AudioInputDevices.list().map {
                DTO.AudioInputDeviceDTO(
                    uid: $0.uid,
                    name: $0.name,
                    manufacturer: $0.manufacturer,
                    transport: $0.transport,
                    is_system_default: $0.isSystemDefault)
            },
            licence_key: AppSettings.licenceKey,
            user_name: AppSettings.userName,
            user_email: AppSettings.userEmail,
            is_pro: AppSettings.isPro,
            is_admin: AppSettings.isAdmin,
            tier: AppSettings.userTier.rawValue,
            onboarding_completed: AppSettings.onboardingCompleted,
            transcription_provider: {
                // `"auto"` when no explicit override is stored, so the
                // tier-driven default is in effect; otherwise echo the
                // stored override — but CLAMP it through the same admin rule
                // as the other three surfaces (runtime read, POST write,
                // Worker). A stale `gemini`/`whisper` value (demoted admin /
                // manual `defaults write`) must not surface to a non-admin,
                // so all four surfaces tell the same story.
                if let raw = UserDefaults.standard.string(forKey: "Corder.set.transcriptionProvider"),
                   let prov = TranscriptionProvider(rawValue: raw) {
                    if !AppSettings.isAdmin, prov == .gemini || prov == .whisper {
                        return "auto"
                    }
                    return raw
                }
                return "auto"
            }(),
            transcription_language: AppSettings.transcriptionLanguage,
            whisper_local_model_ready: LocalWhisperTranscriber.isModelDownloaded(
                AppSettings.whisperLocalVariant),
            whisper_local_variant: AppSettings.whisperLocalVariant.rawValue,
            upsell_snooze: AppSettings.upsellSnooze.nilIfEmpty,
            whisper_local_models: {
                let inflight = LocalWhisperTranscriber.allInflight()
                return LocalWhisperTranscriber.Variant.allCases.map { v in
                    DTO.WhisperLocalModelDTO(
                        id: v.rawValue,
                        label: v.label,
                        size_label: v.sizeLabel,
                        size_mb: v.sizeMB,
                        ready: LocalWhisperTranscriber.isModelDownloaded(v),
                        progress: inflight[v.rawValue])
                }
            }(),
            apple_silicon: LocalWhisperTranscriber.isAvailable()
        )
    }

    private static func settingsGet() -> HttpResponse {
        return jsonResponse(currentSettings())
    }

    /// Monthly usage rollup. Window = current calendar month; resets
    /// at 00:00 of the first day next month. "advanced" sums the
    /// cloud-billed minutes (Gemini + Whisper-cloud), "local" sums
    /// on-device WhisperKit minutes (always unlimited).
    ///
    /// Two UserDefaults knobs let us visually QA the bars without
    /// burning real cloud minutes:
    ///   defaults write com.3mpq.Corder Corder.set.simAdvancedUsedSeconds 1800
    ///   defaults write com.3mpq.Corder Corder.set.simLocalUsedSeconds 600
    /// They're additive on top of the real DB count and zero by
    /// default, so production behaviour is unchanged.
    /// Sends the tail of /tmp/corder.log to the Cloudflare Worker
    /// (`POST /submit-logs`) which forwards via Resend to the
    /// maintainer. The user clicks one button (header Bug icon) and
    /// we attach their email + app version + macOS version for
    /// triage — they don't have to copy anything by hand.
    /// Regex that flags a log line as "interesting" — i.e. worth
    /// shipping to the maintainer's inbox. Routine status lines
    /// (server started, hotkey registered, popover suppressed) are
    /// dropped so the email isn't 95 % noise. Case-insensitive.
    private static let bugLineRegex: NSRegularExpression = {
        let pattern = "(error|fail(ed|ure)?|fatal|crash(ed)?|exception|aborted|panic|noKey|denied|insufficient|invalid|timeout|HTTP [45][0-9]{2}|apiFailure|GError|EXC_|SIGSEGV)"
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
            ?? NSRegularExpression()
    }()

    /// Transcription + capture PIPELINE flow. These are INFO lines, not
    /// errors, but they're exactly what we need to debug a "wrong text"
    /// report (provider chosen, dual-track mode, per-track turn counts,
    /// dominance gate, capture device / Bluetooth route). The error regex
    /// alone is useless for a QUALITY bug that throws no error — e.g. the
    /// far-end voice bleeding into the mic on speakers and being
    /// re-transcribed as the user. Kept separate so the two intents stay
    /// readable.
    private static let flowLineRegex: NSRegularExpression = {
        let pattern = "(transcribe\\(\\)|TranscriptionPipeline|Diarizer|Gemini|Whisper|Groq|whisperLocal|dual-track|timing re-derived|dominance|capUserTurn|CaptureEngine|SystemAudioTap|VoiceProcessing|mic\\.wav|system\\.wav|provider|voiced|bluetooth)"
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
            ?? NSRegularExpression()
    }()

    /// Whether the current session has any matching event lines.
    /// Frontend polls this to decide whether to show the Bug icon
    /// at all — no events → button hidden.
    private static func hasBugEvents() -> HttpResponse {
        // The report button is now ALWAYS available when there's any log
        // to send. Gating it on error-regex hits hid the button exactly
        // when we most needed the report: a transcription-QUALITY bug
        // (wrong text, far-end bleed, mislabelled speaker) throws no error,
        // so `count` was 0 and the user couldn't reach "Send a report" at
        // all. We still surface a matched-event count for context.
        let lines = diagnosticScopeLines()
        let has = !lines.isEmpty
        var count = 0
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if bugLineRegex.firstMatch(in: line, range: range) != nil { count += 1 }
        }
        return jsonResponse(["count": count, "has": has])
    }

    /// Filter the log to ONLY the lines that match `bugLineRegex`,
    /// plus 2 lines of context above and 2 below each hit. Vastly
    /// shorter than the previous whole-tail dump.
    private static func bugEventLog() -> String {
        let lines = diagnosticScopeLines()
        if lines.isEmpty { return "(log file missing or unreadable)" }
        var keep = Array(repeating: false, count: lines.count)
        for i in lines.indices {
            let line = lines[i]
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            // Keep both the error lines AND the transcription/capture flow
            // lines (see flowLineRegex) with ±3 lines of context each. The
            // wider context window matters for the pipeline lines — the
            // per-track turn counts and the chosen audio file are logged a
            // few lines apart.
            let hit = bugLineRegex.firstMatch(in: line, range: range) != nil
                || flowLineRegex.firstMatch(in: line, range: range) != nil
            if hit {
                let from = max(0, i - 3)
                let to = min(lines.count - 1, i + 3)
                for j in from...to { keep[j] = true }
            }
        }
        // Always include the raw tail — the immediate state when the user
        // hit "Send a report", even if none of it matched. Cheap insurance
        // against a quiet failure mode we don't have a keyword for yet.
        let tailStart = max(0, lines.count - 200)
        if tailStart < lines.count { for j in tailStart..<lines.count { keep[j] = true } }

        var out: [String] = []
        var lastKept = -10
        for i in lines.indices where keep[i] {
            if i - lastKept > 1 && !out.isEmpty { out.append("…") }
            out.append(lines[i])
            lastKept = i
        }
        if out.isEmpty { return "(no events in the recent window)" }
        // Byte-cap the payload, keeping the MOST RECENT slice. Worker
        // stores ~200 KB/row comfortably; this just bounds a pathological
        // marathon session.
        let joined = out.joined(separator: "\n")
        let maxBytes = 200_000
        if joined.utf8.count > maxBytes {
            let tail = String(decoding: Array(joined.utf8.suffix(maxBytes)), as: UTF8.self)
            return "…(truncated to last \(maxBytes / 1000) KB)…\n" + tail
        }
        return joined
    }

    /// Diagnostic scope = the last few launches, not just the current one.
    /// A user usually reopens the app before reporting, so the meeting that
    /// misbehaved is one (or two) sessions back; the old
    /// current-session-only scope returned a clean startup tail with none
    /// of the transcription it was supposed to explain. We keep everything
    /// from the 3rd-most-recent `applicationDidFinishLaunching` marker
    /// onward (bounded by the 12k-line `readLogTail` read).
    private static func diagnosticScopeLines() -> [String] {
        let lines = readLogTail(maxLines: 12_000)
        var markerIdx: [Int] = []
        for i in lines.indices where lines[i].contains(sessionMarker) { markerIdx.append(i) }
        if let start = markerIdx.suffix(3).first { return Array(lines[start...]) }
        // No marker in the window (a single marathon session) — return all
        // of it rather than nothing.
        return lines
    }

    /// Last `maxLines` of `/tmp/corder.log`.
    private static func readLogTail(maxLines: Int) -> [String] {
        let path = "/tmp/corder.log"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let full = String(data: data, encoding: .utf8) else { return [] }
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(lines.suffix(maxLines))
    }

    /// Log lines for the CURRENT session only — everything from the last
    /// `applicationDidFinishLaunching` marker onward. `/tmp/corder.log`
    /// accumulates across days, so an unbounded tail makes a bug report
    /// resurface ancient, already-fixed errors (the AI summary then flags
    /// long-dead issues as "critical"). Scoping to this launch keeps the
    /// report — and its summary — about what's actually happening now.
    private static let sessionMarker = "applicationDidFinishLaunching"

    private static func submitLogs() -> HttpResponse {
        let tail = bugEventLog()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let email = AppSettings.userEmail ?? "anonymous"
        let payload: [String: Any] = [
            "email": email,
            "app_version": "\(version) (\(build))",
            "macos_version": macOS,
            "log_tail": tail,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let url = URL(string: "https://corder-api.empqwork.workers.dev/submit-logs") else {
            return .internalServerError
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15
        // Sync via a semaphore — Swifter handlers are blocking; we
        // want to surface success/failure to the React toast in one
        // round-trip, not fire-and-forget.
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            ok = (200..<300).contains(code)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        return ok ? jsonResponse(["ok": true]) : .internalServerError
    }

    /// Test-mode tier flip. Forwards `{"tier":"free"|"max"}` to the
    /// Cloudflare Worker, which calls Supabase admin to update
    /// `app_metadata.tier` for the currently signed-in user, then
    /// refreshes the local Supabase session so the new tier is
    /// reflected in `AppSettings.userTier` immediately (no relaunch).
    /// Used by the Settings → General "Upgrade / Downgrade" testing
    /// block; intended to be removed before real billing ships.
    private static func setTestTier(req: HttpRequest) -> HttpResponse {
        let bodyData = Data(req.body)
        guard let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let tier = (obj["tier"] as? String)?.lowercased(),
              ["free", "pro", "max"].contains(tier) else {
            return .badRequest(.text("tier must be free|pro|max"))
        }
        // Pull the user's Supabase JWT — same source the transcription
        // proxies use. No JWT = no session = nothing to upgrade.
        let sem0 = DispatchSemaphore(value: 0)
        var jwt = ""
        Task { @MainActor in
            jwt = await GeminiTranscriber.jwtForProxy()
            sem0.signal()
        }
        _ = sem0.wait(timeout: .now() + 5)
        guard !jwt.isEmpty else {
            return .raw(401, "Unauthorized", ["Content-Type": "application/json"], { try? $0.write([UInt8]("{\"error\":\"signed out\"}".utf8)) })
        }
        guard let url = URL(string: "https://corder-api.empqwork.workers.dev/billing/test-set-tier"),
              let body = try? JSONSerialization.data(withJSONObject: ["tier": tier]) else {
            return .internalServerError
        }
        var rq = URLRequest(url: url)
        rq.httpMethod = "POST"
        rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rq.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        rq.httpBody = body
        rq.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var responseTier = "free"
        URLSession.shared.dataTask(with: rq) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code), let d = data,
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                ok = (j["ok"] as? Bool) ?? false
                if let nt = j["tier"] as? String { responseTier = nt }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 16)
        guard ok else { return .internalServerError }
        // Refresh local Supabase session so `app_metadata.tier` is
        // re-read into AppSettings.userTier without forcing a relaunch.
        Task { @MainActor in
            try? await SupabaseClientHolder.shared.auth.refreshSession()
            SupabaseTierSync.applyFromCurrentSession()
        }
        return jsonResponse(["ok": true, "tier": responseTier])
    }

    private static func usageGet(repo: MeetingRepository) -> HttpResponse {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let nextMonthStart = cal.date(byAdding: .month, value: 1, to: monthStart) ?? now
        let sinceMs = Int64(monthStart.timeIntervalSince1970 * 1000)
        let resetsMs = Int64(nextMonthStart.timeIntervalSince1970 * 1000)
        let bucket = (try? repo.usageSecondsByClass(sinceMs: sinceMs)) ?? ["advanced": 0, "local": 0]
        let tier = AppSettings.userTier
        let simAdv = Int64(UserDefaults.standard.integer(forKey: "Corder.set.simAdvancedUsedSeconds"))
        let simLoc = Int64(UserDefaults.standard.integer(forKey: "Corder.set.simLocalUsedSeconds"))
        let dto = DTO.Usage(
            plan: tier.rawValue,
            advanced: .init(
                used_seconds: (bucket["advanced"] ?? 0) + simAdv,
                limit_seconds: tier.advancedMonthlyLimitSeconds
            ),
            local: .init(
                used_seconds: (bucket["local"] ?? 0) + simLoc,
                limit_seconds: nil
            ),
            resets_at_ms: resetsMs
        )
        return jsonResponse(dto)
    }

    /// Installed apps for the Settings picker. Scans the usual app
    /// roots, reads each bundle's id + display name, dedups, and floats
    /// apps Corder recently saw on the mic to the top. Best-effort and
    /// off-main (Swifter thread) — purely UI sugar, never blocks core.
    private static func installedAppsGet() -> HttpResponse {
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        var byBundle: [String: String] = [:]   // bundle → display name
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for e in entries where e.hasSuffix(".app") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(e)
                guard let b = Bundle(url: url),
                      let id = b.bundleIdentifier, !id.isEmpty else { continue }
                if byBundle[id] != nil { continue }
                let info = b.infoDictionary
                let name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? (e as NSString).deletingPathExtension
                byBundle[id] = name
            }
        }
        let recent = Set(MicAppsSnapshot.read())
        let apps = byBundle
            .map { DTO.InstalledApp(bundle: $0.key, name: $0.value,
                                    recent: recent.contains($0.key)) }
            .sorted {
                if $0.recent != $1.recent { return $0.recent && !$1.recent }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        return jsonResponse(apps)
    }

    /// 64-pt PNG icon for one bundle id, for the picker / list rows.
    /// Browser-cacheable; 404 when the app isn't resolvable.
    private static func appIcon(bundle: String) -> HttpResponse {
        guard !bundle.isEmpty,
              let appURL = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundle)
        else { return .notFound }
        return autoreleasepool { () -> HttpResponse in
            // Rasterise to a fixed 64 px bitmap. (icon.tiffRepresentation
            // hands back the full multi-resolution icon — up to 1024 px,
            // ~1.4 MB each — far too heavy for a list of rows.)
            let px = 64
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
            else { return .notFound }
            rep.size = NSSize(width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                      from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:])
            else { return .notFound }
            return .raw(200, "OK", [
                "Content-Type": "image/png",
                "Cache-Control": "max-age=86400",
            ]) { try $0.write(png) }
        }
    }

    /// Supported UI locale codes — keep in sync with `Web/src/i18n.ts` LANGS.
    private static let supportedLocales: Set<String> = [
        "en", "uk", "ru", "de", "fr", "es", "pt", "it", "pl", "cs",
        "tr", "nl", "sv", "id", "vi", "ja", "ko", "zh", "hi", "ar",
    ]

    private static func settingsSet(req: HttpRequest) -> HttpResponse {
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.Settings.self, from: body)
            // Persist ANY supported UI locale (must match the frontend's
            // LANGS list), not just ru/en — otherwise a German/French/etc.
            // pick was silently dropped here and reset to English on reload.
            if let lang = parsed.language, Self.supportedLocales.contains(lang) {
                UserDefaults.standard.set(lang, forKey: AppLanguage.key)
                Task { @MainActor in
                    AppContext.shared.language = lang
                }
            }
            if let vocab = parsed.vocabulary {
                UserDefaults.standard.set(
                    vocab.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: AppVocabulary.key)
            }
            if let key = parsed.gemini_key?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                let path = geminiKeyPath
                try? FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try? key.write(toFile: path, atomically: true, encoding: .utf8)
                // Owner-only — it's a secret.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            }
            // Functional toggles + app lists. Absent field ⇒ unchanged
            // (a stale frontend can never silently flip a new toggle).
            if let v = parsed.notifications    { AppSettings.setNotifications(v) }
            if let v = parsed.capture_video    { AppSettings.setCaptureVideo(v) }
            if let v = parsed.capture_audio    { AppSettings.setCaptureAudio(v) }
            if let v = parsed.auto_transcribe  { AppSettings.setAutoTranscribe(v) }
            if let v = parsed.auto_title       { AppSettings.setAutoTitle(v) }
            if let v = parsed.auto_summary     { AppSettings.setAutoSummary(v) }
            if let v = parsed.auto_chapters    { AppSettings.setAutoChapters(v) }
            if let v = parsed.launch_at_login  { AppSettings.setLaunchAtLogin(v) }
            if let v = parsed.telemetry        { AppSettings.setTelemetryEnabled(v) }
            if let v = parsed.stats_enabled    { AppSettings.setStatsEnabled(v) }
            if let v = parsed.preroll          { AppSettings.setPrerollEnabled(v) }
            if let v = parsed.meeting_whitelist { AppSettings.setMeetingWhitelist(v) }
            if let v = parsed.meeting_blacklist { AppSettings.setMeetingBlacklist(v) }
            // Mic device picker. Empty string = "system default", which
            // we treat the same as `nil` (the setter normalises blank
            // → removeObject). The selection applies to the NEXT
            // recording; we don't hot-swap a live capture (would need
            // a engine stop/start cycle while audio is mid-buffer).
            if let uid = parsed.mic_device_uid {
                AppSettings.setMicDeviceUID(uid)
            }
            // Licence key (the user pastes it into the Welcome wizard;
            // Settings may also expose it later). Empty string clears
            // the key and drops the user back to the Free tier; the
            // setter normalises whitespace and absent-vs-empty itself.
            if let key = parsed.licence_key {
                AppSettings.setLicenceKey(key)
            }
            // ASR provider override. `"auto"` clears the override so
            // the tier-driven default kicks back in (Free → whisperLocal,
            // Pro/Max → whisper). Any of the three concrete `TranscriptionProvider`
            // raw values pins the override; anything else is ignored
            // (a stale client can't slip through a typo). The runtime
            // pipeline reads `AppSettings.transcriptionProvider` on the
            // NEXT transcribe call, so the swap takes effect immediately
            // for the next meeting without restarting the app.
            if let raw = parsed.transcription_provider {
                if raw == "auto" {
                    AppSettings.clearTranscriptionProviderOverride()
                } else if let p = TranscriptionProvider(rawValue: raw) {
                    // HARD provider lock: only admins may pin a cloud model
                    // other than Groq. A non-admin trying to set gemini /
                    // whisper-1 (stale client, hand-crafted POST) is coerced
                    // to clearing the override → tier default (Groq/local).
                    // `transcriptionProvider` clamps reads too, so this is
                    // belt-and-suspenders, but it keeps a junk value from
                    // ever landing in UserDefaults.
                    if !AppSettings.isAdmin && (p == .gemini || p == .whisper) {
                        AppSettings.clearTranscriptionProviderOverride()
                    } else {
                        AppSettings.setTranscriptionProvider(p)
                    }
                }
            }
            // Whisper Local variant override (Tiny / Base / Small /
            // Turbo). Stored separately from the provider so a user
            // can have provider=whisperLocal AND pick which model
            // size to use. Unknown ids are silently ignored — same
            // pattern as `transcription_provider`.
            if let raw = parsed.whisper_local_variant,
               let v = LocalWhisperTranscriber.Variant(rawValue: raw) {
                AppSettings.setWhisperLocalVariant(v)
            }
            // Forced transcription language ("" / null → auto-detect).
            if let lang = parsed.transcription_language {
                AppSettings.setTranscriptionLanguage(lang)
            }
            // Upsell snooze map — opaque JSON on the native side, the
            // frontend owns the schema. Empty string clears the snooze.
            if let snooze = parsed.upsell_snooze {
                AppSettings.setUpsellSnooze(snooze)
            }
            // Onboarding flag. Only `true` is meaningful as a payload —
            // we never want a stale client to silently revert "wizard
            // finished" back to false (would re-open the Welcome window
            // on the next launch and confuse the user). True flips the
            // flag; any other value is ignored.
            if parsed.onboarding_completed == true {
                AppSettings.setOnboardingCompleted(true)
            }
            FileLogger.log("settings: language=\(parsed.language ?? "nil") vocab=\(parsed.vocabulary != nil) keySet=\(parsed.gemini_key != nil) toggles[n=\(parsed.notifications.map(String.init) ?? "-"),v=\(parsed.capture_video.map(String.init) ?? "-"),a=\(parsed.capture_audio.map(String.init) ?? "-"),at=\(parsed.auto_transcribe.map(String.init) ?? "-"),ti=\(parsed.auto_title.map(String.init) ?? "-")] wl=\(parsed.meeting_whitelist?.count ?? -1) bl=\(parsed.meeting_blacklist?.count ?? -1)")
            return jsonResponse(currentSettings())
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    /// Body: `{ "id": "openai_whisper-large-v3_turbo" }`. Starts a
    /// background WhisperKit download for the variant. Returns 202
    /// immediately so the React DownloadButton doesn't have to hold a
    /// 30-second connection open; progress is exposed through the
    /// `/api/settings` poll (`whisper_local_models[].progress`).
    /// Idempotent: requesting a variant that's already on disk
    /// returns the current settings with `ready=true` and no work
    /// done. If a download for the same variant is already in
    /// flight, the duplicate call is a no-op (the existing task keeps
    /// running and the new poll sees the same `progress`).
    private static func whisperLocalDownload(req: HttpRequest) -> HttpResponse {
        struct Body: Decodable { let id: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: Data(req.body)),
              let variant = LocalWhisperTranscriber.Variant(rawValue: body.id) else {
            return .badRequest(.text("missing or unknown variant id"))
        }
        if LocalWhisperTranscriber.isModelDownloaded(variant) {
            return jsonResponse(currentSettings())
        }
        if LocalWhisperTranscriber.currentProgress(variant) != nil {
            // Already downloading — let the existing task finish.
            return jsonResponse(currentSettings())
        }
        // Fire-and-forget on the main actor (the downloader is
        // @MainActor-scoped). Any error gets logged + clears the
        // progress entry via the `defer` in `downloadOnly`.
        Task { @MainActor in
            do {
                try await LocalWhisperTranscriber.downloadOnly(variant)
            } catch {
                FileLogger.log("LocalWhisper: download \(variant.rawValue) failed — \(error)")
            }
        }
        return jsonResponse(currentSettings())
    }

    private static func retranscribe(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        FileLogger.log("retranscribe: queued for \(id)")
        // Flip status to `transcribing` so the UI shows the
        // TranscribingBanner immediately. We DO NOT clear the old
        // segments here: if this re-transcribe is interrupted, cancelled,
        // or the model fails, the meeting flips back to `.failed` with
        // the PREVIOUS transcript still intact (the user already paid for
        // it). The new segments only replace the old ones once a run
        // succeeds — the mapping step (`mapDualTrackTurns` etc.) clears +
        // inserts atomically right before writing the fresh result. The
        // TranscribingBanner now shows from status alone, not from an
        // empty segment list, so wiping early is no longer needed.
        if var m = try? repo.meeting(id: id) {
            m.status = .transcribing
            // Reset the start timestamp so the TranscribingBanner counter
            // restarts at 00:00 right away (instant UI feedback before the
            // async enqueue runs). The pipeline also re-stamps it fresh on
            // every run, so this is just for the immediate reset on an
            // explicit re-transcribe; recovery/retry paths rely on the
            // pipeline stamp.
            m.transcribingStartedAt = nil
            try? repo.updateMeeting(m)
        }
        TranscriptionErrors.clear(meetingId: id)
        Task { @MainActor in
            TranscriptionPipeline.shared.enqueue(meetingId: id)
        }
        return .ok(.text("queued"))
    }

    /// On-demand summary. Returns the cached `summary` if present;
    /// otherwise generates one from the transcript (blocking this
    /// Swifter worker for the Gemini round-trip — same accepted pattern
    /// as the Dropbox-hydrate path), stores it, and returns it.
    private static func summarize(id: String, repo: MeetingRepository, force: Bool = false) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        guard let m = try? repo.meeting(id: id) else { return .notFound }
        if !force,
           let cached = m.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty,
           isStructuredMarkdown(cached) {
            // Pre-Granola summaries were plain prose without `###` /
            // bullets — re-render those by falling through, so the new
            // format replaces the old one on first open of the tab.
            return jsonResponse(["summary": cached])
        }
        let segs = (try? repo.segments(forMeeting: id)) ?? []
        guard !segs.isEmpty else {
            return jsonResponse(["summary": "", "error": "no transcript"])
        }
        let spks = (try? repo.speakers(forMeeting: id)) ?? []
        let text = TranscriptFormatter.clipboardText(segments: segs, speakers: spks)

        let sema = DispatchSemaphore(value: 0)
        var result: String?
        var tierGated = false
        Task {
            do { result = try await GeminiSummarizer.generate(transcript: text) }
            catch is PaidFeatureError { tierGated = true }
            catch { }
            sema.signal()
        }
        sema.wait()

        // A 403 tier-gate must surface as a real 403 so the frontend shows the
        // Upgrade upsell (api.ts throws "HTTP 403", SummaryPane keys off it),
        // NOT the generic "generation failed" error card. Load-bearing per
        // the "Paid feature gate" gotcha in NOTES.md.
        if tierGated { return tierGatedResponse("summary") }
        guard let summary = result, !summary.isEmpty else {
            return jsonResponse(["summary": "", "error": "generation failed"])
        }
        try? repo.setSummary(meetingId: id, summary: summary)
        FileLogger.log("summarize: generated summary for \(id) (\(summary.count) chars)")
        return jsonResponse(["summary": summary])
    }

    /// On-demand chapters: same shape as `summarize` — cached value
    /// returned unless `force=true`, otherwise rebuilds via
    /// `GeminiChapters.generate(...)`, persists the JSON string into
    /// `meetings.chapters`, and returns it. Returns an
    /// `{ chapters: "", error: ... }` envelope on the "no transcript"
    /// / "generation failed" paths so the React side surfaces the
    /// same banner family the Summary tab uses.
    private static func chapters(id: String, repo: MeetingRepository, force: Bool = false) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        guard let m = try? repo.meeting(id: id) else { return .notFound }
        if !force, let cached = m.chapters?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return jsonResponse(["chapters": cached])
        }
        let segs = (try? repo.segments(forMeeting: id)) ?? []
        guard !segs.isEmpty else {
            return jsonResponse(["chapters": "", "error": "no transcript"])
        }
        let timed: [(startMs: Int64, text: String)] = segs.map {
            (startMs: Int64($0.startMs), text: $0.text)
        }
        let sema = DispatchSemaphore(value: 0)
        var result: [GeminiChapters.Chapter]?
        var tierGated = false
        Task {
            do { result = try await GeminiChapters.generate(timedLines: timed) }
            catch is PaidFeatureError { tierGated = true }
            catch { }
            sema.signal()
        }
        sema.wait()
        // Real 403 on a tier-gate so the upsell fires (see summarize()).
        if tierGated { return tierGatedResponse("chapters") }
        guard let chapters = result, !chapters.isEmpty,
              let data = try? JSONEncoder().encode(chapters),
              let json = String(data: data, encoding: .utf8) else {
            return jsonResponse(["chapters": "", "error": "generation failed"])
        }
        try? repo.setChapters(meetingId: id, chapters: json)
        FileLogger.log("chapters: generated \(chapters.count) chapters for \(id)")
        return jsonResponse(["chapters": json])
    }

    /// True iff the cached summary already uses the new Granola-style
    /// structured Markdown (`### Heading` + `- ` bullets). Pre-Granola
    /// summaries are plain prose — let them re-generate on first open.
    private static func isStructuredMarkdown(_ s: String) -> Bool {
        // Either an `### ` heading anywhere or at least one bullet line
        // qualifies. We don't require both because a very short meeting
        // might collapse to a single section.
        if s.range(of: #"(^|\n)###\s"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"(^|\n)-\s"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func cancelTranscription(id: String) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        FileLogger.log("cancelTranscription: \(id)")
        Task { @MainActor in
            TranscriptionPipeline.shared.cancel(meetingId: id)
        }
        return .ok(.text("cancelled"))
    }

    private static func lastError(id: String) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        let payload: [String: Any] = ["error": TranscriptionErrors.read(meetingId: id) as Any]
        return jsonResponse(payload)
    }

    private static func setExpectedSpeakers(id: String, req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        guard let body = try? JSONDecoder().decode(DTO.ExpectedSpeakersRequest.self, from: Data(req.body)) else {
            return .badRequest(.text("bad json"))
        }
        do {
            guard (try repo.meeting(id: id)) != nil else { return .notFound }
            try repo.setExpectedOtherSpeakers(meetingId: id, count: body.count)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func deleteMeeting(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            // Best-effort cleanup of cloud archive (fire-and-forget).
            if let m = try? repo.meeting(id: id) {
                if let vp = m.dropboxVideoPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: vp) }
                }
                if let ap = m.dropboxAudioPath {
                    Task.detached { await DropboxService.shared.deleteFile(remotePath: ap) }
                }
            }
            // Best-effort cleanup of files on disk.
            let dir = AppPaths.recordingDir(for: id)
            try? FileManager.default.removeItem(at: dir)
            try repo.deleteMeeting(id: id)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    /// Soft-archive: stamps `archived_at` so the meeting drops out of
    /// the main library and shows up in the archive panel. Audio stays
    /// on disk / Dropbox until the user either restores or wipes it,
    /// or until the 7-day grace period elapses (see launch cleanup).
    private static func archive(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try repo.setArchived(meetingId: id, archivedAt: now)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func restore(id: String, repo: MeetingRepository) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            try repo.setArchived(meetingId: id, archivedAt: nil)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func setPin(id: String, repo: MeetingRepository, pinned: Bool) -> HttpResponse {
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try repo.setPinned(meetingId: id, pinnedAt: pinned ? now : nil)
            return .ok(.text("ok"))
        } catch {
            return .internalServerError
        }
    }

    private static func listArchived(repo: MeetingRepository) -> HttpResponse {
        do {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let retentionMs: Int64 = 7 * 24 * 60 * 60 * 1000  // 7 days
            let items = try repo.listArchived().map { m -> [String: Any] in
                let archivedAt = m.archivedAt ?? now
                let purgeAt = archivedAt + retentionMs
                return [
                    "id": m.id,
                    "started_at": m.startedAt,
                    "duration_ms": m.durationMs as Any,
                    "archived_at": archivedAt,
                    "purge_at": purgeAt
                ]
            }
            return jsonResponse(["items": items])
        } catch {
            return .internalServerError
        }
    }

    private static func renameSpeaker(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let sid = req.params[":sid"] ?? ""
        guard !sid.isEmpty else { return .badRequest(.text("missing speaker id")) }
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.RenameRequest.self, from: body)
            try repo.renameSpeaker(speakerId: sid, customName: parsed.name)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func editSegmentText(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let mid = req.params[":id"] ?? ""
        guard !mid.isEmpty else { return .badRequest(.text("missing meeting id")) }
        guard let segId = Int64(req.params[":segid"] ?? "") else {
            return .badRequest(.text("missing segment id"))
        }
        do {
            let parsed = try JSONDecoder().decode(DTO.SegmentTextRequest.self, from: Data(req.body))
            let trimmed = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .badRequest(.text("empty text")) }
            // Meeting-scope the UPDATE (like reassignSegment / mergeSpeaker) so
            // a stale/forged segment id can't edit a row in another meeting.
            try repo.setSegmentText(meetingId: mid, segmentId: segId, text: trimmed)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func reassignSegment(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let mid = req.params[":id"] ?? ""
        guard let segId = Int64(req.params[":segid"] ?? "") else {
            return .badRequest(.text("missing segment id"))
        }
        do {
            let parsed = try JSONDecoder().decode(DTO.SegmentSpeakerRequest.self, from: Data(req.body))
            // The target speaker must belong to this meeting.
            let speakers = try repo.speakers(forMeeting: mid)
            guard speakers.contains(where: { $0.id == parsed.speaker_id }) else {
                return .badRequest(.text("unknown speaker"))
            }
            try repo.reassignSegment(meetingId: mid, segmentId: segId, toSpeakerId: parsed.speaker_id)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func mergeSpeaker(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let mid = req.params[":id"] ?? ""
        let from = req.params[":sid"] ?? ""
        guard !mid.isEmpty, !from.isEmpty else { return .badRequest(.text("missing id")) }
        do {
            let parsed = try JSONDecoder().decode(DTO.MergeSpeakerRequest.self, from: Data(req.body))
            // Both endpoints of the merge must be real speakers on this meeting.
            let speakers = try repo.speakers(forMeeting: mid)
            guard speakers.contains(where: { $0.id == from }),
                  speakers.contains(where: { $0.id == parsed.into }) else {
                return .badRequest(.text("unknown speaker"))
            }
            try repo.mergeSpeaker(meetingId: mid, from: from, into: parsed.into)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    /// Upcoming-meetings feed for the Dashboard "Upcoming" tab. STUB:
    /// returns an empty, not-connected payload. The live path (Google
    /// `calendar.readonly` provider token → Calendar API `events.list`,
    /// mapped to `DTO.UpcomingEvent`) lands once the OAuth scope is in
    /// place; the JSON contract here is already what the frontend reads.
    private static func upcomingCalendar() -> HttpResponse {
        jsonResponse(GoogleCalendar.cachedResponse())
    }

    private static func renameMeeting(req: HttpRequest, repo: MeetingRepository) -> HttpResponse {
        let id = req.params[":id"] ?? ""
        guard !id.isEmpty else { return .badRequest(.text("missing meeting id")) }
        do {
            let body = Data(req.body)
            let parsed = try JSONDecoder().decode(DTO.MeetingTitleRequest.self, from: body)
            // Empty / whitespace clears the override so the UI falls back
            // to the auto-title (or the date label when there's none).
            let trimmed = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (trimmed?.isEmpty ?? true) ? nil : trimmed
            try repo.setTitle(meetingId: id, title: title)
            return .ok(.text("ok"))
        } catch {
            return .badRequest(.text("\(error)"))
        }
    }

    private static func search(query: String, repo: MeetingRepository) -> HttpResponse {
        guard !query.isEmpty else { return jsonResponse([DTO.SearchHit]()) }
        do {
            let segs = try repo.searchSegments(query: query)
            let hits = segs.map {
                DTO.SearchHit(meeting_id: $0.meetingId, segment_id: $0.id ?? 0,
                              start_ms: $0.startMs, text: $0.text)
            }
            return jsonResponse(hits)
        } catch {
            return .internalServerError
        }
    }

    // MARK: media (Range)

    private enum MediaKind { case video, audio }

    private static func serveMedia(id: String, kind: MediaKind, repo: MeetingRepository, headers: [String: String]) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let dropboxRemote = (kind == .video) ? m.dropboxVideoPath : m.dropboxAudioPath
            let contentType = (kind == .video) ? "video/quicktime" : "audio/wav"

            // Audio resolution order:
            //   1. The post-mix audio.wav inside the meeting dir — this is
            //      what AudioMixer produces from mic+system, and the only
            //      local file that contains BOTH the user and the
            //      interlocutor. Always prefer it when it's on disk.
            //   2. The DB-stored audioPath (usually mic.wav) — fallback for
            //      meetings where mix.wav is gone but mic.wav is still around
            //      (legacy rows pre-dual-track, or capture races).
            //   3. Neither exists → fall through to Dropbox hydrate below,
            //      which restores audio.wav from the archive.
            // Video has only the canonical videoPath; no fallback.
            var url: URL
            if kind == .video {
                url = URL(fileURLWithPath: m.videoPath)
            } else {
                let mixURL = AppPaths.recordingDir(for: id).appendingPathComponent("audio.wav")
                if FileManager.default.fileExists(atPath: mixURL.path) {
                    url = mixURL
                } else {
                    let direct = URL(fileURLWithPath: m.audioPath)
                    if FileManager.default.fileExists(atPath: direct.path) {
                        url = direct
                    } else {
                        // Hydrate target — full mix lives at audio.wav remote.
                        url = mixURL
                    }
                }
            }

            // Cloud cache miss: file was archived to Dropbox and the local
            // copy got deleted. Pull it back to the canonical local path
            // (one-time blocking download), then continue down the regular
            // local-file branch — including Range support. Subsequent
            // scrubbing requests are served straight from disk without
            // re-blocking a Swifter worker.
            if !FileManager.default.fileExists(atPath: url.path), let remote = dropboxRemote {
                FileLogger.log("serveMedia: cache miss for \(id) (\(kind)), fetching from Dropbox \(remote)")
                guard hydrateDropboxFile(remote: remote, localURL: url) else {
                    return .internalServerError
                }
            }
            // Supabase Storage fallback: the typical second-device case.
            // Mac B pulled the meeting metadata from Supabase but no
            // local audio was ever recorded on it. Download the cloud
            // copy once into the canonical local path so the Range
            // branch below can serve scrubs straight from disk on
            // every subsequent request.
            if !FileManager.default.fileExists(atPath: url.path),
               kind == .audio {
                FileLogger.log("serveMedia: cache miss for \(id), trying Supabase Storage")
                let downloaded = hydrateSupabaseAudio(meetingId: id, localURL: url)
                if !downloaded {
                    FileLogger.log("serveMedia: Supabase Storage hydrate failed for \(id)")
                    return .notFound
                }
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

            // Swifter lower-cases header keys.
            guard let rangeHeader = headers["range"] ?? headers["Range"] else {
                let data = try Data(contentsOf: url)
                return .raw(200, "OK", [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(size)"
                ]) { try $0.write(data) }
            }

            guard let r = RangeRequest.parse(rangeHeader, fileSize: size) else {
                return .raw(416, "Range Not Satisfiable", [
                    "Content-Range": "bytes */\(size)"
                ]) { _ in }
            }

            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(r.start))
            let chunk = handle.readData(ofLength: Int(r.length))
            try? handle.close()

            return .raw(206, "Partial Content", [
                "Content-Type": contentType,
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(r.start)-\(r.end)/\(size)",
                "Content-Length": "\(r.length)"
            ]) { try $0.write(chunk) }
        } catch {
            return .internalServerError
        }
    }

    private enum MediaExportKind { case audioM4A, videoWithAudio }

    /// Build (or reuse a cached) export via MediaExporter, then STREAM it
    /// to the client in chunks. The video+audio mux can be ~1.6 GB —
    /// loading that into memory with `Data(contentsOf:)` the way the
    /// playback path does would spike RAM by the whole file size, so this
    /// path reads a sliding window off a FileHandle and writes each chunk
    /// straight to the socket. `Content-Disposition` names the saved file
    /// (the chooser navigates to the URL, so the OS Save panel takes the
    /// name from here).
    private static func serveExport(id: String, kind: MediaExportKind, repo: MeetingRepository) -> HttpResponse {
        do {
            guard let m = try repo.meeting(id: id) else { return .notFound }
            let url: URL?
            let contentType: String
            let filename: String
            switch kind {
            case .audioM4A:
                url = MediaExporter.audioM4A(meetingId: id)
                contentType = "audio/mp4"
                filename = "corder-\(id).m4a"
            case .videoWithAudio:
                url = MediaExporter.videoWithAudio(meetingId: id, videoPath: m.videoPath)
                contentType = "video/mp4"
                filename = "corder-\(id).mp4"
            }
            guard let fileURL = url,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else {
                FileLogger.log("serveExport: export unavailable for \(id) (\(kind))")
                return .internalServerError
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            return .raw(200, "OK", [
                "Content-Type": contentType,
                "Content-Length": "\(size)",
                "Content-Disposition": "attachment; filename=\"\(filename)\"",
                "Accept-Ranges": "none",
            ]) { writer in
                defer { try? handle.close() }
                let chunkSize = 1 << 20   // 1 MiB
                while true {
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    try writer.write(chunk)
                }
            }
        } catch {
            return .internalServerError
        }
    }

    /// One-time Dropbox → local restore. Used by `serveMedia` when the
    /// canonical local file has been archived and deleted. Blocks the
    /// calling Swifter worker for the duration of the download (which can
    /// be tens of seconds for an hour-long meeting), but only on the very
    /// first request — once the file lands at `localURL` every subsequent
    /// request, including Range scrubs, is served straight from disk
    /// without ever touching this code path again.
    ///
    /// We deliberately don't proxy bytes per-request the way the previous
    /// implementation did: scrubbing produces dozens of Range requests in
    /// a few seconds, each of which would have blocked a worker thread on
    /// its own `URLSession.data` round-trip and hammered Dropbox's
    /// rate limit.
    private static func hydrateDropboxFile(remote: String, localURL: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        Task.detached {
            defer { semaphore.signal() }
            do {
                try await DropboxService.shared.download(remotePath: remote, to: localURL)
                ok = true
            } catch {
                FileLogger.log("hydrateDropboxFile: \(remote) → \(localURL.lastPathComponent) failed: \(error)")
            }
        }
        semaphore.wait()
        return ok
    }

    /// Pull a meeting's mix audio from Supabase Storage to the local
    /// `audio.wav` path. The "cross-device cache miss" case: Mac B
    /// signed in, pulled metadata, but has no local recording. The
    /// upload path stores objects at `<user_id>/<meeting_id>/mix.wav`
    /// — we ask the storage client for that key, write it to disk,
    /// then the regular Range branch serves the file. Returns false
    /// on any failure (missing object, not signed in, network).
    private static func hydrateSupabaseAudio(meetingId: String, localURL: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        Task.detached { @MainActor in
            defer { semaphore.signal() }
            guard let uid = SupabaseClientHolder.shared.auth.currentUser?.id else {
                FileLogger.log("hydrateSupabaseAudio: not signed in")
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                // Lowercase UUID — Postgres `auth.uid()::text` returns
                // lowercase, and our Storage RLS policy compares
                // `split_part(name, '/', 1)` against it strictly.
                // Swift's default `uuidString` is UPPERCASE → mismatch
                // → 403 unauthorized. Match the SQL convention.
                let key = "\(uid.uuidString.lowercased())/\(meetingId)/mix.wav"
                let data = try await SupabaseClientHolder.shared.storage
                    .from("recordings")
                    .download(path: key)
                try data.write(to: localURL)
                ok = true
                FileLogger.log("hydrateSupabaseAudio: pulled \(key) (\(data.count) bytes)")
            } catch {
                FileLogger.log("hydrateSupabaseAudio: \(meetingId) failed — \(error)")
            }
        }
        semaphore.wait()
        return ok
    }

    // MARK: helpers

    /// HTTP 403 envelope for a paid-feature tier-gate. The frontend's
    /// `api.ts` throws `HTTP 403` on `!r.ok`, which the Summary/Chapters
    /// panes detect (`message.includes("403")`) to show the Upgrade upsell
    /// instead of the generic error card.
    private static func tierGatedResponse(_ field: String) -> HttpResponse {
        .raw(403, "Forbidden", ["Content-Type": "application/json; charset=utf-8"]) {
            try? $0.write([UInt8]("{\"\(field)\":\"\",\"error\":\"tier_required\"}".utf8))
        }
    }

    private static func jsonResponse<T: Encodable>(_ value: T) -> HttpResponse {
        do {
            let enc = JSONEncoder()
            let data = try enc.encode(value)
            return .raw(200, "OK", ["Content-Type": "application/json; charset=utf-8"]) {
                try $0.write([UInt8](data))
            }
        } catch {
            return .internalServerError
        }
    }

    private static func jsonResponse(_ value: [String: Any]) -> HttpResponse {
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            return .raw(200, "OK", ["Content-Type": "application/json; charset=utf-8"]) {
                try $0.write([UInt8](data))
            }
        } catch {
            return .internalServerError
        }
    }
}
