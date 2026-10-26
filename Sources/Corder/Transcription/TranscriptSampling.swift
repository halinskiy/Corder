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
    /// At most three 900-character excerpts: beginning, middle and end.
    /// Prefer whole lines, but bound a single oversized line as well.
    static func titleExcerpt(_ text: String) -> String {
        let budget = 900
        guard text.count > budget * 3 else { return text }
        let chars = Array(text)
        let starts = [0, (chars.count - budget) / 2, chars.count - budget]
        return starts.enumerated().map { index, raw in
            var start = raw
            var end = raw + budget
            if index > 0, chars[start - 1] != "\n",
               let newline = chars[start..<end].firstIndex(of: "\n") {
                start = newline + 1
            }
            if index < 2, chars[end] != "\n",
               let newline = chars[start..<end].lastIndex(of: "\n") {
                end = newline
            }
            return String(chars[start..<end])
        }.joined(separator: "\n[...]\n")
    }

    /// `budget` characters taken as `windows` evenly spread slices, joined by
    /// an `[…]` line so the model can see where a stretch was skipped.
    /// Returns the text untouched when it already fits.
    ///
    /// Windows are snapped to line boundaries (within 400 characters) so a
    /// slice opens and closes on a whole speaker turn instead of mid-sentence.
    static func evenSample(_ text: String, budget: Int, windows: Int = 6) -> String {
        guard budget > 0 else { return "" }
        guard text.count > budget else { return text }
        guard windows > 1 else { return String(text.prefix(budget)) }
        let chars = Array(text)
        let separator = "\n[…]\n"
        let count = min(windows, max(1, budget / (separator.count + 1)))
        guard count > 1 else { return String(text.prefix(budget)) }
        let per = (budget - separator.count * (count - 1)) / count
        let span = chars.count - per
        var parts: [String] = []
        for i in 0..<count {
            let raw = span * i / (count - 1)
            var start = raw
            var end = min(chars.count, raw + per)
            if i > 0, chars[start - 1] != "\n",
               let nl = chars[start..<min(end, start + 400)].firstIndex(of: "\n"), nl + 1 < end {
                start = nl + 1
            }
            if i < count - 1, chars[end] != "\n",
               let nl = chars[max(start, end - 400)..<end].lastIndex(of: "\n"), nl > start {
                end = nl
            }
            if start < end { parts.append(String(chars[start..<end])) }
        }
        return parts.joined(separator: separator)
    }
}
