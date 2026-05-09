import Foundation

enum TranscriptFormatter {
    /// Human-friendly clipboard format: speaker header on its own line,
    /// then the speaker's turn as a paragraph. Consecutive segments by the
    /// same speaker collapse into one paragraph. Blank line between turns.
    /// No per-segment timestamps — they make the pasted text unreadable in
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
