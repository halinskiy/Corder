import React from "react";
import { Home, LifeBuoy, LogOut, RefreshCw, Shuffle } from "lucide-react";
import type { T } from "../i18n";
import { getSettings, signOut, triggerUpdateCheck, openWelcome } from "../api";

const AVATAR_COUNT = 9;
const AVATAR_STORAGE_KEY = "corder.avatarVariant";

/// Returns one of the 9 abstract glyph indices, persisted across
/// launches. Falls back to a deterministic hash of `seed` if the
/// user hasn't picked yet — so the first run always shows a stable
/// glyph rather than a default placeholder.
function readStoredVariant(seed: string): number {
  try {
    const raw = localStorage.getItem(AVATAR_STORAGE_KEY);
    if (raw !== null) {
      const n = parseInt(raw, 10);
      if (Number.isFinite(n) && n >= 0 && n < AVATAR_COUNT) return n;
    }
  } catch {}
  let hash = 0;
  for (let i = 0; i < seed.length; i++) hash = (hash * 31 + seed.charCodeAt(i)) | 0;
  return Math.abs(hash) % AVATAR_COUNT;
}

/// One of 9 simple, bold glyphs on the accent green. All shapes are
/// built from primitive SVG elements (<circle>, <rect>, <polygon>) +
/// straight-line paths so they render reliably in WKWebView (the
/// arc-only paths I tried first didn't paint on the tester's machine).
function AvatarGlyph({ variant, paid }: { variant: number; paid: boolean }) {
  /// Tier-aware. Paid (Pro / Max) gets the canonical accent-green
  /// fill with a white glyph. Free gets a transparent surface with
  /// a dark glyph and a hairline outline — mirrors the secondary
  /// button treatment so a Free avatar reads as "outlined / not
  /// upgraded yet". The `var(--avatar-cutout)` variable is what
  /// the half-moon case (variant 2) paints over its overlapping
  /// rect — paid = accent, free = bg so the cut-out blends into
  /// the surface.
  const fillBg = paid ? "var(--accent)" : "transparent";
  const fillGlyph = paid ? "#fff" : "var(--fg)";
  const stroke = paid ? "var(--accent)" : "var(--border-strong)";
  return (
    <svg
      viewBox="0 0 40 40"
      width="100%"
      height="100%"
      preserveAspectRatio="xMidYMid meet"
      className="avatar-svg"
      style={{
        display: "block",
        width: "100%",
        height: "100%",
        ["--avatar-cutout" as string]: paid ? "var(--accent)" : "var(--bg)",
      }}
      aria-hidden
    >
      <circle cx="20" cy="20" r="20" fill={fillBg} />
      <g fill={fillGlyph}>{glyphShape(variant, fillGlyph)}</g>
      {/* Ring drawn LAST so glyphs (half-moon cut-out, diagonal bar)
          can't paint over it. Circle, not rect — the avatar frame is
          round, a rectangular stroke gets clipped by border-radius. */}
      <circle
        cx="20"
        cy="20"
        r="19.5"
        fill="none"
        stroke={stroke}
        strokeWidth="1"
      />
    </svg>
  );
}

