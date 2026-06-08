import Foundation

/// Shared filter for the subtitle-style phrases Whisper/WhisperKit
/// hallucinate over silent stretches (leftovers from YouTube training
/// data — "спасибо за просмотр", "Субтитры сделал DimaTorzok", …). This
/// used to be copy-pasted verbatim into `WhisperTranscriber`,
/// `LocalWhisperTranscriber`, and `TranscriptionPipeline`; consolidated
/// here so a new pattern only has to be added once. Behaviour is
/// byte-identical to the old three copies (same list, same normalization,
/// same substring match) — this is a pure de-duplication, not a tuning
/// change.
enum Hallucinations {
    static let patterns: [String] = [
        "субтитры сделал dimatorzok",
        "субтитры подготовил dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры подобрал dimatorzok",
        "субтитры от dimatorzok",
        "продолжение следует",
        "спасибо за просмотр",
        "спасибо за внимание",
        "не забудьте подписаться",
        "подписывайтесь на канал",
        "ставьте лайк",
    ]

    static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()
        let stripped = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let normalised = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        for pat in patterns where normalised.contains(pat) { return true }
        return false
    }
}
