import Foundation
import AppKit
import Network

/// Google "Sign in with Google" for the Welcome wizard. Desktop OAuth
/// flow per https://developers.google.com/identity/protocols/oauth2/native-app
/// — uses a loopback redirect (Google deprecated custom URL schemes
/// for Desktop client types):
///
///   1. Spin up an ephemeral TCP listener on `127.0.0.1:<random port>`.
///   2. Open the system browser on Google's authorize URL with
///      `redirect_uri = http://127.0.0.1:<port>/`.
///   3. User signs in; Google redirects the browser to the loopback.
///   4. Listener captures `code`, returns a tiny "you can close this"
///      HTML page, then tears itself down.
///   5. POST the code to Google's token endpoint for an access token.
///   6. Fetch the user's email via Google's `/userinfo` endpoint.
///
/// Returns `(email, googleUserId)` to the wizard so it can flip into
/// the confirmation state + POST `/signup` to our own backend.
@MainActor
enum GoogleOAuth {

    // OAuth client provisioned by Kostya in Google Cloud Console
    // under the `Corder` project (type: Desktop app). Google
    // explicitly states that the client_secret for Desktop apps is
    // not treated as a real secret — it has to ship inside the
    // binary anyway. Token exchange still requires it.
    static let clientID     = "694852501042-snnes48n4oodv3173fkb7donuvoi48ct.apps.googleusercontent.com"
    static let clientSecret = "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"

    /// Result of a completed sign-in.
    struct Result {
        let email: String
        let googleUserId: String
        let accessToken: String
        /// Display name from the Google `userinfo` claim. Optional —
        /// some accounts have it blank.
        let name: String?
    }

    /// Run the entire authorize + token-exchange + userinfo flow.
    /// Throws on cancellation / network error / any malformed
    /// response. Caller is expected to be on the main actor (the
    /// SignInInteractive view calls it inside an `async` task).
    static func signIn() async throws -> Result {
        // ── 1. Local loopback listener — gives us the redirect URI.
        let listener = try LoopbackListener()
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)/"

        // ── 2. Open the browser on Google's authorize endpoint.
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: "openid email profile"),
            URLQueryItem(name: "access_type",   value: "offline"),
            URLQueryItem(name: "prompt",        value: "consent"),
        ]
        guard let url = auth.url else { throw OAuthError.malformedAuthURL }
        NSWorkspace.shared.open(url)

        // ── 3. Wait for the redirect back to the loopback. The
        // listener stays up for a beat after we got the code so it
        // can serve the styled "/signed-in" follow-up page that the
        // first response 302-redirects the browser to. Otherwise the
        // user sees Google's enormous loopback URL and a blank
        // window when the listener tears down immediately.
        let code = try await listener.waitForCode()
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            listener.stop()
        }

        // ── 4. Exchange the code for an access token.
        let token = try await exchangeCode(code: code, redirectURI: redirectURI)

        // ── 5. Resolve the user's email + Google user id.
        let user = try await fetchUserInfo(accessToken: token.accessToken)
        FileLogger.log("GoogleOAuth: signed in as \(user.email) (\(user.id))")
        // Publish to the loopback listener so the `/signed-in` tab's
        // poll picks it up and injects the address under "Corder
        // picked up your Google account." Persist immediately too so
        // the profile popover gets the right identity even if the
        // user closes the wizard before clicking through.
        LoopbackListener.setLatestEmail(user.email)
        AppSettings.setUserEmail(user.email)
        if let name = user.name, !name.isEmpty {
            AppSettings.setUserName(name)
        }
        return Result(email: user.email,
                      googleUserId: user.id,
                      accessToken: token.accessToken,
                      name: user.name)
    }

    // MARK: - Token exchange

    private struct TokenResponse: Decodable {
        let access_token: String
        let id_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let token_type: String
        var accessToken: String { access_token }
    }

    private static func exchangeCode(code: String, redirectURI: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [(String, String)] = [
            ("code",          code),
            ("client_id",     clientID),
            ("client_secret", clientSecret),
            ("redirect_uri",  redirectURI),
            ("grant_type",    "authorization_code"),
        ]
        req.httpBody = body
            .map { "\($0.0)=\(percentEncode($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "<no body>"
            FileLogger.log("GoogleOAuth: token endpoint \(((resp as? HTTPURLResponse)?.statusCode ?? -1)): \(text)")
            throw OAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private struct UserInfo: Decodable {
        let id: String       // Google's stable user id (`sub`)
        let email: String
        let name: String?
    }

    private static func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.userinfoFailed
        }
        // Userinfo returns `sub` for the stable id; map → `id`.
        struct Raw: Decodable { let sub: String; let email: String; let name: String? }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return UserInfo(id: raw.sub, email: raw.email, name: raw.name)
    }

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    // MARK: - Errors

    enum OAuthError: Error {
        case malformedAuthURL
        case listenerFailed
        case noCodeReceived
        case tokenExchangeFailed
        case userinfoFailed
    }
}

