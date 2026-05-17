import React from "react";
import { X, Video, AudioLines, FileText, FileCode, FileJson, Package } from "lucide-react";
import { audioSrc, videoSrc, transcriptSrc, transcriptMdSrc, transcriptJsonSrc, bundleSrc } from "../api";
import type { T } from "../i18n";

/// Download chooser. Same overlay/card language as Archive (so it
/// inherits the backdrop blur). Each row is a real download link; the
/// "everything" row hits the server-side zip endpoint.
export function DownloadMenu({
  meetingId,
  hasVideo,
  hasTranscript,
  onClose,
  t,
}: {
  meetingId: string;
  hasVideo: boolean;
  hasTranscript: boolean;
  onClose: () => void;
  t: T;
}) {
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const rows: Array<{ icon: React.ReactNode; label: string; href: string; file: string; show: boolean }> = [
    { icon: <Video size={17} strokeWidth={2} />, label: t.download_video, href: videoSrc(meetingId), file: `corder-${meetingId}.mov`, show: hasVideo },
    { icon: <AudioLines size={17} strokeWidth={2} />, label: t.download_audio, href: audioSrc(meetingId), file: `corder-${meetingId}.wav`, show: true },
    { icon: <FileText size={17} strokeWidth={2} />, label: t.download_transcript, href: transcriptSrc(meetingId), file: `corder-${meetingId}.txt`, show: hasTranscript },
    { icon: <FileCode size={17} strokeWidth={2} />, label: t.download_markdown, href: transcriptMdSrc(meetingId), file: `corder-${meetingId}.md`, show: hasTranscript },
    { icon: <FileJson size={17} strokeWidth={2} />, label: t.download_json, href: transcriptJsonSrc(meetingId), file: `corder-${meetingId}.json`, show: hasTranscript },
    { icon: <Package size={17} strokeWidth={2} />, label: t.download_all, href: bundleSrc(meetingId), file: `corder-${meetingId}.zip`, show: true },
  ];

  return (
    <div className="donate-overlay" onClick={onClose}>
      <div
        className="donate-card archive-card"
        role="dialog"
        aria-label={t.download_title}
        onClick={(e) => e.stopPropagation()}
      >
        <button
          className="archive-close"
          onClick={onClose}
          title={t.archive_close_title}
          aria-label={t.archive_close_title}
        >
          <X size={16} strokeWidth={2} />
        </button>
        <div className="donate-card-title">{t.download_title}</div>
        <div className="donate-card-body">{t.download_body}</div>
        <div className="download-list">
          {rows.filter((r) => r.show).map((r) => (
            <a
              key={r.label}
              className="download-row"
              href={r.href}
              download={r.file}
              onClick={() => onClose()}
            >
              <span className="download-row-icon">{r.icon}</span>
              <span className="download-row-label">{r.label}</span>
            </a>
          ))}
        </div>
      </div>
    </div>
  );
}