function glyphShape(variant: number, glyphFill: string): React.ReactNode {
  void glyphFill; // each <path>/<rect> below inherits via the parent <g fill=…>
  switch (variant % AVATAR_COUNT) {
    case 0:
      // Single bold dot
      return <circle cx="20" cy="20" r="10" />;
    case 1:
      // Two stacked dots — friend / dialogue glyph
      return (
        <>
          <circle cx="20" cy="13" r="5.5" />
          <circle cx="20" cy="27" r="5.5" />
        </>
      );
    case 2:
      // Half-moon: full disc with the right half cut out by a rect
      // painted in the SURFACE colour (accent for paid, bg for free).
      // Pulling the cut-out colour from a CSS variable means the
      // glyph file doesn't have to know which tier it's rendering for.
      return (
        <>
          <circle cx="20" cy="20" r="11" />
          <rect x="20" y="9" width="13" height="22" fill="var(--avatar-cutout)" />
        </>
      );
    case 3:
      // Square — rotated 45° for a diamond. SVG transform = stable.
      return <rect x="11" y="11" width="18" height="18" rx="2" transform="rotate(45 20 20)" />;
    case 4:
      // Soft rounded square
      return <rect x="9" y="9" width="22" height="22" rx="5" />;
    case 5:
      // Triangle (equilateral, pointing up)
      return <polygon points="20,8 31,30 9,30" />;
    case 6:
      // Bold diagonal bar — a single rounded rect rotated 45°. The
      // rect is sized so that after rotation its endpoints stay well
      // inside the 19-radius clip circle (overflow:hidden + 50%
      // border-radius). Earlier length=34 put the corners ~17 px
      // from centre, which sat ON the clip boundary and the tip
      // read as "cut off" at the top of the avatar. height=28
      // leaves ~4 px breathing room from the circle's edge.
      return <rect x="17" y="9" width="6" height="22" rx="2" transform="rotate(45 20 20)" />;
    case 7:
      // Outer ring + inner dot — drawn as two concentric paths via
      // a `stroke` ring (not even-odd, which is flaky in WebKit).
      // Ring colour follows the glyph (white on paid, dark on free).
      return (
        <>
          <circle cx="20" cy="20" r="11" fill="none" stroke="currentColor" strokeWidth="3" />
          <circle cx="20" cy="20" r="4" />
        </>
      );
    case 8:
    default:
      // Four-petal flower / quatrefoil — four overlapping circles
      return (
        <>
          <circle cx="20" cy="12" r="6" />
          <circle cx="20" cy="28" r="6" />
          <circle cx="12" cy="20" r="6" />
          <circle cx="28" cy="20" r="6" />
        </>
      );
  }
}

