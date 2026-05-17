import React from "react";
import { User, Settings, LogOut } from "lucide-react";
import type { T } from "../i18n";

/// Avatar button + dropdown. The menu is rendered fixed and anchored to
/// the button's rect so it floats above everything (the header lives in
/// an `overflow:hidden` column). Light/dark via tokens. Click-outside
/// and Esc close it.
export function ProfileMenu({
  onToast,
  t,
}: {
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}) {
  const [open, setOpen] = React.useState(false);
  const [imgOk, setImgOk] = React.useState(true);
  const btnRef = React.useRef<HTMLButtonElement>(null);
  const [pos, setPos] = React.useState<{ top: number; right: number } | null>(null);

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
    // Defer so the opening click doesn't immediately close it.
    const id = window.setTimeout(
      () => window.addEventListener("mousedown", onDown), 0);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", place);
      window.clearTimeout(id);
      window.removeEventListener("mousedown", onDown);
    };
  }, [open, place]);

  const soon = () => { onToast(t.profile_soon, "success"); setOpen(false); };

  return (
    <>
      <button
        ref={btnRef}
        className={"avatar-btn" + (imgOk ? "" : " is-empty")}
        onClick={() => setOpen((v) => !v)}
        title={t.profile_title}
        aria-label={t.profile_title}
      >
        {imgOk ? (
          <img
            className="avatar-img"
            src="/avatar.jpg"
            alt=""
            onError={() => setImgOk(false)}
          />
        ) : (
          <span className="avatar-fallback"><User size={16} strokeWidth={2} /></span>
        )}
      </button>
      {open && pos && (
        <div
          className="profile-pop"
          role="menu"
          style={{ top: pos.top, right: pos.right }}
          onClick={(e) => e.stopPropagation()}
        >
          <div className="profile-pop-head">
            <span className="avatar-img-lg">
              {imgOk
                ? <img src="/avatar.jpg" alt="" onError={() => setImgOk(false)} />
                : <User size={20} strokeWidth={2} />}
            </span>
            <div className="profile-pop-id">
              <div className="profile-pop-name">{t.profile_name}</div>
              <div className="profile-pop-sub">{t.profile_sub}</div>
            </div>
          </div>
          <div className="profile-pop-sep" />
          <button className="profile-pop-item" onClick={soon} role="menuitem">
            <Settings size={15} strokeWidth={2} /> {t.profile_account}
          </button>
          <button className="profile-pop-item" onClick={soon} role="menuitem">
            <LogOut size={15} strokeWidth={2} /> {t.profile_signout}
          </button>
        </div>
      )}
    </>
  );
}
