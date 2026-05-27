import React from "react";
import { createPortal } from "react-dom";
import { X, Search } from "lucide-react";
import {
  getSettings, setSettings, getInstalledApps, appIconSrc,
  type Settings, type InstalledApp, type AudioInputDevice,
} from "../api";
import type { T } from "../i18n";

/// Settings page (right column, next to "Recording"). Toggles are
/// REAL: loaded from and persisted to /api/settings. Each change posts
/// only the changed field (debounced ~400 ms); the backend treats an
/// absent field as "unchanged" so a stale tab can't clobber the rest.
/// Audio (mic + system) deliberately has NO toggle — a transcription
/// recorder must capture audio, it's intrinsic; and mic/system stay
/// coupled because the dual-track pipeline assumes both exist. Video
/// IS optional.
export function SettingsPane({ t }: { t: T }) {
  const [s, setS] = React.useState<Settings | null>(null);
  const [apps, setApps] = React.useState<InstalledApp[]>([]);
  const pending = React.useRef<Settings>({});
  const timer = React.useRef<number | null>(null);

  React.useEffect(() => {
    let alive = true;
    getSettings().then((v) => { if (alive) setS(v); }).catch(() => {});
    // Installed-apps list powers the picker AND resolves bundle ids to
    // friendly names/icons in the rows. Best-effort: on failure the
    // rows just fall back to showing the raw bundle id.
    getInstalledApps().then((a) => { if (alive) setApps(a); }).catch(() => {});
    return () => { alive = false; };
  }, []);

  // Optimistic local update + debounced POST of ONLY the changed
  // fields. The backend leaves omitted fields untouched.
  const patch = React.useCallback((p: Settings) => {
    setS((cur) => (cur ? { ...cur, ...p } : cur));
    pending.current = { ...pending.current, ...p };
    if (timer.current != null) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      const body = pending.current;
      pending.current = {};
      timer.current = null;
      setSettings(body).then((fresh) => setS(fresh)).catch(() => {});
    }, 400);
  }, []);

  // Re-pull settings (hotkey: the POST response's record_hotkey_ok can
  // be stale because the Carbon re-register is async on the main run
  // loop — a short refetch gets the authoritative value).
  const refetch = React.useCallback(() => {
    getSettings().then(setS).catch(() => {});
  }, []);

  const loaded = s != null;
  // Every toggle defaults ON until the real value loads (matches the
  // backend default, so no flicker to "off" then back).
  const on = (k: keyof Settings) => (s?.[k] as boolean | undefined) ?? true;

  // Each plain toggle gets its OWN framed card — the uppercase category
  // labels (NOTIFICATIONS / CAPTURE / TRANSCRIPTION) read as form
  // chrome that the user explicitly didn't want. Settings now feels
  // like a vertical stack of independent setting cards. The two
  // compound sections (Auto-detect lists, Shortcut) keep their titles
  // because they bundle multiple sub-elements that need a frame.
  return (
    <div className="settings-pane">
      <SoloCard>
        <Toggle
          label={t.settings_notifications}
          desc={t.settings_notifications_desc}
          checked={on("notifications")}
          disabled={!loaded}
          onChange={(v) => patch({ notifications: v })}
        />
      </SoloCard>

      <SoloCard>
        <Toggle
          label={t.settings_video}
          desc={t.settings_video_desc}
          checked={on("capture_video")}
          disabled={!loaded}
          onChange={(v) => patch({ capture_video: v })}
        />
      </SoloCard>

      {/* Microphone picker. Sits next to the screen-video toggle
          because both belong to "what the recorder captures". Pre-feature
          behaviour ("System default") stays available as the first option
          and is the value used when `mic_device_uid` is empty/null. The
          choice applies to the NEXT recording — we don't hot-swap a live
          AVAudioEngine binding (would need a stop/start cycle). */}
      <SoloCard>
        <MicDevicePicker
          devices={s?.audio_input_devices ?? []}
          value={s?.mic_device_uid ?? ""}
          disabled={!loaded}
          onChange={(uid) => patch({ mic_device_uid: uid })}
          t={t}
        />
      </SoloCard>

      <SoloCard>
        <Toggle
          label={t.settings_autotranscribe}
          desc={t.settings_autotranscribe_desc}
          checked={on("auto_transcribe")}
          disabled={!loaded}
          onChange={(v) => patch({ auto_transcribe: v })}
        />
      </SoloCard>

      <SoloCard>
        <Toggle
          label={t.settings_autotitle}
          desc={t.settings_autotitle_desc}
          checked={on("auto_title")}
          disabled={!loaded}
          onChange={(v) => patch({ auto_title: v })}
        />
      </SoloCard>

      <SoloCard>
        <Toggle
          label={t.settings_autosummary}
          desc={t.settings_autosummary_desc}
          checked={on("auto_summary")}
          disabled={!loaded}
          onChange={(v) => patch({ auto_summary: v })}
        />
      </SoloCard>

      <div className="settings-divider" />
      <SoloCard>
        <HotkeyRow
          label={s?.record_hotkey_label ?? "⌘⇧F"}
          conflict={s?.record_hotkey_conflict ?? null}
          ok={s?.record_hotkey_ok ?? true}
          disabled={!loaded}
          onSet={(code, mods) => {
            patch({ record_hotkey_code: code, record_hotkey_mods: mods });
            window.setTimeout(refetch, 450);
          }}
          t={t}
        />
      </SoloCard>

      <SoloCard>
        <AppListEditor
          title={t.settings_whitelist}
          items={s?.meeting_whitelist ?? []}
          apps={apps}
          disabled={!loaded}
          onChange={(next) => patch({ meeting_whitelist: next })}
          t={t}
        />
      </SoloCard>

      <SoloCard>
        <AppListEditor
          title={t.settings_blacklist}
          items={s?.meeting_blacklist ?? []}
          apps={apps}
          disabled={!loaded}
          onChange={(next) => patch({ meeting_blacklist: next })}
          t={t}
        />
      </SoloCard>
    </div>
  );
}

