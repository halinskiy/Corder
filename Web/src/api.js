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
export async function retranscribe(id) {
    const r = await fetch(`/api/meetings/${id}/retranscribe`, { method: "POST" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
}
export async function boostMeeting(id) {
    const r = await fetch(`/api/meetings/${id}/boost`, { method: "POST" });
    if (!r.ok)
        throw new Error(`HTTP ${r.status}`);
    return r.json();
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
export function videoSrc(id) {
    return `/api/meetings/${id}/video`;
}
export function audioSrc(id) {
    return `/api/meetings/${id}/audio`;
}
