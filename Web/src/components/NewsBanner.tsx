import React from "react";
import { X } from "lucide-react";
import { getNews, type NewsAction, type NewsItem } from "../api";
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
export function NewsBanner({
  tier, t, onOpenSettings,
}: {
  tier: "free" | "pro" | "max";
  t: T;
  onOpenSettings?: () => void;
}) {
  const [items, setItems] = React.useState<NewsItem[]>([]);
  const [dismissed, setDismissed] = React.useState<Set<string>>(() => loadDismissed());
  const [expanded, setExpanded] = React.useState(false);

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

  const runAction = (action: NewsAction | undefined, url: string | undefined) => {
    const effective: NewsAction = action ?? (url ? "open_url" : "dismiss");
    switch (effective) {
      case "open_url":
        if (url) {
          const native = window.corderOpenExternal;
          if (native) native(url);
          else window.open(url, "_blank", "noopener,noreferrer");
        }
        dismiss();
        break;
      case "open_settings":
        onOpenSettings?.();
        dismiss();
        break;
      case "dismiss":
        dismiss();
        break;
    }
  };

  // Collapsed state: a single glossy green pill with the "New" label.
  // Tapping it expands into the full outline card (title + body + CTA
  // + Skip + ×). Skip / × dismiss the news item permanently. The
  // expand state is session-local — closing and reopening the app
  // brings the pill back; the only thing that hides the news for good
  // is an explicit dismiss.
  if (!expanded) {
    // Full-width running marquee at the very top of the column. Click
    // anywhere on the bar (except the × at the right edge) expands it
    // into the full card. Marquee text duplicated so the loop seam is
    // invisible — `translateX(-50%)` shifts by one copy's worth.
    const eyebrow = t.news_eyebrow ?? "New";
    const segments = Array.from({ length: 6 }, (_, i) => (
      <span className="news-bar-seg" key={i}>
        <span className="news-bar-bang">{eyebrow}!</span>
        <span className="news-bar-dot" aria-hidden>•</span>
      </span>
    ));
    return (
      <div
        className="news-bar"
        role="button"
        tabIndex={0}
        onClick={() => setExpanded(true)}
        onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setExpanded(true); } }}
        aria-label={visible.title}
      >
        <div className="news-bar-shimmer" aria-hidden />
        <div className="news-bar-track" aria-hidden>
          <div className="news-bar-marquee">
            {segments}
            {segments /* duplicate for seamless loop */}
          </div>
        </div>
        <button
          type="button"
          className="news-bar-x"
          onPointerDown={(e) => { e.stopPropagation(); }}
          onClick={(e) => {
            e.stopPropagation();
            e.preventDefault();
            dismiss();
          }}
          aria-label={t.btn_dismiss ?? "Dismiss"}
        >
          <X size={12} strokeWidth={2.4} />
        </button>
      </div>
    );
  }

  const skipLabel = t.rating_skip ?? "Skip";

  return (
    <div className="trans-banner clarify-banner news-banner">
      {visible.dismissible !== false && (
        <button
          type="button"
          className="clarify-dismiss"
          // × in expanded card just collapses back to the bar.
          // Permanent-dismiss lives on the Skip button below.
          onClick={() => setExpanded(false)}
          title={t.btn_collapse ?? "Collapse"}
          aria-label={t.btn_collapse ?? "Collapse"}
        >
          <X size={14} strokeWidth={2} />
        </button>
      )}
      <div className="clarify-text">
        <div className="news-banner-eyebrow">{t.news_eyebrow ?? "New"}</div>
        <div className="clarify-body">{visible.title}</div>
        {visible.body && <div className="summary-banner-sub">{visible.body}</div>}
      </div>
      <div className="clarify-actions clarify-actions-stack">
        {visible.cta_label && (
          <button
            type="button"
            className="clarify-btn accent"
            onClick={() => runAction(visible.cta_action, visible.cta_url)}
          >
            {visible.cta_label}
          </button>
        )}
        {visible.secondary_label && (
          <button
            type="button"
            className="clarify-btn"
            onClick={() => runAction(visible.secondary_action, undefined)}
          >
            {visible.secondary_label}
          </button>
        )}
        {!visible.secondary_label && visible.dismissible !== false && (
          <button
            type="button"
            className="clarify-btn"
            onClick={dismiss}
          >
            {skipLabel}
          </button>
        )}
      </div>
    </div>
  );
}
