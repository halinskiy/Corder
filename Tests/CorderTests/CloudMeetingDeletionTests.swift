import Foundation
import Supabase
import Swifter
import XCTest
@testable import Corder

final class CloudMeetingDeletionTests: XCTestCase {
    @MainActor
    func testSyncOffDeletesStorageSharesAndMeeting() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.stop() }
        let client = try await fixture.client()
        let queue = CloudMeetingDeletion(client: client, defaults: fixture.defaults)
        fixture.defaults.set(false, forKey: "Corder.set.syncTranscripts")
        await queue.deleteMeeting(id: fixture.meetingID)
        XCTAssertTrue(queue.pendingIDs(userID: fixture.userID).isEmpty)
        XCTAssertEqual(fixture.events, ["list shares", "delete shares audio", "delete share rows",
                                       "list recordings", "delete recordings", "list recordings", "delete meeting"])
    }

    @MainActor
    func testLocalOnlyPersistsDeletionUntilAllowedEvenWithSyncOff() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.stop() }
        let client = try await fixture.client()
        fixture.defaults.set(false, forKey: "Corder.set.syncTranscripts")
        fixture.defaults.set(true, forKey: "Corder.set.localOnly")
        await CloudMeetingDeletion(client: client, defaults: fixture.defaults).deleteMeeting(id: fixture.meetingID)
        let restored = CloudMeetingDeletion(client: client, defaults: fixture.defaults)
        XCTAssertEqual(restored.pendingIDs(userID: fixture.userID), [fixture.meetingID])
        await restored.flush()
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.defaults.set(false, forKey: "Corder.set.localOnly")
        await restored.flush()
        XCTAssertTrue(restored.pendingIDs(userID: fixture.userID).isEmpty)
        XCTAssertEqual(fixture.events.last, "delete meeting")
    }

    @MainActor
    func testFailedDeletionStaysQueuedAndDoesNotCrossAccounts() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.stop() }
        let client = try await fixture.client()
        let queue = CloudMeetingDeletion(client: client, defaults: fixture.defaults)
        fixture.failStorage = true
        await queue.deleteMeeting(id: fixture.meetingID)
        XCTAssertEqual(queue.pendingIDs(userID: fixture.userID), [fixture.meetingID])
        XCTAssertFalse(fixture.events.contains("delete meeting"))
        let anotherClient = try await fixture.client(userID: UUID())
        await CloudMeetingDeletion(client: anotherClient, defaults: fixture.defaults).flush()
        XCTAssertEqual(queue.pendingIDs(userID: fixture.userID), [fixture.meetingID])
        fixture.failStorage = false
        await queue.flush()
        XCTAssertTrue(queue.pendingIDs(userID: fixture.userID).isEmpty)
        XCTAssertEqual(fixture.events.last, "delete meeting")
    }

    @MainActor
    func testEnablingLocalOnlyMidDeleteKeepsQueueAndStopsNextRequest() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.stop() }
        let client = try await fixture.client()
        let queue = CloudMeetingDeletion(client: client, defaults: fixture.defaults)
        fixture.blockAfterRead = true
        await queue.deleteMeeting(id: fixture.meetingID)
        XCTAssertEqual(fixture.events, ["list shares"])
        XCTAssertEqual(queue.pendingIDs(userID: fixture.userID), [fixture.meetingID])
    }
}

private final class DeletionFixture: @unchecked Sendable {
    let server = HttpServer()
    let userID = UUID()
    let meetingID = UUID().uuidString
    let suite = "CorderDeletionTests.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    var events: [String] = []
    var failStorage = false
    var blockAfterRead = false
    var hasRecording = true
    var sessions: [URLSession] = []

    init() throws {
        defaults.set(false, forKey: "Corder.set.localOnly")
        server.listenAddressIPv4 = "127.0.0.1"
        server.post["/auth/v1/token"] = { request in
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: String]
            return .ok(.json([
                "access_token": "test-token", "token_type": "bearer", "expires_in": 3600,
                "expires_at": Date().timeIntervalSince1970 + 3600,
                "refresh_token": "refresh", "user": ["id": body["refresh_token"]!, "aud": "authenticated",
                    "app_metadata": [:], "user_metadata": [:], "created_at": "2026-10-26T00:00:00Z",
                    "updated_at": "2026-10-26T00:00:00Z"]
            ]))
        }
        server.get["/rest/v1/shares"] = { [self] request in
            XCTAssertTrue(request.queryParams.contains { $0 == "meeting_id" && $1 == "eq.\(meetingID)" })
            events.append("list shares")
            if blockAfterRead { defaults.set(true, forKey: "Corder.set.localOnly") }
            return .ok(.json([["audio_key": "\(userID.uuidString.lowercased())/\(meetingID).m4a"]]))
        }
        server.delete["/storage/v1/object/shares"] = { [self] request in
            events.append("delete shares audio")
            if failStorage { return .internalServerError }
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: [String]]
            XCTAssertEqual(body["prefixes"], ["\(userID.uuidString.lowercased())/\(meetingID).m4a"])
            return .ok(.json(body["prefixes"]!.map { ["name": $0] }))
        }
        server.delete["/rest/v1/shares"] = { [self] _ in
            events.append("delete share rows")
            return .ok(.json([]))
        }
        server.post["/storage/v1/object/list/recordings"] = { [self] request in
            events.append("list recordings")
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: Any]
            XCTAssertEqual(body["prefix"] as? String, "\(userID.uuidString.lowercased())/\(meetingID)")
            return .ok(.json(hasRecording ? [["name": "mix.wav", "id": UUID().uuidString]] : []))
        }
        server.delete["/storage/v1/object/recordings"] = { [self] request in
            events.append("delete recordings")
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: [String]]
            XCTAssertEqual(body["prefixes"], ["\(userID.uuidString.lowercased())/\(meetingID)/mix.wav"])
            hasRecording = false
            return .ok(.json(body["prefixes"]!.map { ["name": $0] }))
        }
        server.delete["/rest/v1/meetings"] = { [self] request in
            XCTAssertTrue(request.queryParams.contains { $0 == "id" && $1 == "eq.\(meetingID)" })
            events.append("delete meeting")
            return .ok(.json([]))
        }
        try server.start(0, forceIPv4: true)
    }

    func client(userID: UUID? = nil) async throws -> SupabaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupabasePolicyProtocol.self]
        let session = URLSession(configuration: config)
        sessions.append(session)
        let client = SupabaseClient(supabaseURL: URL(string: "http://127.0.0.1:\(try server.port())")!,
                                    supabaseKey: "test-key", options: .init(
                                        auth: .init(storage: DeletionAuthStorage(), autoRefreshToken: false),
                                        global: .init(session: session)))
        _ = try await client.auth.refreshSession(refreshToken: (userID ?? self.userID).uuidString)
        return client
    }

    func stop() {
        sessions.forEach { $0.invalidateAndCancel() }
        server.stop()
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class DeletionAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
