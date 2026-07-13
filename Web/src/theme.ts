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
// "Follow system" was removed, everyone defaults to light, and only an
// explicit "dark" choice opts into dark. A stale stored "system" value
// falls through to the light default below.
export type ThemeMode = "light" | "dark";

function storedMode(): ThemeMode {
  try {
    const v = localStorage.getItem(KEY);
    if (v === "dark" || v === "light") return v;
  } catch {}
  return "light";
}

function resolveDark(mode: ThemeMode): boolean {
  return mode === "dark";
}

function stored(): "light" | "dark" {
  return resolveDark(storedMode()) ? "dark" : "light";
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
  const [mode, setModeState] = React.useState<ThemeMode>(() => storedMode());
  const [isDark, setIsDark] = React.useState(() => resolveDark(storedMode()));

  React.useEffect(() => {
    apply(isDark);
  }, [isDark]);

  /// Apply a new mode with the cursor-origin radial reveal. `origin`
  /// is the click point in viewport coords, pass the event from a
  /// SettingsSelect option click. Falls back to the centre of the
  /// viewport when the caller has nothing better.
  const setMode = React.useCallback(
    (next: ThemeMode, origin?: { x: number; y: number }) => {
      try { localStorage.setItem(KEY, next); } catch {}
      const targetDark = resolveDark(next);
      if (targetDark === isDark) { setModeState(next); return; }
      runWipe(origin, () => {
        setModeState(next);
        setIsDark(targetDark);
      });
    },
    [isDark]
  );

  const toggle = React.useCallback((e: React.MouseEvent) => {
    setMode(isDark ? "light" : "dark", { x: e.clientX, y: e.clientY });
  }, [isDark, setMode]);

  return { isDark, mode, setMode, toggle };
}

/// Cursor-origin radial wipe shared by every theme switch.
function runWipe(origin: { x: number; y: number } | undefined, commit: () => void) {
  const start = (document as unknown as {
    startViewTransition?: (cb: () => void) => {
      ready: Promise<void>;
      finished: Promise<void>;
    };
  }).startViewTransition?.bind(document);

  const doCommit = () => flushSync(commit);

  if (!start) { doCommit(); return; }

  const x = origin?.x ?? window.innerWidth / 2;
  const y = origin?.y ?? window.innerHeight / 2;
  const endRadius = Math.hypot(
    Math.max(x, window.innerWidth - x),
    Math.max(y, window.innerHeight - y)
  );
  const root = document.documentElement;
  root.style.setProperty("--vt-x", `${x}px`);
  root.style.setProperty("--vt-y", `${y}px`);
  root.style.setProperty("--vt-r", `${endRadius}px`);
  root.classList.add("theme-anim");

  const transition = start(doCommit);
  transition.ready.then(() => {
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
  }).catch(() => {});
  transition.finished.catch(() => {}).finally(() => {
    root.classList.remove("theme-anim");
  });
}
