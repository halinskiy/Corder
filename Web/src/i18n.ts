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
  transcript_search: string;
  transcript_empty_failed: string;
  transcript_empty_recording: string;
  transcript_no_match: (q: string) => string;

  btn_copy: string;
  btn_retranscribe: string;
  btn_archive: string;
  btn_boost: string;
  btn_boost_title: string;
  btn_lang_title: string;

  audio_card_title: string;
  timeline_title: string;
  download_audio_title: string;

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
  transcript_search: "Поиск по транскрипту…",
  transcript_empty_failed: "Расшифровка не удалась.",
  transcript_empty_recording: "Идёт запись…",
  transcript_no_match: (q) => `Нет совпадений по «${q}».`,

  btn_copy: "Копировать",
  btn_retranscribe: "Расшифровать заново",
  btn_archive: "В архив",
  btn_boost: "Усилить",
  btn_boost_title: "Когда включён, каждая следующая расшифровка автоматически улучшается через Gemini Flash",
  btn_lang_title: "Сменить язык интерфейса",

  audio_card_title: "Запись",
  timeline_title: "Таймлайн",
  download_audio_title: "Скачать аудиозапись",

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
  transcript_search: "Search the transcript…",
  transcript_empty_failed: "Transcription failed.",
  transcript_empty_recording: "Recording…",
  transcript_no_match: (q) => `No matches for “${q}”.`,

  btn_copy: "Copy",
  btn_retranscribe: "Re-transcribe",
  btn_archive: "Archive",
  btn_boost: "Boost",
  btn_boost_title: "When on, every next transcription is auto-polished via Gemini Flash",
  btn_lang_title: "Change interface language",

  audio_card_title: "Recording",
  timeline_title: "Timeline",
  download_audio_title: "Download audio",

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
