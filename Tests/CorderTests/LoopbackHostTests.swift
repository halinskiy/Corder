import XCTest
@testable import Corder

final class LoopbackHostTests: XCTestCase {
    func test_loopback_hosts_pass() {
        for host in ["127.0.0.1:49152", "127.0.0.1", "localhost:49152", "LOCALHOST:1", "[::1]:49152"] {
            XCTAssertTrue(Routes.isLoopbackHost(host), host)
        }
    }

    func test_rebinding_and_lookalike_hosts_fail() {
        for host in ["evil.example:49152", "evil.example", "127.0.0.1.evil.com:49152",
                     "localhost.evil.com", "[::1].evil.com", "0.0.0.0:49152", ""] {
            XCTAssertFalse(Routes.isLoopbackHost(host), host)
        }
        XCTAssertFalse(Routes.isLoopbackHost(nil))
    }
}
