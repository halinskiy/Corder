import React from "react";

/// Full-screen update modal rendered inside the Library WKWebView.
/// State is pushed in by the Swift side via `window.corderUpdateState(...)`
/// — exactly one piece of state at a time; React doesn't ask, it just
/// displays. Actions go back through `window.webkit.messageHandlers.updateAction`.
///
/// Why React + WebView instead of an NSWindow overlay: a CSS `position:
/// fixed; inset: 0` div is guaranteed to span the entire Library
/// viewport because the Library IS the WebView. SwiftUI overlays
/// through child windows fought the OS on every Sequoia size hint.

export interface UpdateModalState {
  visible: boolean;
  phase:
    | "available"
    | "downloading"
    | "extracting"
    | "readyToInstall"
    | "installing"
    | "installed"
    | "error"
    | "upToDate";
  version: string;
  releaseNotes?: string | null;
  progress: number;
  primaryLabel: string;
  primaryEnabled: boolean;
  phaseStatusLine?: string | null;
  showsProgress: boolean;
  errorMessage?: string | null;
}

const HIDDEN: UpdateModalState = {
  visible: false,
  phase: "available",
  version: "",
  releaseNotes: null,
  progress: 0,
  primaryLabel: "",
  primaryEnabled: false,
  phaseStatusLine: null,
  showsProgress: false,
  errorMessage: null,
};

declare global {
  interface Window {
    corderUpdateState?: (s: UpdateModalState) => void;
    webkit?: {
      messageHandlers?: {
        updateAction?: { postMessage: (action: string) => void };
      };
    };
  }
}

function postAction(action: "primary" | "dismiss") {
  try { window.webkit?.messageHandlers?.updateAction?.postMessage(action); }
  catch { /* dev shell has no native bridge */ }
}

export function UpdateModalHost() {
  const [state, setState] = React.useState<UpdateModalState>(HIDDEN);
  const [notesOpen, setNotesOpen] = React.useState(false);
  // `leaving` is the brief window between Swift saying "hide" and the
  // exit animation finishing — during it we keep the card mounted but
  // toggle a `is-leaving` class so the CSS keyframes can scale + fade
  // it out before React unmounts.
  const [leaving, setLeaving] = React.useState(false);
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  const leaveTimer = React.useRef<number | null>(null);

  React.useEffect(() => {
    window.corderUpdateState = (next) => {
      if (next.visible) {
        // New state coming in. Cancel any in-flight exit, snap the
        // card back to visible.
        if (leaveTimer.current != null) {
          window.clearTimeout(leaveTimer.current);
          leaveTimer.current = null;
        }
        setLeaving(false);
        setState({ ...HIDDEN, ...next });
      } else {
        // Swift asked to hide — start the exit animation, only flip
        // `visible=false` once the keyframes finish (200 ms here so
        // it lines up with the `update-card-out` keyframe).
        setLeaving(true);
        if (leaveTimer.current != null) window.clearTimeout(leaveTimer.current);
        leaveTimer.current = window.setTimeout(() => {
          setLeaving(false);
          setState(HIDDEN);
          setNotesOpen(false);
          leaveTimer.current = null;
        }, 220);
      }
    };
    return () => { delete window.corderUpdateState; };
  }, []);

  // Card-tilt-on-cursor — same vocabulary as the hero cards on
  // marketing sites: track the pointer over the overlay, map it
  // into a small `rotateX / rotateY` pair, write the angles onto
  // CSS variables. A CSS transition smooths the snap so the
  // movement feels physical, not jittery on every mousemove. The
  // listener lives on the OVERLAY (not the card) so the effect
  // reads cursor position even when the cursor isn't directly over
  // the card itself — feels more responsive on small modals.
  React.useEffect(() => {
    const overlay = document.querySelector(".update-overlay") as HTMLElement | null;
    const card = cardRef.current;
    if (!overlay || !card) return;
    const reset = () => {
      card.style.setProperty("--tilt-x", "0deg");
      card.style.setProperty("--tilt-y", "0deg");
      card.style.setProperty("--tilt-shine-x", "50%");
      card.style.setProperty("--tilt-shine-y", "50%");
    };
    const onMove = (e: MouseEvent) => {
      const r = overlay.getBoundingClientRect();
      const nx = ((e.clientX - r.left) / r.width) * 2 - 1;   // -1..1
      const ny = ((e.clientY - r.top) / r.height) * 2 - 1;   // -1..1
      const max = 11;  // max tilt degrees
      const ry = nx * max;
      const rx = -ny * max;
      card.style.setProperty("--tilt-x", `${rx.toFixed(2)}deg`);
      card.style.setProperty("--tilt-y", `${ry.toFixed(2)}deg`);
      // Sheen position follows the cursor for an extra layer of
      // depth, again only when state.visible is true.
      const cardRect = card.getBoundingClientRect();
      const sx = ((e.clientX - cardRect.left) / cardRect.width) * 100;
      const sy = ((e.clientY - cardRect.top) / cardRect.height) * 100;
      card.style.setProperty("--tilt-shine-x", `${sx}%`);
      card.style.setProperty("--tilt-shine-y", `${sy}%`);
    };
    overlay.addEventListener("mousemove", onMove);
    overlay.addEventListener("mouseleave", reset);
    return () => {
      overlay.removeEventListener("mousemove", onMove);
      overlay.removeEventListener("mouseleave", reset);
    };
  }, [state.visible]);

  if (!state.visible && !leaving) return null;

  const onPrimary = () => { if (state.primaryEnabled) postAction("primary"); };
  const onDismiss = () => { postAction("dismiss"); };
  const hasNotes = !!(state.releaseNotes && state.releaseNotes.trim().length > 0);

  // Click on the backdrop (outside the card) closes the modal —
  // same as the in-card Later button. Click inside the card must
  // NOT dismiss, so the card stops propagation on its own click.
  return (
    <div
      className={"update-overlay" + (leaving ? " is-leaving" : "")}
      role="dialog"
      aria-modal="true"
      aria-label={state.version}
      onMouseDown={(e) => { if (e.target === e.currentTarget) onDismiss(); }}
    >
      <StarsCanvas />
      <div
        className={"update-card" + (leaving ? " is-leaving" : "")}
        ref={cardRef}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="update-card-sheen" aria-hidden />
        {hasNotes && (
          <button
            type="button"
            className={"update-help" + (notesOpen ? " is-active" : "")}
            onClick={() => setNotesOpen((v) => !v)}
            aria-label={notesOpen ? "Hide details" : "Show details"}
            title={notesOpen ? "Hide details" : "Show details"}
          >
            ?
          </button>
        )}
        <div className="update-head">
          <div className="update-title">{state.version || "Update available"}</div>
          {state.phaseStatusLine && (
            <div className={"update-status" + (state.phase === "error" ? " error" : "")}>
              {state.phaseStatusLine}
            </div>
          )}
        </div>

        {state.showsProgress && (
          <div className="update-progress" aria-hidden>
            <div className="update-progress-fill" style={{ width: `${Math.max(2, state.progress * 100)}%` }} />
          </div>
        )}

        <div className="update-actions">
          <button
            type="button"
            className="update-primary"
            onClick={onPrimary}
            disabled={!state.primaryEnabled}
          >
            {state.primaryLabel}
          </button>
          <button
            type="button"
            className="update-secondary"
            onClick={onDismiss}
          >
            Later
          </button>
        </div>

        {notesOpen && hasNotes && (
          <div className="update-notes">{state.releaseNotes}</div>
        )}
      </div>
    </div>
  );
}

