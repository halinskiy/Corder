import React from "react";
import { createPortal } from "react-dom";

/// Light-weight tooltip that wraps any child element. Hover the
/// child for `delay` ms (default 350) → a small `.tooltip-pop`
/// floats just below/above the element until the pointer leaves
/// or focus moves away. Matches the look of `.profile-pop` /
/// `.settings-select-pop` so every floating chip in Corder reads
/// as the same visual family.
///
/// Rationale: WKWebView's native `title=` tooltip takes ~1.5 s to
/// show and renders as the system bubble, both miss the
/// "instant context" feeling Kostya is after. A controlled JS
/// tooltip with a tight delay and our design tokens does.
export function Tooltip({
  label, children, side = "bottom", delay = 350, disabled, multiline,
}: {
  label: string;
  children: React.ReactElement;
  /// Wrap the label across lines with roomier padding (for a short
  /// explanation rather than a one-word chip). Default is single-line.
  multiline?: boolean;
  /// Which side of the anchor to float on. "bottom" suits toolbar
  /// rows; "top" suits sidebar rows pinned to the bottom of the
  /// viewport so the tooltip doesn't clip off-screen.
  side?: "top" | "bottom";
  /// ms before the tooltip appears after pointer-enter. 350 is the
  /// sweet spot, fast enough to feel snappy on the second pass,
  /// long enough not to flash when sweeping across the toolbar.
  delay?: number;
  /// Skip the tooltip entirely (e.g. when the anchor itself is
  /// disabled and there's a different message).
  disabled?: boolean;
}) {
  const [shown, setShown] = React.useState(false);
  const [pos, setPos] = React.useState<{ top: number; left: number } | null>(null);
  const timerRef = React.useRef<number | null>(null);
  const anchorRef = React.useRef<HTMLElement | null>(null);

  const cancel = React.useCallback(() => {
    if (timerRef.current != null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const place = React.useCallback(() => {
    const el = anchorRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const left = r.left + r.width / 2;
    const top = side === "bottom" ? r.bottom + 8 : r.top - 8;
    setPos({ top, left });
  }, [side]);

  const onEnter = React.useCallback(() => {
    if (disabled) return;
    cancel();
    timerRef.current = window.setTimeout(() => {
      place();
      setShown(true);
    }, delay);
  }, [cancel, delay, disabled, place]);

  const onLeave = React.useCallback(() => {
    cancel();
    setShown(false);
  }, [cancel]);

  React.useEffect(() => () => cancel(), [cancel]);

  // Clone the child so we can attach a ref + the hover handlers
  // without forcing every caller to do it themselves. The ref is
  // merged with the child's existing ref (if any) so this stays
  // composable with `React.forwardRef` children like buttons.
  const child = React.Children.only(children) as React.ReactElement<{
    ref?: React.Ref<HTMLElement>;
    onMouseEnter?: React.MouseEventHandler<HTMLElement>;
    onMouseLeave?: React.MouseEventHandler<HTMLElement>;
    onMouseDown?: React.MouseEventHandler<HTMLElement>;
    onClick?: React.MouseEventHandler<HTMLElement>;
    onFocus?: React.FocusEventHandler<HTMLElement>;
    onBlur?: React.FocusEventHandler<HTMLElement>;
  }>;
  const cloned = React.cloneElement(child, {
    ref: (node: HTMLElement | null) => {
      anchorRef.current = node;
      const orig = (child as unknown as { ref?: React.Ref<HTMLElement> }).ref;
      if (typeof orig === "function") orig(node);
      else if (orig && typeof orig === "object") {
        (orig as React.MutableRefObject<HTMLElement | null>).current = node;
      }
    },
    onMouseEnter: (e: React.MouseEvent<HTMLElement>) => {
      child.props.onMouseEnter?.(e); onEnter();
    },
    onMouseLeave: (e: React.MouseEvent<HTMLElement>) => {
      child.props.onMouseLeave?.(e); onLeave();
    },
    // Click on the trigger should hide the tooltip immediately and
    // suppress re-show on the lingering hover, otherwise the chip
    // stays floating while the user's already acted on the button
    // (theme switch, archive open, copy, etc.). mouseLeave is the
    // only thing that resets the suppression.
    onMouseDown: (e: React.MouseEvent<HTMLElement>) => {
      child.props.onMouseDown?.(e); onLeave();
    },
    onClick: (e: React.MouseEvent<HTMLElement>) => {
      child.props.onClick?.(e); onLeave();
    },
    onFocus: (e: React.FocusEvent<HTMLElement>) => {
      child.props.onFocus?.(e); onEnter();
    },
    onBlur: (e: React.FocusEvent<HTMLElement>) => {
      child.props.onBlur?.(e); onLeave();
    },
  });

  return (
    <>
      {cloned}
      {shown && pos && createPortal(
        <div
          className={"tooltip-pop tooltip-pop-" + side + (multiline ? " tooltip-pop-multiline" : "")}
          role="tooltip"
          style={{ top: pos.top, left: pos.left }}
        >
          {label}
        </div>,
        document.body
      )}
    </>
  );
}
