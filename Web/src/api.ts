export type MeetingStatus = "recording" | "transcribing" | "ready" | "failed";

export interface MeetingSummary {
  id: string;
  started_at: number;
  ended_at?: number;
  duration_ms?: number;
  status: MeetingStatus;
  /** Auto-generated headline (transcript language). Falls back to the
   *  date label in the UI when absent. */
  title?: string | null;
  preview?: string;
  speaker_count: number;
  /** "Speaker 2 · Влад" etc. — joined names of who actually spoke. */
  speaker_names?: string;
  /** Pinned sessions sort to a group at the very top with a gold title. */
  pinned?: boolean;
  /** False = the user hasn't opened this meeting yet; drives the
   *  "unseen" gold title styling in the sidebar + Recent. */
  viewed?: boolean;
}

export interface SpeakerDTO {
  id: string;
  label: string;
  custom_name?: string | null;
  color_hex?: string | null;
}

export interface SegmentDTO {
  id: number;
  speaker_id: string;
  start_ms: number;
  end_ms: number;
  text: string;
  text_boost?: string | null;
}

export interface MeetingDetail {
  id: string;
  started_at: number;
  duration_ms?: number;
  status: MeetingStatus;
  title?: string | null;
  summary?: string | null;
  speakers: SpeakerDTO[];
  segments: SegmentDTO[];
  expected_other_speakers?: number | null;
  /// Set by the backend when video.mov is on disk locally or
  /// archived to Dropbox. The RightPanel uses it to decide
  /// whether to render the screen-capture preview above the audio.
  has_video?: boolean;
  /// JSON-encoded `[{start_ms, title}]` — Chapters tab. May be
  /// absent on rows that haven't been auto-chaptered yet.
  chapters?: string | null;
  /// Unix-ms timestamp the backend pipeline first moved the meeting
  /// into `transcribing`. The Transcribing banner uses it for the
  /// inline elapsed counter so it reflects real backend work, not
  /// the moment the user opened MeetingView.
  transcribing_started_at?: number | null;
}

export interface UsageBucket {
  used_seconds: number;
  /// `null` = unlimited (no cap drawn; bar renders a shimmer).
  limit_seconds: number | null;
}

export interface Usage {
  plan: "free" | "pro" | "max";
  advanced: UsageBucket;
  local: UsageBucket;
  resets_at_ms: number;
}

