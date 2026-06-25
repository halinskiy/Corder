import React from "react";
import { Loader2 } from "lucide-react";
import { Lang } from "../i18n";

/// In-app sign-in modal rendered inside the Library WKWebView. Mirrors the
/// UpdateModal's look — the same `.update-card` with the cursor-tilt 3D
/// parallax + sheen — but WITHOUT the StarsCanvas (stars belong to the
/// update flow, not sign-in). State is pushed in by the Swift side via
/// `window.corderAuthState(...)`; actions go back through
/// `window.webkit.messageHandlers.authAction`. Auth itself stays native
/// (the Supabase SDK owns the session + the account-folder relaunch); this
/// is purely the surface, so the user never sees a separate window.
///
/// The card is WHITE (`var(--bg)`) — the "guest" treatment — by design:
/// only signed-in users get the green/blue accent, a not-signed-in user
/// stays neutral.

export interface AuthModalState {
  visible: boolean;
  /// True while a native auth round-trip (sign-in / sign-up / Google) is in
  /// flight — disables the form + shows a spinner.
  busy: boolean;
  /// Inline error beneath the form (wrong password, network, etc.).
  error?: string | null;
}

const HIDDEN: AuthModalState = { visible: false, busy: false, error: null };

/// Sign-in vs sign-up is now chosen EXPLICITLY by the user (the "Sign up" /
/// "Sign in" link in the subtitle), never auto-flipped from an unknown
/// email. So `mode` is purely local UI state, not pushed by native.
type AuthMode = "signin" | "signup";

type AuthAction =
  | { type: "submit"; email: string; password: string; mode: AuthMode; agreed: boolean }
  | { type: "google"; agreed: boolean }
  | { type: "dismiss" };

declare global {
  interface Window {
    corderAuthState?: (s: AuthModalState) => void;
  }
}

function postAuth(action: AuthAction) {
  try {
    (window as unknown as {
      webkit?: { messageHandlers?: { authAction?: { postMessage: (m: string) => void } } };
    }).webkit?.messageHandlers?.authAction?.postMessage(JSON.stringify(action));
  } catch { /* dev shell has no native bridge */ }
}