/// Avatar button + dropdown. The menu is rendered fixed and anchored
/// to the button's rect so it floats above everything (the header
/// lives in an `overflow: hidden` column). Click-outside and Esc
/// close it. The 9-variant glyph picker expands inline under the
/// profile header.
export function ProfileMenu({
  onOpenSettings,
  onOpenDashboard,
  t,
}: {
  /// Kept in the signature for the parent's existing call site even
  /// though we don't surface toasts here anymore (Sign-out used to
  /// emit a "Soon" toast — gone with the Upgrade-to-Pro CTA). The
  /// `_onToast` param-name silences `noUnusedParameters`.
  onToast?: (msg: string, kind?: "success" | "error") => void;
  onOpenSettings: () => void;
  onOpenDashboard: () => void;
  t: T;
}) {
  const [open, setOpen] = React.useState(false);
  const [variant, setVariant] = React.useState(() => readStoredVariant(t.profile_name));
  const [userName, setUserName] = React.useState<string | null>(null);
  const [userEmail, setUserEmail] = React.useState<string | null>(null);
  // null = not editing; string = in-progress edit value. Same pattern
  // as the MeetingView breadcrumb rename inline-input.
  const [nameEdit, setNameEdit] = React.useState<string | null>(null);
  const commitName = React.useCallback(async () => {
    if (nameEdit === null) return;
    const v = nameEdit.trim();
    setNameEdit(null);
    if (v === (userName ?? "")) return;
    // Optimistic — POST then trust the server-echoed value on the
    // next /api/settings poll to reconcile.
    setUserName(v.length > 0 ? v : null);
    try {
      await import("../api").then((m) => m.setSettings({ user_name: v }));
    } catch {
      /* next poll snaps state back if the write failed */
    }
  }, [nameEdit, userName]);
  const [tier, setTier] = React.useState<"free" | "pro" | "max">("free");
  const paid = tier === "pro" || tier === "max";

  // Pull tier on mount so the header avatar can render its
  // accent-vs-outlined treatment without waiting for the popover
  // to open. Refreshed alongside the in-popover settings read.
  React.useEffect(() => {
    (async () => {
      try {
        const s = await getSettings();
        if (s.tier === "pro" || s.tier === "max") setTier(s.tier);
        else setTier("free");
      } catch {}
    })();
  }, []);
  const btnRef = React.useRef<HTMLButtonElement>(null);
  const [pos, setPos] = React.useState<{ top: number; right: number } | null>(null);

  /// Pull the signed-in identity (name + email) from the backend each
  /// time the popover opens. Header reads these directly — no more
  /// hard-coded "Kostiantyn Halynskyi" inside `i18n.ts`. The tier
  /// chip moved out of this header (Kostya's feedback: visual noise
  /// while we don't have a real paid surface yet).
  React.useEffect(() => {
    if (!open) return;
    (async () => {
      try {
        const s = await getSettings();
        setUserName(s.user_name ?? null);
        setUserEmail(s.user_email ?? null);
        if (s.tier === "pro" || s.tier === "max") setTier(s.tier);
        else setTier("free");
      } catch {}
    })();
  }, [open]);

  const place = React.useCallback(() => {
    const r = btnRef.current?.getBoundingClientRect();
    if (r) setPos({ top: r.bottom + 8, right: window.innerWidth - r.right });
  }, []);

  React.useEffect(() => {
    if (!open) return;
    place();
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    const onDown = (e: MouseEvent) => {
      if (!btnRef.current?.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("resize", place);
    const id = window.setTimeout(
      () => window.addEventListener("mousedown", onDown), 0);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", place);
      window.clearTimeout(id);
      window.removeEventListener("mousedown", onDown);
    };
  }, [open, place]);

  /// Cycle to a fresh random variant on every click — never repeats
  /// the current one (otherwise rolling the same index does nothing
  /// visible and feels broken). Persists via the same localStorage
  /// key so the choice survives a relaunch. Replaces the old 3×3
  /// grid picker (cleaner, single tap, no extra UI).
  const shuffleAvatar = () => {
    if (AVATAR_COUNT <= 1) return;
    let next = Math.floor(Math.random() * AVATAR_COUNT);
    if (next === variant) next = (next + 1) % AVATAR_COUNT;
    setVariant(next);
    try { localStorage.setItem(AVATAR_STORAGE_KEY, String(next)); } catch {}
  };

  const goDashboard = () => { onOpenDashboard(); setOpen(false); };
  // `onOpenSettings` removed from the popover rows (header has
  // its own gear icon). Reference it once so TS's
  // noUnusedParameters check doesn't complain — the prop stays
  // on the type to avoid cascading the rename through MainHeader
  // / main.tsx call sites.
  void onOpenSettings;

  /// Opens the landing's /contact page in the system browser.
  /// The page on getcorder.com carries the support form + the
  /// right contact email, so the client doesn't have to ship its
  /// own copy. `corderOpenExternal` hands the URL to
  /// `NSWorkspace.shared.open` on the Swift side — WKWebView's
  /// own link handler can't open external HTTP URLs without
  /// extra plumbing.
  const goHelp = () => {
    try {
      (window as unknown as { corderOpenExternal?: (url: string) => void })
        .corderOpenExternal?.("https://getcorder.com/contact/");
    } catch {}
    setOpen(false);
    
  };

  /// Force Sparkle to refetch the appcast right now. Useful when
  /// the user just installed an old build and doesn't want to wait
  /// for Sparkle's lazy ~24 h schedule — or when the previous
  /// background check ran before the new release was published.
  /// The Swift route triggers the same `checkForUpdates` Sparkle
  /// path the UpdatePill uses internally; if a newer version is
  /// found, the standard Sparkle dialog pops up.
  const checkUpdates = async () => {
    setOpen(false);
    
    try { await triggerUpdateCheck(); } catch {}
  };

  return (
    <>
      <button
        ref={btnRef}
        className="avatar-btn avatar-btn-svg"
        onClick={() => setOpen((v) => !v)}
        title={t.profile_title}
        aria-label={t.profile_title}
      >
        <AvatarGlyph variant={variant} paid={paid} />
      </button>
      {open && pos && (
        <div
          className="profile-pop"
          role="menu"
          style={{ top: pos.top, right: pos.right }}
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => e.stopPropagation()}
        >
          <div className="profile-pop-head">
            <button
              className="avatar-img-lg avatar-img-lg-svg avatar-pickable avatar-shuffle"
              onClick={shuffleAvatar}
              title={t.profile_pick_avatar}
              aria-label={t.profile_pick_avatar}
            >
              <AvatarGlyph variant={variant} paid={paid} />
              <span className="avatar-shuffle-overlay" aria-hidden>
                <Shuffle size={18} strokeWidth={2} />
              </span>
            </button>
            <div className="profile-pop-id">
              {/* Signed-in identity, or a sign-in CTA when the
                  account is empty. The previous placeholder text
                  was getting served as a real "account" — the
                  popover even surfaced Sign-out on a signed-out
                  build, which made no sense. */}
              {userEmail ? (
                <>
                  {nameEdit !== null ? (
                    <input
                      className="profile-pop-name profile-pop-name-edit"
                      autoFocus
                      value={nameEdit}
                      placeholder={userEmail.split("@")[0] ?? "Account"}
                      onChange={(e) => setNameEdit(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") { e.preventDefault(); void commitName(); }
                        else if (e.key === "Escape") { e.preventDefault(); setNameEdit(null); }
                      }}
                      onBlur={() => { void commitName(); }}
                    />
                  ) : (
                    <div
                      className="profile-pop-name profile-pop-name-rename"
                      role="button"
                      title={t.profile_name_rename ?? "Rename"}
                      onClick={() => setNameEdit(userName ?? "")}
                    >
                      {userName ?? userEmail.split("@")[0] ?? "Account"}
                    </div>
                  )}
                  <div className="profile-pop-sub">{userEmail}</div>
                </>
              ) : (
                <>
                  <div className="profile-pop-name">{t.profile_signed_out_title ?? "Not signed in"}</div>
                  <div className="profile-pop-sub">{t.profile_signed_out_body ?? "Sign in to access your account."}</div>
                </>
              )}
            </div>
          </div>


          {/* Top group: navigation + support. Settings is gone
              from here — there's already a Settings icon in the
              MainHeader toolbar that fires the same handler, no
              need to surface it twice. Get help took its slot,
              filling out the navigation pair. */}
          <div className="profile-pop-sep" />
          {!userEmail && (
            <button
              className="profile-pop-item"
              onClick={async () => { setOpen(false); try { await openWelcome(); } catch {} }}
              role="menuitem"
            >
              <Home size={15} strokeWidth={2} /> {t.profile_sign_in ?? "Sign in"}
            </button>
          )}
          {userEmail && (
            <button className="profile-pop-item" onClick={goDashboard} role="menuitem">
              <Home size={15} strokeWidth={2} /> {t.profile_dashboard}
            </button>
          )}
          <button className="profile-pop-item" onClick={goHelp} role="menuitem">
            <LifeBuoy size={15} strokeWidth={2} /> {t.profile_help ?? "Get help"}
          </button>
          <button className="profile-pop-item" onClick={checkUpdates} role="menuitem">
            <RefreshCw size={15} strokeWidth={2} /> {t.profile_check_updates ?? "Check for updates"}
          </button>

          {/* Auxiliary group: Sign out (+ legacy danger row slot,
              currently empty — Delete account moved into Settings).
              Same 8 px breathing room from the divider above. */}
          {userEmail && (
            <>
              <div className="profile-pop-sep" />
              <button
                className="profile-pop-item profile-pop-item-danger"
                onClick={async () => {
                  setOpen(false);
                  try { await signOut(); } catch {}
                  // The Swift sign-out path triggers a process relaunch
                  // (per-account on-disk paths can't be swapped live),
                  // so there's no point reloading here — the new
                  // process boots straight into the Welcome wizard.
                }}
                role="menuitem"
              >
                <LogOut size={15} strokeWidth={2} /> {t.profile_signout}
              </button>
            </>
          )}
        </div>
      )}
    </>
  );
}
