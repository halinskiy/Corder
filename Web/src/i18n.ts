// User-visible strings for the Library window. Keep keys stable —
// components import them by key, not by text.
//
// Localised dates / participant counts live in `format.ts`, not here, so
// this file is purely string lookups.

export type Lang = "ru" | "en";

interface Strings {
  breadcrumb_records: string;

  sidebar_search: string;
  sidebar_empty: string;
  sidebar_no_match: string;
  status_recording: string;
  status_transcribing: string;
  status_ready: string;
  status_failed: string;
  participants: (n: number) => string;

  tab_transcript: string;
  tab_summary: string;
  tab_settings: string;
  settings_draft_note: string;
  settings_sec_notifications: string;
  settings_notifications: string;
  settings_notifications_desc: string;
  settings_sec_capture: string;
  settings_video: string;
  settings_video_desc: string;
  settings_system_audio: string;
  settings_system_audio_desc: string;
  settings_mic: string;
  settings_mic_desc: string;
  settings_sec_transcription: string;
  settings_autotranscribe: string;
  settings_autotranscribe_desc: string;
  settings_autotitle: string;
  settings_autotitle_desc: string;
  settings_sec_autodetect: string;
  settings_whitelist: string;
  settings_whitelist_desc: string;
  settings_blacklist: string;
  settings_blacklist_desc: string;
  settings_list_add: string;
  settings_list_add_ph: string;
  settings_list_remove: string;
  settings_list_empty: string;
  settings_list_detected: string;
  settings_pick_search: string;
  settings_pick_none: string;
  settings_pick_recent: string;
  settings_sec_shortcut: string;
  settings_shortcut_label: string;
  settings_shortcut_desc: string;
  settings_shortcut_press: string;
  settings_shortcut_conflict: (name: string) => string;
  settings_shortcut_unbound: string;
  settings_pro_note: string;
  settings_sec_soon: string;
  settings_ext_title: string;
  settings_ext_desc: string;
  settings_mobile_title: string;
  settings_mobile_desc: string;
  settings_tg_title: string;
  settings_tg_desc: string;
  settings_integrations_title: string;
  settings_integrations_desc: string;
  settings_calendar_title: string;
  settings_calendar_desc: string;
  settings_sec_recognition: string;
  settings_vocab_placeholder: string;
  settings_vocab_hint: string;
  settings_sec_api: string;
  settings_key_set: string;
  settings_key_placeholder: string;
  settings_key_hint: string;
  settings_key_hint_set: string;
  settings_save: string;
  settings_saved: string;
  settings_sec_privacy: string;
  settings_privacy_body: string;
  settings_ext_badge_soon: string;
  settings_ext_cta: string;
  summary_generating: string;
  summary_failed: string;
  summary_retry: string;
  transcript_search: string;
  transcript_empty_failed: string;
  transcript_empty_recording: string;
  transcript_no_match: (q: string) => string;

  btn_copy: string;
  btn_retranscribe: string;
  btn_transcribe: string;
  transcript_not_transcribed: string;
  btn_archive: string;
  btn_boost: string;
  btn_boost_title: string;
  btn_lang_title: string;
  btn_theme_title: string;
  theme_light: string;
  theme_dark: string;

  audio_card_title: string;
  timeline_title: string;
  download_audio_title: string;
  download_title: string;
  download_body: string;
  download_video: string;
  download_audio: string;
  download_transcript: string;
  download_markdown: string;
  download_json: string;
  download_all: string;
  profile_title: string;
  profile_name: string;
  profile_sub: string;
  profile_account: string;
  profile_signout: string;
  profile_integrations: string;
  profile_soon: string;

  rec_label: string;
  rec_stop: string;
  trans_label: string;
  trans_stop: string;
  trans_cancelled: string;

  clarify_question: string;
  clarify_just_me: string;
  clarify_dismiss_title: string;
  empty_delete_question: string;
  empty_delete_btn: string;
  empty_archive_btn: string;

