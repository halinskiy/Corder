import React from "react";
import { X } from "lucide-react";
import { getNews, type NewsItem } from "../api";
import type { T } from "../i18n";

declare global {
  interface Window {
    corderOpenExternal?: (url: string) => void;
  }
}

const DISMISS_KEY = "corder.news.dismissed";

function loadDismissed(): Set<string> {
  try {
    const raw = localStorage.getItem(DISMISS_KEY);
    if (!raw) return new Set();
    const arr = JSON.parse(raw) as string[];
    return new Set(Array.isArray(arr) ? arr : []);
  } catch { return new Set(); }
}

function saveDismissed(s: Set<string>) {
  try { localStorage.setItem(DISMISS_KEY, JSON.stringify([...s])); } catch {}
}

/// Outlined call-to-action card pinned above the Dashboard's main
/// "Ready when you are." block. Carries one news item at a time;
/// users dismiss it via the × and the id is remembered forever in
/// localStorage so it never reappears. Pulled from the Worker once
/// on mount + every 10 min — light traffic, only one request.
export function NewsBanner({ tier, t }: { tier: "free" | "pro" | "max"; t: T }) {
  const [items, setItems] = React.useState<NewsItem[]>([]);
  const [dismissed, setDismissed] = React.useState<Set<string>>(() => loadDismissed());

  React.useEffect(() => {
    let alive = true;
    const tick = async () => {
      const fresh = await getNews();
      if (alive) setItems(fresh);
    };
    void tick();
    const id = window.setInterval(tick, 10 * 60 * 1000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  const paid = tier === "pro" || tier === "max";
  const visible = items.find((it) => {
    if (dismissed.has(it.id)) return false;
    const aud = it.audience ?? "all";
    if (aud === "all") return true;
    if (aud === "paid") return paid;
    if (aud === "free") return !paid;
    return false;
  });
  if (!visible) return null;

  const dismiss = () => {
    const next = new Set(dismissed);
    next.add(visible.id);
    setDismissed(next);
    saveDismissed(next);
  };

  const openCta = () => {
    if (!visible.cta_url) return;
    const native = window.corderOpenExternal;
    if (native) native(visible.cta_url);
    else window.open(visible.cta_url, "_blank", "noopener,noreferrer");
  };

  return (
    <div className="trans-banner clarify-banner news-banner">
      {visible.dismissible !== false && (
        <button
          type="button"
          className="news-banner-x"
          onClick={dismiss}
          aria-label={t.btn_dismiss ?? "Dismiss"}
        >
          <X size={14} strokeWidth={2.2} />
        </button>
      )}
      <div className="clarify-text">
        <div className="news-banner-eyebrow">{t.news_eyebrow ?? "New"}</div>
        <div className="clarify-body">{visible.title}</div>
        {visible.body && <div className="summary-banner-sub">{visible.body}</div>}
      </div>
      {visible.cta_label && visible.cta_url && (
        <div className="clarify-actions clarify-actions-stack">
          <button
            type="button"
            className="clarify-btn accent"
            onClick={openCta}
          >
            {visible.cta_label}
          </button>
        </div>
      )}
    </div>
  );
}
