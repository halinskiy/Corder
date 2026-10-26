import Foundation

/// Pure wire payload builder. Exact root and event keys are pinned by tests.
enum TelemetryPayload {
    static func make(id: String, appVersion: String, macOS: String, macModel: String,
                     ramGB: Int, tier: String, meetings: [Meeting], counters: [String: Int]) -> [String: Any] {
        var stats: [String: Any] = [
            "window_hours": 24,
            "meetings_total": meetings.count,
            "meetings_ready": meetings.filter { $0.status == .ready }.count,
            "meetings_failed": meetings.filter { $0.status == .failed }.count,
            "meetings_transcribing": meetings.filter { $0.status == .transcribing }.count,
            "transcribed_advanced": meetings.filter { $0.transcriptionClass == "advanced" }.count,
            "transcribed_local": meetings.filter { $0.transcriptionClass == "local" }.count,
            "total_duration_ms": meetings.compactMap { $0.durationMs }.reduce(0, +),
        ]
        for (key, value) in counters { stats["reliab_\(key)"] = value }
        return ["anonymous_id": id, "app_version": appVersion, "macos_version": macOS,
                "mac_model": macModel, "ram_gb": ramGB, "tier": tier, "events": [stats]]
    }
}
