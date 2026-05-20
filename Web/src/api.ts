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
/// seconds the first time per meeting).
export async function summarize(id: string): Promise<string> {
  const r = await fetch(`/api/meetings/${id}/summarize`, { method: "POST" });
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
  language?: "ru" | "en";
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
