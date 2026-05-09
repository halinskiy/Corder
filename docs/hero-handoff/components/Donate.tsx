import React from "react";
import { Coffee } from "lucide-react";
import type { T } from "../i18n";

const BMC_USER = "3mpq";

/// Floating "Buy me a coffee" button anchored to the bottom-right of the
/// Library window. Clicking it opens a small overlay with three preset
/// amounts that link straight into the author's Buy Me a Coffee page.
export function Donate({ t }: { t: T }) {
  const [open, setOpen] = React.useState(false);

  /// BMC ignores `?amount=` but honours `?coffees=N`, which preselects the
  /// quantity. The page's per-coffee price is whatever the creator set in
  /// BMC settings — for the buttons here to read as $1/$3/$5 literally, the
  /// account must be configured with "One coffee = $1".
  const url = (n: number) =>
    `https://www.buymeacoffee.com/${BMC_USER}?coffees=${n}`;

  /// WKWebView doesn't honour `target="_blank"` without a UIDelegate, so we
  /// route every donate click through the native bridge installed in
  /// LibraryWindow.swift. Falls back to plain window.open when running in a
  /// regular browser (npm run dev) so the dev experience still works.
  const goTo = (href: string) => (e: React.MouseEvent) => {
    e.preventDefault();
    const native = (window as any).corderOpenExternal;
    if (typeof native === "function" && native(href)) {
      setOpen(false);
      return;
    }
    window.open(href, "_blank", "noopener,noreferrer");
    setOpen(false);
  };

  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  return (
    <>
      <button
        className="donate-fab"
        onClick={() => setOpen(true)}
        title={t.donate_button_title}
        aria-label={t.donate_button_title}
      >
        <Coffee size={18} strokeWidth={2} />
      </button>
      {open && (
        <div className="donate-overlay" onClick={() => setOpen(false)}>
          <div
            className="donate-card"
            role="dialog"
            aria-label={t.donate_card_title}
            onClick={(e) => e.stopPropagation()}
          >
            <div className="donate-card-title">{t.donate_card_title}</div>
            <div className="donate-card-body">{t.donate_card_body}</div>
            <div className="donate-amounts">
              <a href={url(1)} onClick={goTo(url(1))} className="donate-amount">$1</a>
              <a href={url(3)} onClick={goTo(url(3))} className="donate-amount">$3</a>
              <a href={url(5)} onClick={goTo(url(5))} className="donate-amount">$5</a>
            </div>
            <button className="donate-dismiss" onClick={() => setOpen(false)}>
              {t.donate_dismiss}
            </button>
          </div>
        </div>
      )}
    </>
  );
}
