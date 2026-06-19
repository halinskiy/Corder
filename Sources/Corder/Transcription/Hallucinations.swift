import Foundation

/// Shared filter for the subtitle-style phrases Whisper/WhisperKit
/// hallucinate over silent stretches (leftovers from YouTube training
/// data — "спасибо за просмотр", "Субтитры сделал DimaTorzok", …). This
/// used to be copy-pasted verbatim into `WhisperTranscriber`,
/// `LocalWhisperTranscriber`, and `TranscriptionPipeline`; consolidated
/// here so a new pattern only has to be added once. The list now also
/// covers the English YouTube-outro phrases Whisper emits on silence
/// ("thank you for watching", "enjoy watching this video", ...), which the
/// original Russian-only list let through.
enum Hallucinations {
    static let patterns: [String] = [
        "субтитры сделал dimatorzok",
        "субтитры подготовил dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры подобрал dimatorzok",
        "субтитры от dimatorzok",
        "продолжение следует",
        "продолжение в следующем видео",
        "продолжение в следующем выпуске",
        "спасибо за просмотр",
        "спасибо за внимание",
        // Russian YouTube-outro farewells Whisper emits over near-silence
        // (seen in benchmark: "До скорых встреч, пока, до."). Distinctive
        // multi-word phrases so genuine "до встречи завтра" speech is safe.
        "до скорых встреч",
        "до новых встреч",
        "не забудьте подписаться",
        "подписывайтесь на канал",
        "ставьте лайк",
        // English YouTube-outro hallucinations Whisper/WhisperKit emit on
        // silent stretches (reported by Kostya on a mostly-silent mic
        // track: "Thank you for watching, and I hope you will have a
        // wonderful day", "...enjoy watching this video"). Distinctive
        // multi-word phrases so they don't catch genuine meeting speech.
        "thank you for watching",
        "thanks for watching",
        "thank you for your watching",
        "thank you so much for watching",
        "i hope you enjoyed",
        "i hope you will enjoy",
        "hope you enjoy this video",
        "enjoy watching this video",
        "enjoy this video",
        "have a wonderful day",
        "have a great day",
        "see you in the next video",
        "see you in the next one",
        "see you next time",
        "i will see you in the next video",
        "dont forget to subscribe",
        "please subscribe to my channel",
        "subscribe to my channel",
        "like and subscribe",
        "if you enjoyed this video",
        "see you in the next one",
        "see you guys next time",
        "subtitles by",
        "transcribed by",
        "amaraorg",
        "редактор субтитров",
        "субтитри",
        "дякую за перегляд",
        "дякую за увагу",
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
