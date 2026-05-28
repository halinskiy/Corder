import React from "react";
import { getSettings, downloadWhisperLocal, setSettings, WhisperLocalModel } from "../api";
import type { T } from "../i18n";
import { SettingsSelect, SettingsSelectOption } from "./SettingsSelect";

const REVEAL_STORAGE_KEY = "corder.dashWhisperPickerRevealed";

/// Compound control rendered right under the Dashboard Start / Stop
/// primary button. Two visual modes share the same slot:
///
///   1. **Progress pill** while the on-device Whisper model isn't on
///      disk yet — mirrors the Settings "Download model" button
///      visually (outline + green fill + percent label). Cannot be
///      clicked — the bar is informational only.
///   2. **Variant picker** once the model is ready — same chevron
///      pill `SettingsSelect` from the Settings panel, listing every
///      WhisperKit size (Turbo / Small / Base / Tiny). Picking a new
///      variant kicks off its download and the slot flips back into
///      progress-pill mode until it lands.
///
/// Visibility rules (by request):
///   • Silent on first launch — the launch-time auto-prefetch runs in
///     the background and does NOT render anything.
///   • The first time the user clicks Start, the slot reveals itself
///     and stays revealed *forever* across sessions (persisted via
///     `localStorage`). Stop does not hide it; closing the window
///     and re-opening doesn't hide it either.
///   • When the model becomes ready the progress pill morphs into the
///     variant picker. The picker stays put as the user's quick-
///     access way to swap models without opening Settings.
///
/// Polls `/api/settings` once a second — same cadence as SettingsPane.
export function WhisperPrefetchPill({
  t,
  revealedSince,
}: {
  t: T;
  /// Monotonic counter bumped by the parent every time the user
  /// presses Start. The first positive value latches reveal in
  /// localStorage; subsequent bumps are no-ops.
  revealedSince: number;
}) {
  const [models, setModels] = React.useState<WhisperLocalModel[]>([]);
  const [variant, setVariant] = React.useState<string | undefined>(undefined);
  const [revealed, setRevealed] = React.useState<boolean>(() => {
    try { return localStorage.getItem(REVEAL_STORAGE_KEY) === "1"; }
    catch { return false; }
  });
  const lastRevealedSince = React.useRef(0);

  // Parent bumped the trigger counter → reveal & persist.
  React.useEffect(() => {
    if (revealedSince !== lastRevealedSince.current && revealedSince > 0) {
      lastRevealedSince.current = revealedSince;
      if (!revealed) {
        setRevealed(true);
        try { localStorage.setItem(REVEAL_STORAGE_KEY, "1"); } catch {}
      }
    }
  }, [revealedSince, revealed]);

  // Poll settings for variant + per-model state.
  React.useEffect(() => {
    if (!revealed) return;
    let alive = true;
    const tick = async () => {
      try {
        const s = await getSettings();
        if (!alive) return;
        setVariant(s.whisper_local_variant);
        setModels(s.whisper_local_models ?? []);
      } catch { /* keep last-known; next poll recovers */ }
    };
    tick();
    const id = window.setInterval(tick, 1000);
    return () => { alive = false; window.clearInterval(id); };
  }, [revealed]);

  const onPickVariant = React.useCallback(async (next: string) => {
    if (next === variant) return;
    setVariant(next); // optimistic — picker stays in sync without waiting
    try {
      await setSettings({ whisper_local_variant: next });
      const model = models.find((m) => m.id === next);
      if (model && !model.ready) {
        // New variant isn't on disk yet — fire the download so the
        // pill mode kicks in on the next poll.
        try { await downloadWhisperLocal(next); } catch {}
      }
    } catch { /* revert on the next poll */ }
  }, [variant, models]);

  if (!revealed) return null;

  const activeModel = models.find((m) => m.id === variant);

  // No `variant` yet (first poll hasn't returned) — render nothing
  // rather than a placeholder that flashes for half a second.
  if (!activeModel) return null;

  // Mode 1: download in flight (or model not on disk).
  if (!activeModel.ready) {
    const raw = typeof activeModel.progress === "number" ? activeModel.progress : 0;
    const pct = Math.max(0, Math.min(100, Math.round(raw * 100)));
    const label = `${t.whisper_prefetch_label ?? "Downloading model"} · ${pct}%`;
    return (
      <button
        type="button"
        className="clarify-btn wl-download-btn is-loading dash-prefetch-pill"
        style={{ ["--wl-progress" as string]: `${pct}%` }}
        disabled
        aria-label={label}
      >
        <span className="wl-download-btn-fill" aria-hidden />
        <span className="wl-download-btn-label">{label}</span>
        <span className="wl-download-btn-label-fill" aria-hidden>{label}</span>
      </button>
    );
  }

  // Mode 2: model ready → variant picker.
  const options: SettingsSelectOption<string>[] = models.map((m) => ({
    value: m.id,
    label: m.label,
    meta: m.size_label,
  }));
  return (
    <div className="dash-prefetch-picker">
      <SettingsSelect<string>
        value={variant ?? activeModel.id}
        options={options}
        onChange={(v) => { void onPickVariant(v); }}
        ariaLabel={t.settings_asr_label ?? "Transcription model"}
      />
    </div>
  );
}
