import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

const source = readFileSync(new URL('./meetingGroups.ts', import.meta.url), 'utf8');
const { outputText } = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } });
const { groupMeetings, sidebarEntries } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`);
const meeting = (id, title, started_at, extra = {}) => ({
  id, title, started_at, source: 'mcp', duration_ms: 60000,
  status: 'ready', speaker_count: 1, viewed: true, ...extra,
});

test('date suffixes form one group across sources, emoji and buckets', () => {
  const rows = [
    meeting('a', 'Telegram: Судно🍻, 22.10', 1),
    meeting('b', 'Telegram: Судно🍻, 23.10 12:30', 2, { source: 'import' }),
    meeting('c', 'Telegram: Судно🍻, 24.10.26 12:30', 3),
    meeting('d', 'Telegram: Судно🍻, 25.10.2026 12:30', 4),
    meeting('live', 'Telegram: Судно🍻, 26.10 12:30', 5, { source: null }),
    meeting('single', 'Telegram: Макс Кусто, 26.10 12:30', 6),
  ];
  const groups = groupMeetings(rows);
  assert.equal(groups.length, 1);
  assert.equal(groups[0].key, 'Telegram: Судно🍻');
  assert.equal(groups[0].latest.id, 'd');
  assert.equal(groups[0].durationMs, 240000);
  assert.deepEqual(groups[0].meetings.map(m => m.id), ['a', 'b', 'c', 'd']);
  assert.deepEqual(sidebarEntries(rows, groups).map(r => r.kind === 'group' ? r.group.key : r.meeting.id),
    ['single', 'live', 'Telegram: Судно🍻']);
});

test('exact duplicates keep the newest, count and sum only unique recordings', () => {
  const rows = [
    meeting('old', 'Telegram: Макс, 22.10 15:56', 1),
    meeting('new', 'Telegram: Макс, 22.10 15:56', 3, { viewed: false }),
    meeting('other-duration', 'Telegram: Макс, 22.10 15:56', 2, { duration_ms: 90000 }),
  ];
  const [group] = groupMeetings(rows);
  assert.deepEqual(group.meetings.map(m => m.id), ['other-duration', 'new']);
  assert.equal(group.durationMs, 150000);
  assert.equal(group.unseen, true);
  assert.equal(rows.length, 3);
  assert.equal(sidebarEntries(rows, [group]).length, 1);
  assert.equal(sidebarEntries(rows, []).length, 3);
});

test('only terminal dates are stripped and ordinary recordings stay separate', () => {
  const rows = [
    meeting('a', 'Review, 22.10 budget', 2),
    meeting('b', 'Review, 23.10 budget', 1),
    meeting('c', 'Review, 22.10', 4, { source: null }),
    meeting('d', 'Review, 23.10', 3, { source: null }),
  ];
  assert.equal(groupMeetings(rows).length, 0);
  assert.equal(sidebarEntries(rows, []).length, 4);
});

test('stack uses its newest date even when an older member is pinned', () => {
  const rows = [
    meeting('old-pinned', 'Telegram: Макс, 22.10', 1, { pinned: true }),
    meeting('pinned', 'Call', 2, { source: null, pinned: true }),
    meeting('new', 'Telegram: Макс, 26.10', 5),
    meeting('normal', 'Call', 3, { source: null }),
  ];
  const entries = sidebarEntries(rows, groupMeetings(rows));
  assert.deepEqual(entries.map(r => r.kind === 'group' ? r.group.latest.id : r.meeting.id),
    ['pinned', 'new', 'normal']);
});


test('ordinary pinned rows retain their existing order', () => {
  const rows = [
    meeting('first-pin', 'Earlier', 1, { source: null, pinned: true }),
    meeting('second-pin', 'Later', 9, { source: null, pinned: true }),
  ];
  assert.deepEqual(sidebarEntries(rows, []).map(r => r.meeting.id), ['first-pin', 'second-pin']);
});
