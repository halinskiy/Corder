# Changelog

All notable changes to Corder. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is read by Sparkle to generate per-version release notes in
the appcast. Entries here become the "What's New" panel users see in
the in-app updater. Keep them human, terse, and oriented to user-visible
behaviour, not internal refactors.

## [Unreleased]

### Added

### Changed

### Fixed

## [0.13.23] — 2026-05-31

### Changed
- **Help-improve-Corder telemetry** is now **ON by default during the test period** so we get real-world signal on transcription failures we can't reproduce locally. Toggle still in Settings — flip it off and nothing leaves your Mac. Will revert to default-off before paid plans ship.

## [0.13.22] — 2026-05-31

### Added
- **Help-improve-Corder telemetry** (opt-in, off by default). New toggle in Settings; when on, the app ships a small diagnostic envelope once per 24h with version, macOS version, Mac model, RAM, tier, and aggregate counts (meetings transcribed, ready vs failed, cloud vs local). Email is SHA-256-hashed into an anonymous id before it leaves the Mac; no transcript text, no audio, no raw email. Lands in a Cloudflare D1 database (`corder-telemetry`) the maintainer can query with `wrangler d1 execute`.

## [0.13.21] — 2026-05-31

### Changed
- **Theme switch tooltip** now reads the action ("Dark theme" in light mode, "Light theme" in dark mode), not the abstract "Toggle light/dark theme".

### Fixed
- **Bug-report rate limit**: the Bug icon now refuses to fire more than once per hour. A spammed click surfaces "You can send a new report in ~X min." instead of mailing the maintainer 50 copies of the same log.

## [0.13.20] — 2026-05-31

### Fixed
- **Free avatar background**: the toolbar and popover-header avatars hard-coded a CSS `background: var(--accent)`, which won against the tier-aware SVG fill — so a Free user still saw a green chip with a black glyph instead of the intended transparent + outline treatment. Background removed; the SVG paints its own (accent for Pro/Max, transparent for Free).

## [0.13.19] — 2026-05-31

### Added
- **Failed-transcription toast** in the Library window. When the pipeline can't finish (model load failed, OOM, MIL network read error, etc.), an in-app toast surfaces *why* and what to do — picking a lighter Whisper variant when the cause is the on-device model not fitting. Other failures get the generic "tap Re-transcribe; send a bug report if it persists" hint.

## [0.13.18] — 2026-05-31

### Added
- **Send-a-bug-report with Undo.** Click the Bug icon → toast at the bottom counts down 10 s with an Undo button (same UX as Archive). The log is only sent when the countdown elapses, so an accidental click never leaves the Mac.
- **Auto-RAM-aware default Whisper variant.** Fresh installs on Macs with ≤ 8 GB RAM default to `Base` (~150 MB, ~500 MB RAM at inference) instead of `Turbo` (1.5 GB on disk, ~3 GB RAM → swap-thrashes 8 GB M1s). Picker still lets the user upgrade.
- **Sign-in CTA in the profile popover** when the account is signed out. Previously the popover read as a "logged in" surface even on a fresh install — Sign out was visible, Sign in wasn't.
- **Tier-aware avatar.** Pro / Max gets the canonical accent-green chip with a white glyph; Free gets a transparent surface with a dark glyph and a hairline outline (mirrors the secondary-button treatment).

### Changed
- **Update pill** label is now just "Update available" — no version number (the version still shows inside the Sparkle dialog when you click).
- **Update pill detection is more eager.** The `/api/update-status` poll now nudges Sparkle to do a silent background appcast check whenever the React UI hasn't seen a verdict yet — the pill no longer waits up to a day for Sparkle's scheduled check.

## [0.13.17] — 2026-05-31

### Added
- **Chapters tab** (Loom-style) next to Transcript and Summary in every meeting view. Gemini Flash Lite splits the transcript into 3–8 topical chapters with `[mm:ss]` timestamps; clicking a row seeks the audio scrubber. Generated server-side after each successful transcribe when **Auto-chapters** is on (new toggle in Settings, on by default). Routes through the same Worker proxy as transcribe / title / summary so Pro / Max users don't need a local Google API key.

## [0.13.16] — 2026-05-31

### Fixed
- **Whisper Cloud polish (`gpt-4o-mini`) now works for Pro / Max** without a local OpenAI key. `WhisperCleanup` was silently returning unchanged turns whenever the local key file was absent — it now routes through the same Worker proxy (`/transcribe/whisper-cleanup`) with JWT auth and the server-side OpenAI key.

### Changed
- **Cloud audio backup temporarily disabled.** Supabase Storage Free plan rejects single-shot uploads over 50 MB, so every recording's `system.wav` (~80 MB on a 7-min call) was failing 413 each cycle. Recordings stay local-only; the transcript still syncs to Supabase. Will flip back on the moment we migrate to Cloudflare R2 (no per-file cap, ∞ egress, free 10 GB).

## [0.13.15] — 2026-05-31

### Fixed
- **Auto-title and auto-summary now work for Pro / Max** without a local Google API key. Both helpers were checking `GeminiTranscriber.apiKey` and silently returning nil when the file wasn't on disk — they now route through the same Worker proxy as the transcribe path (server-side Google key, JWT auth).

## [0.13.14] — 2026-05-31

### Fixed
- **SupabaseSync `segments_speaker_id_fkey` (Postgres 23503)** — actually fixed this time. The 0.13.8 fix bundled speakers + segments into one ordered task but still resolved speaker UUIDs twice (once for the speakers insert, once for the segments map) via `UUID(uuidString: s.id) ?? UUID()` — which yields a fresh random UUID every call when `s.id` isn't a valid UUID string ("user-1", "other-1" etc.). Speakers landed with random A, segments pointed at random B, FK barfed. Now the speaker insert reads the SAME pre-resolved UUID the segments map uses, so the two sides always agree.

## [0.13.13] — 2026-05-31

### Added
- **Gemini cloud transcription now also works without a local API key.** A second catch-all proxy in the Worker (`/transcribe/gemini-proxy/*`) forwards the full Files-API upload chain + `generateContent` to Google with our server key, gated by `app_metadata.tier`. Pro / Max users can now pick either Whisper Cloud or Gemini Flash and have it just work — no local key files in `~/.config/corder/`.

## [0.13.12] — 2026-05-31