/// One-row framed card — no section title above. Used for the standalone
/// toggle settings; visually a single `.settings-rows` frame holding one
/// child. Identical look to a single-row Section but without the eyebrow.
function SoloCard({ children }: { children: React.ReactNode }) {
  return <div className="settings-rows">{children}</div>;
}

/// Microphone input device dropdown. Uses a native `<select>` styled
/// to fit the `.settings-row` frame — same horizontal rhythm as the
/// toggles next to it. We picked native over a portal popover for
/// two reasons: (1) every macOS user already knows how the system
/// menu reads, no behaviour to relearn; (2) keyboard / VoiceOver
/// handling comes free. The first option is the explicit "System
/// default" fall-back (empty UID), and the device flagged
/// `is_system_default` gets a trailing hint so the user can see
/// which physical device the OS currently considers default without
/// switching tabs.
function MicDevicePicker({
  devices, value, disabled, onChange, t,
}: {
  devices: AudioInputDevice[];
  value: string;
  disabled?: boolean;
  onChange: (uid: string) => void;
  t: T;
}) {
  const noDevices = devices.length === 0;
  const sysLabel = t.settings_mic_device_system ?? "System default";
  // Same vertical layout as `HotkeyRow` (.hk-block): label + desc
  // stacked on top, control on its own row underneath, full width.
  // Keeps the design system consistent — every "single control with
  // explainer" row in Settings reads the same way.
  return (
    <div className={"hk-block mic-block" + (disabled ? " is-loading" : "")}
         aria-label={t.settings_mic_device ?? "Microphone"}>
      <div className="settings-row-label">{t.settings_mic_device ?? "Microphone"}</div>
      <div className="settings-row-desc">
        {t.settings_mic_device_desc
          ?? "Pick which input device records your voice."}
      </div>
      <select
        className="settings-row-select mic-select"
        value={value}
        disabled={disabled || noDevices}
        onChange={(e) => onChange(e.target.value)}
        aria-label={t.settings_mic_device ?? "Microphone"}
      >
        <option value="">{sysLabel}</option>
        {devices.map((d) => (
          <option key={d.uid} value={d.uid}>
            {d.is_system_default ? `${d.name} · system default` : d.name}
          </option>
        ))}
        {noDevices && (
          <option value="" disabled>
            {t.settings_mic_device_empty ?? "No input devices found"}
          </option>
        )}
      </select>
    </div>
  );
}

