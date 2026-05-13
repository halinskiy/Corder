import React from "react";
import { getUpdateStatus, triggerUpdateCheck } from "../api";
import type { T } from "../i18n";

interface Props {
  t: T;
  onToast: (msg: string, kind?: "success" | "error") => void;
}

/// Toolbar pill rendered to the left of the language switch when
/// Sparkle has resolved a newer version from the appcast. Same height +
/// border-radius as the surrounding pill buttons; the only difference
/// is a green fill, a slow diagonal shine that sweeps every ~10 s, and
/// a handful of small twinkling stars. Click triggers Sparkle's
/// standard "Update available" panel via /api/update-check.
export function UpdatePill({ t, onToast }: Props) {
  const [available, setAvailable] = React.useState(false);
  const [version, setVersion] = React.useState<string | undefined>(undefined);
  const [busy, setBusy] = React.useState(false);

  // Poll Sparkle's verdict every 60 s + also re-check whenever the
  // window comes back into focus. Cheap (just a NSLock read on the
  // Swift side, no I/O), and lets the pill appear/disappear without
  // the user having to reload the Library window.
  React.useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const s = await getUpdateStatus();
        if (!alive) return;
        setAvailable(s.available);
        setVersion(s.version);
      } catch {}
    };
    tick();
    const id = window.setInterval(tick, 60_000);
    const onFocus = () => { tick(); };
    window.addEventListener("focus", onFocus);
    return () => {
      alive = false;
      window.clearInterval(id);
      window.removeEventListener("focus", onFocus);
    };
  }, []);

  if (!available) return null;

  const onClick = async () => {
    if (busy) return;
    setBusy(true);
    try {
      await triggerUpdateCheck();
    } catch {
      onToast(t.toast_settings_failed, "error");
    }
    // Release busy after a short delay — long enough that the user
    // sees the pulse, short enough not to lock the button if Sparkle's
    // dialog never appears (e.g. it was already on screen).
    window.setTimeout(() => setBusy(false), 2200);
  };

  // Append the target version so the user knows exactly what they're
  // about to install — useful when the appcast bumps twice in a day.
  const label = version
    ? `${t.update_available_label} ${version}`
    : t.update_available_label;

  return (
    <button
      type="button"
      className={"update-pill" + (busy ? " busy" : "")}
      onClick={onClick}
      disabled={busy}
      title={t.update_available_title}
    >
      <span className="update-pill-shine" aria-hidden />
      <span className="update-pill-sparkles" aria-hidden>
        <span>✦</span>
        <span>✦</span>
        <span>✦</span>
        <span>✦</span>
        <span>✦</span>
        <span>✦</span>
      </span>
      <span className="update-pill-text">{label}</span>
    </button>
  );
}