### Added
- **Cloud Whisper now works out of the box for Pro / Max** — Corder no longer ships its own API keys, and Pro / Max users no longer need to drop an OpenAI key into `~/.config/corder/`. The audio goes through `corder-api.empqwork.workers.dev/transcribe/whisper`, the Cloudflare Worker holds the OpenAI key server-side, and `app_metadata.tier` is the gate. Free-tier users transparently fall back to on-device Whisper as before.

## [0.13.11] — 2026-05-31

### Fixed
- **`noKey` failed transcription** when a cloud provider was picked but its API key wasn't on disk. The pipeline now checks for the key file BEFORE the call and silently falls back to on-device Whisper for the run instead of failing the meeting (same code path as the monthly-cap fallback).
- **Rating prompt no longer pesters.** Shows at most ONCE per user, pinned to the first meeting it appeared on — closing the X or sending feedback dismisses it for good. Revisiting that meeting later or opening any other meeting never re-surfaces it. Threshold also bumped back from 1 to 3 ready transcripts so the prompt doesn't appear on a test recording.

## [0.13.10] — 2026-05-31

### Fixed
- App icon stays canonical white on macOS Tahoe (26+) in **dark mode**. Tahoe auto-tints legacy `.icns` icons to near-black on dark backgrounds — we now ship an Asset Catalog with explicit dark + light variants pointing at the same canonical white squircle, so the system uses our copy instead of the auto-tinted one.

## [0.13.9] — 2026-05-31

### Changed
- Monthly usage card hidden for now — re-enabled when paid plans go live and per-tier caps mean something again. The Bug-icon button still ships logs to the maintainer, the model picker still ships under Start; only the usage rollup is gone from the Dashboard for the moment.

### Fixed
- Submit-logs reports now also land as a GitHub Issue in a private maintainer inbox (next to the existing Resend email), so triage isn't bottlenecked on inbox scrolling and long logs aren't lost mid-quote.

## [0.13.8] — 2026-05-31

### Added
- **Send a bug report** button (Bug icon) in the toolbar, left of the theme toggle. One click posts the tail of `/tmp/corder.log` to the maintainer with your email + Corder version + macOS version attached — no Terminal commands required.
- **Remote subscription tier**: at sign-in, Corder reads `app_metadata.tier` from your Supabase user and applies it locally. Pro / Max can now be granted server-side without `defaults write`.
- **Model picker always visible** under the Start button, listing every cloud provider (Gemini Flash / Whisper Cloud) AND every local Whisper size in one chevron pill. Switch with one click; if the local variant isn't on disk yet, the picker flips to a download progress bar.

### Changed
- **Dashboard cold start**: a brand-new install shows only "Ready when you are." + Start + the model picker. Stats and Monthly usage cards reveal themselves after 10 minutes of use, on first relaunch, or when you have at least one recording — and stay revealed forever.
- **Avatar**: one click on the avatar in the profile popover now rolls a fresh random glyph (with a Shuffle hover overlay), instead of opening a 9-cell picker grid.
- Per-tier monthly caps restored — Free 1h / Pro 25h / Max unlimited (the 0.13.6 hard 60-min cap was a test stub).

### Fixed
- **Hard crash on first launch for off-dev testers** ("could not load resource bundle: from /Applications/Corder.app/Corder_Corder.bundle"). SwiftPM's auto-generated `Bundle.module` accessor lives at the .app root, not in `Contents/Resources/`. Routed through our own `Bundle.corderResources` resolver that checks the realistic paths and returns nil instead of fatal-erroring.
- **SupabaseSync `segments_speaker_id_fkey` (Postgres 23503)** on every transcribe. Speakers and segments now upsert in a single ordered task so segments can never land before their referenced speakers.

## [0.13.7] — 2026-05-30

### Changed
- Monthly usage card simplified: drop the progress pills, render `Advanced transcription · 59 min left` and `Local Models · unlimited` as plain `dash-stat-row` lines so the card reads as a continuation of Recordings / Total recorded / This week above.

### Fixed
- Dashboard left column was clipping at the wrong height; OverlayScrollbar thumb could extend up to the window header. Column now pins to `height: 100%` so the thumb tracks the actual visible viewport.
- Stats and Longest columns now share the same 20 px inner padding (Longest was 22 px before).

## [0.13.6] — 2026-05-30

### Added
- **Monthly usage card** on the Dashboard: two progress bars — Advanced transcription (cloud, capped per plan) and Local Models (always unlimited). Bars start full and drain as you consume minutes; the right-hand value shows "X left" or "unlimited".
- **Advanced cap with auto-fallback to on-device Whisper.** When the monthly cloud quota is exhausted, the next recording silently transcribes through the local model — no error, no manual switch. For this release the cap is a flat **60 min for every tier** so the fallback path is testable; tier-specific caps come back with paid plans.
- **Transcribing timer** now reflects backend start time (when the pipeline first flipped to `.transcribing`), not when you opened the meeting view — no more "00:00" every time you switch to a session.

### Changed
- Selecting a meeting then returning to the Dashboard clears the sidebar's highlight (was sticking on the last opened row).
- Rating prompt: email field removed (we use your signed-in email automatically), Skip button removed (close via the X), Send is the single primary CTA — same outlined-card style as every other banner.

### Fixed
- Dashboard left column was clipping the new Usage card off the bottom of the window with no way to scroll. Native scrollbar restored.

## [0.13.5] — 2026-05-30

### Added
- Sign-in step now detects whether the email belongs to an existing account before you submit and swaps the title between **Sign In** and **Sign Up** with a soft squeeze animation. New accounts get a "Confirm password" field that slides in beneath Password — no more silent account creation.
- The Google sign-in success page (the browser tab that says "You're signed in") now has the dot-grid background from 3mpq.studio and both logos are clickable: 3mpq → studio, Corder → getcorder.com.

### Changed
- Welcome-window title for the sign-in step is no longer "Almost there" — it reflects the action you're about to take (Sign In or Sign Up).

## [0.13.4] — 2026-05-29

### Added
- "Check for updates" row in the profile menu.
- Whisper model picker on the Dashboard, revealed once you press Start (from any source).

### Changed
- Single source of truth for the transcription model is the Dashboard; the picker is removed from Settings.
- Tighter copy in Settings (API access, Delete account) and the Dashboard subtitle.
- Recordings show a neutral hollow status dot while transcribing instead of a pulsing gold one.

