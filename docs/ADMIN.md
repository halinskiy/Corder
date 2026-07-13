# Admin Panel, Contract

Worker is live at `https://corder-api.empqwork.workers.dev` with the
endpoints below. Frontend (`getcorder.com/admin`) talks to them with the
operator's Supabase JWT in `Authorization: Bearer <jwt>`. The worker
verifies the JWT against Supabase + checks `app_metadata.role === "admin"`;
non-admin tokens get `403 admin role required`.

## One-time setup

1. **Run the migration** in Supabase SQL editor:
   <https://supabase.com/dashboard/project/cfsajlsctzxgixjwslni/sql>
   File: `supabase/migrations/20260601_admin_news.sql`.

2. **Grant yourself admin role.** In the same SQL editor:
   ```sql
   update auth.users
     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
       || jsonb_build_object('role', 'admin')
     where email = 'hegona3@gmail.com';
   ```
   Sign out + back in (or refresh the JWT), `app_metadata.role` is
   baked into the token at issue time, not read live.

## Public `/news` (used by Corder app)

Already updated to read from the `news_active` view. No frontend change
needed, the React `NewsBanner` consumes the same `{ items: NewsItem[] }`
shape it always did. Audience filtering happens client-side.

## Admin endpoints

All require `Authorization: Bearer <admin JWT>`.

### Users

| Method | Path                       | Body / Query                | Returns                                |
|--------|----------------------------|-----------------------------|----------------------------------------|
| GET    | `/admin/users`             | `?page=1&per_page=200`      | GoTrue admin listing (raw passthrough) |
| POST   | `/admin/users/:id/tier`    | `{"tier":"free\|pro\|max"}` | `{ok:true,user:{…}}`                   |
| POST   | `/admin/users/:id/role`    | `{"role":"admin"\|null}`    | `{ok:true,user:{…}}`                   |
| DELETE | `/admin/users/:id`         |,                           | `{ok:true}`                            |

User row carries `id`, `email`, `created_at`, `last_sign_in_at`,
`app_metadata.tier`, `app_metadata.role`. Usage rollup (meetings count,
total seconds, provider breakdown), TBD; needs a Supabase RPC that
aggregates the `meetings` / `segments` tables.

`role` is orthogonal to `tier`: granting (`"admin"`) or revoking (`null`)
the admin role merges into `app_metadata` without touching the tier. The
Worker refuses to revoke the **caller's own** role (self-lockout guard).
In the admin UI it surfaces as a fourth "Admin" value in the per-row Plan
dropdown, gated behind an inline confirm.

The admin role does more than gate this panel: it is the **transcription
provider lock**. Non-admin users can transcribe ONLY through Groq Whisper
(cloud) plus the single on-device WhisperKit model (Whisper Turbo,
`openai_whisper-large-v3_turbo`). Gemini and OpenAI whisper-1
are admin-only, kept so the operator can benchmark providers. The app
mirrors `app_metadata.role == "admin"` into `AppSettings.isAdmin` via
`SupabaseTierSync`; the only transcription-model picker lives in Settings
and is shown ONLY for an admin token (non-admins choose no model
anywhere, the home-screen picker is gone), and that picker is what unlocks
the Gemini / whisper-1 routes for an admin, while the Worker
returns 403 on `/transcribe/gemini` and `/transcribe/whisper` for a
non-admin. So promoting a user to admin also lets them pick those
providers, not just see the panel.

### News

| Method | Path                | Body                                    | Returns                              |
|--------|---------------------|-----------------------------------------|--------------------------------------|
| GET    | `/admin/news`       |,                                       | `{items: NewsItemRow[]}` (incl. drafts) |
| POST   | `/admin/news`       | partial `NewsItemRow` (no id)           | `{ok:true,item: NewsItemRow}` (201)  |
| PATCH  | `/admin/news/:id`   | partial `NewsItemRow`                   | `{ok:true,item: NewsItemRow}`        |
| DELETE | `/admin/news/:id`   |,                                       | `{ok:true}`                          |

`NewsItemRow` columns (mirror `news_items` table):

```ts
{
  id: string;                     // uuid, server-generated on POST
  title: string;                  // required
  subtitle?: string | null;
  body?: string | null;
  cta_label?: string | null;
  cta_action?: "dismiss" | "open_url" | "open_settings" | null;
  cta_url?: string | null;
  secondary_label?: string | null;
  secondary_action?: "dismiss" | "open_url" | "open_settings" | null;
  secondary_url?: string | null;
  starts_at: string;              // ISO; default now()
  ends_at: string;                // ISO; default now()+7d
  audience: "all" | "free" | "pro" | "max";  // default "all"
  dismissible: boolean;           // default true
  is_draft: boolean;              // default false
  created_at: string;
  updated_at: string;
  created_by: string | null;      // operator uuid
}
```

