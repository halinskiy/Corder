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
        // "спасибо за внимание" — in PRACTICE this is overwhelmingly a
        // Whisper hallucination over silence (Kostya: it "часто появлялось"
        // when nobody said it), not a real closer, so it stays filtered.
        // The destructive launch purge uses isExactHallucination (whole-
        // segment only), so a real sentence merely CONTAINING it ("спасибо
        // за внимание, коллеги, до встречи") is never deleted; the live
        // filter still drops a standalone hallucinated occurrence.
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
        // Common Whisper silence-hallucinations (Kostya: appeared without
        // anyone saying them). Kept filtered; the launch purge is exact-only
        // so a real "have a great day, talk soon" sentence isn't deleted.
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
        "please subscribe",
        "редактор субтитров",
        "субтитри",
        "дякую за перегляд",
        "дякую за увагу",
    ]

    /// Distinctive watermark FRAGMENTS that are never real meeting speech, so
    /// any segment CONTAINING one is a hallucination regardless of length (no
    /// 60%-domination requirement, and safe for the destructive launch purge).
    /// "amaraorg" alone covers the ENTIRE Amara.org subtitle-community credit
    /// family across every language Whisper emits it in over silence —
    /// "Subtitles by the Amara.org community", "Sous-titres … d'Amara.org",
    /// "Untertitel der Amara.org-Community", "Legendas pela comunidade
    /// Amara.org", … all normalise to contain "amaraorg". No real call says
    /// "amara.org" or "CastingWords". (Reported by Kostya: an empty recording
    /// transcribed as "Subtitles by the Amara.org community".)
    static let alwaysDropFragments: [String] = [
        "amaraorg",
        "castingwords",
    ]

    /// Bare caption words Whisper emits over silence: "자막" (Korean for
    /// subtitles), "字幕" (Chinese/Japanese). Unlike the Amara watermark these
    /// are ORDINARY words, so we must not drop every segment containing them —
    /// a Korean speaker really can say "자막" in a meeting. We only drop a
    /// segment that is NOTHING BUT these words (repeated and/or punctuated),
    /// which is exactly the artefact: "자막: 자막:" on an empty track.
    /// (Reported by Kostya: a silent second track transcribed as "자막: 자막:"
    /// and surfaced as a phantom Speaker 2.)
    static let captionWords: [String] = ["자막", "字幕"]

    /// True when the segment consists solely of caption words plus punctuation
    /// or whitespace, i.e. there is no real content left once they're removed.
    static func isOnlyCaptionWords(_ text: String) -> Bool {
        var t = text.lowercased()
        for w in captionWords { t = t.replacingOccurrences(of: w, with: " ") }
        guard text.lowercased() != t else { return false }   // no caption word at all
        // Any remaining letter or digit means there WAS real speech around it.
        return !t.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// True when the WHOLE (raw) segment is a non-speech CAPTION: only music
    /// notes, or fully wrapped in `[...]` / `(...)`. Whisper emits "[Music]",
    /// "[Applause]", "(applause)", "[BLANK_AUDIO]", "♪ ♪" over silence; those
    /// normalise away their brackets ("[Music]" → "music"), so we detect them
    /// on the raw text instead, whole-segment only (never inside real speech).
    static func isNonSpeechCaption(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.allSatisfy({ $0 == "♪" || $0 == "♫" || $0.isWhitespace }) { return true }
        if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) {
            return true
        }
        return false
    }

    static func isHallucination(_ text: String) -> Bool {
        // Bracket/music captions normalise to empty or a bare word, so check
        // the raw text first.
        if isNonSpeechCaption(text) { return true }
        // A segment that is nothing but caption words ("자막: 자막:") is a
        // silence artefact, never real speech.
        if isOnlyCaptionWords(text) { return true }
        let lower = text.lowercased()
        let stripped = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let normalised = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !normalised.isEmpty else { return false }
        // Distinctive watermark fragments → drop regardless of length.
        for frag in alwaysDropFragments where normalised.contains(frag) { return true }
        for pat in patterns where normalised.contains(pat) {
            // Exact match → definitely a hallucination.
            if normalised == pat { return true }
            // Substring match: only drop the turn if the pattern DOMINATES
            // the segment (≥60% of its length). A short pattern ("субтитри",
            // "enjoy this video") appearing inside a long real sentence must
            // NOT nuke that whole turn — and the launch-time purge actually
            // DELETEs matches, so a false positive permanently loses real
            // speech. Genuine all-outro segments still clear the bar; an
            // appended outro is handled display-side by `cleanSegmentText`.
            if Double(pat.count) >= Double(normalised.count) * 0.6 { return true }
        }
        return false
    }

    /// Stricter, EXACT-only variant for the destructive launch-time purge.
    /// Returns true only when the WHOLE segment is a known artefact, never
    /// on the 60%-domination substring rule. `purgeKnownHallucinations`
    /// hard-DELETEs matches from already-stored transcripts (irreversible),
    /// so a real sentence that merely CONTAINS a pattern ("Спасибо за
    /// просмотр презентации") must survive there even though the live
    /// insert-time filter (`isHallucination`) still skips it.
    static func isExactHallucination(_ text: String) -> Bool {
        if isNonSpeechCaption(text) { return true }
        // A segment that is nothing but caption words ("자막: 자막:") is a
        // silence artefact, never real speech.
        if isOnlyCaptionWords(text) { return true }
        let lower = text.lowercased()
        let stripped = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let normalised = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !normalised.isEmpty else { return false }
        // A watermark fragment (amaraorg / castingwords) is never real speech,
        // so it's safe to hard-delete even on the destructive purge path.
        for frag in alwaysDropFragments where normalised.contains(frag) { return true }
        return patterns.contains(normalised)
    }
}