### Fixed
- On-device Whisper now finds its tokenizer correctly on first run (no more "Tokenizer configuration is missing").
- `isModelDownloaded` no longer reports ready while the model is still streaming bytes.

## [0.13.3] — 2026-05-28

### Added
- On-device Whisper model auto-prefetch on first launch — Free-tier default. No more 3-5 min cold-start wait on the first recording.
- Transcription-model picker pinned under the Dashboard "Ready when you are" Start button. The first time the user presses Start it reveals itself and stays revealed forever. Mode 1: progress pill while the model is downloading; mode 2: chevron picker (Turbo / Small / Base / Tiny) once it's on disk. Picking a different size kicks off its download.
- Google sign-in landing page: the Welcome wizard's Google OAuth now redirects to a styled in-app `/auth/callback` route (3mpq + Corder marks, green check, "You're signed in", ⌘W hint) instead of leaving the browser hanging on Google's account chooser. (Supabase Dashboard → Redirect URLs needs `http://127.0.0.1:*` for the loopback to pass the allowlist.)
- `PopoverShell` — single source of truth for menu-bar popover geometry (width, padding, outer / section spacing). PopoverContentView, InviteOfferView, LoadingStateView all read from it so a tweak lands on every surface at once.

### Changed
- Welcome wizard's "Sign in with email" button is always brand-green active. Bad input lights up per-field inline errors (red border + red caption under the offending capsule) instead of greying out the CTA.
- Settings → Transcription model card removed. The picker now lives only under the Dashboard primary button — single source of truth, no risk of the two surfaces drifting.
- Settings → Auto-transcribe / Auto-title / Auto-summary moved above Microphone.
- API access description trimmed to "Use this token to connect Corder to MCP clients".
- Delete account description trimmed to "Permanently removes your account. This cannot be undone."
- Dashboard idle subtitle shortened to "Start a recording in the background."
- Recording subtitle shortened to "Corder keeps recording in the background."
- Menu-bar popover layout tightened — 8 pt closer to the divider on both sides so it reads as a single grouped card.
- Settings toolbar gear is a toggle: a second tap returns to Recent/Recording (same affordance as the Archive button).
- Demo seed rows removed from first launch — new installs land on a clean, empty Library instead of canned "Daily standup" samples.

### Fixed
- WhisperKit model-folder path was off by one segment; `isModelDownloaded` reported "ready" the instant WhisperKit created placeholder packages, before the bytes finished streaming. Now it checks the in-flight progress flag, looks for `.incomplete` markers, and requires all `.mlmodelc` packages to be non-empty.
- `corder-mcp` published to npm. Install: `npx -y corder-mcp` (Claude Desktop / Cursor / Claude Code configs in the README).

## [0.13.2] — 2026-05-28

### Added
- Tooltips rolled out to more surfaces: transcript-toolbar Clarify (Users), Archive sidebar Restore, video fullscreen Close, and the Update pill — same 350 ms delay + design-system chip as the header toolbar.

### Fixed
- Tooltips no longer linger after click: clicking a tooltipped trigger hides the chip instantly and suppresses re-show until the cursor leaves and returns. (Was already partially fixed in 0.13.1; now applied across every Tooltip-wrapped surface.)

## [0.13.1] — 2026-05-28

### Fixed
- Header drag is finally rock-solid. Replaced the old hybrid (28 pt native strip + async JS-bridge for the rest) with a single full-coverage native overlay. The page reports the exact bounding rect of every interactive toolbar button via a `headerHits` bridge, and the overlay's hit-test passes events through only over those rects — drag works in every other pixel (between buttons, over breadcrumb text, all the way down to the bottom border) while hover and click on the real buttons remain native.
- Tooltips no longer linger over the button you just clicked. Click on the trigger hides the chip immediately and suppresses re-show until the cursor leaves and re-enters.

## [0.13.0] — 2026-05-28

### Added
- API access card in Settings: reveal your personal MCP token, copy it, open the API docs. Lets you plug Corder into Claude Desktop, Cursor, ChatGPT desktop or any MCP-aware client.
- `@corder/mcp` MCP server (Node, npm) — exposes `list_meetings`, `get_meeting`, `search_transcripts`, `get_summary`, `list_speakers` tools to any MCP client. Reads scoped to the signed-in user via Supabase row-level security.
- Tooltips on toolbar buttons (Settings, Archive, Theme, Copy, Refresh, Fullscreen) — fast 350 ms delay, design-system styling.
- Archive button in the toolbar is now disabled when there's nothing archived, with a "Archive is empty" tooltip.

### Changed
- Welcome wizard email/password path now uses Supabase Auth (sign-in falls back to sign-up on first attempt) so the cloud account is real from the very first session.

### Fixed
- Profile menu no longer carries a duplicate Settings row — the toolbar gear is the only canonical entry.

## [0.12.0] — 2026-05-28

### Added
- Cloud sync via Supabase: meetings, speakers, segments, summaries and audio files mirror automatically. Sign in on a second Mac and your library shows up.
- Account-scoped on-disk layout: every signed-in Google account has its own per-account folder, so multiple Google accounts on one Mac can't see each other's recordings.
- Welcome wizard now signs in through Supabase (Google OAuth + email/password), with a real session restore on launch.
- Delete account row in Settings (red CTA, confirmation prompt). Cascades through every meeting, speaker, segment, summary and Storage object owned by the user.
- Get help row in the profile popover opens https://getcorder.com/contact/ in the system browser.
- MainHeader's Settings toolbar button now lights up `.active` while the Settings pane is open, matching the Archive toggle.

### Changed
- Notifications: every banner Corder posts now replaces the previous one in Notification Center instead of stacking up.
- Welcome email fires only on first sign-in, not on every Google login. Branded Corder logo replaces the legacy avatar.
- Profile popover refactored: Dashboard + Get help on top, Sign out on the bottom with a divider; Settings moved out (toolbar gear is the canonical entry).

### Fixed
- Profile popover header reads the signed-in email / display name from Supabase instead of the hard-coded placeholder.
- Header drag no longer swallows clicks on breadcrumb / toolbar buttons. The Native title-bar strip is back to 28 pt.
- Rating banner buttons aligned to the design system; chevron stays visible on hover in custom dropdowns.
- DMG installer background re-rendered with the same Tahoe-style glass icon the Dock shows.

