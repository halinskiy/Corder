// User-visible strings for the Library window. Keep keys stable —
// components import them by key, not by text.
//
// Localised dates / participant counts live in `format.ts`, not here, so
// this file is purely string lookups.
//
// Corder ships English-only. The multi-locale tables + LangPicker were
// removed (see git history if they need to come back); `Lang` is kept as
// a one-member type so the threading through the components stays intact
// and re-adding a locale is a localized change.

export type Lang = "en";

/// Single selectable language. Kept as a list (not a bare constant) so
/// the picker scaffolding can be restored without reshaping callers.
/// `cc` (ISO 3166-1 alpha-2, lowercase) drives the `flag-icons` sprite.
export const LANGS: { code: Lang; name: string; native: string; cc: string }[] = [
  { code: "en", name: "English", native: "English", cc: "gb" },
];

interface Strings {
  breadcrumb_records: string;
  breadcrumb_dashboard: string;

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
  tab_chapters?: string;
  chapters_empty_title?: string;
  chapters_empty_body?: string;
  chapters_empty_ready_body?: string;
  chapters_pending_title?: string;
  chapters_pending_body?: string;
  chapters_loading?: string;
  chapters_generate?: string;
  chapters_regenerate?: string;
  chapters_error?: string;
  chapters_search?: string;
  settings_auto_chapters_title?: string;
  settings_auto_chapters_desc?: string;
  settings_telemetry_title?: string;
  settings_telemetry_desc?: string;
  tab_settings: string;
  tab_general_settings?: string;
  tab_advanced_settings?: string;
  tab_integrations: string;
  toast_soon: string;
  settings_draft_note: string;
  settings_sec_notifications: string;
  settings_notifications: string;
  settings_notifications_desc: string;
  settings_launch_at_login_title?: string;
  settings_launch_at_login_desc?: string;
  settings_transcription_language_title?: string;
  settings_transcription_language_desc?: string;
  settings_transcription_language_auto?: string;
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
  settings_autosummary: string;
  settings_autosummary_desc: string;
  /// "Delete account" row in Settings (danger zone).
  settings_delete_account_label?: string;
  settings_delete_account_desc?: string;
  /// Strings for the API & MCP token reveal card in Settings.
  settings_api_label?: string;
  settings_api_desc?: string;
  settings_api_reveal?: string;
  settings_api_copy?: string;
  settings_api_copied?: string;
  settings_api_docs?: string;
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
  /// Microphone input device picker.
  settings_mic_device?: string;
  settings_mic_device_desc?: string;
  settings_mic_device_system?: string;
  settings_mic_device_empty?: string;
  /// Transcription model (ASR provider) picker.
  settings_asr_label?: string;
  settings_asr_desc_free?: string;
  settings_asr_desc_paid?: string;
  /// Description under the Language picker block in Settings.
  settings_language_desc?: string;
  settings_asr_auto?: string;
  settings_asr_local?: string;
  settings_asr_cloud_whisper?: string;
  settings_asr_gemini?: string;
  settings_asr_locked_toast?: string;
  settings_asr_suffix_ready?: string;
  settings_asr_suffix_download?: string;
  settings_asr_suffix_pro?: string;
  settings_asr_intel_warn?: string;
  /// CTA label on the "Download model" button.
  settings_asr_download_cta?: string;
  /// In-progress label that replaces the CTA while a download is running.
  settings_asr_downloading?: string;
  /// Dashboard pill that shows the launch-time auto-prefetch of the
  /// on-device Whisper model.
  whisper_prefetch_label?: string;
  /// Button label during the silent post-download "preparing" phase
  /// (tokenizer staging + one-time ANE compile), no percentage.
  whisper_preparing_label?: string;
  whisper_prefetch_loading?: string;
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
  transcript_search: string;
  search_prev_match: string;
  search_next_match: string;
  settings_video_perf_toast: string;
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
  lang_picker_search: string;
  lang_picker_empty: string;
  btn_theme_title: string;
  btn_theme_to_dark?: string;
  btn_theme_to_light?: string;
  settings_theme_enable_dark?: string;
  settings_theme_enable_dark_desc?: string;
  settings_model_label?: string;
  settings_model_desc?: string;
  btn_dismiss?: string;
  btn_collapse?: string;
  news_eyebrow?: string;
  settings_tier_upgrade_label?: string;
  settings_tier_upgrade_desc?: string;
  settings_tier_upgrade_btn?: string;
  settings_tier_downgrade_label?: string;
  settings_tier_downgrade_desc?: string;
  settings_tier_downgrade_btn?: string;
  settings_tier_upgrading?: string;
  settings_tier_downgrading?: string;
  settings_tier_plan_pro?: string;
  settings_tier_plan_max?: string;
  settings_tier_upgrade_desc_pro?: string;
  settings_tier_upgrade_desc_max?: string;
  theme_light: string;
  theme_dark: string;

