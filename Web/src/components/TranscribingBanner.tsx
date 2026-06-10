import React from "react";
import { Loader2 } from "lucide-react";
import {
  cancelTranscription,
  getSettings,
  getUsage,
  setSettings,
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
  /// Recording length in ms — anchors the progress estimate so a long
  /// meeting fills slower than a short one. `null` falls back to a
  /// fixed time constant.
  durationMs: number | null;
  onCancelled: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}

/// Asymptotic progress estimate for the Stop-button fill. We have no
/// byte-accurate signal (the heavy ASR stage is opaque and the banner
/// unmounts the instant the backend flips the row to `ready`), so we
/// model a believable "work is happening" curve instead: a fast initial
/// rise that decelerates and approaches — but never reaches — a 94%
/// ceiling. It NEVER claims done; completion is signalled by the banner
/// disappearing. `tau` (the time constant) scales with the recording
/// length so a 2-hour meeting doesn't slam to 94% in ten seconds.
function estimateProgress(elapsedSec: number, durationMs: number | null): number {
  const durationSec = durationMs && durationMs > 0 ? durationMs / 1000 : 0;
  // Cloud/local ASR runs many times faster than real time; ~15% of the
  // recording length is a decent middle-ground time constant, floored so
  // short clips still animate over a few seconds rather than instantly.
  const tau = Math.max(6, durationSec * 0.15);
  const ceiling = 0.94;
  return ceiling * (1 - Math.exp(-elapsedSec / tau));
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
export function TranscribingBanner({ meetingId, startedAtMs, durationMs, onCancelled, onToast, t }: Props) {
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

  // Progress fill (0…1) painted as a translucent dark overlay creeping
  // across the Stop button — so a long transcribe reads as "moving",
  // not a frozen spinner. Frozen at full while the user is actually
  // cancelling (the spinner takes over then).
  const progress = stopping ? 1 : estimateProgress(elapsed, durationMs);

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

  const upsell = resolveUpsell(settings, usage);

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
    // "speed" and "unlimited" route to the public pricing page; the
    // page itself differentiates Pro vs Max checkout buttons.
    const w = window as Window & { corderOpenExternal?: (u: string) => void };
    w.corderOpenExternal?.("https://getcorder.com/#pricing");
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
        <div className="clarify-body clarify-body-with-icon">
          <Loader2 size={16} className="trans-inline-spinner" aria-hidden />
          <span>{t.trans_label}</span>
        </div>
        <div className="dash-sub clarify-sub-mono">{m}:{s}</div>
      </div>
      <div className="clarify-actions clarify-actions-stack">
        <button
          className="clarify-btn danger trans-stop-btn"
          onClick={onStop}
          disabled={stopping}
          aria-busy={stopping}
        >
          {/* Translucent progress fill behind the label. width tracks the
              asymptotic estimate; the 1s timer re-renders it so it eases
              forward. CSS transition smooths each step. */}
          <span
            className="trans-stop-fill"
            style={{ width: `${Math.round(progress * 100)}%` }}
            aria-hidden
          />
          <span className="trans-stop-label">
            {stopping ? (
              <Loader2 size={18} className="trans-inline-spinner trans-stop-spinner" aria-hidden />
            ) : (
              t.trans_stop
            )}
          </span>
        </button>
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
