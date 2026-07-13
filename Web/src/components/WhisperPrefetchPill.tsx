import React from "react";
import { Loader2 } from "lucide-react";
import { getSettings, downloadWhisperLocal, setSettings, WhisperLocalModel } from "../api";
import type { T } from "../i18n";
import { SettingsSelect, SettingsSelectOption } from "./SettingsSelect";

/// Compound control rendered right under the Dashboard Start / Stop
/// primary button. Lists every transcription provider (cloud +
/// every local Whisper size) in one chevron pill so the user always
/// sees what model the next recording will run through. Two visual
/// modes share the slot:
///
///   1. **Picker** when the active model is ready (cloud always, or
///      a downloaded local variant). Same chevron pill SettingsSelect
///      from the Settings panel.
///   2. **Progress pill** when the active provider is `whisperLocal`
///      AND the picked variant isn't on disk yet, outline + green
///      fill + percent label. Cannot be clicked.
///
/// Visibility: always, there's no "reveal" gate. The user wanted a
/// single Start surface that also shows what's about to run; hiding
/// the picker until first Start was confusing on a cold install
/// (Pro / Max users especially, whose cloud model never needs a
/// download). Polls `/api/settings` once a second.
export function WhisperPrefetchPill({ t, onToast }: { t: T; onToast?: (m: string, k?: "success" | "error") => void }) {
  const [models, setModels] = React.useState<WhisperLocalModel[]>([]);
  const [variant, setVariant] = React.useState<string | undefined>(undefined);
  const [provider, setProvider] = React.useState<string | undefined>(undefined);
  const [tier, setTier] = React.useState<"free" | "pro" | "max">("free");
  const [isAdmin, setIsAdmin] = React.useState(false);
  // False until the first /api/settings poll lands. The provider/models
  // arrive a beat after mount, so without this the slot flashed an empty
  // picker ("Whisper Cloud · cloud" popping in late looked broken).
  const [loaded, setLoaded] = React.useState(false);

  React.useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const s = await getSettings();
        if (!alive) return;
        setVariant(s.whisper_local_variant);
        setModels(s.whisper_local_models ?? []);
        setProvider(s.transcription_provider);
        setTier((s.tier === "pro" || s.tier === "max") ? s.tier : "free");
        setIsAdmin(s.is_admin === true);
        setLoaded(true);
      } catch { /* keep last-known; next poll recovers */ }
    };
    tick();
    const id = window.setInterval(tick, 1000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);
  const paid = tier === "pro" || tier === "max";

  // Build a flat option list combining the cloud providers and every
  // available local variant. The value embeds the provider in front
  // of the local variant id so a single onChange can route both.
  type Choice = {
    value: string;
    label: string;
    meta?: string;
    provider: "gemini" | "whisper" | "groq" | "whisperLocal";
    variant?: string;
    disabled?: boolean;
  };
  // HARD provider lock. The ONLY cloud model a paying user can pick is
  // Groq Whisper, Gemini and OpenAI whisper-1 are ADMIN-ONLY (kept so
  // the dev can benchmark). Free users see ONLY local models (cloud
  // appears the moment tier flips to Pro / Max). The Worker enforces the
  // same rule server-side, so even a hand-crafted request can't route a
  // normal user through Gemini.
  const groqChoice: Choice = {
    value: "groq",
    label: t.model_groq ?? "Groq Whisper",
    meta: t.model_cloud ?? "cloud",
    provider: "groq",
  };
  const adminCloud: Choice[] = [
    { value: "gemini",  label: "Gemini Flash",  meta: "admin · cloud", provider: "gemini" },
    { value: "whisper", label: t.model_whisper_cloud ?? "Whisper Cloud", meta: "admin · cloud", provider: "whisper" },
  ];
  const cloudChoices: Choice[] = paid
    ? (isAdmin ? [groqChoice, ...adminCloud] : [groqChoice])
    : [];
  const localChoices: Choice[] = models.map((m) => ({
    value: `local:${m.id}`,
    label: m.label,
    meta: m.size_label,
    provider: "whisperLocal",
    variant: m.id,
  }));
  const allChoices: Choice[] = [...cloudChoices, ...localChoices];

  const currentValue = (() => {
    if (provider === "whisperLocal" && variant) return `local:${variant}`;
    if (provider === "groq" && paid) return "groq";
    // gemini / whisper-1: admins keep the explicit selection; for a
    // non-admin these aren't selectable (hard lock), so the picker shows
    // Groq, their only cloud model. The backend already coerces the
    // stored value on the next POST.
    if ((provider === "whisper" || provider === "gemini") && paid) {
      return isAdmin ? (provider === "gemini" ? "gemini" : "whisper") : "groq";
    }
    // Free users have no cloud option, fall back to the first
    // available local variant (or the first option overall).
    return allChoices[0]?.value ?? "";
  })();

  const onPickChoice = React.useCallback(async (next: string) => {
    const choice = allChoices.find((c) => c.value === next);
    if (!choice) return;
    setProvider(choice.provider);
    if (choice.variant) setVariant(choice.variant);
    try {
      const patch: { transcription_provider: "gemini" | "whisper" | "groq" | "whisperLocal"; whisper_local_variant?: string } = {
        transcription_provider: choice.provider,
      };
      if (choice.variant) patch.whisper_local_variant = choice.variant;
      await setSettings(patch);
      if (choice.provider === "whisperLocal" && choice.variant) {
        const model = models.find((m) => m.id === choice.variant);
        if (model && !model.ready) {
          try { await downloadWhisperLocal(choice.variant); } catch {}
        }
      }
    } catch { /* revert on the next poll */ }
  }, [allChoices, models]);

  // Pre-first-poll: render the picker with cloud options so the slot
  // never collapses, Pro / Max users staring at a blank dashboard
  // mid-launch was the previous failure mode.
  const options: SettingsSelectOption<string>[] = allChoices.map((c) => ({
    value: c.value,
    label: c.label,
    meta: c.meta,
    disabled: c.disabled,
  }));

  // First-poll loader, same slot shape as the picker, with a spinner so
  // it's clear something's loading instead of a blank/late pop-in.
  if (!loaded) {
    return (
      <div className="dash-prefetch-picker">
        <button
          type="button"
          className="settings-select-trigger dash-prefetch-loading"
          disabled
          aria-label={t.whisper_prefetch_loading ?? "Loading model…"}
        >
          <span className="settings-select-trigger-label">
            {t.whisper_prefetch_loading ?? "Loading model…"}
          </span>
          <Loader2 size={14} strokeWidth={2} className="dash-prefetch-spin" aria-hidden />
        </button>
      </div>
    );
  }

  // Active local model awaiting download → progress bar instead of picker.
  if (provider === "whisperLocal" && variant) {
    const active = models.find((m) => m.id === variant);
    if (active && !active.ready) {
      const raw = typeof active.progress === "number" ? active.progress : 0;
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
  }

  return (
    <div className="dash-prefetch-picker">
      <SettingsSelect<string>
        value={currentValue}
        options={options}
        onLockedClick={() => onToast?.(t.toast_pro_required ?? "Cloud models need Pro or Max.", "error")}
        onChange={(v) => { void onPickChoice(v); }}
        ariaLabel={t.settings_asr_label ?? "Transcription model"}
      />
    </div>
  );
}
