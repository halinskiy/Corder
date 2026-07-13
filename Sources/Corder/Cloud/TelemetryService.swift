import Foundation
import CryptoKit
import IOKit

/// Opt-in diagnostic telemetry. Default OFF, toggled on by the
/// user in Settings ("Help improve Corder"). Once on, fires once
/// per 24h from `tick()` (called on app launch and every hour
/// while the app is alive). Payload is intentionally narrow:
///   • anonymous_id = SHA-256(email lowercased)
///   • app version, macOS version, Mac model, RAM gigabytes, tier
///   • events[], counts of meetings by status + provider used.
///
/// Explicitly NOT included: transcript text, meeting titles,
/// speaker names, audio, IP address (Cloudflare strips it from
/// the request body server-side; the Worker doesn't log it).
@MainActor
enum TelemetryService {
    private static let endpoint = URL(string: "https://corder-api.empqwork.workers.dev/telemetry")!
    private static let lastSentKey = "Corder.telemetry.lastSentAt"
    private static let oneDay: TimeInterval = 24 * 3600

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
        case tapRebuilds       = "Corder.tele.tapRebuilds"       // watchdog rebuilt the tap
    }
    /// Bump a reliability counter by one. Safe to call from any actor
    /// it's a plain UserDefaults integer increment.
    nonisolated static func bump(_ c: Counter) {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: c.rawValue) + 1, forKey: c.rawValue)
    }
    private static func drainCounters() -> [String: Int] {
        let d = UserDefaults.standard
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
        guard AppSettings.telemetryEnabled else { return }
        let last = UserDefaults.standard.double(forKey: lastSentKey)
        let now = Date().timeIntervalSince1970
        if now - last < oneDay { return }
        UserDefaults.standard.set(now, forKey: lastSentKey)
        Task { await send() }
    }

    private static func send() async {
        let email = AppSettings.userEmail ?? ""
        let anonID = sha256(email.lowercased())
        let macModel = readMacModel()
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let tier = AppSettings.userTier.rawValue
        let events = await collectEvents()
        let payload: [String: Any] = [
            "anonymous_id": anonID,
            "app_version": "\(version) (\(build))",
            "macos_version": macOS,
            "mac_model": macModel,
            "ram_gb": ramGB,
            "tier": tier,
            "events": events,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Aggregate counts over the last 24h of meetings: how many
    /// ended `ready`, how many `failed`, average duration. Just
    /// numbers, no per-meeting identifiers. Safe under the
    /// privacy contract above.
    private static func collectEvents() async -> [[String: Any]] {
        let repo = AppContext.shared.repo
        let sinceMs = Int64((Date().timeIntervalSince1970 - oneDay) * 1000)
        var stats: [String: Any] = ["window_hours": 24]
        if let rows = try? repo.listMeetings() {
            let recent = rows.filter { ($0.startedAt) >= sinceMs }
            stats["meetings_total"] = recent.count
            stats["meetings_ready"] = recent.filter { $0.status == .ready }.count
            stats["meetings_failed"] = recent.filter { $0.status == .failed }.count
            stats["meetings_transcribing"] = recent.filter { $0.status == .transcribing }.count
            let advCount = recent.filter { $0.transcriptionClass == "advanced" }.count
            let localCount = recent.filter { $0.transcriptionClass == "local" }.count
            stats["transcribed_advanced"] = advCount
            stats["transcribed_local"] = localCount
            let totalDur = recent.compactMap { $0.durationMs }.reduce(0, +)
            stats["total_duration_ms"] = totalDur
        }
        // Capture-reliability counters (drained + reset for this window).
        // This is what tells us how often the far end is lost, and how
        // much of it is Bluetooth, the core risk we couldn't see before.
        for (k, v) in drainCounters() { stats["reliab_\(k)"] = v }
        return [stats]
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
