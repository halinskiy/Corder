import React from "react";
import { flushSync } from "react-dom";

/// Light/dark theme with the cursor-origin radial reveal (View
/// Transitions API): the new theme is wiped in as an expanding circle
/// centred on the click point. Falls back to an instant switch where
/// the API is unavailable.
///
/// Persistence note: the embedded server binds to an ephemeral port,
/// so the page origin changes every launch and localStorage does NOT
/// survive a restart. The choice still persists for the whole
/// session; a cross-launch store would need a native bridge.
const KEY = "corder.theme";

function stored(): "light" | "dark" {
  try {
    return localStorage.getItem(KEY) === "dark" ? "dark" : "light";
  } catch {
    return "light";
  }
}

/// Tell native the resolved page background so the NSWindow (visible
/// in the titlebar strip / overscroll rubber-band) follows the theme
/// instead of a hardcoded colour. No-op outside the WKWebView host.
function syncNativeBg() {
  try {
    const bg = getComputedStyle(document.body)
      .getPropertyValue("--bg").trim();
    const bridge = (window as unknown as {
      webkit?: { messageHandlers?: { themeColor?: { postMessage: (m: string) => void } } };
    }).webkit?.messageHandlers?.themeColor;
    if (bg && bridge) bridge.postMessage(bg);
  } catch {}
}

function apply(dark: boolean) {
  document.documentElement.classList.toggle("dark", dark);
  document.body.classList.toggle("dark", dark);
  syncNativeBg();
}

/// Call once before first paint so a session-persisted dark theme is
/// already on when the app mounts.
export function initTheme() {
  apply(stored() === "dark");
}

export function useTheme() {
  const [isDark, setIsDark] = React.useState(() => stored() === "dark");

  React.useEffect(() => {
    apply(isDark);
  }, [isDark]);

  const toggle = React.useCallback(
    (e: React.MouseEvent) => {
      const next = !isDark;
      const commit = () => {
        try {
          localStorage.setItem(KEY, next ? "dark" : "light");
        } catch {}
        // flushSync so the DOM is fully repainted in the new theme
        // *before* the View Transition snapshots it. Without this the
        // React state update is async, the snapshot catches the old
        // theme, and the interface flickers old → new under the wipe.
        flushSync(() => setIsDark(next));
      };

      const start = (document as unknown as {
        startViewTransition?: (cb: () => void) => {
          ready: Promise<void>;
          finished: Promise<void>;
        };
      }).startViewTransition?.bind(document);

      if (!start) {
        commit();
        return;
      }

      const x = e.clientX;
      const y = e.clientY;
      const endRadius = Math.hypot(
        Math.max(x, window.innerWidth - x),
        Math.max(y, window.innerHeight - y)
      );

      // CSS pre-clips `::view-transition-new(root)` to `circle(0 at
      // --vt-x --vt-y)`, so the very first composited frame is already
      // hidden (no flash). These vars feed that static initial clip.
      const root = document.documentElement;
      root.style.setProperty("--vt-x", `${x}px`);
      root.style.setProperty("--vt-y", `${y}px`);
      root.style.setProperty("--vt-r", `${endRadius}px`);

      // Freeze element CSS transitions for the duration of the wipe so
      // colour-animated bits don't flicker under it.
      root.classList.add("theme-anim");

      const transition = start(commit);
      // WAAPI on the VT pseudo = WebKit's ACCELERATED path (CSS
      // @keyframes on clip-path:circle() re-rasterises every frame).
      // `fill: "forwards"` is LOAD-BEARING: without it the animation's
      // effect is dropped the instant it ends, so clip-path snaps back
      // to the CSS resting value (circle(0) — fully hidden), and the
      // old snapshot underneath shows through for a few frames before
      // `transition.finished` tears down the snapshots = backward
      // "snap to old then jump to new" flicker at the END of the wipe.
      transition.ready
        .then(() => {
          root.animate(
            {
              clipPath: [
                `circle(0px at ${x}px ${y}px)`,
                `circle(${endRadius}px at ${x}px ${y}px)`,
              ],
            },
            {
              duration: 700,
              easing: "ease-in-out",
              fill: "forwards",
              pseudoElement: "::view-transition-new(root)",
            }
          );
        })
        .catch(() => {});
      transition.finished
        .catch(() => {})
        .finally(() => {
          root.classList.remove("theme-anim");
        });
    },
    [isDark]
  );

  return { isDark, toggle };
}