export async function getUsage(): Promise<Usage> {
  const r = await fetch("/api/usage");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

/// Send the tail of /tmp/corder.log (last ~2000 lines) to the
/// maintainer through the Cloudflare Worker → Resend pipeline.
/// Backend attaches the signed-in user's email + Corder version
/// + macOS version; the user doesn't have to type anything.
export async function submitLogs(): Promise<void> {
  const r = await fetch("/api/submit-logs", { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

/// Opens the native Welcome wizard at the sign-in step. The
/// frontend has no auth surface of its own — the wizard owns it.
export async function openWelcome(): Promise<void> {
  await fetch("/api/open-welcome", { method: "POST" });
}

export async function listMeetings(): Promise<MeetingSummary[]> {
  const r = await fetch("/api/meetings");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export async function getMeeting(id: string): Promise<MeetingDetail> {
  const r = await fetch(`/api/meetings/${id}`);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export async function getTranscriptText(id: string): Promise<string> {
  const r = await fetch(`/api/meetings/${id}/transcript.txt`);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.text();
}

export async function renameSpeaker(meetingId: string, speakerId: string, name: string | null): Promise<void> {
  const r = await fetch(`/api/meetings/${meetingId}/speakers/${speakerId}/rename`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export async function deleteMeeting(id: string): Promise<void> {
  const r = await fetch(`/api/meetings/${id}`, { method: "DELETE" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export async function archiveMeeting(id: string): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/archive`, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export async function restoreMeeting(id: string): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/restore`, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export async function pinMeeting(id: string, pinned: boolean): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/${pinned ? "pin" : "unpin"}`, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

/** Set a custom title. Empty string clears it back to the auto/date label. */
export async function renameMeeting(id: string, title: string): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/rename`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export interface ArchivedMeeting {
  id: string;
  started_at: number;
  duration_ms?: number;
  archived_at: number;
  /** When the row will be hard-deleted (ms epoch). archived_at + 7 days. */
  purge_at: number;
}

export async function listArchive(): Promise<ArchivedMeeting[]> {
  const r = await fetch("/api/archive");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const j = await r.json();
  return (j.items ?? []) as ArchivedMeeting[];
}

export async function retranscribe(id: string): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/retranscribe`, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

/// Returns the cached summary or generates one on the spot (the
/// backend blocks on the Gemini call, so this request can take a few
/// seconds the first time per meeting). Pass `force=true` to skip the
/// cache and regenerate from scratch.
export async function summarize(id: string, force = false): Promise<string> {
  const url = force
    ? `/api/meetings/${id}/summarize?force=1`
    : `/api/meetings/${id}/summarize`;
  const r = await fetch(url, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const j = await r.json();
  if (j.error || !j.summary) throw new Error(j.error || "no summary");
  return j.summary as string;
}

export async function cancelTranscription(id: string): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/cancel-transcription`, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export async function getLastError(id: string): Promise<string | null> {
  const r = await fetch(`/api/meetings/${id}/last-error`);
  if (!r.ok) return null;
  const j = await r.json();
  return (j.error as string | null) ?? null;
}

export async function setExpectedSpeakers(id: string, count: number | null): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/expected-speakers`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ count }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export interface RecordingState {
  active: boolean;
  meeting_id?: string;
  started_at_ms?: number;
  stopping?: boolean;
}

export async function getRecordingState(): Promise<RecordingState> {
  const r = await fetch("/api/recording/state");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export async function stopRecordingNow(): Promise<void> {
  const r = await fetch("/api/recording/stop", { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export async function startRecordingNow(): Promise<void> {
  const r = await fetch("/api/recording/start", { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export interface Settings {
  /// All locales the LangPicker can show. Untranslated locales fall
  /// back to English at runtime (see `pickStrings` in i18n.ts) — the
  /// backend just stores the code, no translation work needed here.
  language?: string;
  vocabulary?: string;
  /** write-only: send a new Gemini key. Never returned by GET. */
  gemini_key?: string;
  /** read-only: whether a key is on disk. */
  gemini_key_set?: boolean;
  /** Functional toggles. Absent ⇒ unchanged on POST; default true. */
  notifications?: boolean;
  capture_video?: boolean;
  /** mic+system are one switch server-side (dual-track invariant). */
  capture_audio?: boolean;
  auto_transcribe?: boolean;
  auto_title?: boolean;
  auto_summary?: boolean;
  auto_chapters?: boolean;
  telemetry?: boolean;
  /** user-managed bundle ids for the call auto-detector. */
  meeting_whitelist?: string[];
  meeting_blacklist?: string[];
  /** read-only: bundle ids recently seen owning the mic. */
  detected_mic_apps?: string[];
  /** global record hotkey: Carbon key code + Carbon modifier mask. */
  record_hotkey_code?: number;
  record_hotkey_mods?: number;
  /** read-only: label, clashing macOS system shortcut (if any), bound? */
  record_hotkey_label?: string;
  record_hotkey_conflict?: string | null;
  record_hotkey_ok?: boolean;
  /** Preferred mic input device, stored as the stable Core Audio UID.
   *  Empty string / null = "use system default". */
  mic_device_uid?: string | null;
  /** read-only: discoverable input devices (current system default first). */
  audio_input_devices?: AudioInputDevice[];
  /** Paddle-issued licence key the user pasted into the Welcome wizard.
   *  Empty / null = Free tier. */
  licence_key?: string | null;
  /** Display name from the sign-in provider. Shown as the top line in
   *  the profile popover header. */
  user_name?: string | null;
  /** Email used to sign in. Shown under the name in the profile
   *  popover header. */
  user_email?: string | null;
  /** read-only: server-derived "this licence currently looks Pro" flag.
   *  Free tier when false. */
  is_pro?: boolean;
  /** read-only: paid-tier ladder rung. `free` = baseline, `pro` = paying
   *  customer, `max` = top-tier unlimited bundle. Drives the profile
   *  tier badge styling and the Sidebar Upgrade-card visibility. */
  tier?: "free" | "pro" | "max";
  /** read-only: has the user finished the Welcome wizard at least once?
   *  AppDelegate uses this to decide whether to auto-open the wizard
   *  on launch. The wizard's final step flips it. */
  onboarding_completed?: boolean;
  /** ASR provider override. `"auto"` = no override, use the tier
   *  default (Free → whisperLocal, Pro/Max → whisper). The three
   *  concrete values map 1:1 to the Swift `TranscriptionProvider`
   *  rawValues. POST `"auto"` to clear the override. */
  transcription_provider?: "auto" | "gemini" | "whisper" | "whisperLocal";
  /** read-only: is the *currently picked* WhisperKit variant fully
   *  downloaded? Convenience flag — per-variant state lives in
   *  `whisper_local_models`. */
  whisper_local_model_ready?: boolean;
  /** Picked Whisper Local variant id (e.g. "openai_whisper-large-v3_turbo").
   *  Persists across launches; POST the same field to switch. */
  whisper_local_variant?: string;
  /** Per-variant catalogue with ready/progress state. The picker
   *  renders this directly; the DownloadButton under the picker reads
   *  the currently picked entry to decide between idle / Download /
   *  Progress states. */
  whisper_local_models?: WhisperLocalModel[];
  /** read-only: is this Mac Apple Silicon? WhisperKit's Core ML
   *  artefacts are arm64-only; the picker still surfaces the option
   *  on Intel but the pipeline falls back to cloud at runtime. */
  apple_silicon?: boolean;
}

/** One installable WhisperKit variant the user can pick. */
export interface WhisperLocalModel {
  id: string;
  label: string;
  size_label: string;
  size_mb: number;
  ready: boolean;
  /** 0.0–1.0 while WhisperKit is fetching this variant; absent when
   *  no download is in flight. */
  progress?: number | null;
}

/** Start an async download for a Whisper Local variant. Returns the
 *  freshly-snapshot Settings (progress entry will be present on
 *  subsequent polls). Idempotent: a variant already on disk no-ops. */
export async function downloadWhisperLocal(id: string): Promise<Settings> {
  const r = await fetch("/api/whisper-local/download", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export interface AudioInputDevice {
  uid: string;
  name: string;
  manufacturer?: string | null;
  /** "BuiltIn" / "USB" / "Bluetooth" / "Virtual" / "Aggregate" / "Continuity" / etc. */
  transport?: string | null;
  is_system_default: boolean;
}

export async function getSettings(): Promise<Settings> {
  const r = await fetch("/api/settings");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export async function setSettings(s: Settings): Promise<Settings> {
  const r = await fetch("/api/settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(s),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export interface InstalledApp {
  bundle: string;
  name: string;
  /** Corder has seen this app own the mic recently. */
  recent: boolean;
}

export async function getInstalledApps(): Promise<InstalledApp[]> {
  const r = await fetch("/api/installed-apps");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export function appIconSrc(bundle: string): string {
  return `/api/app-icon/${encodeURIComponent(bundle)}`;
}

export function audioSrc(id: string): string {
  return `/api/meetings/${id}/audio`;
}

export function videoSrc(id: string): string {
  return `/api/meetings/${id}/video`;
}

export function transcriptSrc(id: string): string {
  return `/api/meetings/${id}/transcript.txt`;
}

export function transcriptMdSrc(id: string): string {
  return `/api/meetings/${id}/transcript.md`;
}

export function transcriptJsonSrc(id: string): string {
  return `/api/meetings/${id}/transcript.json`;
}

export function bundleSrc(id: string): string {
  return `/api/meetings/${id}/bundle.zip`;
}

export interface UpdateStatus { available: boolean; version?: string }

export async function getUpdateStatus(): Promise<UpdateStatus> {
  const r = await fetch("/api/update-status");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export async function triggerUpdateCheck(): Promise<void> {
  const r = await fetch("/api/update-check", { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

/** Clears the local account state (licence key, display name, tier)
 *  and resets `onboardingCompleted` so the Welcome wizard re-opens on
 *  next launch / window load. There is no server session to invalidate
 *  yet; this is purely a local-state reset that happens on the Swift
 *  side via `AppSettings.setLicenceKey(nil)` etc. */
export async function signOut(): Promise<void> {
  const r = await fetch("/api/account/signout", { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

/** Hard delete — wipes every meeting / speaker / segment / summary /
 *  audio file owned by the signed-in user from Supabase + local
 *  state, then relaunches the app on the Welcome wizard. GDPR
 *  "right to be forgotten" path. */
export async function deleteAccount(): Promise<void> {
  const r = await fetch("/api/account/delete", { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

/** Reveal the signed-in user's Supabase JWT for use with the public
 *  REST API and MCP clients (Claude Desktop, Cursor, ...). Throws on
 *  401 when the user isn't signed in. */
export async function getMcpToken(): Promise<string> {
  const r = await fetch("/api/account/mcp-token");
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const j = await r.json();
  return j.token as string;
}
