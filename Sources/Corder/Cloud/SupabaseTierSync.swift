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
        // Absent / empty tier ≡ Free. Previously we returned early on
        // an empty value ("keeping local") — that left a paid user
        // stuck on the cached tier after a server-side downgrade,
        // because the local Free fallback was never written. Treat
        // empty as Free so server downgrades reflect locally.
        let tier: UserTier
        if let parsed = UserTier(rawValue: raw) {
            tier = parsed
        } else if raw.isEmpty {
            tier = .free
        } else {
            FileLogger.log("SupabaseTierSync: unrecognised tier value '\(raw)' — keeping local")
            return
        }
        let priorTier = AppSettings.userTier
        if priorTier != tier {
            FileLogger.log("SupabaseTierSync: applying tier=\(tier.rawValue) from server (was \(priorTier.rawValue))")
            AppSettings.setUserTier(tier)
        }
        // On any tier change between Free and Paid we reset the
        // transcription-provider override so the tier-driven default
        // kicks in: Free → whisperLocal, Pro/Max → whisper cloud. A
        // user who picked cloud as Pro and then downgrades to Free
        // shouldn't keep a cloud override the Worker will 403 on
        // every recording.
        let wasPaid = (priorTier == .pro || priorTier == .max)
        let isPaid = (tier == .pro || tier == .max)
        if wasPaid != isPaid {
            FileLogger.log("SupabaseTierSync: tier transitioned \(priorTier.rawValue) → \(tier.rawValue) — clearing provider override so the new tier default applies")
            AppSettings.clearTranscriptionProviderOverride()
        }
    }
}
