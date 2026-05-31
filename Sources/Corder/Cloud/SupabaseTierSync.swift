import Foundation

/// Reads the signed-in Supabase user's `app_metadata.tier` and
/// mirrors it into local `AppSettings.userTier`. The admin API (the
/// only thing that can write `app_metadata`) is the source of
/// truth for paid plans — server-side grant beats any local
/// override. Local `defaults write` still works as a fallback while
/// a user is offline / signed-out.
@MainActor
enum SupabaseTierSync {
    /// Apply the tier from whichever session the SDK currently has
    /// cached. Safe to call from launch + every sign-in success
    /// callback. Missing `tier` field = no change (we never
    /// DOWNgrade silently, so a transient network miss can't bump
    /// a paying user back to Free).
    static func applyFromCurrentSession() {
        guard let user = SupabaseClientHolder.shared.auth.currentUser else { return }
        let raw = user.appMetadata["tier"]?.stringValue?.lowercased() ?? ""
        guard let tier = UserTier(rawValue: raw) else {
            FileLogger.log("SupabaseTierSync: no recognised tier in app_metadata (was: \(raw.isEmpty ? "absent" : raw)) — keeping local")
            return
        }
        if AppSettings.userTier != tier {
            FileLogger.log("SupabaseTierSync: applying tier=\(tier.rawValue) from server")
            AppSettings.setUserTier(tier)
        }
    }
}
