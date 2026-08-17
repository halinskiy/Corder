import Foundation

/// Picks what a text-only Gemini pass (title / summary) gets to read when the
/// transcript is longer than its budget.
///
/// The rule is EVEN COVERAGE, never a head crop. Both passes used to take a
/// `prefix(...)`, which silently made them describe the START of a meeting
/// rather than the meeting: a one-hour therapy session that opened on small
/// talk about baking came back titled after the cake, because the fifty
/// minutes after the first 6 000 characters were never sent (reported by a
/// user, 2026-08). Sampling across the whole length costs the same tokens and
/// keeps the middle and the end represented.
enum TranscriptSampling {
    /// `budget` characters taken as `windows` evenly spread slices, joined by
    /// an `[…]` line so the model can see where a stretch was skipped.
    /// Returns the text untouched when it already fits.
    ///
    /// Windows are snapped to line boundaries (within 400 characters) so a
    /// slice opens and closes on a whole speaker turn instead of mid-sentence.
    static func evenSample(_ text: String, budget: Int, windows: Int = 6) -> String {
        guard windows > 1, budget > 0, text.count > budget else { return text }
        let chars = Array(text)
        let per = budget / windows
        guard per > 0 else { return String(chars.prefix(budget)) }
        // Spread window STARTS across the full text, leaving room for the last
        // one to read to the end rather than past it.
        let span = chars.count - per
        var parts: [String] = []
        for i in 0..<windows {
            let raw = span * i / (windows - 1)
            var start = raw
            var end = min(chars.count, raw + per)
            if i > 0, let nl = chars[start..<min(chars.count, start + 400)].firstIndex(of: "\n") {
                start = chars.index(after: nl)
            }
            if end < chars.count, let nl = chars[max(start, end - 400)..<end].lastIndex(of: "\n") {
                end = nl
            }
            if start < end { parts.append(String(chars[start..<end])) }
        }
        return parts.isEmpty ? String(chars.prefix(budget)) : parts.joined(separator: "\n[…]\n")
    }
}
