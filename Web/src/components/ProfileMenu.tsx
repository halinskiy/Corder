import React from "react";
import { Home, LifeBuoy, LogOut, RefreshCw } from "lucide-react";
import type { T } from "../i18n";
import { getSettings, signOut, triggerUpdateCheck } from "../api";

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
function AvatarGlyph({ variant }: { variant: number }) {
  /// Both width/height attributes AND an inline style are set on
  /// the SVG. The attributes cover renderers that read SVG size
  /// from the element; the inline `style` covers ones that only
  /// honour CSS. Inline style beats any stylesheet, so cascade
  /// order can't quietly drop the size declaration. We arrived at
  /// this combo after the popover variant kept rendering at viewBox
  /// natural size (40×40 tile in the corner of a 48 px round chip)
  /// every time we let CSS classes own the dimensions.
  return (
    <svg
      viewBox="0 0 40 40"
      width="100%"
      height="100%"
      preserveAspectRatio="xMidYMid meet"
      className="avatar-svg"
      style={{ display: "block", width: "100%", height: "100%" }}
      aria-hidden
    >
      <rect width="40" height="40" fill="var(--accent)" />
      <g fill="#fff">{glyphShape(variant)}</g>
    </svg>
  );
}

function glyphShape(variant: number): React.ReactNode {
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
      // Half-moon (rectangle clipped by a circle isn't reliable in
      // every renderer — use a polygon arc approximation drawn as
      // a half-disc via two paths: a full circle minus a rect).
      return (
        <>
          <circle cx="20" cy="20" r="11" />
          <rect x="20" y="9" width="13" height="22" fill="var(--accent)" />
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
      return <rect x="17" y="6" width="6" height="28" rx="2" transform="rotate(45 20 20)" />;
    case 7:
      // Outer ring + inner dot — drawn as two concentric paths via
      // a `stroke` ring (not even-odd, which is flaky in WebKit).
      return (
        <>
          <circle cx="20" cy="20" r="11" fill="none" stroke="#fff" strokeWidth="3" />
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
  const [pickerOpen, setPickerOpen] = React.useState(false);
  const [variant, setVariant] = React.useState(() => readStoredVariant(t.profile_name));
  const [userName, setUserName] = React.useState<string | null>(null);
  const [userEmail, setUserEmail] = React.useState<string | null>(null);
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

  const pickVariant = (v: number) => {
    setVariant(v);
    try { localStorage.setItem(AVATAR_STORAGE_KEY, String(v)); } catch {}
    setPickerOpen(false);
  };

  const goDashboard = () => { onOpenDashboard(); setOpen(false); setPickerOpen(false); };
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
    setPickerOpen(false);
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
    setPickerOpen(false);
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
        <AvatarGlyph variant={variant} />
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
              className="avatar-img-lg avatar-img-lg-svg avatar-pickable"
              onClick={() => setPickerOpen((v) => !v)}
              title={t.profile_pick_avatar}
              aria-label={t.profile_pick_avatar}
              aria-expanded={pickerOpen}
            >
              <AvatarGlyph variant={variant} />
            </button>
            <div className="profile-pop-id">
              {/* Real signed-in identity from the backend. Name
                  falls back to the email's local part, then to a
                  generic "Account" so the header never goes blank
                  during the brief moment between the popover open
                  and the settings fetch landing. */}
              <div className="profile-pop-name">
                {userName ?? userEmail?.split("@")[0] ?? "Account"}
              </div>
              {/* Email under the name. The previous tier chip
                  (FREE / PRO / MAX) lived here — pulled out per
                  Kostya's feedback (visual noise without a real
                  paid surface). Re-introduce when paid flows ship. */}
              {userEmail && (
                <div className="profile-pop-sub">{userEmail}</div>
              )}
            </div>
          </div>

          {pickerOpen && (
            <div className="avatar-picker" role="listbox">
              {Array.from({ length: AVATAR_COUNT }).map((_, i) => (
                <button
                  key={i}
                  type="button"
                  className={"avatar-picker-cell" + (i === variant ? " is-active" : "")}
                  onClick={() => pickVariant(i)}
                  role="option"
                  aria-selected={i === variant}
                  title={t.profile_pick_avatar}
                >
                  <AvatarGlyph variant={i} />
                </button>
              ))}
            </div>
          )}

          {/* Top group: navigation + support. Settings is gone
              from here — there's already a Settings icon in the
              MainHeader toolbar that fires the same handler, no
              need to surface it twice. Get help took its slot,
              filling out the navigation pair. */}
          <div className="profile-pop-sep" />
          <button className="profile-pop-item" onClick={goDashboard} role="menuitem">
            <Home size={15} strokeWidth={2} /> {t.profile_dashboard}
          </button>
          <button className="profile-pop-item" onClick={goHelp} role="menuitem">
            <LifeBuoy size={15} strokeWidth={2} /> {t.profile_help ?? "Get help"}
          </button>
          <button className="profile-pop-item" onClick={checkUpdates} role="menuitem">
            <RefreshCw size={15} strokeWidth={2} /> {t.profile_check_updates ?? "Check for updates"}
          </button>

          {/* Auxiliary group: Sign out (+ legacy danger row slot,
              currently empty — Delete account moved into Settings).
              Same 8 px breathing room from the divider above. */}
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
        </div>
      )}
    </>
  );
}
