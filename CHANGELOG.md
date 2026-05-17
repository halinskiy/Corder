# Changelog

All notable changes to Corder. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is read by Sparkle to generate per-version release notes in
the appcast. Entries here become the "What's New" panel users see in
the in-app updater. Keep them human, terse, and oriented to user-visible
behaviour, not internal refactors.

## [Unreleased]

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