  ctx_retranscribe: string;
  ctx_archive: string;
  ctx_pin: string;
  ctx_unpin: string;
  ctx_rename: string;
  sidebar_pinned: string;

  speaker_self: string;
  speaker_rename_title: string;
  inline_editor_placeholder: string;

  toast_copied: string;
  toast_copy_failed: string;
  toast_retranscribe_started: string;
  toast_retranscribe_failed: string;
  toast_deleted: string;
  toast_archived: string;
  toast_undo: string;
  toast_boost_on: string;
  toast_boost_off: string;
  toast_settings_failed: string;

  no_meeting_selected_title: string;
  no_meeting_selected_body: string;
  error_label: string;
  loading: string;

  update_available_label: string;
  update_available_title: string;

  archive_open_title: string;
  archive_title: string;
  archive_empty: string;
  archive_select_all: string;
  archive_action_restore: string;
  archive_action_delete_forever: string;
  archive_retention_note: string;
  archive_purge_in: (days: number) => string;
  archive_close_title: string;
  toast_archive_restored: (n: number) => string;
  toast_archive_deleted: (n: number) => string;
  confirm_delete_forever: (n: number) => string;
}

const ru: Strings = {
  breadcrumb_records: "Записи",

  sidebar_search: "Поиск записей…",
  sidebar_empty: "Записей пока нет. Нажми Start в menu bar.",
  sidebar_no_match: "Нет совпадений.",
  status_recording: "запись",
  status_transcribing: "расшифровка",
  status_ready: "готово",
  status_failed: "ошибка",
  participants: (n) => {
    const m10 = n % 10, m100 = n % 100;
    if (m10 === 1 && m100 !== 11) return `${n} участник`;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return `${n} участника`;
    return `${n} участников`;
  },

  tab_transcript: "Транскрипт",
  tab_summary: "Саммари",
  tab_settings: "Настройки",
  settings_draft_note: "Черновик, настройки дорабатываются.",
  settings_sec_notifications: "Уведомления",
  settings_notifications: "Системные уведомления",
  settings_notifications_desc: "Сообщать о начале записи, готовности расшифровки и потере сети.",
  settings_sec_capture: "Захват",
  settings_video: "Запись видео экрана",
  settings_video_desc: "Сохранять видео того, что было на экране во время встречи.",
  settings_system_audio: "Системный звук",
  settings_system_audio_desc: "Захватывать звук собеседников (звонки, видеоконференции).",
  settings_mic: "Микрофон",
  settings_mic_desc: "Записывать ваш голос с микрофона.",
  settings_sec_transcription: "Расшифровка",
  settings_autotranscribe: "Авторасшифровка",
  settings_autotranscribe_desc: "Расшифровывать запись автоматически после остановки.",
  settings_autotitle: "Автозаголовок",
  settings_autotitle_desc: "Генерировать короткий заголовок встречи из расшифровки.",
  settings_sec_autodetect: "Автоопределение звонков",
  settings_whitelist: "Всегда предлагать запись",
  settings_whitelist_desc: "Приложения, для которых Corder всегда предлагает начать запись, когда они занимают микрофон.",
  settings_blacklist: "Никогда не предлагать",
  settings_blacklist_desc: "Приложения, которые Corder игнорирует, даже если они заняли микрофон (например Loom, OBS, Терминал).",
  settings_list_add: "Добавить",
  settings_list_add_ph: "Bundle ID, напр. us.zoom.xos",
  settings_list_remove: "Убрать",
  settings_list_empty: "Пусто",
  settings_list_detected: "Недавно занимали микрофон — нажмите, чтобы добавить:",
  settings_pick_search: "Поиск приложений…",
  settings_pick_none: "Ничего не найдено",
  settings_pick_recent: "был у микрофона",
  settings_sec_shortcut: "Горячая клавиша",
  settings_shortcut_label: "Старт/стоп записи",
  settings_shortcut_desc: "Системный шорткат для быстрого запуска Corder.",
  settings_shortcut_press: "Нажмите комбинацию…",
  settings_shortcut_conflict: (name) => `Конфликт с системным шорткатом: ${name}. Выбери другую.`,
  settings_shortcut_unbound: "Не удалось назначить — комбинацию уже занимает другое приложение. Выбери другую.",
  settings_pro_note: "Возможности Pro в этой сборке отключены.",
  settings_sec_soon: "Скоро",
  settings_ext_title: "Расширение для браузера",
  settings_ext_desc: "Расшифровка звонков во вкладке браузера: Google Meet, Zoom, без приложения.",
  settings_mobile_title: "Приложение на телефон",
  settings_mobile_desc: "Запись и расшифровка с телефона: встречи, разговоры, заметки на ходу.",
  settings_tg_title: "Телеграм-бот",
  settings_tg_desc: "Голосовые боту: Corder сохранит и расшифрует их вместе с остальными.",
  settings_integrations_title: "Интеграции",
  settings_integrations_desc: "Slack, Notion, CRM: выгрузка расшифровок и саммари в рабочие инструменты.",
  settings_calendar_title: "Автодетект по календарю",
  settings_calendar_desc: "Старт записи по событию календаря, без ручного запуска.",
  settings_sec_recognition: "Распознавание",
  settings_vocab_placeholder: "Имена, термины, аббревиатуры: Logics7, Грослицкий, NestJS…",
  settings_vocab_hint: "Эти слова модель будет писать точно так, как заданы. Сильнее всего влияет на точность на технических созвонах.",
  settings_sec_api: "Gemini API-ключ",
  settings_key_set: "Ключ задан",
  settings_key_placeholder: "Вставь ключ Gemini API",
  settings_key_hint: "Свой ключ — расшифровка идёт на твой счёт Google, не через общий. Хранится локально (~/.config/corder/gemini_key, 0600).",
  settings_key_hint_set: "Ключ сохранён локально. Вставь новый, чтобы заменить.",
  settings_save: "Сохранить",
  settings_saved: "Сохранено",
  settings_sec_privacy: "Приватность",
  settings_privacy_body: "Записи, расшифровки, база и ключ хранятся только на этом компьютере. Диаризация (разделение спикеров) — на устройстве. Для расшифровки аудио отправляется в Google Gemini API; ознакомься с условиями Gemini по обработке данных. Телеметрии и аналитики нет. Проверка обновлений обращается к серверу обновлений. Архивация в Dropbox — только если ты сам её настроил. Ничего не публикуется и не шарится по ссылке.",
  settings_ext_badge_soon: "Скоро",
  settings_ext_cta: "Скоро будет доступно",
  summary_generating: "Генерируем саммари…",
  summary_failed: "Не удалось сгенерировать саммари",
  summary_retry: "Повторить",
  transcript_search: "Поиск по транскрипту…",
  transcript_empty_failed: "Расшифровка не удалась.",
  transcript_empty_recording: "Идёт запись…",
  transcript_no_match: (q) => `Нет совпадений по «${q}».`,

  btn_copy: "Копировать",
  btn_retranscribe: "Расшифровать заново",
  btn_transcribe: "Расшифровать",
  transcript_not_transcribed: "Эта запись ещё не расшифрована.",
  btn_archive: "Архив",
  btn_boost: "Усилить",
  btn_boost_title: "Когда включён, каждая следующая расшифровка автоматически улучшается через Gemini Flash",
  btn_lang_title: "Сменить язык интерфейса",
  btn_theme_title: "Переключить светлую/тёмную тему",
  theme_light: "Светлая",
  theme_dark: "Тёмная",

  audio_card_title: "Запись",
  timeline_title: "Таймлайн",
  download_audio_title: "Скачать аудиозапись",
  download_title: "Скачать",
  download_body: "Что сохранить из этой записи.",
  download_video: "Видео",
  download_audio: "Аудио",
  download_transcript: "Транскрипт",
  download_markdown: "Транскрипт в Markdown",
  download_json: "Транскрипт в JSON",
  download_all: "Всё одним архивом",
  profile_title: "Профиль",
  profile_name: "Аккаунт Corder",
  profile_sub: "Локальный профиль",
  profile_account: "Настройки аккаунта",
  profile_signout: "Выйти",
  profile_integrations: "Интеграции",
  profile_soon: "Скоро",

  rec_label: "Идёт запись",
  rec_stop: "Остановить запись",
  trans_label: "Идёт расшифровка",
  trans_stop: "Остановить расшифровку",
  trans_cancelled: "Расшифровка остановлена",

  clarify_question: "Сколько людей было на звонке?",
  clarify_just_me: "Только я",
  clarify_dismiss_title: "Скрыть подсказку",
  empty_delete_question: "Транскрипт пустой.",
  empty_delete_btn: "Удалить сессию",
  empty_archive_btn: "Архивировать сессию",

  ctx_retranscribe: "Расшифровать заново",
  ctx_archive: "В архив",
  ctx_pin: "Закрепить",
  ctx_unpin: "Открепить",
  ctx_rename: "Переименовать",
  sidebar_pinned: "Закреплённые",

  speaker_self: "Я",
  speaker_rename_title: "Кликни чтобы переименовать",
  inline_editor_placeholder: "Имя",

  toast_copied: "Транскрипт скопирован",
  toast_copy_failed: "Не удалось скопировать",
  toast_retranscribe_started: "Запускаю расшифровку…",
  toast_retranscribe_failed: "Не удалось запустить расшифровку",
  toast_deleted: "Запись удалена",
  toast_archived: "Перенесено в архив",
  toast_undo: "Отменить",
  toast_boost_on: "Усилить ВКЛ",
  toast_boost_off: "Усилить ВЫКЛ",
  toast_settings_failed: "Не удалось сохранить настройку",

  no_meeting_selected_title: "Запись не выбрана",
  no_meeting_selected_body: "Выбери запись из списка слева, или нажми Start в menu bar.",
  error_label: "Ошибка",
  loading: "Загрузка…",

  update_available_label: "Доступен апдейт",
  update_available_title: "Нажмите чтобы установить",

  archive_open_title: "Открыть архив",
  archive_title: "Архив",
  archive_empty: "Архив пуст.",
  archive_select_all: "Выбрать всё",
  archive_action_restore: "Восстановить",
  archive_action_delete_forever: "Удалить навсегда",
  archive_retention_note: "Записи в архиве хранятся 7 дней, потом удаляются автоматически.",
  archive_purge_in: (days) => {
    if (days <= 0) return "сегодня";
    if (days === 1) return "завтра";
    const m10 = days % 10, m100 = days % 100;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return `через ${days} дня`;
    return `через ${days} дней`;
  },
  archive_close_title: "Закрыть",
  toast_archive_restored: (n) => `Восстановлено: ${n}`,
  toast_archive_deleted: (n) => `Удалено навсегда: ${n}`,
  confirm_delete_forever: (n) => `Удалить навсегда ${n} записей? Это действие нельзя отменить.`,
};