### Logs (bug reports + AI summary)

Backed by the `bug_reports` table (migration `20260606_bug_reports.sql`).
Every 🐞 Send-report from the app still emails + files a GitHub issue, but
now ALSO stores the report here and, in the background, asks Gemini Flash
for a short triage summary (`title` / `summary` / `severity`).

The `log_tail` the app ships is now scoped to the last ~3 launch
sessions (not just the current one), because a user usually reopens the
app before reporting, so the meeting that misbehaved is one or two
sessions back. It also keeps the full transcription / capture pipeline
flow lines (provider chosen, dual-track mode, per-track turn counts,
capture device / Bluetooth route), not only error lines, so a quality
bug that throws no error (for example far-end voice bleeding into the
mic on speakers) is still explainable from the log. The report button in
the app is always available now, rather than being hidden when no
error-regex line matched.

| Method | Path                        | Body | Returns                              |
|--------|-----------------------------|------|--------------------------------------|
| GET    | `/admin/logs`               | `?limit=100&archived=true&severity=high&q=text` | `{items: BugReportRow[]}` (newest first, **no** `log_tail`; default = active only, `archived=true` = archived view; `severity` ∈ low\|medium\|high\|critical; `q` = free-text over title+summary+email) |
| GET    | `/admin/logs/:id`           |,    | `{item: BugReportRow}` (incl. full `log_tail`) |
| POST   | `/admin/logs/:id/summarize` |,    | `{ok:true,item: BugReportRow}` (re-runs the Gemini summary) |
| POST   | `/admin/logs/:id/archive`   | `?undo=true` to restore | `{ok:true,item: BugReportRow}` (soft-archive; row stays, leaves active list) |
| POST   | `/admin/logs/bulk-archive`  | `{ids: string[], undo?: boolean}` | `{ok:true,count,items}` (archive/restore many in one call) |

`BugReportRow` columns (mirror `bug_reports`):

```ts
{
  id: string;                 // uuid
  created_at: string;         // ISO
  email: string;              // reporter, or "anonymous"
  app_version: string | null; // "0.13.x (NNN)"
  macos_version: string | null;
  log_tail: string;           // raw log, ONLY returned by GET /admin/logs/:id
  title: string | null;       // ≤ ~8-word AI headline (null until summarized)
  summary: string | null;     // 1-3 sentence AI digest
  severity: "low" | "medium" | "high" | "critical" | null;
  summary_model: string | null;
  summarized_at: string | null;
  archived_at: string | null;     // null = active; timestamp = archived
}
```

Notes:
- The summary is async (`ctx.waitUntil`), so a just-submitted row may have
  `title/summary = null` for a few seconds. The list endpoint omits
  `log_tail` (rows can be ~200 KB); fetch the single row for the full log.
- `severity` is a model guess, render it as a coloured chip, not a hard truth.

## Suggested admin UI flows

### Users tab
- Search + filter by tier
- Per-row inline tier dropdown (free / pro / max), POST `/admin/users/:id/tier`
- "..." menu → Delete (with confirm)
- Usage columns show a placeholder until the aggregate RPC ships

### News tab
- "New" button opens form: title, subtitle, body (textarea), primary CTA
  (label + action select + url), secondary CTA (same), audience select,
  dismissible toggle, date-range picker for `starts_at` / `ends_at`
  (react-day-picker `Range` mode), draft toggle, Save → POST `/admin/news`
- List view: all rows sorted by `created_at desc`, with status pills
  (Draft / Active / Scheduled / Ended), edit / duplicate / delete actions
- Edit form pre-filled from PATCH-load; Save → PATCH `/admin/news/:id`

### Logs tab (3rd tab, after News)
- List view: horizontal cards sorted `created_at desc`, one per report.
  Each card shows: `title` (bold), `summary` (1-2 lines, muted), and a meta
  row (`email` · `app_version` · relative time) + a `severity` chip
  (low=grey, medium=amber, high=orange, critical=red). While `title` is
  null show a "Summarizing…" shimmer.
- Click a card → expand / modal with the **full `log_tail`** (monospace,
  scrollable) fetched from GET `/admin/logs/:id`, plus a **Copy** button
  (copies the raw log) and a "Re-summarize" button → POST
  `/admin/logs/:id/summarize` (replaces the card's title/summary).

## Open follow-ups

- Per-user usage rollup endpoint (needs a Supabase RPC over `meetings`
  + `segments`)
- Audience filter in the worker `/news` (currently the worker returns
  every active row regardless of tier, the React banner ignores it
  for now)
- Audit log for admin actions (who promoted whom to Pro, when)
