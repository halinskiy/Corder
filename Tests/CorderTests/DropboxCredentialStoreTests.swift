import XCTest
@testable import Corder

final class DropboxCredentialStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var secrets: MemorySecrets!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corder-dropbox-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("dropbox.json")
        secrets = MemorySecrets()
    }

    override func tearDownWithError() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
    }

    private func writeConfig(_ values: [String: String]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
        try data.write(to: fileURL)
        return data
    }

    private var legacy: [String: String] {
        ["app_key": "test-app", "app_secret": "test-secret", "refresh_token": "test-refresh",
         "remote_root": "/Archive"]
    }

    private func load() throws -> DropboxService.Credentials {
        try DropboxCredentialStore(fileURL: fileURL, secrets: secrets).load()
    }

    private func assertCredentials(_ credentials: DropboxService.Credentials,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(credentials.app_key, "test-app", file: file, line: line)
        XCTAssertEqual(credentials.app_secret, "test-secret", file: file, line: line)
        XCTAssertEqual(credentials.refresh_token, "test-refresh", file: file, line: line)
        XCTAssertEqual(credentials.remote_root, "/Archive", file: file, line: line)
    }

    func testMigratesOnlyAfterBothSecretsReadBackAndReopensWith0600() throws {
        let original = try writeConfig(legacy)
        secrets.beforeOperation = {
            XCTAssertEqual(try Data(contentsOf: self.fileURL), original)
        }

        assertCredentials(try load())
        XCTAssertEqual(secrets.values, ["app_secret": "test-secret", "refresh_token": "test-refresh"])
        XCTAssertEqual(Set(secrets.readKeys), Set(["app_secret", "refresh_token"]))
        let cleaned = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: String]
        XCTAssertEqual(cleaned, ["app_key": "test-app", "remote_root": "/Archive"])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["dropbox.json"])

        secrets.beforeOperation = nil
        let writes = secrets.writeKeys.count
        assertCredentials(try load())
        XCTAssertEqual(secrets.writeKeys.count, writes, "reading migrated config must not rewrite Keychain")
    }

    func testWriteFailureKeepsOriginalBytesAndUsesFileCredentialsThenRetries() throws {
        let original = try writeConfig(legacy)
        secrets.failedWriteKey = "refresh_token"
        assertCredentials(try load())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(secrets.values["app_secret"], "test-secret")

        secrets.failedWriteKey = nil
        assertCredentials(try load())
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains("refresh_token"))
    }

    func testReadFailureKeepsOriginalBytesAndUsesFileCredentials() throws {
        let original = try writeConfig(legacy)
        secrets.failReads = true
        assertCredentials(try load())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testReadbackMismatchOrMissingValueKeepsOriginalBytes() throws {
        let original = try writeConfig(legacy)
        for readback in ["different-value", nil] as [String?] {
            secrets.overrideReadback = true
            secrets.readback = readback
            assertCredentials(try load())
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }
    }

    func testUsesKeychainWithSanitizedConfigWithoutRewritingFile() throws {
        let original = try writeConfig(["app_key": "test-app", "remote_root": "/Archive"])
        secrets.values = ["app_secret": "test-secret", "refresh_token": "test-refresh"]
        assertCredentials(try load())
        XCTAssertTrue(secrets.writeKeys.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testPartialLegacyConfigCombinesFileAndKeychainThenMigrates() throws {
        _ = try writeConfig(["app_key": "test-app", "app_secret": "test-secret", "remote_root": "/Archive"])
        secrets.values["refresh_token"] = "test-refresh"
        assertCredentials(try load())
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains("app_secret"))
    }

    func testLegacyValuesReplaceStaleKeychainValues() throws {
        _ = try writeConfig(legacy)
        secrets.values = ["app_secret": "old-secret", "refresh_token": "old-refresh"]
        assertCredentials(try load())
        XCTAssertEqual(secrets.values["app_secret"], "test-secret")
        XCTAssertEqual(secrets.values["refresh_token"], "test-refresh")
    }

    func testRewriteFailureKeepsOriginalFileAndCredentialsAndCanRetry() throws {
        let original = try writeConfig(legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        assertCredentials(try load())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["dropbox.json"])

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        assertCredentials(try load())
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains("app_secret"))
    }

    func testMissingSecretsOrUnavailableKeychainWithoutLegacyCopyFailsWithoutChangingFile() throws {
        let original = try writeConfig(["app_key": "test-app"])
        XCTAssertThrowsError(try load())
        secrets.failReads = true
        XCTAssertThrowsError(try load())
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertTrue(secrets.writeKeys.isEmpty)
    }

    func testMissingOrMalformedConfigDoesNotTouchKeychain() throws {
        XCTAssertThrowsError(try load())
        try Data("{".utf8).write(to: fileURL)
        XCTAssertThrowsError(try load())
        XCTAssertTrue(secrets.readKeys.isEmpty)
        XCTAssertTrue(secrets.writeKeys.isEmpty)
    }

    func testAbsentRemoteRootRemainsOptionalAfterMigration() throws {
        var config = legacy
        config.removeValue(forKey: "remote_root")
        _ = try writeConfig(config)
        XCTAssertNil(try load().remote_root)
        let cleaned = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: String]
        XCTAssertEqual(cleaned, ["app_key": "test-app"])
    }
}

private final class MemorySecrets: DropboxSecretStore {
    enum Failure: Error { case unavailable }
    var values: [String: String] = [:]
    var readKeys: [String] = []
    var writeKeys: [String] = []
    var failedWriteKey: String?
    var failReads = false
    var overrideReadback = false
    var readback: String?
    var beforeOperation: (() throws -> Void)?

    func read(_ key: String) throws -> String? {
        try beforeOperation?()
        readKeys.append(key)
        if failReads { throw Failure.unavailable }
        return overrideReadback ? readback : values[key]
    }

    func write(_ value: String, for key: String) throws {
        try beforeOperation?()
        writeKeys.append(key)
        if failedWriteKey == key { throw Failure.unavailable }
        values[key] = value
    }
}
