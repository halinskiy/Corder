import Foundation
@preconcurrency import Supabase

/// Deletion carries identifiers, never new meeting content. Keep tombstones
/// per account until every remote step succeeds, including across relaunches.
@MainActor
final class CloudMeetingDeletion {
    private let client: SupabaseClient
    private let defaults: UserDefaults
    private static let key = "Corder.pendingMeetingDeletions"
    private var flushing = false

    init(client: SupabaseClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

    func pendingIDs(userID: UUID) -> [String] {
        entries[userID.uuidString.lowercased()] ?? []
    }

    private var entries: [String: [String]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    func deleteMeeting(id: String) async {
        guard let uid = client.auth.currentUser?.id else { return }
        guard UUID(uuidString: id) != nil else {
            FileLogger.log("CloudMeetingDeletion: rejected invalid meeting id")
            return
        }
        var all = entries
        let account = uid.uuidString.lowercased()
        var ids = all[account] ?? []
        if !ids.contains(id) { ids.append(id) }
        all[account] = ids
        defaults.set(all, forKey: Self.key)
        await flush()
    }

    func flush() async {
        guard !flushing, let uid = client.auth.currentUser?.id else { return }
        guard NetworkPolicy.allows(.account, defaults: defaults) else {
            if !pendingIDs(userID: uid).isEmpty {
                FileLogger.log("CloudMeetingDeletion: deferred until Local only is disabled")
            }
            return
        }
        flushing = true
        defer { flushing = false }
        while let id = pendingIDs(userID: uid).first {
            do {
                try await removeRemote(id: id, userID: uid)
                var all = entries
                let account = uid.uuidString.lowercased()
                all[account] = (all[account] ?? []).filter { $0 != id }
                defaults.set(all, forKey: Self.key)
            } catch {
                FileLogger.log("CloudMeetingDeletion: deletion queued for retry, \(error)")
                return
            }
        }
    }

    private func requireAccount(_ uid: UUID) throws {
        guard client.auth.currentUser?.id == uid else { throw CancellationError() }
        guard NetworkPolicy.allows(.account, defaults: defaults) else {
            throw NetworkPolicy.Blocked(channel: .account)
        }
    }

    private struct ShareObjects: Decodable {
        let audio_key: String?
        let video_key: String?
    }

    private func removeRemote(id: String, userID: UUID) async throws {
        let owner = userID.uuidString.lowercased()
        try requireAccount(userID)
        let shares: [ShareObjects] = try await client.from("shares")
            .select("audio_key,video_key").eq("meeting_id", value: id)
            .eq("owner_id", value: owner).execute().value
        let paths = Array(Set(shares.flatMap { [$0.audio_key, $0.video_key].compactMap { $0 } }))
        if !paths.isEmpty {
            try requireAccount(userID)
            _ = try await client.storage.from("shares").remove(paths: paths)
        }
        // shares has no meeting foreign key, so it needs an explicit delete.
        // Keep its keys until Storage succeeds, otherwise a retry loses them.
        try requireAccount(userID)
        try await client.from("shares").delete().eq("meeting_id", value: id)
            .eq("owner_id", value: owner).execute()

        // List the recording prefix as well as deleting rows: metadata may be
        // missing after an interrupted upload. Removing each page avoids a cap.
        let prefix = "\(owner)/\(id)"
        while true {
            try requireAccount(userID)
            let files = try await client.storage.from("recordings")
                .list(path: prefix, options: SearchOptions(limit: 100, offset: 0))
            guard !files.isEmpty else { break }
            let paths = files.map { "\(prefix)/\($0.name)" }
            try requireAccount(userID)
            let removed = try await client.storage.from("recordings").remove(paths: paths)
            guard !removed.isEmpty else {
                throw NSError(domain: "CloudMeetingDeletion", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Storage deletion made no progress"])
            }
        }
        try requireAccount(userID)
        // FK cascades remove speakers, segments, summaries and recordings_meta.
        try await client.from("meetings").delete().eq("id", value: id)
            .eq("user_id", value: owner).execute()
    }
}
