import React from "react";

/// The bottom-right download orb, and the modal it opens.
///
/// The orb is the landing's CorderPresence orb (state B of its window → orb →
/// form morph), reused rather than re-invented: 56px / 48px on mobile, pinned
/// right+bottom 32px / 28px, accent fill, white lucide CloudDownload at 24px,
/// hover scale(1.06), tap scale(0.96). On the landing its mirror is the
/// bottom-left cookie circle; here that side belongs to the audio.
///
/// Clicking opens the same card as the entry gate — Corder's modals are one
/// family (update, sign-in, gate), so this one gets the same shell, the same
/// cursor-tilt and the same buttons.
///
/// The size lives in CSS (--sp-orb), never inline: an inline width beat the
/// mobile media query, so the orb stayed 56 while play shrank to 48 and the
/// gap to the track collapsed to zero.

export function ShareDownload({ downloadUrl, ownerName }: { downloadUrl: string; ownerName: string | null }) {
  const [open, setOpen] = React.useState(false);
  const [leaving, setLeaving] = React.useState(false);
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  const overlayRef = React.useRef<HTMLDivElement | null>(null);

  const close = React.useCallback(() => {
    if (leaving) return;
    setLeaving(true);
    window.setTimeout(() => { setOpen(false); setLeaving(false); }, 220);
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

  // The app's cursor-tilt, same as UpdateModal / SignInModal / the gate: rects
  // cached (a getBoundingClientRect per mousemove forces two sync reflows),
  // writes coalesced to one per frame, and no transition on the tracked
  // transform — only on leave, via tilt-snap-back.
  React.useEffect(() => {
    if (!open) return;
    const overlay = overlayRef.current, card = cardRef.current;
    if (!overlay || !card) return;
    let oRect = overlay.getBoundingClientRect();
    let cRect = card.getBoundingClientRect();
    const remeasure = () => { oRect = overlay.getBoundingClientRect(); cRect = card.getBoundingClientRect(); };
    let raf = 0, px = 0, py = 0;
    const max = 4;
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

  return (
    <>
      <button
        type="button"
        className="sp-orb"
        onClick={() => setOpen(true)}
        aria-label="Download Corder"
      >
        <CloudDownloadIcon />
      </button>

      {open && (
        <div
          className={"sp-gate" + (leaving ? " is-leaving" : "")}
          role="dialog"
          aria-modal="true"
          ref={overlayRef}
          onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}
        >
          <div className={"sp-gate-card" + (leaving ? " is-leaving" : "")} ref={cardRef}>
            <div className="sp-gate-sheen" aria-hidden />
            <img className="sp-gate-mark" src="/brand-mark-256.png" width={64} height={64} alt="" aria-hidden />
            <h2 className="sp-gate-title">Get Corder</h2>
            <p className="sp-gate-body">
              {ownerName
                ? `${ownerName} recorded this with Corder. It runs on your Mac and keeps the transcript there. No bot joins the call.`
                : "Corder records your meetings on your Mac and writes the transcript there. No bot joins the call."}
            </p>
            <a className="sp-cta sp-cta--primary sp-gate-cta" href={downloadUrl}>
              <AppleMark />
              Download for Mac
            </a>
            <button type="button" className="sp-cta sp-cta--ghost sp-gate-skip" onClick={close}>
              Not now
            </button>
          </div>
        </div>
      )}
    </>
  );
}

/// Lucide CloudDownload, inlined exactly as the landing's orb inlines it.
function CloudDownloadIcon() {
  return (
    <svg
      width="24" height="24" viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"
      aria-hidden
    >
      <path d="M12 13v8l-4-4" />
      <path d="m12 21 4-4" />
      <path d="M4.393 15.269A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.436 8.284" />
    </svg>
  );
}

function AppleMark() {
  return (
    <svg width={24} height={24} viewBox="0 0 24 24" fill="currentColor" aria-hidden style={{ transform: "translateY(0.5px)" }}>
      <path d="M17.05 20.28c-.98.95-2.05.88-3.08.41-1.09-.47-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.41C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}
