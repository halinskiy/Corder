import React from "react";
import { StarsCanvas } from "./StarsCanvas";
import type { T } from "../i18n";

/// Upgrade / pricing modal. Reuses the exact shell of the update modal
/// (`.update-overlay` + the `.update-card` visual vocabulary: tilt,
/// sheen, entrance animation) and the same primary/secondary buttons
/// (`.update-primary` / `.update-secondary`). Opened by dispatching a
/// `corder-open-pricing` window event (the "Upgrade" upsell CTA fires
/// it); closed by clicking the backdrop or Escape.
///
/// Each plan is its own mini-card with two stacked buttons: "Upgrade"
/// (primary → the purchase page) and "Details" (secondary → flips a
/// feature panel OVER the plan face; the button takes the same active
/// state as the update modal's `?` toggle, and a second click flips
/// back).

interface Plan {
  id: string;
  name: string;
  price: string;
  period: string;
  features: string[];
}

// Plan data mirrors getcorder.com/#pricing verbatim. Kept as a constant
// (product data / prices, universal across locales) rather than i18n.
const PLANS: Plan[] = [
  {
    id: "free",
    name: "Free",
    price: "$0",
    period: "forever",
    features: [
      "5 hours of transcription a month",
      "Speakers labelled on every call",
      "Searchable transcript, drag out to Notion",
      "Screen video captured alongside the audio",
      "No bot joins the call",
    ],
  },
  {
    id: "pro",
    name: "Pro",
    price: "$8.25",
    period: "per month",
    features: [
      "Everything in Free, and",
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
    features: [
      "Everything in Pro, and",
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

/// Cursor-tilt parallax — the same vocabulary as the update modal card
/// (and UpdatePill). Applied per plan card so each one reacts on its own.
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

function PricingCard({ plan, t, onUpgrade }: { plan: Plan; t: T; onUpgrade: () => void }) {
  const [detailsOpen, setDetailsOpen] = React.useState(false);
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  useTilt(cardRef, 9);

  return (
    <div className="pricing-card" ref={cardRef} onMouseDown={(e) => e.stopPropagation()}>
      <div className="update-card-sheen" aria-hidden />
      <div className="pricing-card-top">
        <div className="pricing-face">
          <div className="pricing-name">{plan.name}</div>
          <div className="pricing-price">
            {plan.price}
            <span className="pricing-period">{plan.period}</span>
          </div>
        </div>
        {detailsOpen && (
          <div className="pricing-detail update-notes">
            {plan.features.map((f, i) => (
              <div className="pricing-feature" key={i}>{f}</div>
            ))}
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
      <div className={"pricing-wrap" + (leaving ? " is-leaving" : "")}>
        <div className="pricing-title">{t.pricing_title ?? "Upgrade Corder"}</div>
        <div className="pricing-row" onMouseDown={(e) => e.stopPropagation()}>
          {PLANS.map((plan) => (
            <PricingCard key={plan.id} plan={plan} t={t} onUpgrade={onUpgrade} />
          ))}
        </div>
      </div>
    </div>
  );
}
