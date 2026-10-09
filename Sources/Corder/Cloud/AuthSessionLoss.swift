import Foundation
import Supabase

/// Classifies a failed Supabase session restore or refresh.
///
/// A DEFINITIVE loss means the refresh token is gone for good: revoked by a
/// sign-out on another Mac, rotated away because two Macs shared one cloned
/// session (Migration Assistant copies the keychain), the user deleted, or
/// the stored session missing while the app still remembers an email. The
/// account IS signed out and the app must say so, instead of keeping a cached
/// email next to a dead token (before 0.15.75 the profile then read "signed
/// in" while Share answered "sign in to share" and admin surfaces vanished).
///
/// Everything else (offline, DNS, a 5xx, a rate limit) is transient: the
/// cached identity, admin role and tier stay untouched and the next refresh
/// sorts it out. Never downgrade a paying user over a flaky network.
enum AuthSessionLoss {
    nonisolated static func isDefinitive(_ error: Error) -> Bool {
        guard let auth = error as? AuthError else { return false }
        switch auth {
        case .sessionMissing:
            return true
        case .api(let message, let code, _, let response):
            let gone: Set<ErrorCode> = [
                .refreshTokenNotFound, .refreshTokenAlreadyUsed,
                .sessionNotFound, .sessionExpired, .userNotFound, .badJWT,
            ]
            if gone.contains(code) { return true }
            // Older GoTrue builds answer a dead refresh token with a bare
            // 400/401 and a message instead of an error code.
            guard (400...403).contains(response.statusCode) else { return false }
            let m = message.lowercased()
            return m.contains("refresh token") || m.contains("session") || m.contains("jwt")
        default:
            return false
        }
    }
}
