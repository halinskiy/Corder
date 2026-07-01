import React from "react";
import { Loader2 } from "lucide-react";
import { Tooltip } from "./Tooltip";
import {
  cancelTranscription,
  getSettings,
  getUsage,
  setSettings,
  startRecordingNow,
  type Settings,
  type Usage,
} from "../api";
import type { T } from "../i18n";

/// One-shot random sparkle field generated on mount. Each entry is a
/// `<span>` with its own position, font size, animation delay, and
/// peak opacity — together they read as a natural twinkling cluster
/// instead of the synchronous six-star ring the `.update-pill` uses.
/// Memoized so a re-render (every 1 s from the timer) doesn't reshuffle
/// the positions and re-trigger every animation.
interface SparkleSpec {
  top: string;
  left: string;
  size: number;
  delay: number;
  peak: number;
  duration: number;
}
function makeSparkleField(count: number): SparkleSpec[] {
  const out: SparkleSpec[] = [];
  for (let i = 0; i < count; i++) {
    out.push({
      top: (Math.random() * 88) + "%",
      left: (Math.random() * 96) + "%",
      size: 3 + Math.random() * 7,
      delay: Math.random() * 3,
      peak: 0.25 + Math.random() * 0.7,
      duration: 1.8 + Math.random() * 1.6,
    });
  }
  return out;
}

