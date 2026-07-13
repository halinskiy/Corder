import Foundation
@preconcurrency import Supabase

/// Lazy singleton over the Supabase client. Reads the project URL +
/// anon (publishable) key from compile-time constants, both are
/// public and safe to ship in the binary (RLS is the security
/// boundary, not these keys).
///
/// The legacy `GoogleOAuth.swift` (loopback) and the Cloudflare
/// Worker `/signup` path stay alive for the brief overlap period
/// while the wizard learns to drive `client.auth.signInWithOAuth`
/// instead. Once the new auth flow is the only path, both can be
/// retired.
enum SupabaseEnvironment {
    /// Project ref: `cfsajlsctzxgixjwslni`. Hosted in West EU.
    static let url = URL(string: "https://cfsajlsctzxgixjwslni.supabase.co")!
    /// `sb_publishable_*` token, replaces the older anon JWT. Safe
    /// to ship in a public binary: every read/write is gated by RLS
    /// against the signed-in user. Rotate via the Supabase dashboard
    /// if it ever leaks; rotation invalidates this constant only
    /// (no data exposure).
    static let publishableKey = "sb_publishable_sqnQntW3VL3Qqh5YGzYFeA_G70fFq2N"
}

@MainActor
enum SupabaseClientHolder {
    /// Shared client. Lazy so the SDK doesn't initialise URLSession
    /// + the auth storage on app launch unless something actually
    /// touches Supabase. After wizard sign-in it's effectively
    /// permanent, the session refresher runs in the background.
    static let shared: SupabaseClient = {
        SupabaseClient(
            supabaseURL: SupabaseEnvironment.url,
            supabaseKey: SupabaseEnvironment.publishableKey
        )
    }()
}