// MARK: - Loopback HTTP listener

/// One-shot TCP listener on a random localhost port. Speaks just
/// enough HTTP to capture `GET /?code=...` and respond with a
/// minimal "you can close this tab" HTML page. Kept inside this
/// file (rather than promoted to a general server) because nothing
/// else in the app needs it.
private final class LoopbackListener {

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    /// Shared bucket the `/signed-in/identity` endpoint reads to tell
    /// the post-OAuth tab which Google account got picked up. Set
    /// from `signIn(presenting:)` once `fetchUserInfo` completes;
    /// the listener stays alive for ~2 s after the redirect so the
    /// tab's JS poll has time to fetch it before we tear down.
    nonisolated(unsafe) private static var latestEmail: String?
    nonisolated(unsafe) private static let emailLock = NSLock()
    static func setLatestEmail(_ email: String?) {
        emailLock.lock(); defer { emailLock.unlock() }
        latestEmail = email
    }
    fileprivate static func currentLatestEmail() -> String? {
        emailLock.lock(); defer { emailLock.unlock() }
        return latestEmail
    }

    init() throws {}

    /// Bind a fresh listener on an OS-chosen ephemeral port and
    /// return that port number to the caller (we need it to build
    /// the `redirect_uri`).
    ///
    /// Async on purpose: `NWListener` reports its readiness via the
    /// state-update handler on the queue it's started on. The earlier
    /// version blocked on a `DispatchGroup.wait()` while also having
    /// the listener installed on `.main` — same thread the caller was
    /// suspending — which deadlocked itself: the `ready` callback
    /// could never run while main was blocked, and 3 s later the call
    /// gave up with `listenerFailed`. Using a CheckedContinuation
    /// lets the main actor genuinely yield until NWListener fires.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        return try await withCheckedThrowingContinuation { cont in
            var settled = false
            l.stateUpdateHandler = { state in
                guard !settled else { return }
                switch state {
                case .ready:
                    settled = true
                    if let port = l.port?.rawValue {
                        cont.resume(returning: port)
                    } else {
                        l.cancel()
                        cont.resume(throwing: GoogleOAuth.OAuthError.listenerFailed)
                    }
                case .failed(let err):
                    settled = true
                    FileLogger.log("GoogleOAuth: listener failed: \(err)")
                    l.cancel()
                    cont.resume(throwing: GoogleOAuth.OAuthError.listenerFailed)
                case .cancelled:
                    if !settled {
                        settled = true
                        cont.resume(throwing: GoogleOAuth.OAuthError.listenerFailed)
                    }
                default: break
                }
            }
            // Background queue so the callback never depends on the
            // caller's thread being free.
            l.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Suspends until the browser hits the redirect URL and we've
    /// extracted `code=…`. Resumes the awaiting task.
    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, error in
            guard let self = self else { connection.cancel(); return }
            if let error = error {
                self.continuation?.resume(throwing: error)
                self.continuation = nil
                connection.cancel()
                return
            }
            guard let data = data,
                  let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse "GET /<path>?<query> HTTP/1.1".
            // Just enough URL parsing — no need to be RFC-tight.
            //   • First hit carries `code=…` from Google's redirect.
            //     Resume the continuation, then bounce the browser
            //     to `/signed-in` so the user sees a short URL +
            //     styled confirmation page instead of Google's
            //     200-character loopback monster.
            //   • Second hit is `/signed-in` (same listener still
            //     up for ~4 s). Serve the styled page, then close.
            //   • Anything else: tiny 404, close.
            // JSON identity poll — called by the /signed-in tab's JS
            // every 250ms until it gets an email (or the listener
            // tears down). Cheap; static accessor + tiny payload.
            if text.contains("GET /signed-in/identity") {
                let email = LoopbackListener.currentLatestEmail() ?? ""
                let json = #"{"email":"\#(email)"}"#
                let body = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(json)"
                connection.send(content: body.data(using: .utf8),
                                completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
                return
            }
            if text.contains("GET /signed-in") {
                let html = Self.signedInHTML
                let body = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: body.data(using: .utf8),
                                completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
                return
            }
            if let codeRange = text.range(of: "code=") {
                let after = text[codeRange.upperBound...]
                let raw = after.prefix { $0 != "&" && $0 != " " && $0 != "\r" && $0 != "\n" }
                // Google sends the auth code URL-percent-encoded in
                // the redirect query string (typically contains a `/`
                // as `%2F`). We MUST decode it before handing it
                // to `exchangeCode`, otherwise the body builder
                // there percent-encodes the already-encoded string,
                // turning `%2F` into `%252F` — and Google replies
                // `invalid_grant: Malformed auth code.`
                let code = String(raw).removingPercentEncoding ?? String(raw)
                // 302 → /signed-in. Browsers re-issue a GET against
                // the new path (without the query string from the
                // original Google redirect), which is exactly the
                // URL-cleanup we want.
                let resp = "HTTP/1.1 302 Found\r\nLocation: /signed-in\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: resp.data(using: .utf8),
                                completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
                self.continuation?.resume(returning: code)
                self.continuation = nil
                return
            }
            // Unknown request — tiny 404, close.
            let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: resp.data(using: .utf8),
                            completion: .contentProcessed { _ in
                                connection.cancel()
                            })
        }
    }

    /// Static HTML for the post-redirect "you're signed in" page.
    /// Inline CSS so the page renders identically regardless of where
    /// the browser is on its caching schedule, and so we don't ship a
    /// second asset for a one-shot screen. Brand accent + Corder mark
    /// drawn as inline SVG (the two-bar squircle) so it matches the
    /// app icon without depending on a remote image.
    private static let signedInHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <title>Signed in to Corder</title>
      <meta name="viewport" content="width=device-width,initial-scale=1" />
      <style>
        :root {
          color-scheme: light dark;
          --bg: #ffffff;
          --fg: #111111;
          --fg-muted: #6b6b6b;
          --accent: #1F7A4F;
          --border: rgba(0,0,0,0.10);
          --logo-3mpq: #212121;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #0e0f10;
            --fg: #f5f5f5;
            --fg-muted: #9b9b9b;
            --border: rgba(255,255,255,0.10);
            --logo-3mpq: #ffffff;
          }
        }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--bg);
          color: var(--fg);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text",
            "Inter", "Helvetica Neue", sans-serif;
          -webkit-font-smoothing: antialiased;
          min-height: 100%;
        }
        /* Brand row sits 16 px from the top, ignored by the centring
           below. Two 64×64 marks (3mpq + Corder) separated by a thin
           translucent vertical divider with generous breathing room
           on both sides. */
        .brand {
          position: absolute;
          top: 40px;
          left: 0;
          right: 0;
          display: flex;
          justify-content: center;
          align-items: center;
          gap: 10px;
        }
        /* Both marks 24×24 — the brand-row reads as a discreet footer
           mark, not a hero. Hard-clamped against any SVG intrinsic
           sizing through `!important` + explicit flex-basis. */
        .brand .mark {
          width: 24px !important;
          height: 24px !important;
          flex: 0 0 24px !important;
          display: flex;
          align-items: center;
          justify-content: center;
          overflow: hidden;
          box-sizing: border-box;
        }
        .brand .mark.corder {
          background: #ffffff;
          border-radius: 5px;
          border: 1px solid var(--border);
          gap: 3px;
          box-shadow: 0 2px 6px rgba(0,0,0,0.10);
          /* Extra 2 px of breathing room on the right side of the
             separator — visually centres the brand-name pair so the
             Corder squircle doesn't crowd the hairline. */
          margin-left: 2px;
        }
        .brand .mark.corder .bar {
          width: 3.5px;
          height: 12px;
          background: #111111;
          border-radius: 1.75px;
        }
        .brand .mark.three { color: var(--logo-3mpq); }
        .brand .mark.three svg {
          width: 24px !important;
          height: 24px !important;
          display: block;
        }
        .brand .mark.three svg path { fill: currentColor; }
        .brand .sep {
          width: 1px;
          height: 14px;
          background: currentColor;
          opacity: 0.18;
          color: var(--fg);
          flex: 0 0 1px;
        }
        /* The content column is centred on the viewport regardless of
           the brand row above it — that's why we don't put the brand
           inside the same flex container. */
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
          width: 44px;
          height: 44px;
          border-radius: 50%;
          background: var(--accent);
          color: white;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 22px;
          line-height: 1;
        }
        /* Vertical rhythm: check ─28px─ h1 ─8px─ p. The hint chip
           lives in its own absolute box pinned 32 px from the bottom
           of the viewport, so it doesn't ride the centred stack. */
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
          left: 0;
          right: 0;
          bottom: 32px;
          text-align: center;
          font-size: 13px;
          color: var(--fg-muted);
        }
        /* `⌘W` chip — solid brand-green pill, white glyph, fully
           opaque regardless of the surrounding muted-text colour. */
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
      <div class="brand" aria-hidden="true">
        <div class="mark three" aria-label="3mpq">
          <svg width="64" height="64" viewBox="0 0 536 536" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg">
            <path d="M447.208 451.089C460.632 466.532 473.891 481.802 487.488 497.41C471.374 507.65 455.935 517.385 439.822 527.621C432.773 519.063 425.892 510.669 419.012 502.448C414.817 497.245 410.285 492.207 406.258 486.836C403.906 483.649 401.558 483.649 398.202 484.993C378.395 491.874 358.091 497.41 336.944 498.249C285.589 500.264 241.279 484.825 205.869 446.224C203.015 443.036 202.513 440.853 204.524 436.991C216.944 414.001 229.028 390.839 241.785 366.504C261.419 421.552 300.02 440.853 356.244 428.938C344.832 415.342 333.756 402.251 322.175 388.49C337.783 378.418 352.888 368.519 368.496 358.282C379.234 370.867 389.643 383.119 400.213 395.539C408.944 385.804 413.978 374.729 416.495 362.811C422.034 336.967 421.027 311.456 412.131 286.615C398.202 247.512 362.788 225.192 321.336 228.885C319.321 229.05 317.306 229.219 314.287 229.387C323.014 212.604 331.404 196.828 339.798 180.884C340.468 179.542 341.307 178.367 341.978 177.024C349.195 163.43 349.195 163.43 364.634 166.619C440.493 182.731 493.361 248.351 494.031 327.232C494.368 373.051 480.772 413.832 449.725 448.239C448.886 448.741 448.216 449.58 447.208 451.089Z"/>
            <path d="M33.5054 499.428C33.5054 387.317 33.5054 276.048 33.5054 164.272C102.316 164.272 170.79 164.272 239.768 164.272C239.768 184.58 239.768 205.055 239.768 226.034C196.468 226.034 153.336 226.034 109.868 226.034C109.868 249.53 109.868 272.187 109.868 295.514C150.818 295.514 191.266 295.514 233.558 295.514C232.55 300.885 232.719 305.919 230.872 309.949C223.658 324.549 215.602 338.816 208.216 353.416C206.369 357.109 203.684 357.611 200.159 357.611C172.469 357.443 144.776 357.611 117.085 357.611C114.903 357.611 112.553 357.611 109.868 357.611C109.868 384.298 109.868 410.479 109.868 436.994C127.658 436.994 145.112 436.994 163.07 436.994C162.399 438.84 162.231 440.185 161.559 441.361C152.161 459.317 142.762 477.442 133.029 495.233C131.854 497.248 128.665 499.428 126.483 499.428C96.9449 499.765 67.407 499.597 37.7012 499.597C36.5262 499.765 35.3516 499.597 33.5054 499.428Z"/>
            <path d="M355.736 150.343C361.946 138.426 367.987 126.679 374.197 115.098C390.644 84.0497 407.259 52.8333 423.541 21.617C425.387 18.0928 427.234 16.75 431.26 16.75C452.408 16.9178 473.555 16.75 494.867 16.75C496.545 16.75 498.223 16.9178 499.901 17.0856C507.624 18.4284 509.635 23.7987 504.433 29.505C496.211 38.2321 487.653 46.6236 479.259 55.0151C452.07 82.2035 424.211 108.553 398.199 136.58C385.778 150.007 372.856 153.699 355.736 150.343Z"/>
            <path d="M79.4908 40.0757C106.008 40.0757 124.133 58.7048 124.133 86.2289C124.133 112.914 105.504 132.046 79.6586 132.214C53.8129 132.382 35.016 113.082 34.8479 86.3967C34.6801 59.376 53.3092 40.2435 79.4908 40.0757Z"/>
            <path d="M194.615 40.0757C220.797 40.0757 238.753 58.8726 238.753 86.061C238.753 113.249 220.126 132.214 193.776 132.214C168.098 132.214 149.469 112.578 149.469 86.061C149.469 59.2082 168.266 40.0757 194.615 40.0757Z"/>
          </svg>
        </div>
        <div class="sep" aria-hidden="true"></div>
        <div class="mark corder" aria-label="Corder">
          <div class="bar"></div>
          <div class="bar"></div>
        </div>
      </div>
      <div class="content">
        <div class="check" aria-hidden="true">✓</div>
        <h1>You're signed in</h1>
        <p>Corder picked up your Google account<span id="email-line"></span>. You can close this tab and head back to the app.</p>
        <div class="hint">Press <kbd>⌘W</kbd> to close.</div>
      </div>
      <script>
        // Poll the loopback listener for the resolved Google email
        // and inject it into the copy so the user can verify which
        // account they signed in with. The listener stays alive for
        // ~2 s after the redirect; we stop polling as soon as we
        // get a non-empty email back (or after ~3 s when the
        // listener tears down).
        (function () {
          var attempts = 0;
          var slot = document.getElementById("email-line");
          function tick() {
            attempts += 1;
            fetch("/signed-in/identity", { cache: "no-store" })
              .then(function (r) { return r.ok ? r.json() : null; })
              .then(function (j) {
                if (j && j.email) {
                  slot.textContent = " — " + j.email;
                  return;
                }
                if (attempts < 12) { setTimeout(tick, 250); }
              })
              .catch(function () {
                if (attempts < 12) { setTimeout(tick, 250); }
              });
          }
          tick();
        })();
      </script>
    </body>
    </html>
    """
}
