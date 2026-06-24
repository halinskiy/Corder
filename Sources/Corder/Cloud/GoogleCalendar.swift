import Foundation
import AppKit

/// Optional, opt-in Google Calendar connection that powers the Dashboard
/// "Upcoming" tab. Deliberately ISOLATED from the sign-in flow: regular
/// Google login (email/profile) is untouched, so existing users never see
/// the calendar consent. Only when the user clicks "Connect calendar" do
/// we run a SECOND, incremental OAuth that adds `calendar.readonly` to the
/// session — and only those users see the (currently unverified) calendar
/// consent screen.
///
/// Flow:
///  1. `startConnect()` → opens a Google OAuth URL that requests the
///     calendar scope, with the same loopback `/auth/callback` redirect
///     the sign-in uses. Sets `pendingConnect`.
///  2. The browser round-trips to `/auth/callback`; `authCallback`
///     calls `auth.session(from:)`, then — because `pendingConnect` is
///     set — invokes `finishConnect()`.
///  3. `finishConnect()` reads the now calendar-scoped `providerToken`
///     off the session, fetches the upcoming events, and caches them on
///     disk (account-scoped). `/api/calendar/upcoming` serves that cache.
///
/// Token refresh (Google access tokens expire in ~1h) needs the Google
/// client secret, which lives on the Worker — so for now the events are
/// fetched at connect time and cached; a stale connection is refreshed by
/// the user reconnecting. Proper background refresh is a Worker follow-up.
@MainActor
enum GoogleCalendar {
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"

    /// Set while an incremental calendar-connect OAuth is in flight so the
    /// shared `/auth/callback` handler knows to harvest the calendar token
    /// (vs a plain sign-in, which must behave exactly as before).
    private(set) static var pendingConnect = false

    nonisolated private static var cacheURL: URL {
        AppPaths.accountRoot.appendingPathComponent("calendar_cache.json")
    }

    // MARK: connect

    /// Email of the account that was signed into Corder when the connect
    /// was launched. Used to (a) pin Google's account chooser via
    /// `login_hint` and (b) reject a callback that switched to a different
    /// account, so connecting a calendar can never silently swap the
    /// signed-in Corder identity.
    private static var pendingConnectEmail: String?

