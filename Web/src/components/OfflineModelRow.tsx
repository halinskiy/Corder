import React from "react";
import { getSettings, downloadWhisperLocal, WhisperLocalModel } from "../api";
import type { T } from "../i18n";

/// Advanced-settings row that lets a Pro / Max user PRE-DOWNLOAD the on-device
/// Whisper model as an OFFLINE SAFETY NET. Paid users transcribe in the cloud
/// (Groq); this model is only touched when the connection drops mid-call, so
/// it's opt-in. The app no longer stages it automatically, that ran hot for up
/// to 25 min right after an upgrade and lit a bogus "Preparing model…" on the
/// finished cloud transcript. There is a single on-device variant (Whisper
/// Turbo), so this drives `whisper_local_models[0]`.
///
/// Self-polls `/api/settings` every second while mounted (same pattern as
/// `WhisperPrefetchPill`) so the progress fill and the final ready flip land
/// without touching the rest of the Settings poll machinery. Reuses the exact
/// `.wl-download-btn` progress button from the model picker, only the resting
/// label and the ready state differ.
export function OfflineModelRow({ t }: { t: T }) {
  const [model, setModel] = React.useState<WhisperLocalModel | null>(null);
  const [loaded, setLoaded] = React.useState(false);
  // Set the instant the user clicks so the button flips to its loading shell
  // immediately, the backend snapshot returned by the POST can precede the
  // first `progress` entry (the download Task starts a beat later), so without
  // this the button would bounce back to "Download model" for one poll cycle.
  const [clicked, setClicked] = React.useState(false);

  React.useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const s = await getSettings();
        if (!alive) return;
        setModel(s.whisper_local_models?.[0] ?? null);
        setLoaded(true);
      } catch { /* keep last-known; next poll recovers */ }
    };
    tick();
    const id = window.setInterval(tick, 1000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  const ready = model?.ready === true;
  const progress = typeof model?.progress === "number" ? model.progress : null;
  const downloading = !ready && (progress !== null || clicked);
  // Progress pins at 0.99 through the silent tokenizer + ANE compile (no byte
  // callbacks). Surface that tail as "Preparing model" rather than a stuck
  // 99% bar, mirroring the TranscribingBanner.
  const preparing = downloading && progress !== null && progress >= 0.99;

  const onDownload = React.useCallback(async () => {
    if (!model || ready) return;
    setClicked(true);
    try { await downloadWhisperLocal(model.id); }
    catch { setClicked(false); }
  }, [model, ready]);

  return (
    <div className="hk-block">
      <div className="settings-row-label">
        {t.settings_offline_model_label ?? "Offline transcription"}
      </div>
      <div className="settings-row-desc">
        {t.settings_offline_model_desc ??
          "Download the on-device model so Corder can finish a transcript even if your internet drops mid-call. About 1.5 GB, downloaded once."}
      </div>

      {ready ? (
        // Done state: an inert outline button in the SAME shell as the "Add" /
        // "Open" settings buttons (base `.clarify-btn`, no accent), greyed via
        // `:disabled`. No checkmark, nothing left to do, per Kostya.
        <button
          type="button"
          className="clarify-btn wl-download-btn"
          disabled
        >
          {t.settings_offline_model_ready ?? "Ready for offline use"}
        </button>
      ) : downloading ? (
        (() => {
          const pct = Math.max(0, Math.min(100, Math.round((progress ?? 0) * 100)));
          const label = preparing
            ? (t.settings_offline_model_preparing ?? "Preparing model")
            : `${t.settings_offline_model_downloading ?? "Downloading model"} · ${pct}%`;
          return (
            <button
              type="button"
              className="clarify-btn accent wl-download-btn is-loading"
              style={{ ["--wl-progress" as string]: `${pct}%` }}
              disabled
              aria-label={label}
            >
              <span className="wl-download-btn-fill" aria-hidden />
              <span className="wl-download-btn-label">{label}</span>
              <span className="wl-download-btn-label-fill" aria-hidden>{label}</span>
            </button>
          );
        })()
      ) : (
        // Idle: neutral outline button matching the "Add" / "Open" settings
        // buttons (base `.clarify-btn`, no accent). The green progress fill
        // only appears while actually downloading (the `.is-loading` branch).
        <button
          type="button"
          className="clarify-btn wl-download-btn"
          disabled={!loaded || !model}
          onClick={() => { void onDownload(); }}
        >
          {t.settings_offline_model_download ?? "Download model"}
        </button>
      )}
    </div>
  );
}
