import React from "react";
import { createPortal } from "react-dom";
import { Check, ChevronDown } from "lucide-react";

/// One option in a `SettingsSelect`. `meta` is a short trailing hint
/// rendered in muted text after the label (e.g. "system default",
/// "1.5 GB download", "Pro+"). `disabled` options stay visible but
/// can't be selected and fire `onLockedClick` instead of `onChange`.
export interface SettingsSelectOption<V extends string = string> {
  value: V;
  label: string;
  meta?: string;
  disabled?: boolean;
  /// Optional leading visual (icon, flag chip, etc.) painted to the
  /// left of `label` in both the trigger pill and each option row.
  /// Used by Settings → Language to surface a country flag per option;
  /// other call sites can leave it undefined.
  leading?: React.ReactNode;
}

/// Reusable single-select dropdown that visually matches the rest of
/// the Corder UI (same `.profile-pop`-style popover as `LangPicker`)
/// instead of falling back to the native `<select>` (which renders as
/// a dark macOS context menu and looks alien inside the white settings
/// cards). Use this everywhere in Settings where a row needs a single
/// pick from a short list — Microphone, Transcription model, etc.
///
/// The trigger is a full-width pill (same base `button` token as the
/// rest of the app, 8/14 padding, 13 px text, 999 px radius); the
/// chevron lives on the right and stays visible on hover (the bug
/// where it disappeared came from native `<select>`'s arrow being
/// painted over a hover background).
export function SettingsSelect<V extends string = string>({
  value,
  options,
  disabled,
  onChange,
  onLockedClick,
  ariaLabel,
}: {
  value: V;
  options: SettingsSelectOption<V>[];
  disabled?: boolean;
  onChange: (v: V) => void;
  /// Called when the user clicks a `disabled` option — lets the parent
  /// fire a toast ("Upgrade to Pro to use cloud models" etc.) without
  /// changing the actual value. If omitted, disabled clicks no-op.
  onLockedClick?: (v: V) => void;
  ariaLabel?: string;
}) {
  const [open, setOpen] = React.useState(false);
  const btnRef = React.useRef<HTMLButtonElement>(null);
  const popRef = React.useRef<HTMLDivElement>(null);
  /// Position of the popover. `placement` tells the renderer whether
  /// the popover hangs DOWN from the trigger (default) or flips UP
  /// when the trigger sits too close to the viewport's bottom edge —
  /// see `placeDropdown` for the calculation. The chevron rotates
  /// using the same flag so the visual arrow always points "into"
  /// the open list, not opposite to it.
  const [pos, setPos] = React.useState<
    { top: number; left: number; width: number; placement: "down" | "up" } | null
  >(null);

  /// Active-option label rendered inside the trigger. Falls back to
  /// the raw value if the option list doesn't carry the current value
  /// (e.g. an `mic_device_uid` referring to a hardware UID that just
  /// got unplugged); the user still sees *something* meaningful.
  const active = options.find((o) => o.value === value);
  const activeLabel = active?.label ?? String(value);

  /// Pick a top + placement that keeps the popover inside the
  /// viewport. We don't know the popover's real height until React
  /// mounts it (chicken-and-egg with `position: fixed`), so the first
  /// pass uses a sane estimate from the option count; a second pass
  /// inside the open-effect re-measures the rendered list and snaps
  /// to the actual height if it ended up shorter or taller. The 8 px
  /// margin from the viewport edge mirrors what the `.profile-pop`
  /// shell uses elsewhere (LangPicker / SortPicker / ProfileMenu).
  const placeDropdown = React.useCallback(() => {
    const r = btnRef.current?.getBoundingClientRect();
    if (!r) return;
    const measured = popRef.current?.getBoundingClientRect().height;
    // Per-row ~38 px + 16 px shell padding, capped at the same 320 px
    // `max-height` set on `.settings-select-pop` in styles.css.
    const estimated = Math.min(320, options.length * 38 + 16);
    const popH = measured && measured > 0 ? measured : estimated;
    const margin = 8;
    const spaceBelow = window.innerHeight - r.bottom - margin;
    const spaceAbove = r.top - margin;
    // Flip up only when there's actually MORE room above. Otherwise
    // anchor below (the default reading direction) even if it means
    // the list scrolls; auto-flip is meant for the bottom-of-pane
    // case Kostya hit, not for "every dropdown that touches the
    // viewport".
    const placeUp = popH + 6 > spaceBelow && spaceAbove > spaceBelow;
    const top = placeUp
      ? Math.max(margin, r.top - popH - 6)
      : r.bottom + 6;
    setPos({ top, left: r.left, width: r.width, placement: placeUp ? "up" : "down" });
  }, [options.length]);

  const toggle = React.useCallback(() => {
    if (disabled) return;
    setOpen((v) => {
      if (!v) placeDropdown();
      return !v;
    });
  }, [disabled, placeDropdown]);

  React.useEffect(() => {
    if (!open) return;
    // Second-pass measurement: now that the popover is in the DOM we
    // know its real height, so re-run `placeDropdown` once on the
    // next frame to snap to a tighter top.
    const raf = window.requestAnimationFrame(placeDropdown);
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    const onDown = (e: MouseEvent) => {
      if (!btnRef.current?.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("resize", placeDropdown);
    // capture:true so scrolls inside the Settings pane also reposition.
    window.addEventListener("scroll", placeDropdown, true);
    const id = window.setTimeout(() => window.addEventListener("mousedown", onDown), 0);
    return () => {
      window.cancelAnimationFrame(raf);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", placeDropdown);
      window.removeEventListener("scroll", placeDropdown, true);
      window.clearTimeout(id);
      window.removeEventListener("mousedown", onDown);
    };
  }, [open, placeDropdown]);

  const pick = (o: SettingsSelectOption<V>) => {
    if (o.disabled) {
      onLockedClick?.(o.value);
      setOpen(false);
      return;
    }
    onChange(o.value);
    setOpen(false);
  };

  return (
    <>
      <button
        ref={btnRef}
        type="button"
        className={"settings-select-trigger" + (open ? " is-open" : "")}
        onClick={toggle}
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={ariaLabel}
      >
        {active?.leading && (
          <span className="settings-select-leading">{active.leading}</span>
        )}
        <span className="settings-select-trigger-label">
          {activeLabel}
          {active?.meta && (
            <span className="settings-select-trigger-meta"> · {active.meta}</span>
          )}
        </span>
        <ChevronDown
          size={14}
          strokeWidth={2}
          className="settings-select-chevron"
        />
      </button>
      {open && pos && createPortal(
        <div
          ref={popRef}
          className={"profile-pop settings-select-pop placement-" + pos.placement}
          role="listbox"
          style={{ top: pos.top, left: pos.left, width: pos.width }}
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => e.stopPropagation()}
        >
          {options.map((o) => {
            const isActive = o.value === value;
            return (
              <button
                key={o.value}
                type="button"
                className={
                  "profile-pop-item settings-select-item" +
                  (isActive ? " is-active" : "") +
                  (o.disabled ? " is-locked" : "")
                }
                role="option"
                aria-selected={isActive}
                onClick={() => pick(o)}
              >
                {o.leading && (
                  <span className="settings-select-leading">{o.leading}</span>
                )}
                <span className="settings-select-item-label">{o.label}</span>
                {o.meta && (
                  <span className="settings-select-item-meta">{o.meta}</span>
                )}
                {isActive && (
                  <Check size={14} strokeWidth={2.5} className="settings-select-check" />
                )}
              </button>
            );
          })}
        </div>,
        document.body
      )}
    </>
  );
}
