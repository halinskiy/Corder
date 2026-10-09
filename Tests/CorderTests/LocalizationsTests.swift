import XCTest
@testable import Corder

final class LocalizationsTests: XCTestCase {
    /// `L.t` falls back to the key itself when a table lacks it, so an
    /// untranslated string would show up as "record_start_failed" in the UI.
    func test_recording_error_keys_exist_in_both_languages() {
        for key in ["record_start_failed", "record_save_failed", "record_low_disk"] {
            XCTAssertNotEqual(L.t(key, lang: "en"), key, "missing en: \(key)")
            XCTAssertNotEqual(L.t(key, lang: "ru"), key, "missing ru: \(key)")
        }
        XCTAssertTrue(L.t("record_low_disk", lang: "en").contains("{mb}"))
    }
}
