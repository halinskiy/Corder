import Foundation
import Swifter
import XCTest
import Supabase
@testable import Corder

final class SupabaseTransportTests: XCTestCase {
    func testSDKRefreshAndPostgRESTForFreeAndPaidSessions() async throws {
        let server = HttpServer()
        server.listenAddressIPv4 = "127.0.0.1"
        server.post["/auth/v1/token"] = { request in
            XCTAssertEqual(request.headers["apikey"], "test-key")
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: String]
            let tier = body["refresh_token"]!
            XCTAssertTrue(["free", "pro"].contains(tier))
            return .ok(.json([
                "access_token": "token-" + tier, "token_type": "bearer", "expires_in": 3600,
                "expires_at": Date().timeIntervalSince1970 + 3600, "refresh_token": "refreshed-" + tier,
                "user": ["id": "00000000-0000-0000-0000-000000000001", "aud": "authenticated",
                         "app_metadata": ["tier": tier], "user_metadata": [:],
                         "created_at": "2026-10-26T00:00:00Z", "updated_at": "2026-10-26T00:00:00Z"]
            ]))
        }
        server.patch["/rest/v1/meetings"] = { request in
            XCTAssertEqual(request.headers["apikey"], "test-key")
            XCTAssertTrue(["Bearer token-free", "Bearer token-pro"].contains(request.headers["authorization"] ?? ""))
            let body = try! JSONSerialization.jsonObject(with: Data(request.body)) as! [String: String]
            XCTAssertEqual(body, ["title": "Meeting title"])
            return .ok(.json([]))
        }
        let audio = Data(repeating: 37, count: 256 * 1024)
        server.post["/storage/v1/object/recordings/audio.wav"] = { request in
            XCTAssertEqual(request.headers["apikey"], "test-key")
            XCTAssertTrue(["Bearer token-free", "Bearer token-pro"].contains(request.headers["authorization"] ?? ""))
            XCTAssertEqual(request.headers["x-upsert"], "true")
            XCTAssertNotNil(Data(request.body).range(of: audio))
            return .ok(.json(["Key": "recordings/audio.wav", "Id": "test-upload"]))
        }
        server.get["/rest/v1/denied"] = { _ in
            .raw(403, "Forbidden", ["Content-Type": "application/json"]) { writer in
                try writer.write(Data(#"{"code":"42501","message":"denied","details":null,"hint":null}"#.utf8))
            }
        }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupabasePolicyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(
            supabaseURL: URL(string: "http://127.0.0.1:\(try server.port())")!, supabaseKey: "test-key",
            options: .init(auth: .init(storage: MemoryAuthStorage(), autoRefreshToken: false), global: .init(session: session)))
        for tier in ["free", "pro"] {
            let refreshed = try await client.auth.refreshSession(refreshToken: tier)
            XCTAssertEqual(refreshed.accessToken, "token-" + tier)
            XCTAssertEqual(refreshed.refreshToken, "refreshed-" + tier)
            try await client.from("meetings").update(["title": "Meeting title"]).eq("id", value: "test").execute()
            let uploaded = try await client.storage.from("recordings").upload("audio.wav", data: audio, options: .init(upsert: true))
            XCTAssertEqual(uploaded.fullPath, "recordings/audio.wav")
            do {
                try await client.from("denied").select().execute()
                XCTFail("PostgREST error must propagate")
            } catch let error as PostgrestError {
                XCTAssertEqual(error.code, "42501")
            }
        }
    }

    func testLocalOnlyRejectsWithoutSendingOrSigningOut() async throws {
        let key = "Corder.set.localOnly"
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(saved, forKey: key) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupabasePolicyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for path in ["/auth/v1/token", "/rest/v1/meetings", "/storage/v1/object/recordings/audio.wav"] {
            do {
                _ = try await session.data(from: URL(string: "http://127.0.0.1:9" + path)!)
                XCTFail("Local only must reject requests")
            } catch {
                XCTAssertEqual((error as NSError).domain, (NetworkPolicy.Blocked(channel: .account) as NSError).domain)
                XCTAssertFalse(AuthSessionLoss.isDefinitive(error))
            }
        }
    }

    func testCancellationReachesNativeRequest() async throws {
        let started = expectation(description: "request reached server")
        let server = HttpServer()
        server.listenAddressIPv4 = "127.0.0.1"
        server.get["/slow"] = { _ in
            started.fulfill()
            Thread.sleep(forTimeInterval: 1)
            return .ok(.text("late"))
        }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupabasePolicyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(try server.port())/slow")!
        let task = Task { try await session.data(from: url) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
    }

    func testRedirectRemainsUnderTheCallingSessionDelegate() async throws {
        let server = HttpServer()
        server.listenAddressIPv4 = "127.0.0.1"
        server.post["/start"] = { _ in .raw(307, "Temporary Redirect", ["Location": "/destination"], nil) }
        server.post["/destination"] = { _ in .ok(.text("followed")) }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupabasePolicyProtocol.self]
        let delegate = RejectRedirect()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(try server.port())/start")!)
        request.httpMethod = "POST"
        request.httpBody = Data("payload".utf8)
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 307)
        XCTAssertEqual(response.url?.path, "/start")
        XCTAssertEqual(delegate.redirects, 1)
    }

    func testUploadPreservesBodyAndHeaders() async throws {
        let payload = Data(repeating: 42, count: 8 * 1024 * 1024)
        let server = HttpServer()
        server.listenAddressIPv4 = "127.0.0.1"
        server.post["/storage/v1/object/recordings/audio.wav"] = { request in
            XCTAssertEqual(Data(request.body), payload)
            XCTAssertEqual(request.headers["authorization"], "Bearer test-token")
            XCTAssertEqual(request.headers["apikey"], "test-key")
            XCTAssertEqual(request.headers["x-upsert"], "true")
            return .ok(.text("uploaded"))
        }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SupabasePolicyProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(try server.port())/storage/v1/object/recordings/audio.wav")!)
        request.httpMethod = "POST"
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.setValue("test-key", forHTTPHeaderField: "apikey")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await session.upload(for: request, from: payload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "uploaded")
    }
}

private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}

private final class RejectRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        completionHandler(nil)
    }
}
