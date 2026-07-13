import AppKit
import Foundation

/// Drives the in-app sign-in MODAL (`SignInModalHost`, rendered in the
/// Library WKWebView), which replaces the old separate native sign-in
/// window. The web modal posts JSON actions via the `authAction` message
/// handler; this controller performs the REAL auth through the Supabase
/// SDK, so the session + the per-account folder binding stay native, and
/// pushes UI state back to the web via `window.corderAuthState(...)`. On a
/// successful sign-in it relaunches, so the new process boots into the
/// signed-in account's folder (same handoff the old window used).
@MainActor
final class AuthController {
    static let shared = AuthController()
    private init() {}

    private var busy = false
    private var oauthInFlight = false

    /// Show the modal (Profile → Sign in). The web renders from the state
    /// we push; "unknown" mode means "email not classified yet".
    func present() {
        // Make sure the Library (which hosts the modal) is on screen.
        LibraryWindow.shared.show(serverURL: AppContext.shared.server.baseURL)
        push(visible: true, error: nil)
    }

    /// Dispatch a JSON action string posted by the web modal.
    func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "dismiss":   push(visible: false, error: nil)
        case "google":    google(agreed: (obj["agreed"] as? Bool) ?? false)
        case "submit":
            submit(email: (obj["email"] as? String) ?? "",
                   password: (obj["password"] as? String) ?? "",
                   mode: (obj["mode"] as? String) ?? "signin",
                   agreed: (obj["agreed"] as? Bool) ?? false)
        default: break
        }
    }

    // MARK: - Email + password

    private func submit(email rawEmail: String, password: String, mode: String, agreed: Bool) {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard agreed else {
            push(visible: true, error: "Please agree to the Terms and Privacy Policy first."); return
        }
        guard !email.isEmpty, !password.isEmpty else {
            push(visible: true, error: "Enter your email and password."); return
        }
        guard !busy else { return }
        busy = true
        push(visible: true, busy: true, error: nil)
        Task { @MainActor in
            let client = SupabaseClientHolder.shared.auth
            do {
                // Explicit mode, the user chose Sign in vs Sign up; no auto-
                // flip from an unknown email.
                if mode == "signup" {
                    _ = try await client.signUp(email: email, password: password)
                } else {
                    _ = try await client.signIn(email: email, password: password)
                }
                finishSignedIn(email: email, name: nil, provider: "email")
            } catch {
                busy = false
                FileLogger.log("AuthController: \(mode) failed for \(email): \(error)")
                push(visible: true, error: mode == "signup"
                     ? "Couldn't create your account. The email may already be in use."
                     : "Wrong email or password. New here? Tap Sign up.")
            }
        }
    }

    // MARK: - Google (loopback → in-app /auth/callback → signed-in notif)

    private func google(agreed: Bool) {
        guard agreed else {
            push(visible: true,error: "Please agree to the Terms and Privacy Policy first."); return
        }
        guard !oauthInFlight else { return }
        oauthInFlight = true
        busy = true
        push(visible: true,busy: true, error: nil)
        Task { @MainActor in
            defer { oauthInFlight = false }
            do {
                let port = AppContext.shared.server.port
                let redirect = URL(string: "http://127.0.0.1:\(port)/auth/callback")!
                let url = try SupabaseClientHolder.shared.auth.getOAuthSignInURL(
                    provider: .google, redirectTo: redirect)
                NSWorkspace.shared.open(url)
                let signedIn = await Self.waitForSignedIn(timeoutNanos: 60_000_000_000)
                guard signedIn, let user = SupabaseClientHolder.shared.auth.currentUser else {
                    busy = false
                    push(visible: true,
                         error: signedIn ? nil : "Google sign-in didn't complete. Try again.")
                    return
                }
                let meta = user.userMetadata
                let name = (meta["full_name"]?.stringValue ?? meta["name"]?.stringValue) as String?
                finishSignedIn(email: user.email ?? "", name: name, provider: "google")
            } catch {
                busy = false
                FileLogger.log("AuthController: Google sign-in failed: \(error)")
                push(visible: true,error: "Google sign-in failed. Try again.")
            }
        }
    }

    /// Await the AppDelegate's `.corderSupabaseSignedIn` (posted after the
    /// `/auth/callback` route hands the code to `auth.session(from:)`),
    /// racing a timeout so a cancelled browser tab doesn't hang forever.
    private static func waitForSignedIn(timeoutNanos: UInt64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in NotificationCenter.default
                    .notifications(named: .corderSupabaseSignedIn).prefix(1) { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Success + state push

    private func finishSignedIn(email: String, name: String?, provider: String) {
        if !email.isEmpty { AppSettings.setUserEmail(email) }
        if let name, !name.isEmpty { AppSettings.setUserName(name) }
        AppSettings.setHasSignedInBefore(true)
        SupabaseTierSync.applyFromCurrentSession()
        FileLogger.log("AuthController: signed in via \(provider) (\(email)), relaunching into account folder")
        CorderRelaunch.now()
    }

    private func push(visible: Bool, busy: Bool = false, error: String?) {
        // `mode` (signin/signup) is owned by the web modal (the user toggles
        // it with the link); we never push it back.
        var payload: [String: Any] = ["visible": visible, "busy": busy]
        if let error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.corderAuthState && window.corderAuthState(\(json))"
        LibraryWindow.shared.webViewRef?.evaluateJavaScript(js, completionHandler: nil)
    }
}
