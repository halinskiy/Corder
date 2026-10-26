import Foundation
import GRDB
import Swifter
import WebKit
import XCTest
@testable import Corder

final class HostGuardTests: XCTestCase {
    private func makeServer(port: @escaping () -> UInt16) throws -> HttpServer {
        let dbq = try DatabaseQueue()
        try Migrations.register().migrate(dbq)
        let server = HttpServer()
        Routes.register(server: server, repo: MeetingRepository(dbq: dbq), port: port)
        return server
    }

    private func response(_ server: HttpServer, method: String = "GET", path: String = "/api/meetings",
                          host: String?, origin: String? = nil) -> HttpResponse {
        let request = HttpRequest()
        request.method = method
        request.path = path
        request.headers["host"] = host
        request.headers["origin"] = origin
        let (_, handler) = server.dispatch(request)
        return handler(request)
    }

    func test_allowedHosts() {
        for host in ["127.0.0.1:54321", "localhost:54321", "[::1]:54321", "LOCALHOST:54321",
                     "127.0.0.1", "localhost", "LOCALHOST"] {
            XCTAssertTrue(Routes.isAllowedHost(host, port: 54321), host)
        }
    }

    func test_rejectedHosts() {
        let hosts: [String?] = [nil, "", "evil.example:54321", "127.0.0.1.evil.com:54321",
                               "localhost.evil.com:54321", "127.0.0.1:54322", "localhost:54322",
                               "[::1]:54322", "[::1]", "::1:54321", "0.0.0.0:54321",
                               "127.1:54321", "localhost.:54321", "localhost:",
                               "localhost:054321", "localhost:54321@evil.example", "http://localhost:54321",
                               "localhost:54321/path", "localhost:54321, evil.example:54321",
                               " localhost:54321", "localhost:54321 "]
        for host in hosts {
            XCTAssertFalse(Routes.isAllowedHost(host, port: 54321), host ?? "<missing>")
        }
    }

    func test_unboundPortFailsClosed() {
        for host in ["127.0.0.1", "localhost", "127.0.0.1:0", "[::1]:0"] {
            XCTAssertFalse(Routes.isAllowedHost(host, port: 0), host)
        }
    }

    func test_rebindingRequestIsRejected() throws {
        let server = try makeServer(port: { 54321 })
        XCTAssertEqual(response(server, host: "evil.example:54321").statusCode, 421)
    }

    func test_allMethodsAndPathsAreGuardedBeforeCSRF() throws {
        let server = try makeServer(port: { 54321 })
        let paths = ["/", "/mcp", "/assets/index.js", "/auth/callback", "/api/meetings",
                     "/api/meetings/test/transcript.txt", "/api/meetings/test/transcript.md",
                     "/api/meetings/test/transcript.json", "/api/meetings/test/audio",
                     "/api/meetings/test/video", "/api/meetings/test/bundle.zip",
                     "/api/search", "/api/calendar/upcoming", "/api/settings", "/unknown"]
        for method in ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE"] {
            for path in paths {
                for host in ["evil.example:54321", nil] {
                    XCTAssertEqual(response(server, method: method, path: path, host: host,
                                            origin: "http://evil.example:54321").statusCode, 421,
                                   "\(method) \(path) Host=\(host ?? "<missing>")")
                }
            }
        }
    }

    func test_hostGuardIsFirstAndCSRFStillRejectsForeignOrigin() throws {
        let server = HttpServer()
        server.middleware.append { _ in .ok(.text("must not bypass Host guard")) }
        let dbq = try DatabaseQueue()
        Routes.register(server: server, repo: MeetingRepository(dbq: dbq), port: { 54321 })
        XCTAssertEqual(response(server, host: "evil.example:54321").statusCode, 421)

        let guarded = try makeServer(port: { 54321 })
        guarded.post["/probe"] = { _ in .ok(.text("ok")) }
        XCTAssertEqual(response(guarded, method: "POST", path: "/probe", host: "localhost:54321",
                                origin: "http://evil.example").statusCode, 403)
        XCTAssertEqual(response(guarded, method: "POST", path: "/probe", host: "localhost:54321",
                                origin: "http://localhost:54321").statusCode, 200)
        XCTAssertEqual(response(guarded, method: "POST", path: "/probe", host: "localhost:54321").statusCode, 200)
    }

    private func startProbeServer() throws -> (HttpServer, UInt16) {
        let server = HttpServer()
        let dbq = try DatabaseQueue()
        Routes.register(server: server, repo: MeetingRepository(dbq: dbq), port: { [weak server] in
            guard let server, let port = try? server.port() else { return 0 }
            return UInt16(exactly: port) ?? 0
        })
        server.get["/probe"] = { .ok(.text($0.headers["host"] ?? "<missing>")) }
        server.get["/auth/callback"] = { .ok(.text($0.headers["host"] ?? "<missing>")) }
        server.get["/oauth-redirect"] = { _ in
            .raw(302, "Found", ["Location": "/auth/callback"], nil)
        }
        server.listenAddressIPv4 = "127.0.0.1"
        try server.start(0, forceIPv4: true)
        return (server, try UInt16(server.port()))
    }

    func test_liveServerAcceptsURLSessionAndRejectsRebinding() async throws {
        let (server, port) = try startProbeServer()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/probe"))
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "127.0.0.1:\(port)")

        var request = URLRequest(url: url)
        request.setValue("evil.example:\(port)", forHTTPHeaderField: "Host")
        let (_, rejected) = try await session.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 421)
    }

    func test_liveServerAcceptsCurlHostAndRejectsMissingHost() throws {
        let (server, port) = try startProbeServer()
        defer { server.stop() }
        for (headers, expected) in [([], "127.0.0.1:\(port)\n200"),
                                    (["--header", "Host: localhost"], "localhost\n200"),
                                    (["--header", "Host: evil.example:\(port)"], "\n421"),
                                    (["--header", "Host:"], "\n421")] {
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["--silent", "--show-error", "--noproxy", "*", "--max-time", "5", "--http1.1",
                              "--write-out", "\n%{http_code}"] + headers + ["http://127.0.0.1:\(port)/probe"]
            let output = Pipe()
            curl.standardOutput = output
            try curl.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            curl.waitUntilExit()
            XCTAssertEqual(curl.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
        }
    }

    @MainActor
    func test_webViewSendsHostIncludingOAuthRedirect() async throws {
        let (server, port) = try startProbeServer()
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        for path in ["/probe", "/oauth-redirect"] {
            let loaded = expectation(description: path)
            let observer = HostProbeNavigation(loaded: loaded)
            webView.navigationDelegate = observer
            webView.load(URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))))
            await fulfillment(of: [loaded], timeout: 15)
            XCTAssertNil(observer.error)
            let body = try await webView.evaluateJavaScript("document.body.innerText") as? String
            XCTAssertEqual(body?.trimmingCharacters(in: .whitespacesAndNewlines), "127.0.0.1:\(port)")
            if path == "/oauth-redirect" { XCTAssertEqual(webView.url?.path, "/auth/callback") }
        }
    }
}

@MainActor
private final class HostProbeNavigation: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    var error: Error?

    init(loaded: XCTestExpectation) { self.loaded = loaded }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        loaded.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        loaded.fulfill()
    }
}
