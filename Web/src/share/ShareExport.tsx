import React from "react";
import { Download, FileText, AudioLines, Package } from "lucide-react";
import type { MeetingDetail } from "../api";
import { displaySpeakerName } from "../format";

/// Export: the top-right circle, and the picker it opens.
///
/// Same three choices the app's download menu offers — transcript, audio, or
/// both — but the transcript is built here on the client from the data the page
/// already has, so there's no server round-trip for it.
///
/// The circle is the orb's geometry (56px, the corner inset, hover scale) in
/// the ghost treatment, so the four corners of the page read as one set: mark,
/// search, export, orb.
export function ShareExport({ detail, audioUrl }: { detail: MeetingDetail; audioUrl: string | null }) {
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

  // The app's cursor-tilt, as on every Corder modal: cached rects, one write
  // per frame, no transition on the tracked transform.
  React.useEffect(() => {
    if (!open) return;
    const overlay = overlayRef.current, card = cardRef.current;
    if (!overlay || !card) return;
    let oRect = overlay.getBoundingClientRect();
    let cRect = card.getBoundingClientRect();
    const remeasure = () => { oRect = overlay.getBoundingClientRect(); cRect = card.getBoundingClientRect(); };
    let raf = 0, px = 0, py = 0;
    const apply = () => {
      raf = 0;
      const nx = ((px - oRect.left) / oRect.width) * 2 - 1;
      const ny = ((py - oRect.top) / oRect.height) * 2 - 1;
      card.style.setProperty("--tilt-x", `${(-ny * 4).toFixed(2)}deg`);
      card.style.setProperty("--tilt-y", `${(nx * 4).toFixed(2)}deg`);
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

  const baseName = (detail.title || "meeting").replace(/[/\\:*?"<>|]/g, "").trim() || "meeting";

  const downloadTranscript = () => {
    const blob = new Blob([transcriptText(detail)], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    saveAs(url, `${baseName}.txt`);
    // Revoke on the next tick: revoking synchronously can beat the click.
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
    close();
  };

  const downloadAudio = () => {
    if (audioUrl) saveAs(audioUrl, `${baseName}.m4a`);
    close();
  };

  const downloadBoth = () => {
    if (!audioUrl) return;
    downloadTranscript();
    // Two saves back to back: browsers drop the second if it lands in the same
    // gesture, so the audio waits a beat.
    window.setTimeout(() => saveAs(audioUrl, `${baseName}.m4a`), 600);
  };

  return (
    <>
      <button
        type="button"
        className="sp-corner-btn sp-export"
        onClick={() => setOpen(true)}
        aria-label="Export"
        title="Export"
      >
        <Download size={20} strokeWidth={2} />
      </button>

      {open && (
        <div
          className={"sp-gate" + (leaving ? " is-leaving" : "")}
          role="dialog"
          aria-modal="true"
          ref={overlayRef}
          onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}
        >
          <div className={"sp-gate-card sp-pick-card" + (leaving ? " is-leaving" : "")} ref={cardRef}>
            <div className="sp-gate-sheen" aria-hidden />
            <h2 className="sp-gate-title">Export</h2>
            <p className="sp-gate-body">Take this meeting with you.</p>

            <div className="sp-picks">
              <button type="button" className="sp-pick" onClick={downloadTranscript}>
                <span className="sp-pick-icon"><FileText size={18} strokeWidth={1.8} /></span>
                <span className="sp-pick-text">
                  <b>Transcript</b>
                  <i>Plain text, with speakers and timestamps</i>
                </span>
              </button>

              <button type="button" className="sp-pick" onClick={downloadAudio} disabled={!audioUrl}>
                <span className="sp-pick-icon"><AudioLines size={18} strokeWidth={1.8} /></span>
                <span className="sp-pick-text">
                  <b>Audio</b>
                  <i>{audioUrl ? "The recording, as m4a" : "Not shared with this link"}</i>
                </span>
              </button>

              <button type="button" className="sp-pick" onClick={downloadBoth} disabled={!audioUrl}>
                <span className="sp-pick-icon"><Package size={18} strokeWidth={1.8} /></span>
                <span className="sp-pick-text">
                  <b>Both</b>
                  <i>Transcript and audio</i>
                </span>
              </button>
            </div>

            <button type="button" className="sp-cta sp-cta--ghost sp-gate-skip" onClick={close}>
              Close
            </button>
          </div>
        </div>
      )}
    </>
  );
}

function saveAs(url: string, filename: string) {
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

/// The transcript as the app writes it: "[0:12] Name: text", one turn a line.
function transcriptText(detail: MeetingDetail): string {
  const names = new Map(detail.speakers.map((s) => [s.id, displaySpeakerName(s.custom_name, s.label, null)]));
  const head = [detail.title || "Untitled meeting", new Date(detail.started_at).toLocaleString("en-GB"), ""];
  const body = detail.segments.map((s) => {
    const t = Math.floor(s.start_ms / 1000);
    const stamp = `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
    return `[${stamp}] ${names.get(s.speaker_id) ?? "Speaker"}: ${s.text}`;
  });
  return [...head, ...body, ""].join("\n");
}
