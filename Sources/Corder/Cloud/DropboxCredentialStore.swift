import Foundation
import Darwin
import LocalAuthentication
import Security

protocol DropboxSecretStore {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
}

struct DropboxCredentialStore {
    let fileURL: URL
    let secrets: any DropboxSecretStore

    private struct Configuration: Codable {
        let app_key: String
        var app_secret: String?
        var refresh_token: String?
        let remote_root: String?
    }

    private enum MigrationError: Error {
        case readbackMismatch
    }

    func load() throws -> DropboxService.Credentials {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw DropboxService.DropboxError.missingCredentials
        }
        var config = try JSONDecoder().decode(Configuration.self, from: data)
        // The file wins until migration finishes, including after a partial write
        // or when the user replaces legacy credentials during setup.
        guard let appSecret = try config.app_secret ?? secrets.read("app_secret"),
              let refreshToken = try config.refresh_token ?? secrets.read("refresh_token") else {
            throw DropboxService.DropboxError.missingCredentials
        }
        let credentials = DropboxService.Credentials(app_key: config.app_key, app_secret: appSecret,
                                                     refresh_token: refreshToken, remote_root: config.remote_root)

        if config.app_secret != nil || config.refresh_token != nil {
            do {
                if let value = config.app_secret { try secrets.write(value, for: "app_secret") }
                if let value = config.refresh_token { try secrets.write(value, for: "refresh_token") }
                let storedSecret = try secrets.read("app_secret")
                let storedToken = try secrets.read("refresh_token")
                guard storedSecret == appSecret, storedToken == refreshToken else {
                    throw MigrationError.readbackMismatch
                }
                config.app_secret = nil
                config.refresh_token = nil
                try replaceConfig(with: JSONEncoder().encode(config))
            } catch {
                // Never remove the fallback until every secret is verified and
                // the atomic replacement succeeds. Retry on the next read.
            }
        }
        return credentials
    }

    private func replaceConfig(with data: Data) throws {
        var template = Array(fileURL.deletingLastPathComponent()
            .appendingPathComponent(".dropbox-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw posixError() }
        let temporaryPath = String(cString: template)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlink(temporaryPath)
        }
        // Set permissions before writing or publishing the new inode. A chmod
        // after Data.write(.atomic) leaves a window with inherited permissions.
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporaryPath, fileURL.path) == 0 else { throw posixError() }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct DropboxKeychainSecrets: DropboxSecretStore {
    static let service = "com.3mpq.Corder.dropbox"

    private struct KeychainError: Error {
        let status: OSStatus
    }

    private func query(_ key: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            // Request noninteractive authentication where supported by Keychain.
            kSecUseAuthenticationContext as String: context
        ]
    }

    func read(_ key: String) throws -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    func write(_ value: String, for key: String) throws {
        let request = query(key)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = request.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}
