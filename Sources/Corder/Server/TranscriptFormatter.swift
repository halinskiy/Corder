import Foundation

enum TranscriptFormatter {
    /// Human-friendly clipboard format: speaker header on its own line,
    /// then the speaker's turn as a paragraph. Consecutive segments by the
    /// same speaker collapse into one paragraph. Blank line between turns.
    /// No per-segment timestamps, they make the pasted text unreadable in
    /// docs/chats; users wanting timing can use the audio scrubber.
    static func clipboardText(segments: [Segment], speakers: [Speaker]) -> String {
        let byId = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })

        var blocks: [(name: String, text: String)] = []
        for seg in segments {
            let speaker = byId[seg.speakerId]
            let name = displayName(for: speaker)
            let segText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segText.isEmpty { continue }
            if var last = blocks.last, last.name == name {
                last.text += " " + segText
                blocks[blocks.count - 1] = last
            } else {
                blocks.append((name: name, text: segText))
            }
        }
        return blocks.map { "\($0.name)\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Markdown export: a title heading then one bolded speaker name per
    /// turn followed by the paragraph (same turn-collapsing as clipboard).
    static func markdown(segments: [Segment], speakers: [Speaker], title: String) -> String {
        let byId = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        var out = "# \(title)\n\n"
        var blocks: [(name: String, text: String)] = []
        for seg in segments {
            let name = displayName(for: byId[seg.speakerId])
            let segText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segText.isEmpty { continue }
            if var last = blocks.last, last.name == name {
                last.text += " " + segText
                blocks[blocks.count - 1] = last
            } else {
                blocks.append((name: name, text: segText))
            }
        }
        out += blocks.map { "**\($0.name)**\n\n\($0.text)" }.joined(separator: "\n\n")
        return out
    }

    /// JSON export: structured segments with timing + speaker label, so
    /// the data is machine-portable (the anti-lock-in ask).
    static func json(segments: [Segment], speakers: [Speaker], title: String) -> String {
        let byId = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        let segs: [[String: Any]] = segments.map { s in
            [
                "speaker": displayName(for: byId[s.speakerId]),
                "start_ms": s.startMs,
                "end_ms": s.endMs,
                "text": s.text
            ]
        }
        let root: [String: Any] = ["title": title, "segments": segs]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Mirrors the UI: the local user speaker (tagged via either label or
    /// `customName == "you"`) renders as "I"; explicit user-set names take
    /// priority over labels; otherwise we fall back to "Speaker N".
    private static func displayName(for speaker: Speaker?) -> String {
        guard let s = speaker else { return "Unknown" }
        let custom = s.customName?.trimmingCharacters(in: .whitespaces) ?? ""
        // "you" is the pipeline's internal placeholder for the local user.
        // Show it as "I" regardless of which field it landed in.
        if custom.lowercased() == "you" || s.label == "you" { return "I" }
        if !custom.isEmpty { return custom }
        return s.label
    }
}
