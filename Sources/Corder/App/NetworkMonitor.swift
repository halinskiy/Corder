import Foundation
import Network

/// Watches the system's network reachability and reacts to two transitions
/// that matter for Corder:
///
///   1. **Lost while recording.** The recording itself is local and keeps
///      going, but transcription / Boost / Dropbox upload all need the
///      network when Stop fires. We post a banner so the user knows the
///      pipeline will need connectivity later.
///
///   2. **Restored after a meeting failed for network reasons.** Auto-retry
///      anything in `.failed` state whose stored error string contains a
///      network marker — typically meetings whose Gemini call landed during
///      the offline window.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private init() {}

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.3mpq.corder.network")

    /// Last reachability we saw. `nil` until the first callback lands.
    private var lastOnline: Bool?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.handle(online: online)
            }
        }
        monitor.start(queue: queue)
        FileLogger.log("NetworkMonitor: started")
    }

    private func handle(online: Bool) {
        // First update: just record state, don't post a banner — we're
        // probably still booting and the user knows their own connection
        // status.
        defer { lastOnline = online }
        guard let prev = lastOnline else { return }
        guard prev != online else { return }

        if online {
            FileLogger.log("NetworkMonitor: back online")
            NotificationsService.post(
                title: L.notif("notif_net_restored_title"),
                body: L.notif("notif_net_restored_body")
            )
            Task { await retryNetworkFailedMeetings() }
        } else {
            FileLogger.log("NetworkMonitor: went offline")
            // Only nag the user if they're actively recording — otherwise
            // a brief Wi-Fi flicker shouldn't spawn notifications.
            if case .recording = AppContext.shared.recordingState {
                NotificationsService.post(
                    title: L.notif("notif_net_lost_title"),
                    body: L.notif("notif_net_lost_body")
                )
            }
        }
    }

    /// Walk recently failed meetings and re-enqueue the ones whose stored
    /// error string indicates a transient network problem. Quota / billing
    /// failures are intentionally NOT retried — those need the user to
    /// fix something on their side.
    private func retryNetworkFailedMeetings() async {
        let repo = AppContext.shared.repo
        guard let meetings = try? repo.listMeetings() else { return }
        // Respect the SAME retry budget the launch auto-retry uses
        // (AppDelegate). Without it a flapping connection re-enqueues the
        // same meeting on every online transition — an unbounded, paid
        // re-transcribe loop. `failedRetriableMeetingIds` already excludes
        // rows that exhausted their attempts.
        let retriable = Set((try? repo.failedRetriableMeetingIds(maxAttempts: 3)) ?? [])
        for m in meetings {
            guard m.status == .failed, retriable.contains(m.id) else { continue }
            guard let err = TranscriptionErrors.read(meetingId: m.id) else { continue }
            // Phrase chosen so we catch our own GError.network message
            // ("No internet …") plus URLError descriptions surfaced through
            // boost / Dropbox paths.
            let lower = err.lowercased()
            guard lower.contains("no internet")
               || lower.contains("offline")
               || lower.contains("network") else { continue }

            FileLogger.log("NetworkMonitor: auto-retrying failed-by-network meeting \(m.id) (under budget)")
            TranscriptionErrors.clear(meetingId: m.id)
            // Serial: await each run before starting the next so a reconnect
            // after a long offline window doesn't fire N paid pipelines at
            // once (thundering herd).
            await TranscriptionPipeline.shared.enqueue(meetingId: m.id).value
        }
    }
}