/// Lightweight starfield via a Canvas + requestAnimationFrame loop.
/// Particles spawn at random points around the viewport and drift
/// toward centre; alpha follows a triangle envelope so they ramp in
/// and out instead of popping. 200 particles is a comfortable count
/// at ~30-fps even on integrated GPUs.
function StarsCanvas() {
  const ref = React.useRef<HTMLCanvasElement | null>(null);

  React.useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    let stars = makeStars(200, canvas);
    let raf = 0;
    let last = performance.now();

    const dpr = Math.min(2, window.devicePixelRatio || 1);

    const resize = () => {
      const { clientWidth: w, clientHeight: h } = canvas;
      canvas.width = w * dpr;
      canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    const tick = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      const w = canvas.clientWidth;
      const h = canvas.clientHeight;
      const cx = w / 2, cy = h / 2;

      ctx.clearRect(0, 0, w, h);

      for (const s of stars) {
        s.life += dt;
        s.x += s.vx * dt;
        s.y += s.vy * dt;
        const dx = s.x - cx, dy = s.y - cy;
        const distSq = dx * dx + dy * dy;
        if (s.life >= s.maxLife || distSq < 16 || s.x < -20 || s.x > w + 20 || s.y < -20 || s.y > h + 20) {
          respawn(s, w, h);
        }
        const t = s.life / s.maxLife;
        const env = t < 0.5 ? t * 2 : (1 - t) * 2;
        const alpha = Math.max(0, Math.min(0.9, env));
        ctx.beginPath();
        ctx.fillStyle = `rgba(255,255,255,${alpha})`;
        ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
        ctx.fill();
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, []);

  return <canvas ref={ref} className="update-stars" aria-hidden />;
}

interface Star {
  x: number; y: number;
  vx: number; vy: number;
  r: number;
  life: number; maxLife: number;
}

function makeStars(n: number, canvas: HTMLCanvasElement): Star[] {
  const out: Star[] = [];
  const w = canvas.clientWidth || 800;
  const h = canvas.clientHeight || 600;
  for (let i = 0; i < n; i++) {
    const s: Star = { x: 0, y: 0, vx: 0, vy: 0, r: 0, life: 0, maxLife: 1 };
    respawn(s, w, h);
    out.push(s);
  }
  return out;
}

function respawn(s: Star, w: number, h: number) {
  const cx = w / 2, cy = h / 2;
  s.x = Math.random() * w;
  s.y = Math.random() * h;
  const dx = cx - s.x;
  const dy = cy - s.y;
  const dist = Math.max(1, Math.hypot(dx, dy));
  const speed = 110 + Math.random() * 110;
  s.vx = (dx / dist) * speed;
  s.vy = (dy / dist) * speed;
  s.r = 0.6 + Math.random() * 1.1;
  s.life = 0;
  s.maxLife = 0.6 + Math.random() * 0.8;
}