    /// Build the incremental OAuth URL (calendar scope + offline access so
    /// a refresh token is issued) and open it in the browser.
    static func startConnect() {
        let port = AppContext.shared.server.port
        guard let redirect = URL(string: "http://127.0.0.1:\(port)/auth/callback") else { return }
        let signedInEmail = SupabaseClientHolder.shared.auth.currentUser?.email
        var params: [(name: String, value: String?)] = [
            ("access_type", "offline"),
            // Force the consent so Google re-issues a provider token that
            // actually carries the calendar grant even if the user
            // authorised Google sign-in earlier.
            ("prompt", "consent"),
        ]
        // Pin Google's chooser to the same account Corder is signed in as,
        // so the connected calendar matches the Corder identity.
        if let email = signedInEmail, !email.isEmpty {
            params.append(("login_hint", email))
        }
        do {
            let url = try SupabaseClientHolder.shared.auth.getOAuthSignInURL(
                provider: .google, scopes: scope, redirectTo: redirect, queryParams: params)
            pendingConnect = true
            pendingConnectEmail = signedInEmail
            // Expire the pending flag if the user abandons the browser flow,
            // so a much-later ordinary sign-in callback can't be mistaken
            // for this calendar connect.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if pendingConnect {
                    pendingConnect = false
                    pendingConnectEmail = nil
                    FileLogger.log("GoogleCalendar: pending connect expired (no callback)")
                }
            }
            FileLogger.log("GoogleCalendar: opening incremental calendar OAuth (hint=\(signedInEmail ?? "none"))")
            NSWorkspace.shared.open(url)
        } catch {
            FileLogger.log("GoogleCalendar: failed to build connect URL — \(error)")
        }
    }

    /// Called by `authCallback` after a successful `session(from:)` WHEN a
    /// calendar connect was pending. Harvests the provider token and caches
    /// the upcoming events. No-op for ordinary sign-ins.
    /// `priorAccessToken`/`priorRefreshToken` are the Corder session that was
    /// live BEFORE `authCallback` ran `session(from:)`. On an account
    /// mismatch we restore them so a calendar connect can never leave the app
    /// signed in as a different Google account (the documented invariant).
    static func finishConnectIfPending(priorAccessToken: String? = nil,
                                       priorRefreshToken: String? = nil) async {
        guard pendingConnect else { return }
        pendingConnect = false
        let expectedEmail = pendingConnectEmail
        pendingConnectEmail = nil
        // Identity guard: `session(from:)` in authCallback ALREADY swapped the
        // live session to whatever account the browser resolved to. If that's
        // a DIFFERENT account than the one we connected as (or ANY account
        // when none was signed in), the swap must be ROLLED BACK — otherwise a
        // calendar connect silently changes the Corder identity (wrong
        // account-id sandbox, wrong JWT/tier). Only logging + returning (the
        // old behaviour) left the wrong identity in place.
        let nowEmail = SupabaseClientHolder.shared.auth.currentUser?.email
        let identityChanged: Bool = {
            guard let expectedEmail, !expectedEmail.isEmpty else { return true } // no prior identity → never bind an arbitrary account via connect
            guard let nowEmail else { return false }
            return expectedEmail.lowercased() != nowEmail.lowercased()
        }()
        if identityChanged {
            FileLogger.log("GoogleCalendar: connect resolved to a different account (was \(expectedEmail ?? "none"), now \(nowEmail ?? "none")) — reverting session, not caching")
            do {
                if let at = priorAccessToken, let rt = priorRefreshToken {
                    _ = try await SupabaseClientHolder.shared.auth.setSession(accessToken: at, refreshToken: rt)
                } else {
                    try await SupabaseClientHolder.shared.auth.signOut()
                }
            } catch {
                FileLogger.log("GoogleCalendar: failed to revert session after connect mismatch — \(error)")
            }
            return
        }
        let session = SupabaseClientHolder.shared.auth.currentSession
        guard let token = session?.providerToken, !token.isEmpty else {
            FileLogger.log("GoogleCalendar: connect finished but no providerToken on session")
            return
        }
        // Persist the refresh token so the feed can be renewed past the 1h
        // access-token expiry (see refreshIfStale).
        let refresh = session?.providerRefreshToken
        do {
            let events = try await fetchUpcoming(accessToken: token)
            writeCache(connected: true, events: events, refreshToken: refresh)
            FileLogger.log("GoogleCalendar: connected, cached \(events.count) events (refreshToken=\(refresh != nil))")
        } catch {
            let code = (error as NSError).code
            let authFailed = (code == 401 || code == 403)
            FileLogger.log("GoogleCalendar: event fetch failed (code \(code), authFailed=\(authFailed)) — \(error)")
            writeCache(connected: !authFailed, events: [], refreshToken: authFailed ? nil : refresh)
        }
    }

    /// Renew the feed when it's stale. Reads the cached refresh token, mints
    /// a fresh access token via the Worker (which holds the Google client
    /// secret), refetches events, and rewrites the cache. Called on
    /// app-active. No-op unless connected, with a refresh token, and the
    /// cache is older than `maxAgeSeconds`. Best-effort: any failure leaves
    /// the existing cache untouched.
    static func refreshIfStale(maxAgeSeconds: Double = 30 * 60) async {
        guard let cache = readCache(), cache.connected,
              let refresh = cache.refreshToken, !refresh.isEmpty else { return }
        if Date().timeIntervalSince1970 - cache.fetchedAt < maxAgeSeconds { return }
        guard let access = await exchangeRefreshToken(refresh) else {
            FileLogger.log("GoogleCalendar: token refresh failed — keeping cached events")
            return
        }
        do {
            let events = try await fetchUpcoming(accessToken: access)
            writeCache(connected: true, events: events, refreshToken: refresh)
            FileLogger.log("GoogleCalendar: refreshed feed, \(events.count) events")
        } catch {
            FileLogger.log("GoogleCalendar: refetch after token refresh failed — \(error)")
        }
    }

    /// Exchange a Google refresh token for a fresh access token via the
    /// Cloudflare Worker (which holds GOOGLE_CLIENT_SECRET). The app never
    /// sees the client secret. Returns nil on any failure.
    private static func exchangeRefreshToken(_ refreshToken: String) async -> String? {
        guard let url = URL(string: "https://corder-api.empqwork.workers.dev/calendar/refresh") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let jwt = SupabaseClientHolder.shared.auth.currentSession?.accessToken {
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // MARK: read

    /// Cached payload for `/api/calendar/upcoming`. Not-connected by
    /// default (no cache file yet). nonisolated so the Swifter route can
    /// read it straight off its background thread (file read only).
    nonisolated static func cachedResponse() -> DTO.UpcomingResponse {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return DTO.UpcomingResponse(connected: false, events: [])
        }
        return DTO.UpcomingResponse(connected: cache.connected, events: cache.events)
    }

    // MARK: Google Calendar API

    /// GET primary calendar events in the next 30 days, expanded to single
    /// instances and ordered by start. Maps to the frontend DTO.
    static func fetchUpcoming(accessToken: String) async throws -> [DTO.UpcomingEvent] {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let timeMin = iso.string(from: now)
        let timeMax = iso.string(from: now.addingTimeInterval(30 * 24 * 3600))
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            URLQueryItem(name: "timeMin", value: timeMin),
            URLQueryItem(name: "timeMax", value: timeMax),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "25"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "GoogleCalendar", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { mapEvent($0) }
    }

    private static func mapEvent(_ item: [String: Any]) -> DTO.UpcomingEvent? {
        guard let id = item["id"] as? String else { return nil }
        let title = (item["summary"] as? String) ?? ""
        let startMs = parseTime(item["start"] as? [String: Any])
        guard let startMs else { return nil }   // skip undated rows
        let endMs = parseTime(item["end"] as? [String: Any])
        let attendees = (item["attendees"] as? [[String: Any]])?.count
        let join = joinURL(item)
        return DTO.UpcomingEvent(
            id: id, title: title, start_ms: startMs, end_ms: endMs,
            attendees: attendees, platform: platform(for: join), join_url: join)
    }

    /// `{ "dateTime": "2026-..T..+03:00" }` for timed events,
    /// `{ "date": "2026-06-10" }` for all-day. Returns epoch ms.
    private static func parseTime(_ dict: [String: Any]?) -> Int64? {
        guard let dict else { return nil }
        if let dt = dict["dateTime"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: dt) { return Int64(d.timeIntervalSince1970 * 1000) }
            let f2 = ISO8601DateFormatter()
            if let d = f2.date(from: dt) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        if let day = dict["date"] as? String {
            // All-day events are a floating calendar day, not an instant.
            // Parse in UTC so the day doesn't shift by the device offset.
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            if let d = f.date(from: day) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        return nil
    }

    private static func joinURL(_ item: [String: Any]) -> String? {
        if let hangout = item["hangoutLink"] as? String, !hangout.isEmpty { return hangout }
        if let conf = item["conferenceData"] as? [String: Any],
           let entries = conf["entryPoints"] as? [[String: Any]] {
            // Prefer the video entry point.
            if let video = entries.first(where: { ($0["entryPointType"] as? String) == "video" }),
               let uri = video["uri"] as? String { return uri }
            if let uri = entries.first?["uri"] as? String { return uri }
        }
        return nil
    }

    private static func platform(for url: String?) -> String? {
        guard let url else { return nil }
        let host = URL(string: url)?.host?.lowercased() ?? url.lowercased()
        if host.contains("zoom") { return "zoom" }
        if host.contains("meet.google") || host.contains("hangout") { return "meet" }
        if host.contains("teams.microsoft") { return "teams" }
        return nil
    }

    // MARK: cache

    private struct Cache: Codable {
        let connected: Bool
        let events: [DTO.UpcomingEvent]
        let fetchedAt: Double
        // Google refresh token, captured at connect (access_type=offline).
        // Used to mint a fresh 1h access token via the Worker so the feed
        // survives past the initial token's expiry. nil for pre-refresh
        // caches and after an auth failure.
        var refreshToken: String? = nil
    }

    nonisolated private static func readCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private static func writeCache(connected: Bool, events: [DTO.UpcomingEvent], refreshToken: String?) {
        let cache = Cache(connected: connected, events: events,
                          fetchedAt: Date().timeIntervalSince1970, refreshToken: refreshToken)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL)
        }
    }
}
