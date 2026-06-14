import React from "react";
import { getUpdateStatus, triggerUpdateCheck } from "../api";
import { Tooltip } from "./Tooltip";
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
// Module-level cache of the last-known update status. The header (and
// this pill) is re-mounted whenever the user navigates between surfaces
// (Dashboard ↔ MeetingView), so without a shared cache each new pill
// would start at `available=false` and flash empty until its own poll
// returned — the pill "disappears and needs time again" on every page.
// Seeding state from this cache makes the pill appear instantly on every
// surface once ANY instance has resolved the status at least once.
let cachedStatus: { available: boolean; version?: string } = { available: false };

export function UpdatePill({ t, onToast }: Props) {
  const [available, setAvailable] = React.useState(cachedStatus.available);
  const [version, setVersion] = React.useState<string | undefined>(cachedStatus.version);
  const [busy, setBusy] = React.useState(false);
  const pillRef = React.useRef<HTMLButtonElement | null>(null);

  // 3D cursor-tilt — the same parallax vocabulary as the update modal
  // card. Listener lives on the pill itself; the rotation amounts are
  // smaller (max 6° vs the modal's 11°) because the pill is tiny and
  // a strong tilt feels exaggerated on a 30 px element. The sheen
  // position follows the cursor for an extra depth cue.
  React.useEffect(() => {
    const el = pillRef.current;
    if (!el) return;
    const reset = () => {
      el.style.setProperty("--tilt-x", "0deg");
      el.style.setProperty("--tilt-y", "0deg");
      el.style.setProperty("--tilt-shine-x", "50%");
      el.style.setProperty("--tilt-shine-y", "50%");
    };
    const onMove = (e: MouseEvent) => {
      const r = el.getBoundingClientRect();
      const nx = ((e.clientX - r.left) / r.width) * 2 - 1;   // -1..1
      const ny = ((e.clientY - r.top) / r.height) * 2 - 1;   // -1..1
      const max = 6;
      const ry = nx * max;
      const rx = -ny * max;
      el.style.setProperty("--tilt-x", `${rx.toFixed(2)}deg`);
      el.style.setProperty("--tilt-y", `${ry.toFixed(2)}deg`);
      const sx = ((e.clientX - r.left) / r.width) * 100;
      const sy = ((e.clientY - r.top) / r.height) * 100;
      el.style.setProperty("--tilt-shine-x", `${sx}%`);
      el.style.setProperty("--tilt-shine-y", `${sy}%`);
    };
    reset();
    el.addEventListener("mousemove", onMove);
    el.addEventListener("mouseleave", reset);
    return () => {
      el.removeEventListener("mousemove", onMove);
      el.removeEventListener("mouseleave", reset);
    };
  }, [available]);

  // Poll Sparkle's verdict every 60 s + also re-check whenever the
  // window comes back into focus. Cheap (just a NSLock read on the
  // Swift side, no I/O), and lets the pill appear/disappear without
  // the user having to reload the Library window.
  React.useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const s = await getUpdateStatus();
        cachedStatus = { available: s.available, version: s.version };
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

  // Just "Update available" — no specific version number per
  // Kostya's call. Two appcast bumps in a day still surface as a
  // single pill that re-fires the dialog on click; the dialog
  // itself shows the version.
  void version;
  const label = t.update_available_label;

  return (
    <Tooltip label={t.update_available_title}>
      <button
        ref={pillRef}
        type="button"
        className={"update-pill" + (busy ? " busy" : "")}
        onClick={onClick}
        disabled={busy}
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
    </Tooltip>
  );
}