## [0.11.0] — 2026-05-27

### Added
- Pick a Whisper Local model size in Settings: Turbo (1.5 GB), Small (480 MB), Base (150 MB) or Tiny (75 MB). Per-variant download tracking.
- Inline "Download model" button under the Transcription model picker — primary green CTA that flips into an outlined progress bar with live percent as WhisperKit fetches the bytes.
- Language picker moved into Settings as a third dropdown alongside Microphone and Transcription model.
- Get help link in the profile menu (opens a mailto handoff to support).
- Rating banner under finished transcripts (1–5 stars, optional comment when rating ≤ 4, optional email).

### Changed
- Microphone and Transcription model dropdowns use the in-app popover style instead of the native macOS select (matches the language picker and the rest of the UI).
- Dropdowns auto-flip upward when there isn't room below the trigger.
- Profile menu spacing reworked: 8 px breathing room around each separator, Get help sits in the same group as Sign out.

### Fixed
- Download button text now stays readable across the full progress bar (no more pink-on-green from the previous blend-mode attempt).

## [0.10.0] — 2026-05-27

### Added
- Local Whisper via WhisperKit (large-v3-turbo, Core ML) as a third ASR provider — Apple Silicon only, $0/час after the one-time ~1.5 GB multilingual model download into `~/Library/Application Support/Corder/models/`. Falls back to Gemini transparently on Intel.
- OpenAI gpt-4o-mini-transcribe as optional ASR provider (default remains Gemini).
- LLM polish step (gpt-4o-mini) for Whisper transcripts — punctuation + typo cleanup, ~$0.005/час additional cost. Toggle in `AppSettings.transcriptCleanup`.
- **Welcome-wizard на первом запуске**: двухшаговый онбординг —
  карточки Microphone + Screen Recording (с deep-link в System
  Settings и passive-preflight, без рекурсивных промптов) → шаг
  Sign in (email + password ИЛИ Continue with Google). Окно
  пинит фиксированный размер 380×516, без мерцания при смене
  шага.
- **Google OAuth через loopback**: системный браузер открывает
  Google consent screen, `GoogleOAuth.signIn()` поднимает локальный
  loopback-listener, обменивает code → token → userinfo, имя и
  email кладутся в `AppSettings`.
- **DemoSeeder**: при первом запуске в БД заливаются демонстрационные
  встречи, чтобы Library не была пустой. Версия seed-rows трекается
  и старые seeds подметаются при апдейте.
- **Email backend на Cloudflare Worker** (`corder-api.empqwork.workers.dev`):
  wizard fire-and-forget POST'ит provider/email/name на `/signup`,
  Worker триггерит приветственное письмо через Resend.
- **Header drag через JS bridge**: WKWebView перестаёт глотать
  mousedown на пустых местах шапки — JS постит `drag` событие в
  нативный handler, который вызывает `window.performDrag(with:)`.
  Окно тянется за любую пустую часть header'а.
- **Brand-mark squircle icon**: канонический иконконтент — белый
  squircle с двумя чёрными вертикальными капсулами; регенерируется
  из `~/corder-brand/` (исходники + скрипты).
- **20 языков интерфейса** через `LangPicker`: globe-кнопка в шапке
  открывает попап с поиском и SVG-флагами (npm `flag-icons`).
  Полные переводы: en, uk, ru, de, fr, es, pt, it, pl, cs, tr, nl,
  sv, id, vi, ja, ko, zh, hi, ar. Языки без полного словаря
  фолбэкаются на English через `pickStrings(lang)`. Порядок в
  пикере: en → uk → ru → по глобальной популярности.
- **Дашборд** как landing-страница (`activeId === null`): Stats
  левее, сортируемый Recent правее, ResizeHandle общий с
  MeetingView. Селектор сортировки Recent (Самые длительные /
  Недавние / Больше спикеров) сохраняется в localStorage.
- **Auto-summary** (опционально, в Настройках): сразу после
  транскрибации пайплайн вызывает Gemini и кладёт структурированное
  Granola-style саммари в БД. Тогл — `Setting > Auto-summary`.
- **Summary tab** с Granola-style structured-markdown рендерером
  (`### разделы`, вложенные буллеты, **жирные** числа/решения) и
  тулбаром Copy / Refresh / Search — пиксельно совпадает с
  Transcript-тулбаром.
- **Меню профиля**: 9 SVG-вариантов аватара в 3×3 пикере
  (точка, два круга, полумесяц, ромб, скруглённый квадрат,
  треугольник, плюс, кольцо+точка, четырёхлистник), имя
  «Kostiantyn Halynskyi», id #012103, пункты Home → Dashboard,
  Settings (кросс-сурфэйс), Sign out (красная). Аватар-вариант
  сохраняется в localStorage.
- **Mark-as-viewed**: непросмотренные записи в сайдбаре и Recent
  отрисованы золотистым заголовком (миграция БД v16, колонка
  `viewed_at`). Снимается автоматически при первом открытии
  сессии в статусе `.ready`.
- **Auto-archive коротких безмолвных записей**: если запись была
  короче 60 секунд и не уловлено ни одного звука выше речевого
  пола — Corder сразу переносит её в Архив (7-дневное удержание),
  показывает in-window тост через WKWebView-bridge
  (`corder-toast` CustomEvent) и системное уведомление.
- **Popover silence warning**: если во время записи никто не
  говорил > 10 минут — в meнюбар-попапе над кнопкой Stop появляется
  янтарная карточка «Всё ещё идёт запись / Никто не говорил
  10 минут».
- Настройки реально работают: тумблеры (уведомления, видео экрана,
  авто-транскрипт, авто-название) сохраняются и читаются на бэкенде.
- Глобальный шорткат записи (по умолчанию ⌘⇧F). Carbon
  `RegisterEventHotKey`, без Accessibility. Внутри настроек —
  «нажмите комбинацию», лейбл и предупреждение о конфликте.
- Белый / чёрный списки приложений для авто-предложения записи —
  Corder перестаёт спрашивать про микро в Telegram / Discord /
  что угодно, что ты добавил в blacklist; whitelist наоборот
  заставляет предложить.
- Пикер приложений вместо ручного ввода bundle id: список
  установленных приложений с настоящими иконками,
  поиск, недавние «owners of mic».