/// One app list (whitelist or blacklist). No bundle-id typing: the
/// user picks from installed apps via a searchable dropdown — apps
/// Corder recently saw on the mic float to the top. Rows show the app
/// icon + friendly name (bundle id is the tooltip). Built only from
/// existing tokens/components — consistency first.
function AppListEditor({
  title, items, apps, disabled, onChange, t,
}: {
  title: string;
  items: string[];
  apps: InstalledApp[];
  disabled?: boolean;
  onChange: (next: string[]) => void;
  t: T;
}) {
  const [open, setOpen] = React.useState(false);
  const [q, setQ] = React.useState("");
  const addRef = React.useRef<HTMLButtonElement | null>(null);
  const popRef = React.useRef<HTMLDivElement | null>(null);
  const [pos, setPos] = React.useState<{ top: number; left: number; width: number } | null>(null);

  const place = React.useCallback(() => {
    const r = addRef.current?.getBoundingClientRect();
    if (r) setPos({ top: r.bottom + 6, left: r.left, width: r.width });
  }, []);

  const nameFor = (b: string) => apps.find((a) => a.bundle === b)?.name ?? b;
  const add = (b: string) => {
    if (!items.includes(b)) onChange([...items, b]);
    setOpen(false);
    setQ("");
  };
  const remove = (b: string) => onChange(items.filter((x) => x !== b));

  // Picker is PORTALLED to <body> and fixed-positioned at the button's
  // rect — the settings list is `overflow:hidden` and stacked under
  // sibling cards, so an in-flow dropdown got clipped / hidden. Anchored
  // like ProfileMenu; repositions on scroll/resize; outside-click/Esc.
  React.useEffect(() => {
    if (!open) return;
    place();
    const onDoc = (e: MouseEvent) => {
      const tgt = e.target as Node;
      if (!popRef.current?.contains(tgt) && !addRef.current?.contains(tgt)) {
        setOpen(false);
      }
    };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    const id = window.setTimeout(
      () => window.addEventListener("mousedown", onDoc), 0);
    window.addEventListener("keydown", onKey);
    window.addEventListener("resize", place);
    // capture:true so it also catches scrolls inside the settings pane.
    window.addEventListener("scroll", place, true);
    return () => {
      window.clearTimeout(id);
      window.removeEventListener("mousedown", onDoc);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open, place]);

  const ql = q.trim().toLowerCase();
  const choices = apps
    .filter((a) => !items.includes(a.bundle))
    .filter((a) =>
      !ql ||
      a.name.toLowerCase().includes(ql) ||
      a.bundle.toLowerCase().includes(ql)
    );

  return (
    <div className="applist-block">
      <div className="settings-row-label">{title}</div>
      {/* Picked apps render as a plain stack (no surrounding frame,
          no Empty placeholder — empty just means no rows). The Add
          button sits below them as a regular outline `.clarify-btn`,
          matching "Transcribe now" in the empty-transcript banner. */}
      {items.length > 0 && (
        <div className="applist">
          {items.map((b) => (
            <div className="applist-row" key={b}>
              <img
                className="applist-ico"
                src={appIconSrc(b)}
                alt=""
                aria-hidden
                onError={(e) => { e.currentTarget.style.visibility = "hidden"; }}
              />
              <span className="applist-name" title={b}>{nameFor(b)}</span>
              <button
                type="button"
                className="applist-x"
                disabled={disabled}
                aria-label={t.settings_list_remove}
                title={t.settings_list_remove}
                onClick={() => remove(b)}
              >
                <X size={14} strokeWidth={2.2} />
              </button>
            </div>
          ))}
        </div>
      )}
      <button
        ref={addRef}
        type="button"
        className="clarify-btn bigbtn-full applist-addbtn"
        disabled={disabled}
        onClick={() => setOpen((v) => !v)}
      >
        {t.settings_list_add}
      </button>
      {open && pos && createPortal(
        <div
          ref={popRef}
          className="apick"
          style={{ position: "fixed", top: pos.top, left: pos.left, width: pos.width, zIndex: 9999 }}
        >
          <div className="apick-head">
            <div className="search-field">
              <Search size={14} strokeWidth={2} />
              <input
                autoFocus
                type="search"
                value={q}
                placeholder={t.settings_pick_search}
                onChange={(e) => setQ(e.target.value)}
              />
            </div>
          </div>
          <div className="apick-list">
            {choices.length === 0 && (
              <div className="apick-none">{t.settings_pick_none}</div>
            )}
            {choices.map((a) => (
              <button
                type="button"
                className="apick-item"
                key={a.bundle}
                onClick={() => add(a.bundle)}
              >
                <img
                  className="applist-ico"
                  src={appIconSrc(a.bundle)}
                  alt=""
                  aria-hidden
                  onError={(e) => { e.currentTarget.style.visibility = "hidden"; }}
                />
                <span className="apick-name">{a.name}</span>
                {a.recent && (
                  <span className="apick-recent">{t.settings_pick_recent}</span>
                )}
              </button>
            ))}
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}

// JS KeyboardEvent.code → Carbon virtual key code. Enough for global
// hotkeys (letters, digits, F-keys, a few specials). The backend
// formats the label and checks system-shortcut conflicts from the same
// numbers, so this is the single mapping point.
const JS_TO_CARBON: Record<string, number> = {
  KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5, KeyZ: 6, KeyX: 7,
  KeyC: 8, KeyV: 9, KeyB: 11, KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15,
  KeyY: 16, KeyT: 17, KeyO: 31, KeyU: 32, KeyI: 34, KeyP: 35, KeyL: 37,
  KeyJ: 38, KeyK: 40, KeyN: 45, KeyM: 46,
  Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21, Digit6: 22, Digit5: 23,
  Digit9: 25, Digit7: 26, Digit8: 28, Digit0: 29,
  F1: 122, F2: 120, F3: 99, F4: 118, F5: 96, F6: 97, F7: 98, F8: 100,
  F9: 101, F10: 109, F11: 103, F12: 111,
  Space: 49, Enter: 36, Tab: 48, Escape: 53,
  ArrowLeft: 123, ArrowRight: 124, ArrowDown: 125, ArrowUp: 126,
};

/// Global record-hotkey control. Click to capture, then press the
/// combo. Surfaces a warning when it clashes with a known macOS system
/// shortcut, or when the OS refused the binding (something else owns
/// it). Reuses the existing settings-row layout.
function HotkeyRow({
  label, conflict, ok, disabled, onSet, t,
}: {
  label: string;
  conflict: string | null;
  ok: boolean;
  disabled?: boolean;
  onSet: (code: number, mods: number) => void;
  t: T;
}) {
  const [capturing, setCapturing] = React.useState(false);

  React.useEffect(() => {
    if (!capturing) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (["Meta", "Shift", "Alt", "Control"].includes(e.key)) return;
      if (e.key === "Escape") { setCapturing(false); return; }
      const code = JS_TO_CARBON[e.code];
      if (code == null) return; // unsupported key — keep waiting
      // Carbon mask: cmd 256 | shift 512 | option 2048 | ctrl 4096.
      let mods = 0;
      if (e.metaKey) mods |= 256;
      if (e.shiftKey) mods |= 512;
      if (e.altKey) mods |= 2048;
      if (e.ctrlKey) mods |= 4096;
      // A global hotkey needs a strong modifier (⌘/⌃/⌥) — ⇧-only or a
      // bare key would fire while typing anywhere.
      if ((mods & (256 | 4096 | 2048)) === 0) return;
      setCapturing(false);
      onSet(code, mods);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [capturing, onSet]);

  return (
    <div className="hk-block" aria-label={t.settings_shortcut_label}>
      <div className="settings-row-label">{t.settings_shortcut_label}</div>
      <div className="settings-row-desc">{t.settings_shortcut_desc}</div>
      {conflict && (
        <div className="hk-warn">{t.settings_shortcut_conflict(conflict)}</div>
      )}
      {!conflict && !ok && (
        <div className="hk-warn">{t.settings_shortcut_unbound}</div>
      )}
      <button
        type="button"
        className={"clarify-btn bigbtn-full hk-capbtn" + (capturing ? " capturing" : "")}
        disabled={disabled}
        onClick={() => setCapturing((v) => !v)}
      >
        {capturing ? t.settings_shortcut_press : label}
      </button>
    </div>
  );
}



/// Controlled + persisted. The whole row is the hit target
/// (hover-highlights like a sidebar session; click anywhere toggles).
/// `disabled` is true until settings load, so it can't post a stale
/// default before the real value arrives.
function Toggle({
  label, desc, checked, disabled, onChange,
}: {
  label: string;
  desc: string;
  checked: boolean;
  disabled?: boolean;
  onChange: (value: boolean) => void;
}) {
  const flip = () => { if (!disabled) onChange(!checked); };
  return (
    <div
      className={"settings-row" + (disabled ? " is-loading" : "")}
      role="switch"
      aria-checked={checked}
      aria-disabled={disabled}
      aria-label={label}
      tabIndex={disabled ? -1 : 0}
      onClick={flip}
      onKeyDown={(e) => {
        if (e.key === " " || e.key === "Enter") { e.preventDefault(); flip(); }
      }}
    >
      <div className="settings-row-text">
        <div className="settings-row-label">{label}</div>
        <div className="settings-row-desc">{desc}</div>
      </div>
      <span className={"set-switch" + (checked ? " on" : "")} aria-hidden>
        <span className="set-switch-thumb" />
      </span>
    </div>
  );
}
