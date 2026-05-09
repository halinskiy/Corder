export async function listMeetings() {
    const r = await fetch("/api/meetings");
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    return r.json();
}
export async function getMeeting(id) {
    const r = await fetch(`/api/meetings/${id}`);
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    return r.json();
}
export async function getTranscriptText(id) {
    const r = await fetch(`/api/meetings/${id}/transcript.txt`);
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    return r.text();
}
export async function renameSpeaker(meetingId, speakerId, name) {
    const r = await fetch(`/api/meetings/${meetingId}/speakers/${speakerId}/rename`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name }),
    });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function deleteMeeting(id) {
    const r = await fetch(`/api/meetings/${id}`, { method: "DELETE" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function archiveMeeting(id) {
    const r = await fetch(`/api/meetings/${id}/archive`, { method: "POST" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function restoreMeeting(id) {
    const r = await fetch(`/api/meetings/${id}/restore`, { method: "POST" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function listArchive() {
    const r = await fetch("/api/archive");
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    const j = await r.json();
    return (j.items ?? []);
}
export async function retranscribe(id) {
    const r = await fetch(`/api/meetings/${id}/retranscribe`, { method: "POST" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function cancelTranscription(id) {
    const r = await fetch(`/api/meetings/${id}/cancel-transcription`, { method: "POST" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function getLastError(id) {
    const r = await fetch(`/api/meetings/${id}/last-error`);
    if (!r.ok)
        return null;
    const j = await r.json();
    return j.error ?? null;
}
export async function setExpectedSpeakers(id, count) {
    const r = await fetch(`/api/meetings/${id}/expected-speakers`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ count }),
    });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function getRecordingState() {
    const r = await fetch("/api/recording/state");
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    return r.json();
}
export async function stopRecordingNow() {
    const r = await fetch("/api/recording/stop", { method: "POST" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function getSettings() {
    const r = await fetch("/api/settings");
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    return r.json();
}
export async function setSettings(s) {
    const r = await fetch("/api/settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(s),
    });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    return r.json();
}
export function audioSrc(id) {
    return `/api/meetings/${id}/audio`;
}