- Категория «Интеграции» в попапе профиля (Google, Apple,
  Telegram, Slack, Calendar) с реальными лого — вынесено из
  «coming soon» в Настройках.
- Новый дизайн-шелл `.modal-pop` для попапов: контурная карточка
  в стиле inline-баннеров (`This recording isn't transcribed yet`)
  вместо тяжёлой «стоковой» модалки. Применён к Archive и
  Download chooser.
- Кнопка `Transcribe` в баннере пустого / упавшего транскрипта —
  можно транскрибировать вручную при выключенном авто-транскрипте.
- Стоп-микс: при выключенном авто-транскрипте `audio.wav`
  (микс мик + дальняя сторона) собирается прямо на остановке,
  чтобы запись сразу проигрывалась с собеседником без
  ручного транскрипта.

### Changed
- Кнопка Archive в шапке транскрипта — только иконка
  (консистентно с соседними toolbar-кнопками).
- `.clarify-btn` стал inline-flex с gap — иконки внутри
  кнопок Restore / Delete в Archive стоят ровно рядом
  с текстом, без поломки text-only вызовов.
- Per-process детектор микрофона: предложение записи
  теперь триггерится конкретным приложением (Discord / Zoom /
  Meet), а не любым включением микро.
- Дубль-инстанс Corder убивается при запуске — было два процесса.
- Schema v15: `output_bluetooth_at_start` на meeting row.

### Fixed
- Полная потеря системного звука после стопа: поздний буфер
  тапа после `CaptureEngine.stop()` пересоздавал и обнулял
  уже записанный `system.wav` (логи говорили
  «473088 frames captured», а файл 0 байт). Добавлен флаг
  `tearingDown` — поздние буферы дропаются, а не truncate'ят
  файл.
- Эхо в dual-track транскрипте: одинаковые реплики
  «своими словами» приписывались собеседнику. Добавлен
  `echoFiltered` поверх мика.
- BT-аудио собеседника: выбор дорожки (Core-Audio tap vs
  SCStream backup) теперь по голосовой энергии
  (`VoiceActivityDetector.voicedEnergy`), а не по факту
  Bluetooth-роута. Cache key bumped to `dual:v10:` /
  `inperson:v10:`. (Сам SCStream-бэкап сейчас пишет тишину
  в 100% записей — расследуется отдельно; компаратор корректно
  его игнорирует, тап продолжает работать.)
- Стоп-микс на BT: больше не выбирается заведомо тихий
  `system_sck.wav` — источник системы для микса тоже выбирается
  по голосовой энергии.
- Мерцание интерфейса при смене темы в WKWebView (scrollbar,
  Timeline, видео): нейтрализованы layer-promoting CSS свойства
  в `html.theme-anim *`, отдельный named-group для видео,
  задержка перерисовки 200 мс.
- FLIP-анимация видео при сворачивании из fullscreen была
  кривой: скрабер сидел в потоке и сбивал raster — переведён
  в `position: absolute`.
- Красный блоб в окне библиотеки больше не дёргается при
  переходе recording → idle: добавлена relax-огибающая на
  часах TimelineView (0.5 с easeOut), 30 Гц держится до конца
  оседания, чтобы переход 30 → 20 Гц не икнул.
- Ховер у toggle-блоков в Настройках (типа Screen video
  recording) светлее — было слишком тёмно.

## [0.9.0] — 2026-05-17

### Added
- Переименование сессии: ПКМ по сессии → «Переименовать», либо клик
  по заголовку в хлебных крошках. Пустое имя возвращает авто/дату.
- Скачивание: видео, аудио, транскрипт (TXT / Markdown / JSON) и
  ZIP-бандл — через системный диалог сохранения.
- Закрепление сессий (ПКМ → «Закрепить»): отдельная группа сверху,
  пометка золотым кружком.

### Fixed
- Запись: убрано ложное уведомление «No audio captured». Срабатывало
  на нормальных записях, сделанных при открытом окне библиотеки —
  проверка тишины читала метр уже после его сброса. Звук всё это
  время писался корректно.
- Скачивание реально работает: в WKWebView `<a download>` молча
  ничего не сохранял (Markdown и остальное) — добавлен нативный
  download-обработчик.
- Краш при двойном клике по шапке окна.
- Скелетон загрузки виден сразу при открытии библиотеки.
- Сайдбар: убран лишний зазор у скроллбара — один чёткий
  разделитель; видимая точка между длительностью и временем; мета
  больше не переносится на две строки.
- Окно тянется за любую пустую часть шапки, а не только сверху.

### Changed
- Тема по умолчанию — светлая, язык — английский.
- Кнопки языка/темы в шапке унифицированы с кнопками транскрипта
  (одинаковый размер и стиль).
- Настройки: убран ввод Gemini-ключа (подписочная модель), добавлены
  словарь распознавания и блок приватности; интеграции помечены
  «Скоро».

### Removed
- Boost (полировка через Gemini 2.5 Pro) и панель приглашения —
  не вошли в релизную модель продукта.

## [0.8.8] — 2026-05-14

### Fixed
- `video.mov` больше не стирается локально после загрузки в Dropbox.
  Из-за этого свежие записи показывали пустой плеер: видео в облаке
  есть, но первый play требовал hydrate-round-trip который часто падал
  на 404. Теперь файл лежит рядом с `audio.wav` и играется мгновенно.
- Окончательный фикс мерцающего курсора на блобе: NSTrackingArea
  переведён на `.cursorUpdate`-only, без `mouseEnteredAndExited`.
  Курсор форсится через override `cursorUpdate(with:)`, hover-scale
  по-прежнему живёт в SwiftUI `.onContinuousHover`.

## [0.8.7] — 2026-05-13

### Fixed
- Курсор на плавающем блобе перестал моргать между pointing-hand и
  стрелкой. NSTrackingArea теперь создаётся один раз, а не на каждом
  layout-цикле — раньше пересоздание синтезировало mouseExited при
  каждом тике TimelineView, попирая push'нутый курсор обратно к
  системной стрелке.
- Видео-превью в Library теперь со скруглёнными углами (`border-radius:
  8px`), совпадает по форме с карточкой Timeline ниже.

## [0.8.6] — 2026-05-13