  audio_card_title: string;
  timeline_title: string;
  download_audio_title: string;
  download_format_desc?: string;
  download_nothing?: string;
  download_title: string;
  ghost_video_title?: string;
  ghost_video_sub?: string;
  ghost_video_cta?: string;
  ghost_video_on_title?: string;
  ghost_video_on_sub?: string;
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
  profile_dashboard: string;
  profile_account: string;
  profile_language?: string;
  profile_help?: string;
  profile_check_updates?: string;
  profile_admin?: string;
  profile_delete?: string;
  profile_delete_confirm?: string;
  profile_signout: string;
  profile_pick_avatar: string;
  profile_integrations: string;
  profile_soon: string;

  rec_label: string;
  rec_stop: string;
  trans_label: string;
  trans_downloading_model?: string;
  /// Headline for the silent post-download compile phase.
  trans_preparing_model?: string;
  trans_start_new?: string;
  /// Tertiary "Cancel" during the model download/preparing phase + its hint.
  trans_cancel_prepare?: string;
  trans_cancel_prepare_hint?: string;
  trans_slow_hint?: string;
  trans_stop: string;
  trans_cancelled: string;
  trans_upsell_speed_title?: string;
  trans_upsell_speed_desc?: string;
  trans_upsell_speed_cta?: string;
  trans_upsell_best_title?: string;
  trans_upsell_best_desc?: string;
  trans_upsell_best_cta?: string;
  trans_upsell_unlimited_title?: string;
  trans_upsell_unlimited_desc?: string;
  trans_upsell_unlimited_cta?: string;
  pricing_title?: string;
  pricing_upgrade?: string;
  pricing_details?: string;
  settings_stats_title?: string;
  settings_stats_desc?: string;
  settings_preroll_title?: string;
  settings_preroll_desc?: string;
  transcribe_failed_short?: string;
  summary_failed_short?: string;
  chapters_failed_short?: string;
  send_report?: string;
  report_sent?: string;
  summary_locked_body?: string;
  chapters_locked_body?: string;

  clarify_question: string;
  clarify_just_me: string;
  clarify_dismiss_title: string;
  empty_delete_question: string;
  empty_delete_btn: string;
  empty_archive_btn: string;

  ctx_retranscribe: string;
  ctx_archive: string;
  ctx_archive_selected: (n: number) => string;
  ctx_pin: string;
  ctx_unpin: string;
  ctx_rename: string;
  sidebar_pinned: string;

  speaker_self: string;
  edit_text?: string;
  assign_line_to?: string;
  merge_speaker_into?: string;
  no_other_speakers?: string;
  edit_failed?: string;
  dashboard_tab_upcoming?: string;
  upcoming_up_next?: string;
  upcoming_none?: string;
  upcoming_none_sub?: string;
  upcoming_connect_title?: string;
  upcoming_connect_sub?: string;
  upcoming_connect_cta?: string;
  upcoming_untitled?: string;
  upcoming_soon?: string;
  upcoming_connecting?: string;
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
  dashboard_heading: string;
  dashboard_subtitle: string;
  usage_title?: string;
  usage_subtitle?: string;
  usage_advanced?: string;
  usage_local?: string;
  submit_logs_title?: string;
  submit_logs_success?: string;
  submit_logs_failed?: string;
  submit_logs_pending?: string;
  submit_logs_cooldown?: string;
  profile_signed_out_title?: string;
  profile_name_rename?: string;
  profile_signed_out_body?: string;
  profile_sign_in?: string;
  model_gemini?: string;
  model_whisper_cloud?: string;
  model_groq?: string;
  model_cloud?: string;
  model_pro_only?: string;
  toast_pro_required?: string;
  dashboard_subtitle_recording?: string;
  rec_starting?: string;
  rec_stopping?: string;
  sidebar_today?: string;
  ghost_title?: string;
  ghost_duration?: string;
  ghost_preview?: string;
  toast_undo_done?: (n: number) => string;
  profile_tier_free?: string;
  profile_tier_pro?: string;
  profile_tier_max?: string;
  profile_upgrade?: string;
  upgrade_card_title?: string;
  upgrade_card_body?: string;
  upgrade_card_cta?: string;
  dashboard_stat_total: string;
  dashboard_stat_time: string;
  dashboard_stat_thisweek: string;
  dashboard_start: string;
  /// Tooltip/label for the green "+" header button that starts a new recording.
  header_new_recording?: string;
  dashboard_recent: string;
  dashboard_recent_empty: string;
  dashboard_tab_stats: string;
  dashboard_tab_home?: string;
  dashboard_tab_recent: string;
  dashboard_sort_duration: string;
  dashboard_sort_recent: string;
  dashboard_sort_speakers: string;
  summary_empty_title: string;
  summary_empty_body: string;
  summary_loading: string;
  summary_generate: string;
  summary_regenerate: string;
  summary_error: string;
  summary_no_transcript: string;
  summary_search: string;
  error_label: string;
  loading: string;