interface Props {
  meetingId: string;
  /// Unix-ms timestamp the backend stamped when the pipeline first
  /// flipped this meeting into `transcribing`. The banner counter
  /// elapses from this mark — that way the user sees real backend
  /// time, not "00:00" every time they open the meeting view.
  /// `null` for legacy rows; we fall back to "now" so the counter
  /// still ticks instead of going negative.
  startedAtMs: number | null;
  /// Recording length in ms. Kept for callers; no longer drives the
  /// fill now that we have a real backend progress signal.
  durationMs: number | null;
  /// Real transcription progress in [0, 1], polled from the backend
  /// (`MeetingDetail.transcribe_progress`). `null` when the backend
  /// hasn't reported yet (legacy rows / cloud providers that don't
  /// stream per-window callbacks) — we then render an empty fill and
  /// rely on the spinner + elapsed counter for the "moving" signal.
  progress: number | null;
  /// On-device model download progress in [0, 1] while a transcription is
  /// waiting on the ~1.5 GB local model to fetch (new free-tier Mac).
  /// When set, the banner shows a "Downloading model" state and the fill
  /// tracks THIS, then switches to `progress` once the model lands.
  modelDownloadProgress: number | null;
  /// True during the silent post-download phase (tokenizer staging + the
  /// one-time ANE Core ML compile). The byte progress is pinned at 0.99 then,
  /// so we swap the frozen "Downloading model · 99%" for a "Preparing model…"
  /// indeterminate state — the compile can take minutes on a slow Mac and the
  /// old label read as a stuck download.
  modelPreparing: boolean | null;
  onCancelled: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

type UpsellKind = "speed" | "best" | "unlimited" | null;
/// Just the concrete upsell variants — `null` is the "nothing to push"
/// sentinel and isn't a valid map key. Split out so the snooze record
/// can be typed as `Partial<Record<UpsellSlot, number>>` without
/// TypeScript complaining about `null` in a key position.
type UpsellSlot = Exclude<UpsellKind, null>;

/// Resolve the upsell variant from the current settings + usage
/// snapshot. Returns `null` when nothing actionable is left to push.
///   • Free + whisperLocal       → "speed"     (push Pro for cloud speed)
///   • Paid + whisperLocal       → "best"      (flip provider to cloud,
///                                              no tier upgrade — the user
///                                              already paid for cloud)
///   • Pro + cloud bucket spent  → "unlimited" (push Max)
/// Note: we deliberately do NOT push Gemini. Whisper is cheaper per
/// minute on our side, so moving a Pro user off Whisper costs us money
/// without sharper output. The "best model" upsell flips a Max/Pro
/// user from their manually-selected local model onto the cloud model
/// they're already entitled to — same tier, better quality.
/// 4-hour snooze per upsell kind. After the user hits ✕ on a given
/// scenario (e.g. "speed") we save the timestamp into native
/// UserDefaults via `setSettings({upsell_snooze: …})` and hide that
/// scenario for the next 4 hours. The other two scenarios stay live —
/// flipping plans or running out of cloud hours surfaces a fresh
/// strip regardless of an old dismiss.
const SNOOZE_MS = 4 * 60 * 60 * 1000;
function isSnoozed(kind: UpsellSlot, map: Partial<Record<UpsellSlot, number>>): boolean {
  const ts = map[kind];
  if (typeof ts !== "number") return false;
  return Date.now() - ts < SNOOZE_MS;
}

function resolveUpsell(s: Settings | null, u: Usage | null): UpsellKind {
  if (!s || !u) return null;
  const tier = s.tier ?? "free";
  const explicit = s.transcription_provider ?? "auto";
  const effective: "gemini" | "whisper" | "groq" | "whisperLocal" =
    explicit === "auto"
      ? tier === "free"
        ? "whisperLocal"
        : "whisper"
      : explicit;

  if (effective === "whisperLocal") {
    return tier === "free" ? "speed" : "best";
  }

  if (tier === "pro") {
    const limit = u.advanced.limit_seconds;
    const used = u.advanced.used_seconds;
    const spent = limit !== null && used >= limit;
    if (spent) return "unlimited";
  }
  return null;
}

/// "Transcribing…" card. Shares the EXACT same shell as every other
/// status / empty / clarify banner in the product —
/// `.trans-banner.clarify-banner` + `.clarify-text` (body + sub) +
/// `.clarify-actions` — so the surface doesn't change size or layout
/// between recording / transcribing / failed / empty states. The
/// spinner sits inline next to the headline so the "this is moving"
/// signal is part of the title, not a separate row that grows the card.
export function TranscribingBanner({ meetingId, startedAtMs, progress, modelDownloadProgress, modelPreparing, onCancelled, onToast, t }: Props) {
  // When the on-device model is still downloading, the banner reads
  // "Downloading model" and the fill tracks the download; once the model
  // lands, modelDownloadProgress goes null and we fall back to the real
  // transcription progress. This is what tells a first-run free user
  // "it's fetching a 1.5 GB model" instead of looking frozen.
  const downloadingModel = modelDownloadProgress != null;
  // Preparing = bytes are down but we're in the silent tokenizer-stage + ANE
  // compile (minutes on a slow Mac, no callbacks → progress frozen at 0.99).
  // Show an indeterminate "Preparing model…" instead of a stuck "· 99%".
  const preparing = downloadingModel && modelPreparing === true;
  const dlPct = Math.round(Math.max(0, Math.min(1, modelDownloadProgress ?? 0)) * 100);
  // While preparing the bar is indeterminate: pin the fill to 100% (a full
  // green surface) and let the CSS pulse carry the "still working" signal —
  // no misleading percentage, since this phase has no real progress to report.
  const dlFillPct = preparing ? 100 : dlPct;
  const dlLabel = preparing
    ? (t.whisper_preparing_label ?? "Loading the model…")
    : `${t.whisper_prefetch_label ?? "Downloading model"} · ${dlPct}%`;
  const headline = downloadingModel
    ? (preparing
        ? (t.trans_preparing_model ?? "Preparing model…")
        : (t.trans_downloading_model ?? "Downloading model…"))
    : t.trans_label;
  // Backend mark when the pipeline went into .transcribing. Falling
  // back to Date.now() for legacy rows that don't carry the field —
  // keeps the timer monotonic rather than negative.
  const startedAt = startedAtMs ?? Date.now();
  const [now, setNow] = React.useState(Date.now());
  const [stopping, setStopping] = React.useState(false);
  const [settings, setSettingsState] = React.useState<Settings | null>(null);
  const [usage, setUsage] = React.useState<Usage | null>(null);
  // Dismiss is persisted server-side (UserDefaults via `/api/settings`)
  // so the cross actually MEANS something across launches and across
  // meetings — Костя's case: clicked ✕, app restarted, the same upsell
  // came back. We hydrate the timestamp map from `settings.upsell_snooze`
  // (opaque JSON the native side just round-trips) once settings land.
  // Snooze is 4 hours per upsell kind (SNOOZE_MS); after that we get another shot.
  const upsellDismissedAt: Partial<Record<UpsellSlot, number>> = React.useMemo(() => {
    const raw = settings?.upsell_snooze;
    if (!raw) return {};
    try { return JSON.parse(raw) as Partial<Record<UpsellSlot, number>>; }
    catch { return {}; }
  }, [settings?.upsell_snooze]);

  const persistSnooze = React.useCallback(async (next: Partial<Record<UpsellSlot, number>>) => {
    const json = JSON.stringify(next);
    // Optimistic local update — write the new JSON onto the cached
    // settings so subsequent reads of `upsellDismissedAt` see the
    // dismiss immediately, even before the POST round-trips.
    setSettingsState((cur) => cur ? { ...cur, upsell_snooze: json } : cur);
    // Send ONLY the changed field — the backend treats absent fields as
    // unchanged. Re-POSTing the whole cached `settings` snapshot would
    // revert any toggle the user changed in Settings since this banner
    // mounted (stale-snapshot clobber).
    try { await setSettings({ upsell_snooze: json }); }
    catch { /* server write failed — next render will reconcile on the next /api/settings poll */ }
  }, []);

  const sparkles = React.useMemo(() => makeSparkleField(28), []);

  React.useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  React.useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const [s, u] = await Promise.all([getSettings(), getUsage()]);
        if (!alive) return;
        setSettingsState(s);
        setUsage(u);
      } catch { /* keep upsell hidden on fetch failure */ }
    })();
    return () => { alive = false; };
  }, []);

  const elapsed = Math.max(0, Math.floor((now - startedAt) / 1000));
  const m = Math.floor(elapsed / 60).toString().padStart(2, "0");
  const s = (elapsed % 60).toString().padStart(2, "0");

  const onStop = async () => {
    setStopping(true);
    try {
      await cancelTranscription(meetingId);
      onToast(t.trans_cancelled, "success");
      onCancelled();
    } catch {
      setStopping(false);
      onToast(t.toast_settings_failed, "error");
    }
  };

  // Upsells are hidden for now: no paid plans are offered yet and the
  // transcription flow is still being polished. Re-enable by assigning
  // `resolveUpsell(settings, usage)` here once the pricing flow is ready.
  const upsell: UpsellKind = null;
  void resolveUpsell(settings, usage);

  const onUpsell = async () => {
    if (upsell === "best") {
      // Paid user sitting on the local model. Spec from Костя:
      //   1. flip the override to `auto` so paid tiers resolve to cloud
      //   2. CANCEL the in-flight whisperLocal run, then stop —
      //      the user re-triggers transcribe themselves so they choose
      //      when the (now-cloud) run starts on the new model.
      // While cancellation propagates we put the visible Stop button
      // into its busy state — that's the affordance Костя expects to
      // see "правда что-то идёт".
      // Snooze the "best" upsell — the user just took the action it
      // proposed, no reason to show it again on the next meeting.
      if (upsell) {
        void persistSnooze({ ...upsellDismissedAt, [upsell]: Date.now() });
      }
      setStopping(true);
      try {
        // Only the changed field (see persistSnooze note) — never re-POST
        // the whole cached snapshot.
        const next = await setSettings({ transcription_provider: "auto" });
        setSettingsState(next);
        await cancelTranscription(meetingId);
        // Don't call onCancelled() — parent polls status every ~1 s,
        // sees the pipeline flip to `.failed`, unmounts this banner.
      } catch {
        setStopping(false);
        onToast(t.toast_settings_failed, "error");
      }
      return;
    }
    // Pricing modal hidden for now — upgrade upsells route straight to
    // the pricing section on getcorder.com (in-app modal disabled until
    // the purchase flow is finalised). Re-enable the in-app modal by
    // dispatching `corder-open-pricing` again.
    (window as unknown as { corderOpenExternal?: (u: string) => void }).corderOpenExternal?.("https://getcorder.com/#pricing");
  };

  // English fallbacks live next to the consumer because i18n.ts marks
  // these keys optional (untranslated locales fall back to en at the
  // table level, but the table-level fallback only kicks in when the
  // ENTIRE locale is absent — per-key gaps still need `??`).
  const upsellCopy =
    upsell === "speed"
      ? {
          title: t.trans_upsell_speed_title ?? "Upgrade for speed",
          desc: t.trans_upsell_speed_desc ?? "Cloud transcription runs several times faster than local.",
          cta: t.trans_upsell_speed_cta ?? "Upgrade to Pro",
        }
      : upsell === "best"
      ? {
          title: t.trans_upsell_best_title ?? "Try our best model",
          desc: t.trans_upsell_best_desc ?? "Cloud transcription is faster and more accurate. Included in your plan.",
          cta: t.trans_upsell_best_cta ?? "Switch to cloud",
        }
      : upsell === "unlimited"
      ? {
          title: t.trans_upsell_unlimited_title ?? "Upgrade for unlimited",
          desc: t.trans_upsell_unlimited_desc ?? "You're out of Pro cloud hours this month.",
          cta: t.trans_upsell_unlimited_cta ?? "Upgrade to Max",
        }
      : null;

  return (
    <div className="trans-banner clarify-banner">
      <div className="clarify-text">
        <Tooltip
          multiline
          label={t.trans_slow_hint ?? "The on-device model compiles for the Neural Engine the first time it runs. That one-time step can take a few minutes on some Macs; after it, transcripts are fast."}
        >
          <div className="clarify-body clarify-body-with-icon trans-headline-hint">
            <Loader2 size={16} className="trans-inline-spinner" aria-hidden />
            <span>{headline}</span>
          </div>
        </Tooltip>
        <div className="dash-sub clarify-sub-mono">{m}:{s}</div>
      </div>
      <div className="clarify-actions clarify-actions-stack">
        <button
          className={
            "clarify-btn trans-stop-btn " +
            (downloadingModel
              ? "trans-stop-btn--downloading" + (preparing ? " trans-stop-btn--preparing" : "")
              : "danger")
          }
          style={downloadingModel ? ({ ["--wl-progress" as string]: `${dlFillPct}%` } as React.CSSProperties) : undefined}
          // While the model is downloading the button is a progress
          // INDICATOR, not a Stop control — clicking it must do nothing
          // (a click during the download was cancelling the whole run and
          // failing the meeting). It re-enables as the real Stop button
          // once the model lands and transcription proper begins.
          onClick={downloadingModel ? undefined : onStop}
          disabled={stopping || downloadingModel}
          aria-busy={stopping}
          aria-label={downloadingModel ? dlLabel : undefined}
        >
          {downloadingModel ? (
            // SAME button (identical size) temporarily showing the model
            // download instead of Stop. Reuses the green-fill + dual-label
            // mechanism from the Settings download pill (`wl-download-*`),
            // so a normal user — who has no model picker — still sees what
            // is happening. Reverts to "Stop transcription" once the model
            // lands and real transcription starts.
            <>
              <span className="wl-download-btn-fill" aria-hidden />
              <span className="wl-download-btn-label">{dlLabel}</span>
              <span className="wl-download-btn-label-fill" aria-hidden>{dlLabel}</span>
            </>
          ) : (
            <>
              {/* Real transcription progress fill, monotonic, caps at 0.99. */}
              <span
                className="trans-stop-fill"
                style={{ width: `${Math.round(Math.max(0, Math.min(1, progress ?? 0)) * 100)}%` }}
                aria-hidden
              />
              <span className="trans-stop-label">
                {stopping ? (
                  <Loader2 size={18} className="trans-inline-spinner trans-stop-spinner" aria-hidden />
                ) : (
                  t.trans_stop
                )}
              </span>
            </>
          )}
        </button>
        {downloadingModel && (
          <>
            {/* The model download/compile can take a while on a slow Mac. Let
                the user start a NEW recording without waiting for it — the
                current meeting keeps preparing in the background and transcribes
                once the model lands. Secondary (outlined) so it never competes
                with the primary progress button above. */}
            <button
              type="button"
              className="clarify-btn"
              onClick={async () => {
                try { await startRecordingNow(); }
                catch { onToast(t.toast_settings_failed, "error"); }
              }}
            >
              <span className="rec-startnew-dot" aria-hidden />
              {t.trans_start_new ?? "Start a new recording"}
            </button>
            {/* Explicit abort for a long/hot one-time setup. Previously the only
                out during the 5-18 min compile was starting ANOTHER recording,
                which reads as a trap on a slow/hot Mac. The Core ML compile is
                OS-uncancellable so it keeps caching in the background — hence the
                copy promises it resumes from cache next time, not that it stops
                the heat instantly. Tertiary text style so it stays below the two
                buttons. Routes through onStop → cancel-transcription (writes
                .failed safely) so a stray click can't corrupt anything. */}
            <Tooltip
              multiline
              label={t.trans_cancel_prepare_hint ?? "Stops transcribing this meeting. The one-time setup keeps finishing in the background, so next time it's instant."}
            >
              <button
                type="button"
                className="trans-cancel-link"
                onClick={onStop}
                disabled={stopping}
              >
                {t.trans_cancel_prepare ?? "Cancel"}
              </button>
            </Tooltip>
          </>
        )}
      </div>
      {upsellCopy && upsell && !isSnoozed(upsell, upsellDismissedAt) && (
        <div className="trans-upsell">
          <button
            type="button"
            className="trans-upsell-close"
            onClick={() => {
              void persistSnooze({ ...upsellDismissedAt, [upsell]: Date.now() });
            }}
            aria-label="Dismiss"
            title="Dismiss"
          >
            ×
          </button>
          <div className="trans-upsell-title">{upsellCopy.title}</div>
          <div className="trans-upsell-desc">{upsellCopy.desc}</div>
          <button
            type="button"
            className="update-pill trans-upsell-cta"
            onClick={onUpsell}
          >
            <span className="trans-upsell-sparkles" aria-hidden>
              {sparkles.map((sp, i) => (
                <span
                  key={i}
                  style={{
                    top: sp.top,
                    left: sp.left,
                    fontSize: `${sp.size}px`,
                    animationDelay: `${sp.delay}s`,
                    animationDuration: `${sp.duration}s`,
                    ["--sparkle-peak" as string]: sp.peak,
                  } as React.CSSProperties}
                >
                  ✦
                </span>
              ))}
            </span>
            <span className="update-pill-text">{upsellCopy.cta}</span>
          </button>
        </div>
      )}
    </div>
  );
}