### Fixed
- Если видео для встречи недоступно (файл удалён, нет в Dropbox или
  просто старая запись без видео), плеер больше не показывает чёрный
  прямоугольник — карточка скрывается полностью, аудио-контролы
  занимают её место сверху.

## [0.8.5] — 2026-05-13

### Performance
- В idle (приложение запущено, никто не пишет, курсор не над блобом)
  TimelineView блоба теперь полностью на паузе. Раньше даже на 6 Hz
  каждый тик прогонял полный SwiftUI ViewGraph + NSHostingView layout
  pass, что давало ~10 % фонового CPU. Стало 0 %. Анимация включается
  обратно при ховере (20 Hz) или старте записи (30 Hz).

## [0.8.4] — 2026-05-13

### Changed
- Update-pill после клика показывает короткий "busy" pulse (зелёный
  тень-импульс) пока Sparkle открывает свой диалог установки. Раньше
  было непонятно зарегистрировался ли клик.

## [0.8.3] — 2026-05-13

### Fixed
- Sparkle теперь делает silent background-check через 2 секунды после
  старта (по дефолту откладывал первую проверку на 24 ч). Без этого
  pill «Доступен апдейт» не загорался у свежеустановленных копий пока
  не пройдут сутки.
- Курсор плавающего блоба наконец стабильно превращается в pointing
  hand: NSTrackingArea с mouseEntered/Exited делает push/pop, плюс
  убран конфликтующий `NSCursor.set()` из SwiftUI onContinuousHover.

## [0.8.2] — 2026-05-13

### Changed
- Update-pill теперь показывает целевую версию ("Доступен апдейт 0.8.2"),
  плюс перепроверяет статус при возврате окна в фокус — не нужно ждать
  следующего 60-секундного тика чтобы pill появился сразу после релиза.

## [0.8.1] — 2026-05-13

### Added
- Зелёный pill «Доступен апдейт» слева от языкового переключателя в
  тулбаре. Появляется когда Sparkle подтянул из appcast более свежую
  версию. Клик запускает стандартную панель обновления Sparkle.
  Дизайн — sparkle-эффект и периодический shine, повторяющий
  pricing-CTA из corder-landing.

### Fixed
- Архив выглядел неровно: разная высота строк, мелкие шрифты, метка
  «in 7 days» плавала между строкой заголовка и meta. Сетка строки
  переразложена, выравнивание справа — по первой строке заголовка,
  единый размер шрифта для duration / purge-метки.

## [0.8.0] — 2026-05-13

### Added
- **Auto-detect видео-звонков** — когда запускается знакомое meeting-
  приложение (Zoom, Teams, Meet, Slack, браузеры с веб-звонками) и
  системный микрофон занят ≥3 с, всплывает blurred-капсула с
  предложением начать запись. Тап — морф в плавающий блоб.
- **Блоб в Library** — кнопка в правом нижнем углу окна теперь тот же
  морфящийся блоб (а не Buy Me a Coffee). Клик переключает запись.
  Плавающий блоб уходит, пока Library в фокусе.
- **Видео-запись экрана** — `video.mov` теперь действительно пишется
  (HEVC, 15 fps, ~1.5 Mbps). В UI отображается немое превью над
  плеером; аудио ведёт таймлайн.
- **Skeleton UI** — список встреч и панель деталей рендерят
  плейсхолдеры на первой загрузке вместо пустоты.
