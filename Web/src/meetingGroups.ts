import type { MeetingSummary } from "./api";

export interface MeetingGroup {
  key: string;
  meetings: MeetingSummary[];
  memberIds: Set<string>;
  latest: MeetingSummary;
  durationMs: number;
  unseen: boolean;
}

export type SidebarEntry =
  | { kind: "meeting"; meeting: MeetingSummary }
  | { kind: "group"; group: MeetingGroup };

const DATE_SUFFIX = /,\s*\d{2}\.\d{2}(?:\.(?:\d{4}|\d{2}))?\.?(?:\s+\d{2}:\d{2}(?::\d{2})?)?\s*$/u;

export function groupMeetings(meetings: MeetingSummary[]): MeetingGroup[] {
  const candidates = new Map<string, MeetingSummary[]>();
  for (const meeting of meetings) {
    if (meeting.source !== "mcp" && meeting.source !== "import") continue;
    const key = meeting.title?.replace(DATE_SUFFIX, "").trim();
    if (!key) continue;
    const members = candidates.get(key) ?? [];
    members.push(meeting);
    candidates.set(key, members);
  }
  const groups: MeetingGroup[] = [];
  for (const [key, members] of candidates) {
    if (members.length < 2) continue;
    const unique = new Map<string, MeetingSummary>();
    for (const meeting of [...members].sort((a, b) => b.started_at - a.started_at)) {
      const identity = JSON.stringify([meeting.title, meeting.duration_ms ?? null]);
      if (!unique.has(identity)) unique.set(identity, meeting);
    }
    const recordings = [...unique.values()].sort((a, b) => a.started_at - b.started_at);
    groups.push({
      key,
      meetings: recordings,
      memberIds: new Set(members.map(m => m.id)),
      latest: recordings[recordings.length - 1],
      durationMs: recordings.reduce((sum, m) => sum + (m.duration_ms ?? 0), 0),
      unseen: recordings.some(m => m.viewed === false),
    });
  }
  return groups;
}

export function sidebarEntries(meetings: MeetingSummary[], groups: MeetingGroup[]): SidebarEntry[] {
  const groupedIds = new Set(groups.flatMap(group => [...group.memberIds]));
  const entries: SidebarEntry[] = [
    ...meetings.filter(m => !groupedIds.has(m.id)).map(meeting => ({ kind: "meeting" as const, meeting })),
    // Exact duplicates folded into one recording leave a normal row, not a stack of one.
    ...groups.map(group => group.meetings.length > 1
      ? ({ kind: "group" as const, group })
      : ({ kind: "meeting" as const, meeting: group.latest })),
  ];
  // A stack belongs to its latest date bucket, including stacks with pinned members.
  return entries.sort((a, b) => {
    const pinnedA = a.kind === "meeting" && a.meeting.pinned;
    const pinnedB = b.kind === "meeting" && b.meeting.pinned;
    if (!!pinnedA !== !!pinnedB) return pinnedA ? -1 : 1;
    if (pinnedA && pinnedB) return 0;
    const dateA = a.kind === "meeting" ? a.meeting.started_at : a.group.latest.started_at;
    const dateB = b.kind === "meeting" ? b.meeting.started_at : b.group.latest.started_at;
    return dateB - dateA;
  });
}
