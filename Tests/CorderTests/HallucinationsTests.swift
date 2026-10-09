import XCTest
@testable import Corder

final class HallucinationsTests: XCTestCase {
    func test_all_patterns_are_hallucinations_and_exact_matches() {
        for pattern in Hallucinations.patterns {
            XCTAssertTrue(Hallucinations.isHallucination(pattern), "Pattern: \(pattern)")
            XCTAssertTrue(Hallucinations.isExactHallucination(pattern), "Pattern: \(pattern)")
        }
    }

    func test_case_and_punctuation_are_ignored() {
        let cases = [
            "Спасибо за просмотр!",
            "  THANK YOU FOR WATCHING.  "
        ]
        for text in cases {
            XCTAssertTrue(Hallucinations.isHallucination(text), "Text: \(text)")
            XCTAssertTrue(Hallucinations.isExactHallucination(text), "Text: \(text)")
        }
    }

    func test_short_pattern_inside_long_real_sentence_survives() {
        let text = "Ставьте лайк, это была шутка, а теперь к делу, коллеги, давайте обсудим бюджет на следующий квартал и сроки"
        // 12 / 103 is below 60%, so the short pattern does not dominate.
        XCTAssertFalse(Hallucinations.isHallucination(text))
        XCTAssertFalse(Hallucinations.isExactHallucination(text))
    }

    func test_dominant_patterns_match_live_filter_but_not_exact_filter() {
        let cases: [(text: String, hallucination: Bool, exact: Bool)] = [
            // 19 / 26 is about 73.08%, above 60%, but the whole string differs.
            ("спасибо за просмотр друзья", true, false),
            // 19 / 28 is about 67.86%, above 60%, but the whole string differs.
            ("thanks for watching everyone", true, false)
        ]
        for testCase in cases {
            XCTAssertEqual(Hallucinations.isHallucination(testCase.text), testCase.hallucination,
                           "Text: \(testCase.text)")
            XCTAssertEqual(Hallucinations.isExactHallucination(testCase.text), testCase.exact,
                           "Text: \(testCase.text)")
        }
    }

    func test_always_drop_fragments_match_inside_long_real_sentences() {
        let cases = [
            "Субтитры сделал DimaTorzok, а теперь поговорим о планах на год",
            // Normalisation removes the dot, so amara.org matches amaraorg.
            "Субтитры подготовила amara.org, а теперь поговорим о планах на год",
            "Субтитры подготовила CastingWords, а теперь поговорим о планах на год"
        ]
        for text in cases {
            XCTAssertTrue(Hallucinations.isHallucination(text), "Text: \(text)")
            XCTAssertTrue(Hallucinations.isExactHallucination(text), "Text: \(text)")
        }
    }

    func test_non_speech_captions_require_notes_or_closed_wrappers() {
        let cases: [(text: String, expected: Bool)] = [
            ("♪♪", true),
            ("♪ ♫", true),
            ("[Music]", true),
            ("(laughs)", true),
            ("hello", false),
            ("", false),
            ("   ", false),
            ("[not closed", false)
        ]
        for testCase in cases {
            XCTAssertEqual(Hallucinations.isNonSpeechCaption(testCase.text), testCase.expected,
                           "Text: \(testCase.text)")
        }
    }

    func test_only_caption_words_rejects_text_with_real_content() {
        let cases: [(text: String, expected: Bool)] = [
            ("자막", true),
            ("字幕 字幕", true),
            ("자막!", true),
            ("字幕 hello", false),
            ("hello", false)
        ]
        for testCase in cases {
            XCTAssertEqual(Hallucinations.isOnlyCaptionWords(testCase.text), testCase.expected,
                           "Text: \(testCase.text)")
        }
    }

    func test_repetition_loops_require_at_least_six_words() {
        let cases: [(text: String, expected: Bool)] = [
            ("да да да да да да да", true),
            ("thank you thank you thank you", true),
            ("the cat sat on the mat today", false),
            ("да", false),
            ("да да", false),
            ("да да да", false),
            ("да да да да", false),
            ("да да да да да", false),
            ("thank you thank you", false)
        ]
        for testCase in cases {
            XCTAssertEqual(Hallucinations.isRepetitionLoop(testCase.text), testCase.expected,
                           "Text: \(testCase.text)")
        }
    }

    func test_empty_and_whitespace_only_text_is_not_hallucination_or_loop() {
        let cases = ["", " ", "   ", "\t", "\n", " \t\n "]
        for text in cases {
            XCTAssertFalse(Hallucinations.isHallucination(text), "Text: \(text)")
            XCTAssertFalse(Hallucinations.isExactHallucination(text), "Text: \(text)")
            XCTAssertFalse(Hallucinations.isRepetitionLoop(text), "Text: \(text)")
        }
    }

    func test_normalisation_keeps_non_latin_letters() {
        XCTAssertTrue(Hallucinations.isHallucination("Продолжение следует"))
        XCTAssertTrue(Hallucinations.isExactHallucination("Продолжение следует"))

        let text = "продолжение следует завтра утром"
        // 19 / 32 = 59.375%, below 60%, so the live filter also returns false.
        XCTAssertFalse(Hallucinations.isHallucination(text))
        XCTAssertFalse(Hallucinations.isExactHallucination(text))
    }
}
