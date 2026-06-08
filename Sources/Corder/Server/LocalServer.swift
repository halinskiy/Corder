import Foundation
import Swifter

final class LocalServer {
    private let server = HttpServer()
    private(set) var port: UInt16 = 0

    func start(routes: (HttpServer) -> Void) throws {
        routes(server)
        // Bind to LOOPBACK ONLY. Swifter defaults to INADDR_ANY (0.0.0.0)
        // when no listen address is set, which would expose the entire
        // unauthenticated /api/* surface — including /api/account/mcp-token
        // (the user's live Supabase JWT) — to anyone on the same LAN. The
        // app only ever connects to itself via 127.0.0.1, so loopback is
        // the correct and sufficient bind.
        server.listenAddressIPv4 = "127.0.0.1"
        // Prefer the SAME port we used last launch. Random-port
        // allocation broke OAuth: Supabase's `redirectTo` baked the
        // port at click-time, the browser later opened
        // `127.0.0.1:OLD_PORT/auth/callback?code=...`, but the next
        // launch had a different port and the callback hit nothing.
        // We persist the last successful port and try it first;
        // if it's taken we fall back to a fresh OS-assigned port.
        let storedKey = "Corder.localServerPort"
        let stored = UInt16(UserDefaults.standard.integer(forKey: storedKey))
        do {
            if stored != 0 {
                try server.start(in_port_t(stored), forceIPv4: true, priority: .userInitiated)
            } else {
                try server.start(0, forceIPv4: true, priority: .userInitiated)
            }
        } catch {
            // Port in use → take whatever the OS gives us.
            try server.start(0, forceIPv4: true, priority: .userInitiated)
        }
        port = try UInt16(server.port())
        UserDefaults.standard.set(Int(port), forKey: storedKey)
    }

    func stop() {
        server.stop()
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }
}
