import Foundation
import CryptoKit
import IOKit

/// Pseudonymous diagnostic telemetry, ON by default, optional in Settings.
/// One daily ping: email SHA-256 when signed in, random install ID otherwise;
/// device/version/tier and aggregate reliability counts, no meeting content.
@MainActor
enum TelemetryService {
    private static let endpoint = URL(string: "https://corder-api.empqwork.workers.dev/telemetry")!
    private static let lastSentKey = "Corder.telemetry.lastSentAt"
    private static let oneDay: TimeInterval = 24 * 3600
    private static let installIDKey = "Corder.telemetry.installId"
    /// Random id made once per install, used while signed out. Before this
    /// every guest hashed an empty email and collapsed into one id, so the
    /// device count in the admin stats was wrong by the number of guests.
    private static var installID: String {
        if let id = UserDefaults.standard.string(forKey: installIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: installIDKey)
        return id
    }

    // MARK: - Reliability counters (the whole point: measure far-end loss)
    //
    // Rolling, anonymous integer counters bumped by the capture pipeline.
    // No identifiers, no content. Read + reset into each daily ping so we
    // can finally SEE how often the other person is lost, split by BT.
    // Thread-safe via UserDefaults' own atomicity (single-key int writes).
    enum Counter: String {
        case recordings        = "Corder.tele.recordings"        // total stopped recordings
        case btRecordings      = "Corder.tele.btRecordings"      // output was Bluetooth at start
        case farEndLost        = "Corder.tele.farEndLost"        // system track came out silent
        case btFarEndLost      = "Corder.tele.btFarEndLost"      // silent AND Bluetooth
        case micLost           = "Corder.tele.micLost"           // mic track came out silent, far end fine
        case tapRebuilds       = "Corder.tele.tapRebuilds"       // watchdog rebuilt the tap
    }
    /// Bump a reliability counter by one. Safe to call from any actor
    /// it's a plain UserDefaults integer increment.
    nonisolated static func bump(_ c: Counter) {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: c.rawValue) + 1, forKey: c.rawValue)
    }
    nonisolated static func drainCounters(in d: UserDefaults = .standard) -> [String: Int] {
        var out: [String: Int] = [:]
        for c in [Counter.recordings, .btRecordings, .farEndLost, .btFarEndLost, .tapRebuilds] {
            out[c.rawValue.replacingOccurrences(of: "Corder.tele.", with: "")] = d.integer(forKey: c.rawValue)
            d.removeObject(forKey: c.rawValue)   // reset the window after reading
        }
        return out
    }

    /// Call from `applicationDidFinishLaunching` AND from a 1-hour
    /// timer. Returns immediately if telemetry is off or the 24h
    /// window hasn't elapsed yet.
    static func tickIfDue() {
        guard NetworkPolicy.allows(.telemetry) else { return }
        let last = UserDefaults.standard.double(forKey: lastSentKey)
        let now = Date().timeIntervalSince1970
        if now - last < oneDay { return }
        UserDefaults.standard.set(now, forKey: lastSentKey)
        Task { await send() }
    }

    private static func send() async {
        guard NetworkPolicy.allows(.telemetry) else { return }
        // Signed in: a stable hash of the email (one id per account across
        // Macs). Signed out: the per-install id.
        let anonID: String
        if let email = AppSettings.userEmail, !email.isEmpty {
            anonID = sha256(email.lowercased())
        } else {
            anonID = installID
        }
        FileLogger.log("TelemetryService: daily ping as \(anonID.prefix(8)) (\(AppSettings.userEmail == nil ? "guest, install id" : "account hash"))")
        let macModel = readMacModel()
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let tier = AppSettings.userTier.rawValue
        let sinceMs = Int64((Date().timeIntervalSince1970 - oneDay) * 1000)
        let recent = ((try? AppContext.shared.repo.listMeetings()) ?? []).filter { $0.startedAt >= sinceMs }
        let payload = TelemetryPayload.make(id: anonID, appVersion: "\(version) (\(build))",
            macOS: macOS, macModel: macModel, ramGB: ramGB, tier: tier,
            meetings: recent, counters: drainCounters())
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15
        _ = try? await NetworkPolicy.data(for: req, channel: .telemetry)
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func readMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}
