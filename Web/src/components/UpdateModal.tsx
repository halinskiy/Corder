import React from "react";
import { Loader2 } from "lucide-react";
import { StarsCanvas } from "./StarsCanvas";
import { Lang, pickStrings } from "../i18n";

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

/// Tidy the release-notes blob before display. The Swift side hands us
/// plain text already, but the changelog convention prefixes every
/// entry with the version as a heading — which just duplicates the
/// modal title and leaves a stray blank line + indentation gap. Strip
/// the leading version line, trim per-line indentation, and collapse
/// runs of blank lines so the notes read as plain text, not a sparse
/// outline.
function cleanNotes(raw: string, version: string): string {
  const verNum = version.replace(/^version\s+/i, "").trim();
  const lines = raw
    .replace(/\r/g, "")
    .split("\n")
    // Trim each line, drop indentation, and strip ANY leading list
    // marker (•, ·, -, *, –, —) + spaces — the notes must read as plain
    // text, never a bulleted list.
    .map((l) =>
      l
        .replace(/\s+$/g, "")
        .replace(/^\s*[•·\-*–—]+\s+/, "")
        .replace(/^\s+/g, (m) => (m.length > 1 ? "" : m))
    );
  // Drop leading empty / version-only lines.
  while (lines.length && (lines[0].trim() === "" || lines[0].trim() === verNum)) {
    lines.shift();
  }
  return lines
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function UpdateModalHost({ lang }: { lang: Lang }) {
  const t = pickStrings(lang);
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

  // The primary button label is ALWAYS "Install" while at rest — never a
  // frozen "Installing…" verb. At rest the button shows NO progress and
  // NO spinner; it only reacts once the user actually clicks Install and
  // real work begins. `busy` = Sparkle is actively working (the button is
  // disabled by the Swift side once work starts). When busy the label is
  // replaced by a centered spinner (the app's standard button loader);
  // for a real download we ALSO show a left-anchored fill that tracks the
  // genuine download progress. Install/extract have no byte signal, so
  // they show only the spinner — never a fake "filling on its own" bar.
  const INSTALL_PHASES = ["available", "downloading", "extracting", "readyToInstall", "installing"];
  const isInstallPhase = INSTALL_PHASES.includes(state.phase);
  const working =
    state.phase === "downloading" ||
    state.phase === "extracting" ||
    state.phase === "installing";
  const busy = working && !state.primaryEnabled;
  const determinate = busy && state.showsProgress && state.progress > 0;
  const buttonLabel = isInstallPhase ? (t.update_install ?? "Install") : state.primaryLabel;
  const fillPct = determinate ? Math.max(4, state.progress * 100) : 0;

  if (!state.visible && !leaving) return null;

  const onPrimary = () => { if (state.primaryEnabled) postAction("primary"); };
  const onDismiss = () => { postAction("dismiss"); };
  const hasNotes = !!(state.releaseNotes && state.releaseNotes.trim().length > 0);
  const notesBody = hasNotes
    ? cleanNotes(state.releaseNotes!, state.version)
    : "No release notes attached to this update.";

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
        <button
          type="button"
          className={"update-help" + (notesOpen ? " is-active" : "")}
          onClick={() => setNotesOpen((v) => !v)}
          aria-label={notesOpen ? "Hide details" : "Show details"}
          title={notesOpen ? "Hide details" : "Show details"}
        >
          ?
        </button>
        <div className="update-head">
          <div className="update-title">{state.version || "Update available"}</div>
          {state.phaseStatusLine && (
            <div className={"update-status" + (state.phase === "error" ? " error" : "")}>
              {state.phaseStatusLine}
            </div>
          )}
        </div>

        <div className="update-actions">
          {/* Primary button is hidden when Swift passes an empty label —
              the no-update modal has nothing actionable so the only
              affordance left is the secondary "Later" (= dismiss). */}
          {state.primaryLabel && (
            <button
              type="button"
              className={"update-primary" + (busy ? " is-working" : "")}
              onClick={onPrimary}
              disabled={!state.primaryEnabled}
            >
              {determinate && (
                <span
                  className="update-primary-fill"
                  aria-hidden
                  style={{ width: `${fillPct}%` }}
                />
              )}
              <span className="update-primary-label">
                {busy
                  ? <Loader2 size={16} strokeWidth={2.5} className="update-primary-spin" aria-label="Working" />
                  : buttonLabel}
              </span>
            </button>
          )}
          <button
            type="button"
            className="update-secondary"
            onClick={onDismiss}
          >
            {t.update_later ?? "Later"}
          </button>
        </div>

        {notesOpen && (
          <div className={"update-notes" + (hasNotes ? "" : " is-empty")}>
            {notesBody}
          </div>
        )}
      </div>
    </div>
  );
}

