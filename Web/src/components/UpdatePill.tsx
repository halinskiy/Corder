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

  // Poll Sparkle's verdict every 60 s. Cheap (just a NSLock read on
  // the Swift side, no I/O), and lets the pill appear/disappear
  // without the user having to reload the Library window.
  React.useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const s = await getUpdateStatus();
        if (alive) setAvailable(s.available);
      } catch {}
    };
    tick();
    const id = window.setInterval(tick, 60_000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  if (!available) return null;

  const onClick = async () => {
    try {
      await triggerUpdateCheck();
    } catch {
      onToast(t.toast_settings_failed, "error");
    }
  };

  return (
    <button
      type="button"
      className="update-pill"
      onClick={onClick}
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
      <span className="update-pill-text">{t.update_available_label}</span>
    </button>
  );
}
