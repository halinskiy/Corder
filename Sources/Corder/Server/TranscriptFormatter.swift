import Foundation

enum TranscriptFormatter {
    static func clipboardText(segments: [Segment], speakers: [Speaker]) -> String {
        let byId = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        return segments.map { seg -> String in
            let stamp = formatTimestamp(ms: seg.startMs)
            let sp = byId[seg.speakerId]
            let name: String
            if let s = sp {
                if let custom = s.customName, !custom.isEmpty {
                    name = "\(s.label) (\(custom))"
                } else {
                    name = s.label
                }
            } else {
                name = "Unknown"
            }
            return "[\(stamp)] \(name): \(seg.text)"
        }.joined(separator: "\n")
    }

    private static func formatTimestamp(ms: Int64) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
