import React from "react";

/// The entry interstitial, Granola's pattern: before you read someone's shared
/// meeting, the product introduces itself, and you dismiss it.
///
/// This is the highest-intent moment the page has — a visitor just got a Corder
/// link from someone they know and is about to see what it produces. It was
/// left out of the first cut on the theory that a modal reads pushy for a
/// privacy product; wrong call, since it's also the only place the page ever
/// asks for anything.
///
/// The card carries the app's cursor-tilt parallax, the same one the update and
/// sign-in modals use — Corder's modals move, so this one does too.
///
/// Dismissed by the button, Esc, or the backdrop, and it never blocks twice:
/// the choice is remembered per browser, so a second link doesn't re-pitch
/// someone who already said "maybe later".
const SEEN_KEY = "corder.share.gateSeen.v2";

export function ShareGate({ ownerName, downloadUrl }: { ownerName: string | null; downloadUrl: string }) {
  const [open, setOpen] = React.useState(() => {
    try { return localStorage.getItem(SEEN_KEY) !== "1"; } catch { return true; }
  });
  const [leaving, setLeaving] = React.useState(false);
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  const overlayRef = React.useRef<HTMLDivElement | null>(null);

  const close = React.useCallback(() => {
    if (leaving) return;
    setLeaving(true);
    try { localStorage.setItem(SEEN_KEY, "1"); } catch { /* private mode */ }
    window.setTimeout(() => setOpen(false), 220);
  }, [leaving]);

  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    window.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [open, close]);

  // Cursor-tilt parallax, lifted from the app's modals (SignInModal /
  // UpdateModal). The details that matter, all learned there:
  //  · rects are CACHED and only remeasured on resize — reading
  //    getBoundingClientRect on every mousemove forced two synchronous
  //    reflows per event, which is what made the tilt stutter;
  //  · writes are coalesced into ONE per frame via rAF;
  //  · the tracked transform carries NO transition (it would lag behind a
  //    moving target); `tilt-snap-back` adds one only on cursor-leave.
  React.useEffect(() => {
    if (!open) return;
    const overlay = overlayRef.current;
    const card = cardRef.current;
    if (!overlay || !card) return;

    let oRect = overlay.getBoundingClientRect();
    let cRect = card.getBoundingClientRect();
    const remeasure = () => { oRect = overlay.getBoundingClientRect(); cRect = card.getBoundingClientRect(); };
    let raf = 0;
    let px = 0, py = 0;
    const max = 4;   // gentle, same as the sign-in card

    const apply = () => {
      raf = 0;
      const nx = ((px - oRect.left) / oRect.width) * 2 - 1;
      const ny = ((py - oRect.top) / oRect.height) * 2 - 1;
      card.style.setProperty("--tilt-x", `${(-ny * max).toFixed(2)}deg`);
      card.style.setProperty("--tilt-y", `${(nx * max).toFixed(2)}deg`);
      card.style.setProperty("--tilt-shine-x", `${(((px - cRect.left) / cRect.width) * 100).toFixed(1)}%`);
      card.style.setProperty("--tilt-shine-y", `${(((py - cRect.top) / cRect.height) * 100).toFixed(1)}%`);
    };
    const onMove = (e: MouseEvent) => {
      px = e.clientX; py = e.clientY;
      card.classList.remove("tilt-snap-back");
      if (!raf) raf = requestAnimationFrame(apply);
    };
    const reset = () => {
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      card.classList.add("tilt-snap-back");
      card.style.setProperty("--tilt-x", "0deg");
      card.style.setProperty("--tilt-y", "0deg");
      card.style.setProperty("--tilt-shine-x", "50%");
      card.style.setProperty("--tilt-shine-y", "50%");
    };

    overlay.addEventListener("mousemove", onMove);
    overlay.addEventListener("mouseleave", reset);
    window.addEventListener("resize", remeasure);
    return () => {
      overlay.removeEventListener("mousemove", onMove);
      overlay.removeEventListener("mouseleave", reset);
      window.removeEventListener("resize", remeasure);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [open]);

  if (!open) return null;

  return (
    <div
      className={"sp-gate" + (leaving ? " is-leaving" : "")}
      role="dialog"
      aria-modal="true"
      ref={overlayRef}
      onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}
    >
      <div className={"sp-gate-card" + (leaving ? " is-leaving" : "")} ref={cardRef}>
        <div className="sp-gate-sheen" aria-hidden />
        <img className="sp-gate-mark" src="/brand-mark-128.png" width={64} height={64} alt="" aria-hidden />
        <h2 className="sp-gate-title">
          {ownerName ? <><span>{ownerName}</span> shared a recording with you.</> : "A recording was shared with you."}
        </h2>
        <p className="sp-gate-body">
          Corder records your meetings on your Mac and writes the transcript there.
          No bot joins the call.
        </p>
        <a className="sp-cta sp-cta--primary sp-gate-cta" href={downloadUrl}>
          <AppleMark />
          Download Corder
        </a>
        <button type="button" className="sp-cta sp-cta--ghost sp-gate-skip" onClick={close}>
          Maybe later
        </button>
      </div>
    </div>
  );
}

function AppleMark() {
  return (
    <svg width={24} height={24} viewBox="0 0 24 24" fill="currentColor" aria-hidden style={{ transform: "translateY(0.5px)" }}>
      <path d="M17.05 20.28c-.98.95-2.05.88-3.08.41-1.09-.47-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.41C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}
