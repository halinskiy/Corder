import Foundation

/// Shared string table for everything that renders outside the Vite/React
/// frontend — the menu-bar popover, the meeting-invite panel, and any
/// other native chrome that needs to follow `AppContext.language`.
///
/// Keep keys short and topical (`invite_subtitle`, not `meeting_invite_record_question`)
/// — the dictionary stays readable that way.
enum L {
    static func t(_ key: String, lang: String) -> String {
        let dict = lang == "ru" ? ru : en
        return dict[key] ?? en[key] ?? key
    }
    private static let en: [String: String] = [
        // Menu-bar popover
        "idle": "Not recording",
        "recording": "Recording",
        "saving": "Saving…",
        "start": "Start recording",
        "stop": "Stop recording",
        "open_library": "Open library",
        "quit": "Quit",
        // Meeting invite panel
        "invite_question": "Record meeting?",
        "invite_tap_hint": "Tap to start recording",
        "invite_not_now": "Not now",
        // Loading state shown after the user accepts an invite (or
        // hits manual Start) while the capture engine warms up — gives
        // the user feedback that something is happening between click
        // and the floating blob appearing.
        "starting_recording": "Starting recording…",
        // Native macOS notification banners. `{s}` is substituted with
        // the recording length in seconds at call time.
        "notif_saved_title": "Recording saved",
        "notif_saved_body": "Transcribing {s}s…",
        "notif_ready_title": "Transcript ready",
        "notif_ready_body": "Open the library to view it.",
        "notif_silent_title": "No audio captured",
        "notif_silent_body": "The recording is effectively silent — check the input device and Microphone permission.",
        "notif_stopped_title": "Recording stopped",
        "notif_net_restored_title": "Internet restored",
        "notif_net_restored_body": "Retrying any meetings that failed while offline.",
        "notif_net_lost_title": "No internet",
        "notif_net_lost_body": "Recording continues locally. Transcription will need a connection when you stop.",
    ]
    private static let ru: [String: String] = [
        "idle": "Запись не идёт",
        "recording": "Идёт запись",
        "saving": "Сохраняем…",
        "start": "Начать запись",
        "stop": "Остановить запись",
        "open_library": "Открыть библиотеку",
        "quit": "Выйти",
        "invite_question": "Записать встречу?",
        "invite_tap_hint": "Нажми, чтобы начать запись",
        "invite_not_now": "Не сейчас",
        "starting_recording": "Начинаем запись…",
        "notif_saved_title": "Запись сохранена",
        "notif_saved_body": "Расшифровка {s}с…",
        "notif_ready_title": "Расшифровка готова",
        "notif_ready_body": "Открой библиотеку чтобы посмотреть.",
        "notif_silent_title": "Звук не записался",
        "notif_silent_body": "Запись фактически беззвучная — проверь устройство ввода и доступ к микрофону.",
        "notif_stopped_title": "Запись остановлена",
        "notif_net_restored_title": "Интернет восстановлен",
        "notif_net_restored_body": "Повторяю встречи, упавшие без сети.",
        "notif_net_lost_title": "Нет интернета",
        "notif_net_lost_body": "Запись идёт локально. Для расшифровки понадобится сеть, когда остановишь.",
    ]

    /// Convenience for native notifications: resolves against the
    /// persisted language (these fire from non-MainActor contexts —
    /// SleepWatchdog / NetworkMonitor — so we read the thread-safe
    /// `AppLanguage.current`, not `AppContext.shared.language`).
    static func notif(_ key: String) -> String {
        t(key, lang: AppLanguage.current)
    }
}
