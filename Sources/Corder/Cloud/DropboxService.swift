import Foundation

/// Long-lived archive for the audio/video that Corder produces. Files are
/// uploaded to a single Dropbox app folder (`/Corder/<meeting-id>/...`) and
/// then deleted locally. When the user later opens an archived meeting we ask
/// Dropbox for a short-lived `temporary_link` and stream from there.
///
/// Auth uses a refresh-token flow: the long-lived refresh token lives in
/// `~/.config/corder/dropbox.json`, and we exchange it for a fresh
/// short-lived access token whenever the cached one is about to expire.
actor DropboxService {
    static let shared = DropboxService()

    struct Credentials: Codable {
        let app_key: String
        let app_secret: String
        let refresh_token: String
        let remote_root: String?
    }

    enum DropboxError: Error, LocalizedError {
        case missingCredentials
        case http(Int, String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:    return "Dropbox credentials missing (~/.config/corder/dropbox.json)"
            case .http(let s, let body): return "Dropbox API \(s): \(body.prefix(280))"
            case .decode(let m):         return "Dropbox decode failed: \(m)"
            }
        }
    }

    private static let credsPath = ("~/.config/corder/dropbox.json" as NSString).expandingTildeInPath

    private var cachedAccessToken: String?
    private var cachedExpiry: Date?

    nonisolated var isConfigured: Bool {
        FileManager.default.fileExists(atPath: Self.credsPath)
    }

    private func loadCreds() throws -> Credentials {
        let url = URL(fileURLWithPath: Self.credsPath)
        guard let data = try? Data(contentsOf: url) else {
            throw DropboxError.missingCredentials
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    /// Returns the configured remote root (defaults to `/Corder`).
    func remoteRoot() async throws -> String {
        let c = try loadCreds()
        return c.remote_root ?? "/Corder"
    }

    /// Refresh-or-reuse access token. Dropbox short-lived tokens last ~4h,
    /// we refresh 60 s early to be safe.
    private func getAccessToken() async throws -> String {
        if let token = cachedAccessToken, let expiry = cachedExpiry, Date() < expiry {
            return token
        }
        let creds = try loadCreds()
        var req = URLRequest(url: URL(string: "https://api.dropbox.com/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        let body = "grant_type=refresh_token&refresh_token=\(creds.refresh_token)&client_id=\(creds.app_key)&client_secret=\(creds.app_secret)"
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DropboxError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw DropboxError.decode("token response: \(String(data: data, encoding: .utf8) ?? "")")
        }
        cachedAccessToken = token
        cachedExpiry = Date().addingTimeInterval(TimeInterval(expiresIn) - 60)
        return token
    }

    /// Uploads a local file to Dropbox. Routes through chunked
    /// upload_session/* APIs when the file is bigger than ~140 MB (Dropbox's
    /// one-shot limit is 150 MB, we leave headroom). Returns the canonical
    /// `path_display` of the uploaded file.
    func upload(localFile: URL, remotePath: String) async throws -> String {
        let token = try await getAccessToken()
        let attrs = try FileManager.default.attributesOfItem(atPath: localFile.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let oneshotLimit: Int64 = 140 * 1024 * 1024

        if size <= oneshotLimit {
            return try await uploadOneShot(localFile: localFile, remotePath: remotePath, token: token)
        } else {
            return try await uploadChunked(localFile: localFile, remotePath: remotePath, token: token)
        }
    }

    private func uploadOneShot(localFile: URL, remotePath: String, token: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let arg: [String: Any] = [
            "path": remotePath,
            "mode": "overwrite",
            "autorename": false,
            "mute": true
        ]
        let argData = try JSONSerialization.data(withJSONObject: arg)
        req.setValue(String(data: argData, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")

        // `upload(for:fromFile:)` streams the body straight off disk in
        // small chunks instead of buffering the whole file into RAM (which
        // `Data(contentsOf:)` + `httpBody` did). Critical for hour-long
        // recordings where the .wav reaches ~110 MB.
        let (respData, resp) = try await URLSession.shared.upload(for: req, fromFile: localFile)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DropboxError.http(status, String(data: respData, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let path = json["path_display"] as? String else {
            throw DropboxError.decode("upload response: \(String(data: respData, encoding: .utf8) ?? "")")
        }
        return path
    }

    private func uploadChunked(localFile: URL, remotePath: String, token: String) async throws -> String {
        let chunkSize = 8 * 1024 * 1024 // 8 MB
        let handle = try FileHandle(forReadingFrom: localFile)
        defer { try? handle.close() }
        let attrs = try FileManager.default.attributesOfItem(atPath: localFile.path)
        let totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        // 1. Start session — first chunk is sent in the start request.
        let first = handle.readData(ofLength: chunkSize)
        if first.isEmpty { throw DropboxError.decode("empty file") }

        var startReq = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload_session/start")!)
        startReq.httpMethod = "POST"
        startReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        startReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        startReq.timeoutInterval = 600
        let startArg = try JSONSerialization.data(withJSONObject: ["close": false])
        startReq.setValue(String(data: startArg, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
        startReq.httpBody = first

        let (startData, startResp) = try await URLSession.shared.data(for: startReq)
        var status = (startResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DropboxError.http(status, String(data: startData, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: startData) as? [String: Any],
              let sessionId = json["session_id"] as? String else {
            throw DropboxError.decode("start response: \(String(data: startData, encoding: .utf8) ?? "")")
        }

        var offset = Int64(first.count)

        // 2. Append chunks, finishing on the last one so we save a round-trip.
        while offset < totalSize {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            let isLast = (offset + Int64(chunk.count)) >= totalSize

            if isLast {
                var finReq = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload_session/finish")!)
                finReq.httpMethod = "POST"
                finReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                finReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                finReq.timeoutInterval = 600
                let finArg: [String: Any] = [
                    "cursor": ["session_id": sessionId, "offset": offset],
                    "commit": [
                        "path": remotePath,
                        "mode": "overwrite",
                        "autorename": false,
                        "mute": true
                    ]
                ]
                let finArgData = try JSONSerialization.data(withJSONObject: finArg)
                finReq.setValue(String(data: finArgData, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
                finReq.httpBody = chunk

                let (finData, finResp) = try await URLSession.shared.data(for: finReq)
                status = (finResp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    throw DropboxError.http(status, String(data: finData, encoding: .utf8) ?? "")
                }
                guard let fj = try JSONSerialization.jsonObject(with: finData) as? [String: Any],
                      let path = fj["path_display"] as? String else {
                    throw DropboxError.decode("finish response: \(String(data: finData, encoding: .utf8) ?? "")")
                }
                return path
            } else {
                var apReq = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload_session/append_v2")!)
                apReq.httpMethod = "POST"
                apReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                apReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                apReq.timeoutInterval = 600
                let apArg: [String: Any] = [
                    "cursor": ["session_id": sessionId, "offset": offset],
                    "close": false
                ]
                let apArgData = try JSONSerialization.data(withJSONObject: apArg)
                apReq.setValue(String(data: apArgData, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
                apReq.httpBody = chunk

                let (apData, apResp) = try await URLSession.shared.data(for: apReq)
                status = (apResp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    throw DropboxError.http(status, String(data: apData, encoding: .utf8) ?? "")
                }
                offset += Int64(chunk.count)
            }
        }
        throw DropboxError.decode("chunked upload didn't reach finish")
    }

    /// Direct-stream URL good for ~4 hours. Supports HTTP Range so HTML5
    /// `<video>` and `<audio>` elements can scrub.
    func getTemporaryLink(remotePath: String) async throws -> URL {
        let token = try await getAccessToken()
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_temporary_link")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": remotePath])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DropboxError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = json["link"] as? String,
              let url = URL(string: link) else {
            throw DropboxError.decode("temporary_link response: \(String(data: data, encoding: .utf8) ?? "")")
        }
        return url
    }

    /// Streams a Dropbox file straight to a local URL. Used by retranscribe
    /// when the audio mix has been archived, and by `Routes.hydrateDropboxFile`
    /// for media playback.
    ///
    /// Implementation: `URLSession.shared.download(for:)` writes to a
    /// temporary file as chunks come in, never buffering the whole body in
    /// memory. We then move that temp file into place. For hour-long
    /// recordings this keeps the resident-memory bump under a few MB
    /// instead of the full ~110 MB the previous `data(for:)` + `write(to:)`
    /// path consumed.
    func download(remotePath: String, to localURL: URL) async throws {
        let token = try await getAccessToken()
        var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 600
        let arg = try JSONSerialization.data(withJSONObject: ["path": remotePath])
        req.setValue(String(data: arg, encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")

        let (tempURL, resp) = try await URLSession.shared.download(for: req)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // download(for:) writes the error body to the temp file too —
            // surface it for diagnosis.
            let body = (try? String(contentsOf: tempURL, encoding: .utf8)) ?? ""
            throw DropboxError.http(status, body)
        }

        let dir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `move` won't overwrite — make sure the destination is clear first.
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)
    }

    /// Best-effort delete (used when a meeting is removed from the library).
    func deleteFile(remotePath: String) async {
        do {
            let token = try await getAccessToken()
            var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["path": remotePath])
            _ = try await URLSession.shared.data(for: req)
        } catch {
            FileLogger.log("Dropbox: delete \(remotePath) failed: \(error)")
        }
    }
}