export function SignInModalHost({ lang }: { lang: Lang }) {
  void lang;
  const [state, setState] = React.useState<AuthModalState>(HIDDEN);
  const [leaving, setLeaving] = React.useState(false);
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [confirm, setConfirm] = React.useState("");
  const [agreed, setAgreed] = React.useState(false);
  const [mode, setMode] = React.useState<AuthMode>("signin");
  const cardRef = React.useRef<HTMLDivElement | null>(null);
  const leaveTimer = React.useRef<number | null>(null);

  // Swift drives visibility + busy/mode/error. New state cancels any
  // in-flight exit animation; a hide request plays the exit then unmounts.
  React.useEffect(() => {
    window.corderAuthState = (next) => {
      if (next.visible) {
        if (leaveTimer.current != null) { window.clearTimeout(leaveTimer.current); leaveTimer.current = null; }
        setLeaving(false);
        setState({ ...HIDDEN, ...next });
      } else {
        setLeaving(true);
        if (leaveTimer.current != null) window.clearTimeout(leaveTimer.current);
        leaveTimer.current = window.setTimeout(() => {
          setLeaving(false);
          setState(HIDDEN);
          setEmail(""); setPassword(""); setConfirm(""); setAgreed(false); setMode("signin");
          leaveTimer.current = null;
        }, 220);
      }
    };
    return () => { delete window.corderAuthState; };
  }, []);

  // Same cursor-tilt parallax as the update card: map the pointer over the
  // overlay into a small rotateX/rotateY pair + a sheen position, written
  // onto CSS variables the `.update-card` rules read.
  React.useEffect(() => {
    const overlay = document.querySelector(".update-overlay.auth-overlay") as HTMLElement | null;
    const card = cardRef.current;
    if (!overlay || !card) return;
    const reset = () => {
      card.style.setProperty("--tilt-x", "0deg");
      card.style.setProperty("--tilt-y", "0deg");
      card.style.setProperty("--tilt-shine-x", "50%");
      card.style.setProperty("--tilt-shine-y", "50%");
    };
    const onMove = (e: MouseEvent) => {
      const r = overlay.getBoundingClientRect();
      const nx = ((e.clientX - r.left) / r.width) * 2 - 1;
      const ny = ((e.clientY - r.top) / r.height) * 2 - 1;
      const max = 4;   // gentle tilt — subtler than the update modal
      card.style.setProperty("--tilt-x", `${(-ny * max).toFixed(2)}deg`);
      card.style.setProperty("--tilt-y", `${(nx * max).toFixed(2)}deg`);
      const cr = card.getBoundingClientRect();
      card.style.setProperty("--tilt-shine-x", `${((e.clientX - cr.left) / cr.width) * 100}%`);
      card.style.setProperty("--tilt-shine-y", `${((e.clientY - cr.top) / cr.height) * 100}%`);
    };
    overlay.addEventListener("mousemove", onMove);
    overlay.addEventListener("mouseleave", reset);
    return () => { overlay.removeEventListener("mousemove", onMove); overlay.removeEventListener("mouseleave", reset); };
  }, [state.visible]);

  if (!state.visible && !leaving) return null;

  const isSignUp = mode === "signup";
  const ctaLabel = isSignUp ? "Sign up with email" : "Sign in with email";
  const canSubmit = email.trim().length > 0 && password.length > 0 && agreed && !state.busy
    && (!isSignUp || confirm.length > 0);

  const submit = () => {
    if (state.busy) return;
    postAuth({ type: "submit", email: email.trim(), password, mode, agreed });
  };
  const dismiss = () => postAuth({ type: "dismiss" });

  return (
    <div
      className={"update-overlay auth-overlay" + (leaving ? " is-leaving" : "")}
      role="dialog"
      aria-modal="true"
      aria-label={"Sign in"}
      onMouseDown={(e) => { if (e.target === e.currentTarget) dismiss(); }}
    >
      <div
        className={"update-card auth-card" + (leaving ? " is-leaving" : "")}
        ref={cardRef}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="update-card-sheen" aria-hidden />

        <div className="update-head">
          <div className="update-title">{isSignUp ? "Sign up" : "Sign in"}</div>
          <div className="update-status">
            {isSignUp
              ? "Create an account to unlock more with a subscription. Already have one? "
              : "Signing in unlocks more with a subscription. You can also "}
            <button
              type="button"
              className="auth-switch"
              disabled={state.busy}
              onClick={() => setMode(isSignUp ? "signin" : "signup")}
            >
              {isSignUp ? "Sign in" : "Sign up"}
            </button>
          </div>
        </div>

        <div className="auth-form">
          <input
            className="auth-input"
            type="email"
            inputMode="email"
            autoComplete="username"
            placeholder={"you@example.com"}
            value={email}
            disabled={state.busy}
            onChange={(e) => setEmail(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") submit(); }}
          />
          <input
            className="auth-input"
            type="password"
            autoComplete={isSignUp ? "new-password" : "current-password"}
            placeholder={"Password"}
            value={password}
            disabled={state.busy}
            onChange={(e) => setPassword(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") submit(); }}
          />
          {isSignUp && (
            <input
              className="auth-input"
              type="password"
              autoComplete="new-password"
              placeholder={"Confirm password"}
              value={confirm}
              disabled={state.busy}
              onChange={(e) => setConfirm(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") submit(); }}
            />
          )}

          {state.error && <div className="auth-error">{state.error}</div>}

          <div className="auth-or"><span /><em>{"or"}</em><span /></div>

          <button
            type="button"
            className="auth-google"
            disabled={state.busy}
            onClick={() => postAuth({ type: "google", agreed })}
          >
            <GoogleMark /> {"Continue with Google"}
          </button>

          <label className="auth-terms">
            <input type="checkbox" checked={agreed} disabled={state.busy} onChange={(e) => setAgreed(e.target.checked)} />
            <span>
              {"I agree to the "}
              <a onClick={() => corderOpen("https://getcorder.com/terms/")}>{"Terms"}</a>
              {" and "}
              <a onClick={() => corderOpen("https://getcorder.com/privacy-policy/")}>{"Privacy Policy"}</a>
            </span>
          </label>
        </div>

        <div className="update-actions">
          <button
            type="button"
            className={"update-primary auth-primary" + (state.busy ? " is-working" : "")}
            onClick={submit}
            disabled={!canSubmit}
          >
            <span className="update-primary-label">
              {state.busy
                ? <Loader2 size={16} strokeWidth={2.5} className="update-primary-spin" aria-label="Working" />
                : ctaLabel}
            </span>
          </button>
          <button type="button" className="update-secondary" onClick={dismiss}>
            {"Later"}
          </button>
        </div>
      </div>
    </div>
  );
}

function corderOpen(url: string) {
  try {
    (window as unknown as { corderOpenExternal?: (u: string) => void }).corderOpenExternal?.(url);
  } catch { /* no-op in dev */ }
}

function GoogleMark() {
  return (
    <svg width="16" height="16" viewBox="0 0 18 18" aria-hidden style={{ flexShrink: 0 }}>
      <path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.71-1.57 2.68-3.89 2.68-6.62z" />
      <path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.81.54-1.84.86-3.04.86-2.34 0-4.32-1.58-5.03-3.7H.96v2.33A9 9 0 0 0 9 18z" />
      <path fill="#FBBC05" d="M3.97 10.72a5.4 5.4 0 0 1 0-3.44V4.95H.96a9 9 0 0 0 0 8.1l3.01-2.33z" />
      <path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58C13.46.89 11.43 0 9 0A9 9 0 0 0 .96 4.95l3.01 2.33C4.68 5.16 6.66 3.58 9 3.58z" />
    </svg>
  );
}
