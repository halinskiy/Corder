import React from "react";
import { StarsCanvas } from "./StarsCanvas";
import type { T } from "../i18n";

/// Upgrade / pricing modal. ONE unified modal (same shell as the update
/// modal: `.update-overlay` + the `.update-card` vocabulary — tilt,
/// sheen, entrance animation) that holds the paid plans as columns,
/// instead of separate floating cards. Opened by dispatching a
/// `corder-open-pricing` window event (the "Upgrade" upsell CTA fires
/// it); closed by clicking the backdrop or Escape.
///
/// Each plan column has two stacked buttons: "Upgrade" (primary → the
/// purchase page) and "Details" (secondary). Details swaps the plan
/// face (name + price) for its feature list, in place (no grey panel,
/// no scrollbar), and takes the pressed/active state like the update
/// modal's `?` toggle; a second click swaps back.

interface Plan {
  id: string;
  name: string;
  price: string;
  period: string;
  yearly: string;
  features: string[];
}

// Plan data mirrors getcorder.com/#pricing verbatim. Free is omitted —
// this is an upgrade surface, the user is already on it. Kept as a
// constant (product data / prices, universal across locales).
const PLANS: Plan[] = [
  {
    id: "pro",
    name: "Pro",
    price: "$8.25",
    period: "per month",
    yearly: "$99 billed yearly",
    features: [
      "Everything in Free, plus:",
      "25 hours a month included",
      "Auto-summary with sections and action items",
      "Custom summary templates for your call type",
      "Priority support, direct line to the maker",
    ],
  },
  {
    id: "max",
    name: "Max",
    price: "$19.92",
    period: "per month",
    yearly: "$239 billed yearly",
    features: [
      "Everything in Pro, plus:",
      "Unlimited transcription, fair use applies",
      "Stronger handling of accents and crosstalk",
      "Early builds before public release",
      "Dedicated support, same-day reply",
    ],
  },
];

const PURCHASE_URL = "https://getcorder.com/#pricing";

declare global {
  interface Window {
    corderOpenExternal?: (url: string) => void;
  }
}

/// Cursor-tilt parallax — the same vocabulary as the update modal card.
function useTilt(ref: React.RefObject<HTMLElement>, max: number) {
  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const reset = () => {
      el.style.setProperty("--tilt-x", "0deg");
      el.style.setProperty("--tilt-y", "0deg");
      el.style.setProperty("--tilt-shine-x", "50%");
      el.style.setProperty("--tilt-shine-y", "50%");
    };
    const onMove = (e: MouseEvent) => {
      const r = el.getBoundingClientRect();
      const nx = ((e.clientX - r.left) / r.width) * 2 - 1;
      const ny = ((e.clientY - r.top) / r.height) * 2 - 1;
      el.style.setProperty("--tilt-x", `${(-ny * max).toFixed(2)}deg`);
      el.style.setProperty("--tilt-y", `${(nx * max).toFixed(2)}deg`);
      el.style.setProperty("--tilt-shine-x", `${((e.clientX - r.left) / r.width) * 100}%`);
      el.style.setProperty("--tilt-shine-y", `${((e.clientY - r.top) / r.height) * 100}%`);
    };
    reset();
    el.addEventListener("mousemove", onMove);
    el.addEventListener("mouseleave", reset);
    return () => {
      el.removeEventListener("mousemove", onMove);
      el.removeEventListener("mouseleave", reset);
    };
  }, [ref, max]);
}

function PricingColumn({ plan, t, onUpgrade }: { plan: Plan; t: T; onUpgrade: () => void }) {
  const [detailsOpen, setDetailsOpen] = React.useState(false);
  return (
    <div className="pricing-col">
      <div className="pricing-col-top">
        {detailsOpen ? (
          <div className="pricing-detail">
            {plan.features.map((f, i) => (
              <div className="pricing-feature" key={i}>{f}</div>
            ))}
          </div>
        ) : (
          <div className="pricing-face">
            <div className="pricing-name">{plan.name}</div>
            <div className="pricing-price">
              {plan.price}
              <span className="pricing-period">{plan.period}</span>
            </div>
            <div className="pricing-yearly">{plan.yearly}</div>
          </div>
        )}
      </div>
      <div className="update-actions">
        <button type="button" className="update-primary" onClick={onUpgrade}>
          <span className="update-primary-label">{t.pricing_upgrade ?? "Upgrade"}</span>
        </button>
        <button
          type="button"
          className={"update-secondary" + (detailsOpen ? " is-active" : "")}
          onClick={() => setDetailsOpen((v) => !v)}
        >
          {t.pricing_details ?? "Details"}
        </button>
      </div>
    </div>
  );
}

export function PricingModalHost({ t }: { t: T }) {
  const [visible, setVisible] = React.useState(false);
  const [leaving, setLeaving] = React.useState(false);
  const leaveTimer = React.useRef<number | null>(null);
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  useTilt(cardRef, 7);

  const close = React.useCallback(() => {
    setLeaving(true);
    if (leaveTimer.current != null) window.clearTimeout(leaveTimer.current);
    leaveTimer.current = window.setTimeout(() => {
      setLeaving(false);
      setVisible(false);
      leaveTimer.current = null;
    }, 220);
  }, []);

  React.useEffect(() => {
    const open = () => {
      if (leaveTimer.current != null) {
        window.clearTimeout(leaveTimer.current);
        leaveTimer.current = null;
      }
      setLeaving(false);
      setVisible(true);
    };
    window.addEventListener("corder-open-pricing", open);
    return () => window.removeEventListener("corder-open-pricing", open);
  }, []);

  React.useEffect(() => {
    if (!visible) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [visible, close]);

  if (!visible && !leaving) return null;

  const onUpgrade = () => {
    try { window.corderOpenExternal?.(PURCHASE_URL); } catch { /* dev shell */ }
    close();
  };

  return (
    <div
      className={"update-overlay" + (leaving ? " is-leaving" : "")}
      role="dialog"
      aria-modal="true"
      aria-label={t.pricing_title ?? "Upgrade Corder"}
      onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}
    >
      <StarsCanvas />
      <div
        className={"pricing-modal" + (leaving ? " is-leaving" : "")}
        ref={cardRef}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="update-card-sheen" aria-hidden />
        <div className="pricing-title">{t.pricing_title ?? "Upgrade Corder"}</div>
        <div className="pricing-row">
          {PLANS.map((plan) => (
            <PricingColumn key={plan.id} plan={plan} t={t} onUpgrade={onUpgrade} />
          ))}
        </div>
      </div>
    </div>
  );
}