- **VAD pre-pass** — RMS-gating длинных тишин перед загрузкой в
  Gemini (см. полный список в diff'е).

### Changed
- **Плейбек содержит обоих собеседников** — `audio.wav` (полный
  mic+system mix) больше не удаляется после Dropbox-загрузки, и
  audio-роут предпочитает его mic.wav-only.
- **Авто-детект ставит ожидаемых спикеров = 2** — Gemini-диаризация
  больше не разваливает одного собеседника на 5 «Speaker N» на длинном
  звонке. Группа всегда правится в clarify-баннере.
- **Блоб упирается в края экрана** — нельзя утащить за visible-frame.

### Performance
- **TimelineView блоба** — 60 Hz → state-driven 6–30 Hz, плюс пауза
  пока host-окно скрыто/occluded. Главный источник фоновой нагрузки.
- **React polling** — `getRecordingState` 1 с → 5 с в idle (1 с во
  время записи), `listMeetings` 5 с → 15 с в idle (5 с в записи).
- **MeetingDetector** — тик 2 с → 4 с; CoreAudio-запрос пропускается
  если ни одного meeting-приложения не запущено.
- **`/api/meetings`** — N+1 (по segments+speakers на каждую встречу)
  свернут в один SQL запрос с correlated subselects.

### Removed
- Buy Me a Coffee FAB и связанная обвязка.
- Мёртвый `DropboxService.getTemporaryLink()`, неиспользуемые i18n
  ключи, лишний CSS (`.video-card`, `.video-fallback`).
- Старые `.js` файлы в `Web/src/` (tsc теперь с `noEmit`).

## [0.7.0] — 2026-05-09

### Added
- **Dual-track transcription** — `mic.wav` and `system.wav` are sent to
  Gemini as **two parallel File API calls** (`async let micPart` /
  `async let sysPart`). The mic call uses a single-speaker prompt
  ("Speaker 1 always = you"); the system call uses a diarise prompt
  ("identify each remote participant"). Results are merged by start-ms.
  Eliminates the "your words got attributed to your friend during a
  silent gap" class of bug that single-stream-with-channel-gate has —
  Granola/Grain-grade quality on a local pipeline.
- **Anti-hallucination prompt directive** — Gemini was filling silent
  stretches with poetry / weather / song lyrics. The transcribe prompt
  now has an explicit "if a stretch contains no clearly intelligible
  speech, output NO segment" clause.
- **Auto-split fallback for truncated chunks** — long meetings (>9 min)
  are sliced into chunks before upload; if Gemini truncates the JSON
  response (the 65 k token cap on chunk N), the pipeline halves that
  chunk and retries, recursively up to depth 3 (~70 s minimum slice).
  No more "no segments in JSON" red toasts on hour-long meetings.
- **Raw-turn cache, keyed by audio MD5** (migration v7). After the
  first successful transcription we persist the raw Gemini turns +
  the audio hash on the meeting row. Re-mapping speakers (clarify
  banner, expected-speakers change) and re-transcribing after a
  Dropbox archive both reuse the cache — zero extra File API calls.
  Cache key is `dual:{micMD5}:{sysMD5}` for dual-track and
  `mix:{audioMD5}` for the legacy mix path.
- **Floating recording HUD pill** — Granola-style. NSPanel,
  `.canJoinAllSpaces`, persists across Space switches, draggable,
  `.nonactivatingPanel` so clicking it doesn't steal focus. Shows a
  pulsing red dot, a 7-bar EQ-style waveform driven by mic + system
  RMS (sqrt-scaled so quiet speech reads as ~50 % bar height), an
  elapsed-time counter, and a one-click Stop button.
  - `RecordingLevelMeter` singleton fed from CaptureEngine taps,
    publishes at 30 Hz with a fast-attack / slow-release envelope and
    pushes a rolling 7-slot history at 12 Hz.
- **Archive bin (migration v8 — `archived_at`)** — right-click
  → Archive moves a session out of the main list into a 7-day bin.
  Toolbar Archive button opens the archive panel. Restore or
  delete-forever per row (with `confirm()` guard) or in bulk via
  per-row checkboxes + master checkbox. `purgeExpiredArchive()` runs
  on launch and hard-deletes anything older than 7 days. Replaces the
  old hard-Delete from the row context menu and the `EmptyDeleteBanner`
  primary action.
- **`POST /api/meetings/:id/archive` + `/restore`** routes; legacy
  `DELETE /api/meetings/:id` retained for the delete-forever path.
- **`GET /api/archive`** returns archived rows with `archived_at` +
  `purge_at` (= archived_at + 7 d) for the new ArchiveView.
- **Soft-archive toast with Undo** — same pattern as the old soft-
  delete: deleting from the row context menu shows a toast with a
  5 s countdown and an `Undo` button; only after the timer expires
  does the row actually move to the bin.
- **Per-meeting clarify-banner state in localStorage** — `open` /
  `closed` is remembered so the user's choice survives a reload, but
  the auto-open heuristic (`detected ≥ 2 && expected == null`) still
  applies on first sight.
- **New app icon** — two glossy 3D pause bars on a warm-white radial
  ground. Replaces the previous green-on-white logo. Resolves the icon
  cache invalidation by bumping `CFBundleVersion` (1 → 2). The portfolio
  variant for 3mpq.studio matches.

### Changed
- **`mic.wav` / `system.wav` are kept on disk after Dropbox upload.**
  Previously we deleted both as soon as the mix was archived; the
  dual-track re-transcribe path now needs the originals. Added a small
  amount of disk pressure but the cache hit means we rarely re-upload.
- **Audio capture cleanup** — removed the unused `.microphone` SCStream
  output handler (we use AVAudioEngine on the input device for mic);
  added a `systemFramesWritten` counter + first-buffer log so future
  "no system audio captured" diagnostics are immediate.
- **MeetingRepository.setRawTurnsCache(meetingId:geminiRawTurns:audioHash:)**
  — targeted UPDATE that touches only those two columns. Replaces the
  earlier "load row → mutate → save row" pattern that re-wrote
  `status` with a stale value and tripped `resetStuckMeetings()` on
  next launch.
- **Toast Action button styling per variant** — `.toast-success
  .toast-action` is now dark-on-light, `.toast-error .toast-action`
  white-on-translucent. The Archive button on the success toast was
  invisible against the white pill.
- **Archive view spacing reuses `.donate-card` tokens** — same 4 px /
  20 px rhythm between title and body as the BMC popup.

### Removed
- **WhisperKit + FluidAudio dependencies fully retired** (already
  removed earlier in this cycle but leaving the entry here for
  archaeology). Local Whisper large-v3 transcription was producing
  meaningfully worse results than Gemini 2.5 Flash on Russian / English
  mixed audio, and the ~1.5 GB CoreML model bloat was disproportionate
  to the value. The app binary shrank from ~19 MB to ~7 MB; build time
  fell from ~25 s to ~8 s. The channel-gate
  (`Diarizer.userMicDominance`) is preserved — still used by the
  legacy single-stream Gemini path when only the mix is available
  (post-archive without cached raw turns).
- `TranscriptionProvider` toggle / setting / DTO field. Cloud is now
  the only path; if Gemini is unreachable the transcription fails with
  a network toast instead of falling back to a slow local model the
  user has been waiting for already.

### Changed
- **Boost runs on Gemini 2.5 Pro**, not Flash. ~3-4× the cost per
  minute, but materially better at preserving register and fixing
  recognition errors in mixed-language transcripts. Transcription
  itself stays on Flash.

### Added
- **Cloud transcription via Gemini 2.5 Flash** — now the default
  provider. Audio uploaded to the Google File API, transcribed with
  built-in speaker labels, deleted after the call. Existing local
  Whisper path stays available as a fallback (`defaults write
  com.3mpq.Corder Corder.transcriptionProvider whisper`).
- **Speakers clarification banner** — when the diarizer over-counts,
  the user sees a "How many people were on the call?" card with
  `Just me / 2 / 3 / 4+` pills. Clicking re-runs diarisation with that
  count pinned. Dismissible per-meeting via X (persists in localStorage).
- **Toolbar Users-icon button** — circular pill in the transcript
  toolbar; toggles the clarify banner with a soft expand/collapse animation.
- **Transcribing state UI** — recording-card-style banner with a green
  spinner, live timer, and Stop transcription button that actually
  cancels the in-flight pipeline.
- **Soft delete with Undo** — deleting any session shows a red toast
  with a 5-second countdown and an `Undo` button. The actual REST
  delete only fires after the timer expires.
- **Empty / failed-transcript banner** — replaces the "Empty transcript"
  text with a card. Failed variant offers Re-transcribe + Delete; ready
  empty offers just Delete.
- **Recording placeholder** — race-window between Stop and the pipeline
  flipping `status` to `transcribing` no longer flashes plain text;
  the rec-card visual stays put.
- **`expected_other_speakers` migration (v5)** — pinned cluster count
  per meeting, surfaced through the clarify banner.
- **Audio mix peak normalisation** — replaces the unconditional `/N`
  divisor with a peak-targeted gain so quiet recordings stay loud.
- **Section dividers in the sidebar** — hairline + breathing room
  between TODAY / YESTERDAY / N DAYS AGO buckets.
- Per-session `Cancel transcription` HTTP endpoint, `Last error` HTTP
  endpoint, surfaced in the UI as a red toast on Gemini quota /
  billing failures.
- Repository-level `docs/`: `ARCHITECTURE.md`, `SECURITY.md`,
  `DESIGN.md`, `API.md`, `DEVELOPMENT.md`, `RELEASE.md`.
- **XCTest suite** (23 tests). Covers `RangeRequest.parse`,
  `TranscriptFormatter.clipboardText`, `AudioMixer.mix`,
  `Diarizer.userMicDominance`, plus the migrations + repository.
  Caught and fixed a `customName == "you"` corner case in the
  formatter on first run.
- **Streaming Dropbox upload** (`URLSession.upload(for:fromFile:)`)
  and **streaming download** (`URLSession.download(for:)`) — both
  paths now stay in constant memory regardless of file size, so
  multi-hour recordings won't OOM.

### Changed
- **Default transcription provider is now Gemini Flash**, not local
  Whisper. The repo's "local-first" framing has been softened
  accordingly — users opt out of cloud, not into it. See `SECURITY.md`
  for the privacy implications.
- **AVAssetWriter machinery removed** from `CaptureEngine`. The writer
  was already dormant (`-16122` failures across every config we
  tried), but the orphaned ~80 lines around it are now gone.
- **Right-panel timeline bar height** is now 20 px (was 10), the per-
  speaker activity reads more clearly.
- **Toast styling** — success / info toasts are now white with a
  hairline border (matched to the EN / Copy / Delete header pills).
  Error toasts stay red. All toasts slide in/out from the bottom on
  a 280 ms cubic-bezier easing.
- **Brand accent confirmed as green** (`#1f7a4f`) — every selected /
  toggle-on / CTA fill in the app uses the accent token now. Black
  is reserved for text and icons.
- **Re-transcribe flips status synchronously** before enqueuing the
  pipeline so the UI never flashes "Empty transcript" between the
  click and the next poll.

### Fixed
- 14 stale `.js` build artefacts under `Web/src/` were left behind by
  earlier `tsc --watch` runs. Cleaned up — the source tree is `.tsx`
  only now.
- `Meeting`, `Speaker`, `Segment` structs now default optional fields
  to `nil`. Adding a new optional column no longer breaks every
  call site.
- 16 unused i18n keys removed (`bucket_today / yesterday / week_ago /
  …`, `date_today_at / yesterday_at`, `transcript_empty_ready`,
  provider toggle copy, etc.). Plus `formatTimestamp` utility and
  the `.tl-play` CSS class — also unreferenced.
- `boost_text` / `boosted_at` no longer appear in the wire DTO; the
  SQL columns persist on disk for compatibility but aren't read or
  written.

### Removed
- `/api/meetings/:id/boost` endpoint — superseded by the auto-boost
  inside the transcription pipeline (`BoostMode.isEnabled`).
- `videoSrc()` and `boostMeeting()` exports from the frontend API
  layer — neither was called.
- Legacy meeting-level `boosted_text` / `boosted_at` columns dropped
  in migration `v6_drop_legacy_boost_columns`. Per-segment `text_boost`
  (v3) is the only path now.
- `NSUserNotification` API — replaced by `UserNotifications.framework`
  via the new `NotificationsService` helper. Banners now ask for
  permission on first launch and route taps back through a
  `UNUserNotificationCenterDelegate`.
- `Routes.proxyDropboxFile` per-request proxy — replaced by a
  one-time `hydrateDropboxFile` cache restore. After the cold
  fetch, scrubbing reads straight from local disk and never blocks
  another Swifter worker.

## [0.5.0] — 2026-05-03

Snapshot of the state at the moment the repo was made public.

### Added
- Speaker diarization rebuilt around the **two-source** trick: mic vs
  system RMS gate decides "user", FluidAudio (CoreML pyannote 3.1 +
  WeSpeaker) clusters only the system-audio side. Replaces the previous
  pitch-based k-means that misassigned the user 80% of the time.
- ScreenCaptureKit **microphone capture** (macOS 15+ shared mic tap),
  replacing AVAudioEngine — the latter silently lost samples whenever
  Telegram or Zoom held an exclusive mic claim.
- Microphone TCC permission flow with explicit `AVCaptureDevice.requestAccess`
  and a temporary `setActivationPolicy(.regular)` so the prompt actually
  appears for an LSUIElement app.
- Dropbox archival: `audio.wav` uploads after each transcription, local
  files are deleted, playback streams via signed temporary links proxied
  through the local server with the correct `Content-Type`.
- "Усилить" toggle (per-user persisted setting). When on, every new
  transcript is auto-polished segment-by-segment via Gemini 2.5 Flash.
- Hallucination filter for Whisper YouTube-subtitle artefacts ("Субтитры
  сделал DimaTorzok", "Спасибо за просмотр", "Продолжение следует…").
- Audio player with green progress, hover-time tooltip, ±click scrub.
- Adaptive timeline cursor — switches to white when contrast against the
  underlying speaker tick is below WCAG 2.5.

### Changed
- Whisper model: `medium` → `large-v3` with VAD chunking. Long recordings
  (1h+) now finish; Russian quality went up substantially.
- Library window UI: right panel moved from "video card + timeline" to
  "audio card + timeline".
- Sidebar list: hover/active styling, hairline divider draws below the
  scrollbar via background gradient (no more z-index gymnastics).

### Fixed
- Whisper detected Russian as English when `detectLanguage: true` —
  pinned to `language: "ru"`.
- Cmd+C on transcript text inside WKWebView would beep — added a real
  Edit menu in `AppDelegate.installMainMenu` and `e.preventDefault()`
  on the JS keydown bridge.
- Stop button visibility in dark mode (used `windowBackgroundColor`
  for the glyph foreground).
- Right-click context menu on sidebar items closing the moment it
  opened (window-level `contextmenu` listener was racing the React
  state).

### Removed
- AVAssetWriter video output (the writer flips to `.failed` with
  `-16122` on every config tested on this macOS build).
- Pitch-based k-means clustering + per-meeting "boost prose" view.

## [0.1.0] — 2026-04-XX

Initial walking skeleton: ScreenCaptureKit recording, Whisper-CPP via
WhisperKit, SQLite via GRDB, Vite/React Library window served by Swifter.
Single-speaker, English-only, no diarization.