  update_available_label: string;
  update_available_title: string;
  update_install?: string;
  update_later?: string;

  archive_open_title: string;
  archive_empty_tooltip?: string;
  archive_title: string;
  archive_empty: string;
  archive_select_all: string;
  archive_action_restore: string;
  archive_action_delete_forever: string;
  archive_retention_note: string;
  archive_purge_in: (days: number) => string;
  archive_back_to_library: string;
  archive_close_title: string;
  toast_archive_restored: (n: number) => string;
  toast_archive_deleted: (n: number) => string;
  confirm_delete_forever: (n: number) => string;

  rating_title?: string;
  rating_comment_placeholder?: string;
  rating_email_placeholder?: string;
  rating_submit?: string;
  rating_skip?: string;
  rating_thanks?: string;
}

const en: Strings = {
  breadcrumb_records: "Recordings",
  breadcrumb_dashboard: "Welcome",

  sidebar_search: "Search recordings…",
  sidebar_empty: "No recordings yet. Click Start in the menu bar.",
  sidebar_no_match: "No matches.",
  status_recording: "recording",
  status_transcribing: "transcribing",
  status_ready: "ready",
  status_failed: "failed",
  participants: (n) => `${n} participant${n === 1 ? "" : "s"}`,

  tab_integrations: "Integrations",
  toast_soon: "Coming soon",
  tab_transcript: "Transcript",
  tab_summary: "Summary",
  tab_chapters: "Chapters",
  chapters_empty_title: "Chapters appear here",
  chapters_empty_body: "Ready after the transcript.",
  chapters_empty_ready_body: "Split the transcript into chapters.",
  chapters_pending_title: "Generating chapters…",
  chapters_pending_body: "Hang tight.",
  chapters_loading: "Hang tight.",
  chapters_generate: "Generate chapters",
  chapters_regenerate: "Regenerate",
  chapters_error: "Chapters didn't work. Send a report.",
  chapters_search: "Search chapters…",
  settings_auto_chapters_title: "Auto-chapters",
  settings_auto_chapters_desc: "Split a finished transcript.",
  settings_telemetry_title: "Help improve Corder",
  settings_telemetry_desc: "Send anonymous diagnostic counts to the maintainer once a day.",
  tab_settings: "Settings",
  tab_general_settings: "General",
  tab_advanced_settings: "Advanced",
  settings_draft_note: "Draft. Settings still in progress.",
  settings_sec_notifications: "Notifications",
  settings_notifications: "System notifications",
  settings_notifications_desc: "Notify on recording start, transcript ready, and network loss.",
  settings_launch_at_login_title: "Launch at login",
  settings_launch_at_login_desc: "Open Corder automatically when your Mac starts.",
  settings_transcription_language_title: "Transcription language",
  settings_transcription_language_desc: "Auto-detect works for most calls.",
  settings_transcription_language_auto: "Auto-detect",
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
  settings_autosummary: "Auto-summary",
  settings_autosummary_desc: "Generate a structured recap as soon as the transcript is ready.",
  settings_delete_account_label: "Delete account",
  settings_delete_account_desc: "Permanently removes your account. This cannot be undone.",
  settings_api_label: "API access",
  settings_api_desc: "Use this token to connect Corder to MCP clients",
  settings_api_reveal: "Reveal MCP token",
  settings_api_copy: "Copy",
  settings_api_copied: "Copied",
  settings_api_docs: "API docs ↗",
  settings_sec_autodetect: "Call auto-detect",
  settings_whitelist: "Always offer to record",
  settings_whitelist_desc: "Apps Corder always offers to record when they take the microphone.",
  settings_blacklist: "Never offer to record",
  settings_blacklist_desc: "Apps Corder ignores even when they hold the microphone (e.g. Loom, OBS, Terminal).",
  settings_list_add: "Add",
  settings_list_add_ph: "Bundle ID, e.g. us.zoom.xos",
  settings_list_remove: "Remove",
  settings_list_empty: "Empty",
  settings_list_detected: "Recently used your mic — tap to add:",
  settings_pick_search: "Search apps…",
  settings_pick_none: "No apps found",
  settings_pick_recent: "used mic",
  settings_mic_device: "Microphone",
  settings_mic_device_desc: "Select input device which records your voice",
  settings_mic_device_system: "Auto",
  settings_mic_device_empty: "No input devices found",
  settings_asr_label: "Transcription model",
  settings_asr_desc_free: "Local Whisper on your Mac: free, offline. Pro and Max unlock cloud models.",
  settings_asr_desc_paid: "You can pin a different one.",
  settings_language_desc: "Interface language for the app.",
  settings_asr_auto: "Auto (recommended)",
  settings_asr_local: "Whisper Local (on-device)",
  settings_asr_cloud_whisper: "Whisper Cloud (OpenAI)",
  settings_asr_gemini: "Gemini 2.5 Flash",
  settings_asr_locked_toast: "Upgrade to Pro to use cloud models",
  settings_asr_suffix_ready: "ready",
  settings_asr_suffix_download: "1.5 GB download",
  settings_asr_download_cta: "Download model",
  settings_asr_downloading: "Downloading…",
  whisper_prefetch_label: "Downloading model",
  whisper_preparing_label: "Optimizing for your Mac",
  whisper_prefetch_loading: "Loading model…",
  settings_asr_suffix_pro: "Pro+",
  settings_asr_intel_warn: "Local Whisper isn't available on Intel Macs and transcription will fall back to the cloud.",
  settings_pro_note: "Pro features are disabled in this build.",
  settings_sec_soon: "Coming soon",
  settings_ext_title: "Browser extension",
  settings_ext_desc: "Transcribe calls inside a browser tab: Google Meet, Zoom, no app.",
  settings_mobile_title: "Mobile app",
  settings_mobile_desc: "Record and transcribe from your phone: meetings, talks, notes on the go.",
  settings_tg_title: "Telegram bot",
  settings_tg_desc: "Send voice messages to the bot. Corder saves and transcribes them.",
  settings_integrations_title: "Slack channel",
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
  settings_privacy_body: "Recordings, transcripts, the database and your key stay only on this Mac. Diarization (speaker separation) runs on-device. For transcription, audio is sent to the Google Gemini API; review Gemini's data terms. Anonymous reliability diagnostics are on by default and can be turned off here; they never include your recordings, transcripts, or audio. Update checks contact the update server. Dropbox archival happens only if you set it up. Nothing is published or shared by link.",
  settings_ext_badge_soon: "Soon",
  settings_ext_cta: "Available soon",
  transcript_search: "Search the transcript…",
  search_prev_match: "Previous match",
  search_next_match: "Next match",
  settings_video_perf_toast: "May affect performance",
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
  lang_picker_search: "Search a language…",
  lang_picker_empty: "No matches",
  btn_theme_title: "Toggle light/dark theme",
  btn_theme_to_dark: "Dark theme",
  btn_theme_to_light: "Light theme",
  settings_theme_enable_dark: "Dark theme",
  settings_theme_enable_dark_desc: "Dark interface.",
  settings_model_label: "Transcription model",
  settings_model_desc: "Which model the next recording is transcribed with.",
  btn_dismiss: "Dismiss",
  news_eyebrow: "New",
  settings_tier_upgrade_label: "Upgrade",
  settings_tier_upgrade_desc: "Pro Features",
  settings_tier_upgrade_desc_pro: "Pro Features",
  settings_tier_upgrade_desc_max: "Max Features",
  settings_tier_upgrade_btn: "Upgrade",
  settings_tier_downgrade_label: "Downgrade",
  settings_tier_downgrade_desc: "Free Features",
  settings_tier_downgrade_btn: "Downgrade",
  settings_tier_upgrading: "Upgrading…",
  settings_tier_downgrading: "Downgrading…",
  settings_tier_plan_pro: "Pro",
  settings_tier_plan_max: "Max",
  theme_light: "Light",
  theme_dark: "Dark",

  audio_card_title: "Recording",
  timeline_title: "Timeline",
  download_audio_title: "Download audio",
  download_format_desc: "Pick which file to save.",
  download_nothing: "Nothing to export yet.",
  download_title: "Download",
  ghost_video_title: "Capture your screen too",
  ghost_video_sub: "Allow Screen Recording to include screen video. Audio recording works without it.",
  ghost_video_cta: "Enable screen video",
  ghost_video_on_title: "Screen video",
  ghost_video_on_sub: "Your screen appears here while you record.",
  download_body: "What to save from this recording.",
  download_video: "Video + audio",
  download_audio: "Audio",
  download_transcript: "Transcript",
  download_markdown: "Transcript as Markdown",
  download_json: "Transcript as JSON",
  download_all: "Everything as one archive",
  profile_title: "Profile",
  profile_name: "Kostiantyn Halynskyi",
  profile_sub: "id #012103",
  profile_dashboard: "Welcome",
  profile_account: "Settings",
  profile_language: "Language",
  profile_help: "Get help",
  profile_check_updates: "Check for updates",
  profile_admin: "Open admin panel",
  profile_delete: "Delete account",
  profile_delete_confirm: "Delete your account and all recordings? This cannot be undone.",
  profile_signout: "Sign out",
  profile_pick_avatar: "Change avatar",
  profile_integrations: "Integrations",
  profile_soon: "Soon",

  rec_label: "Recording",
  rec_stop: "Stop recording",
  trans_label: "Transcribing",
  trans_downloading_model: "Downloading model…",
  trans_preparing_model: "Preparing model…",
  trans_start_new: "Start a new recording",
  trans_cancel_prepare: "Cancel",
  trans_cancel_prepare_hint: "Stops transcribing this meeting. The one-time setup keeps finishing in the background, so next time it's instant.",
  trans_slow_hint: "The on-device model compiles for the Neural Engine the first time it runs. That one-time step can take a few minutes on some Macs; after it, transcripts are fast.",
  trans_stop: "Stop transcription",
  trans_cancelled: "Transcription stopped",
  trans_upsell_speed_title: "Upgrade for speed",
  trans_upsell_speed_desc: "Cloud transcription runs several times faster than local.",
  trans_upsell_speed_cta: "Upgrade to Pro",
  trans_upsell_best_title: "Try our best model",
  trans_upsell_best_desc: "Cloud transcription is faster and more accurate. Included in your plan.",
  trans_upsell_best_cta: "Switch to cloud",
  trans_upsell_unlimited_title: "Upgrade for unlimited",
  trans_upsell_unlimited_desc: "You're out of Pro cloud hours this month.",
  trans_upsell_unlimited_cta: "Upgrade to Max",

  clarify_question: "How many people were on the call?",
  clarify_just_me: "Just me",
  clarify_dismiss_title: "Dismiss",
  empty_delete_question: "Empty transcript.",
  empty_delete_btn: "Delete session",
  empty_archive_btn: "Archive Session",

  ctx_retranscribe: "Re-transcribe",
  ctx_archive: "Archive",
  ctx_archive_selected: (n) => `Archive (${n})`,
  ctx_pin: "Pin",
  ctx_unpin: "Unpin",
  ctx_rename: "Rename",
  sidebar_pinned: "Pinned",

  speaker_self: "I",
  edit_text: "Edit text",
  assign_line_to: "Assign line to",
  merge_speaker_into: "Merge speaker into",
  no_other_speakers: "No other speakers",
  edit_failed: "Couldn't save the edit",
  dashboard_tab_upcoming: "Upcoming",
  upcoming_up_next: "Up next",
  upcoming_none: "No upcoming meetings",
  upcoming_none_sub: "Nothing scheduled in the next 30 days.",
  upcoming_connect_title: "See your upcoming meetings",
  upcoming_connect_sub: "Connect your calendar to line up the meetings you can record.",
  upcoming_connect_cta: "Connect calendar",
  upcoming_untitled: "Untitled meeting",
  upcoming_soon: "Soon",
  upcoming_connecting: "Waiting for Google…",
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
  dashboard_heading: "Ready when you are.",
  dashboard_subtitle: "For the most accurate transcript, wear headphones during calls.",
  dashboard_subtitle_recording: "Corder keeps recording in the background.",
  usage_title: "Monthly usage",
  usage_subtitle: "Transcription minutes this month.",
  usage_advanced: "Advanced transcription",
  usage_local: "Local Models",
  submit_logs_title: "Send a bug report",
  submit_logs_success: "Logs sent. Thanks!",
  submit_logs_failed: "Couldn't send the log. Try again.",
  submit_logs_pending: "Sending log…",
  submit_logs_cooldown: "You can send a new report in ~{m} min.",
  profile_signed_out_title: "Not signed in",
  profile_signed_out_body: "Sign in to access your account.",
  profile_sign_in: "Sign in",
  model_gemini: "Gemini Flash",
  model_whisper_cloud: "Whisper Cloud",
  model_groq: "Groq Whisper",
  model_cloud: "cloud",
  model_pro_only: "Pro+",
  toast_pro_required: "Cloud models require a Pro or Max plan.",
  rec_starting: "Starting…",
  rec_stopping: "Stopping…",
  sidebar_today: "Today",
  ghost_title: "Your first recording",
  ghost_duration: "—",
  ghost_preview: "Hit Start to begin.",
  toast_undo_done: (n) => n === 1 ? "Restored" : `Restored ${n}`,
  profile_tier_free: "Free",
  profile_tier_pro: "Pro",
  profile_tier_max: "Max",
  profile_upgrade: "Upgrade to Pro",
  upgrade_card_title: "Unlock Max",
  upgrade_card_body: "Unlimited recordings, all ASR providers, priority support",
  upgrade_card_cta: "Upgrade",
  dashboard_stat_total: "Recordings",
  dashboard_stat_time: "Total recorded",
  dashboard_stat_thisweek: "This week",
  dashboard_start: "Start recording",
  header_new_recording: "New recording",
  dashboard_recent: "Recent",
  dashboard_recent_empty: "No recordings yet.",
  dashboard_tab_stats: "Stats",
  dashboard_tab_home: "Home",
  dashboard_tab_recent: "Recent",
  dashboard_sort_duration: "Longest",
  dashboard_sort_recent: "Most recent",
  dashboard_sort_speakers: "Most speakers",
  summary_empty_title: "No summary yet",
  summary_empty_body: "Generate a structured recap of this meeting.",
  summary_loading: "Generating summary…",
  summary_generate: "Generate summary",
  summary_regenerate: "Regenerate",
  summary_error: "Summary didn't work. Send a report.",
  summary_no_transcript: "The summary will appear once the meeting is transcribed.",
  summary_search: "Search the summary…",
  error_label: "Error",
  loading: "Loading…",

  update_install: "Install",
  update_later: "Later",
  update_available_label: "Update available",
  pricing_title: "Upgrade Corder",
  pricing_upgrade: "Upgrade",
  pricing_details: "Details",
  settings_stats_title: "Statistics",
  settings_stats_desc: "Show recording counters on the dashboard.",
  settings_preroll_title: "Catch the start of calls",
  settings_preroll_desc: "Keep the beginning of a detected call.",
  transcribe_failed_short: "Transcription failed.",
  summary_failed_short: "Summary didn't work.",
  chapters_failed_short: "Chapters didn't work.",
  send_report: "Send a report",
  report_sent: "Report sent.",
  summary_locked_body: "Summaries are a Pro feature.",
  chapters_locked_body: "Chapters are a Pro feature.",
  update_available_title: "Click to install",

  archive_open_title: "Open archive",
  archive_empty_tooltip: "Archive is empty",
  archive_title: "Archive",
  archive_empty: "Archive is empty.",
  archive_select_all: "Select all",
  archive_action_restore: "Restore",
  archive_action_delete_forever: "Delete forever",
  archive_retention_note: "Items in archive are kept for 7 days, then deleted automatically.",
  archive_back_to_library: "Library",
  archive_purge_in: (days) => {
    if (days <= 0) return "today";
    if (days === 1) return "tomorrow";
    return `in ${days} days`;
  },
  archive_close_title: "Close",
  toast_archive_restored: (n) => `Restored: ${n}`,
  toast_archive_deleted: (n) => `Deleted forever: ${n}`,
  confirm_delete_forever: (n) => `Delete ${n} item${n === 1 ? "" : "s"} forever? This cannot be undone.`,

  rating_title: "How is Corder treating you?",
  rating_comment_placeholder: "What can we improve? (optional)",
  rating_email_placeholder: "Email (optional)",
  rating_submit: "Send",
  rating_skip: "Skip",
  rating_thanks: "Thanks for the feedback!",
};

export const STRINGS: Partial<Record<Lang, Strings>> = { en };

/// Returns the Strings table for `lang`. English-only build, so this is
/// always `en`; kept as a function so callers don't change if locales
/// are restored.
export function pickStrings(_lang: Lang): Strings {
  return en;
}

export type T = Strings;