const en: Strings = {
  breadcrumb_records: "Recordings",

  sidebar_search: "Search recordings…",
  sidebar_empty: "No recordings yet. Click Start in the menu bar.",
  sidebar_no_match: "No matches.",
  status_recording: "recording",
  status_transcribing: "transcribing",
  status_ready: "ready",
  status_failed: "failed",
  participants: (n) => `${n} participant${n === 1 ? "" : "s"}`,

  tab_transcript: "Transcript",
  tab_summary: "Summary",
  tab_settings: "Settings",
  settings_draft_note: "Draft. Settings still in progress.",
  settings_sec_notifications: "Notifications",
  settings_notifications: "System notifications",
  settings_notifications_desc: "Notify on recording start, transcript ready, and network loss.",
  settings_sec_capture: "Capture",
  settings_video: "Screen video recording",
  settings_video_desc: "Save a video of what was on screen during the meeting.",
  settings_system_audio: "System audio",
  settings_system_audio_desc: "Capture the other side's audio (calls, video conferences).",
  settings_mic: "Microphone",
  settings_mic_desc: "Record your own voice from the microphone.",
  settings_sec_transcription: "Transcription",
  settings_autotranscribe: "Auto-transcribe",
  settings_autotranscribe_desc: "Transcribe the recording automatically after you stop.",
  settings_autotitle: "Auto-title",
  settings_autotitle_desc: "Generate a short meeting title from the transcript.",
  settings_sec_autodetect: "Call auto-detect",
  settings_whitelist: "Always offer to record",
  settings_whitelist_desc: "Apps Corder always offers to record when they take the microphone.",
  settings_blacklist: "Never offer",
  settings_blacklist_desc: "Apps Corder ignores even when they hold the microphone (e.g. Loom, OBS, Terminal).",
  settings_list_add: "Add",
  settings_list_add_ph: "Bundle ID, e.g. us.zoom.xos",
  settings_list_remove: "Remove",
  settings_list_empty: "Empty",
  settings_list_detected: "Recently used your mic — tap to add:",
  settings_pick_search: "Search apps…",
  settings_pick_none: "No apps found",
  settings_pick_recent: "used mic",
  settings_sec_shortcut: "Shortcut",
  settings_shortcut_label: "Start/stop recording",
  settings_shortcut_desc: "A global shortcut to quickly start Corder.",
  settings_shortcut_press: "Press a combo…",
  settings_shortcut_conflict: (name) => `Conflicts with a system shortcut: ${name}. Pick another.`,
  settings_shortcut_unbound: "Couldn't bind — another app already uses this combo. Pick another.",
  settings_pro_note: "Pro features are disabled in this build.",
  settings_sec_soon: "Coming soon",
  settings_ext_title: "Browser extension",
  settings_ext_desc: "Transcribe calls inside a browser tab: Google Meet, Zoom, no app.",
  settings_mobile_title: "Mobile app",
  settings_mobile_desc: "Record and transcribe from your phone: meetings, talks, notes on the go.",
  settings_tg_title: "Telegram bot",
  settings_tg_desc: "Send voice messages to the bot. Corder saves and transcribes them.",
  settings_integrations_title: "Integrations",
  settings_integrations_desc: "Slack, Notion, CRM: push transcripts and summaries into your tools.",
  settings_calendar_title: "Calendar auto-detect",
  settings_calendar_desc: "Start recording from a calendar event, no manual trigger.",
  settings_sec_recognition: "Recognition",
  settings_vocab_placeholder: "Names, terms, acronyms: Logics7, Hrolitsky, NestJS…",
  settings_vocab_hint: "The model spells these exactly as written. The single biggest accuracy lever on technical calls.",
  settings_sec_api: "Gemini API key",
  settings_key_set: "Key is set",
  settings_key_placeholder: "Paste your Gemini API key",
  settings_key_hint: "Your own key — transcription is billed to your Google account, not a shared one. Stored locally (~/.config/corder/gemini_key, 0600).",
  settings_key_hint_set: "Key stored locally. Paste a new one to replace it.",
  settings_save: "Save",
  settings_saved: "Saved",
  settings_sec_privacy: "Privacy",
  settings_privacy_body: "Recordings, transcripts, the database and your key stay only on this Mac. Diarization (speaker separation) runs on-device. For transcription, audio is sent to the Google Gemini API; review Gemini's data terms. No telemetry, no analytics. Update checks contact the update server. Dropbox archival happens only if you set it up. Nothing is published or shared by link.",
  settings_ext_badge_soon: "Soon",
  settings_ext_cta: "Available soon",
  summary_generating: "Generating summary…",
  summary_failed: "Couldn't generate the summary",
  summary_retry: "Retry",
  transcript_search: "Search the transcript…",
  transcript_empty_failed: "Transcription failed.",
  transcript_empty_recording: "Recording…",
  transcript_no_match: (q) => `No matches for “${q}”.`,

  btn_copy: "Copy",
  btn_retranscribe: "Re-transcribe",
  btn_transcribe: "Transcribe now",
  transcript_not_transcribed: "This recording isn't transcribed yet.",
  btn_archive: "Archive",
  btn_boost: "Boost",
  btn_boost_title: "When on, every next transcription is auto-polished via Gemini Flash",
  btn_lang_title: "Change interface language",
  btn_theme_title: "Toggle light/dark theme",
  theme_light: "Light",
  theme_dark: "Dark",

  audio_card_title: "Recording",
  timeline_title: "Timeline",
  download_audio_title: "Download audio",
  download_title: "Download",
  download_body: "What to save from this recording.",
  download_video: "Video",
  download_audio: "Audio",
  download_transcript: "Transcript",
  download_markdown: "Transcript as Markdown",
  download_json: "Transcript as JSON",
  download_all: "Everything as one archive",
  profile_title: "Profile",
  profile_name: "Corder account",
  profile_sub: "Local profile",
  profile_account: "Account settings",
  profile_signout: "Sign out",
  profile_integrations: "Integrations",
  profile_soon: "Soon",

  rec_label: "Recording",
  rec_stop: "Stop recording",
  trans_label: "Transcribing",
  trans_stop: "Stop transcription",
  trans_cancelled: "Transcription stopped",

  clarify_question: "How many people were on the call?",
  clarify_just_me: "Just me",
  clarify_dismiss_title: "Dismiss",
  empty_delete_question: "Empty transcript.",
  empty_delete_btn: "Delete session",
  empty_archive_btn: "Archive Session",

  ctx_retranscribe: "Re-transcribe",
  ctx_archive: "Archive",
  ctx_pin: "Pin",
  ctx_unpin: "Unpin",
  ctx_rename: "Rename",
  sidebar_pinned: "Pinned",

  speaker_self: "I",
  speaker_rename_title: "Click to rename",
  inline_editor_placeholder: "Name",

  toast_copied: "Transcript copied",
  toast_copy_failed: "Could not copy",
  toast_retranscribe_started: "Starting transcription…",
  toast_retranscribe_failed: "Could not start transcription",
  toast_deleted: "Recording deleted",
  toast_archived: "Archived",
  toast_undo: "Undo",
  toast_boost_on: "Boost On",
  toast_boost_off: "Boost Off",
  toast_settings_failed: "Could not save setting",

  no_meeting_selected_title: "No recording selected",
  no_meeting_selected_body: "Pick a recording from the list on the left, or press Start in the menu bar.",
  error_label: "Error",
  loading: "Loading…",

  update_available_label: "Update available",
  update_available_title: "Click to install",

  archive_open_title: "Open archive",
  archive_title: "Archive",
  archive_empty: "Archive is empty.",
  archive_select_all: "Select all",
  archive_action_restore: "Restore",
  archive_action_delete_forever: "Delete forever",
  archive_retention_note: "Items in archive are kept for 7 days, then deleted automatically.",
  archive_purge_in: (days) => {
    if (days <= 0) return "today";
    if (days === 1) return "tomorrow";
    return `in ${days} days`;
  },
  archive_close_title: "Close",
  toast_archive_restored: (n) => `Restored: ${n}`,
  toast_archive_deleted: (n) => `Deleted forever: ${n}`,
  confirm_delete_forever: (n) => `Delete ${n} item${n === 1 ? "" : "s"} forever? This cannot be undone.`,
};

export const STRINGS: Record<Lang, Strings> = { ru, en };

export type T = Strings;
