export type MeetingStatus = "recording" | "transcribing" | "ready" | "failed";

export interface MeetingSummary {
  id: string;
  started_at: number;
  ended_at?: number;
  duration_ms?: number;
  status: MeetingStatus;
  preview?: string;
  speaker_count: number;
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
  speakers: SpeakerDTO[];
  segments: SegmentDTO[];
  boosted_text?: string | null;
  boosted_at?: number | null;
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

export async function retranscribe(id: string): Promise<void> {
  const r = await fetch(`/api/meetings/${id}/retranscribe`, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
}

export async function boostMeeting(id: string): Promise<{ ok: boolean; error?: string }> {
  const r = await fetch(`/api/meetings/${id}/boost`, { method: "POST" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
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

export interface Settings {
  boost_mode: boolean;
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

export function videoSrc(id: string): string {
  return `/api/meetings/${id}/video`;
}

export function audioSrc(id: string): string {
  return `/api/meetings/${id}/audio`;
}
