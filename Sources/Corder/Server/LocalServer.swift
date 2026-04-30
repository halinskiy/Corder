import Foundation
import Swifter

final class LocalServer {
    private let server = HttpServer()
    private(set) var port: UInt16 = 0

    func start(routes: (HttpServer) -> Void) throws {
        routes(server)
        try server.start(0, forceIPv4: true, priority: .userInitiated)
        port = try UInt16(server.port())
    }

    func stop() {
        server.stop()
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }
}
