import React from "react";
import { createPortal } from "react-dom";
import { X, Search } from "lucide-react";
import {
  getSettings, setSettings, getInstalledApps, appIconSrc,
  downloadWhisperLocal,
  type Settings, type InstalledApp, type AudioInputDevice,
  type WhisperLocalModel,
} from "../api";
import { LANGS, type Lang, type T } from "../i18n";
import { SettingsSelect, type SettingsSelectOption } from "./SettingsSelect";

/// Settings page (right column, next to "Recording"). Toggles are
/// REAL: loaded from and persisted to /api/settings. Each change posts
/// only the changed field (debounced ~400 ms); the backend treats an
/// absent field as "unchanged" so a stale tab can't clobber the rest.
/// Audio (mic + system) deliberately has NO toggle — a transcription
/// recorder must capture audio, it's intrinsic; and mic/system stay
/// coupled because the dual-track pipeline assumes both exist. Video
/// IS optional.
export function SettingsPane({
  t,
  lang,
  onLangChange,
}: {
  t: T;
  /// Current UI language. Surfaced here so the Language block can
  /// render its own SettingsSelect inline — same affordance as
  /// Microphone / Transcription model. Parent owns the persisted
  /// state (lifted into App-level so MainHeader / ProfileMenu /
  /// Settings stay in sync).
  lang: Lang;
  onLangChange: (next: Lang) => void;
}) {
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

  // Poll /api/settings every second while at least one Whisper Local
  // model is in flight, so the inline DownloadButton's progress fill
  // updates without the user touching anything. As soon as no model
  // has a non-null `progress` we stop — the rest of Settings is
  // user-edited only, no polling needed.
  const isDownloading = !!s?.whisper_local_models?.some(
    (m) => typeof m.progress === "number");
  React.useEffect(() => {
    if (!isDownloading) return;
    let alive = true;
    const tick = () => {
      getSettings().then((v) => { if (alive) setS(v); }).catch(() => {});
    };
    const id = window.setInterval(tick, 1000);
    return () => { alive = false; window.clearInterval(id); };
  }, [isDownloading]);

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

      {/* ASR provider override. Same `.hk-block` shell as MicDevicePicker
          so the two "single select with explainer" rows read identically.
          Free tier sees a Pro-locked picker (Auto + Local always usable,
          cloud options visually dimmed + ignored on click with a toast);
          Pro/Max sees every option enabled. */}
      <SoloCard>
        <TranscriptionProviderPicker
          value={s?.transcription_provider ?? "auto"}
          tier={s?.tier ?? "free"}
          variant={s?.whisper_local_variant}
          models={s?.whisper_local_models ?? []}
          appleSilicon={s?.apple_silicon ?? true}
          disabled={!loaded}
          onProviderChange={(v) => patch({ transcription_provider: v })}
          onVariantChange={(v) => patch({ whisper_local_variant: v })}
          onSettingsReplace={(next) => setS(next)}
          t={t}
        />
      </SoloCard>

      {/* Language picker. Same `.hk-block` shell as Microphone /
          Transcription model — three "single select with explainer"
          rows in a row read identically. The block deliberately uses
          our SettingsSelect (NO search field) instead of the full
          LangPicker (with flags + search): search makes sense for the
          20-locale popover that lives in the header, but in a
          settings row a chevron + a short scrollable list reads
          consistent with Microphone and Transcription model. */}
      <SoloCard>
        <LanguageBlock lang={lang} onChange={onLangChange} t={t} />
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

/// Microphone input device dropdown. Uses our portal-popover
/// `SettingsSelect` so the dropdown reads as part of the Corder UI
/// (matches the `.profile-pop` family) instead of the dark native
/// macOS context menu. The first option is the explicit "System
/// default" fall-back (empty UID), and the device flagged
/// `is_system_default` gets a trailing meta so the user can see
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
  const options: SettingsSelectOption<string>[] = [
    { value: "", label: sysLabel },
    ...devices.map<SettingsSelectOption<string>>((d) => ({
      value: d.uid,
      label: d.name,
      meta: d.is_system_default ? "system default" : undefined,
    })),
  ];
  return (
    <div className={"hk-block mic-block" + (disabled ? " is-loading" : "")}
         aria-label={t.settings_mic_device ?? "Microphone"}>
      <div className="settings-row-label">{t.settings_mic_device ?? "Microphone"}</div>
      <div className="settings-row-desc">
        {t.settings_mic_device_desc
          ?? "Pick which input device records your voice."}
      </div>
      <SettingsSelect
        value={value}
        options={options}
        disabled={disabled || noDevices}
        onChange={onChange}
        ariaLabel={t.settings_mic_device ?? "Microphone"}
      />
      {noDevices && (
        <div className="settings-row-desc" style={{ opacity: 0.75, marginTop: 8 }}>
          {t.settings_mic_device_empty ?? "No input devices found"}
        </div>
      )}
    </div>
  );
}

/// ASR provider override picker. Visually identical to `MicDevicePicker`
/// (`.hk-block`/`.mic-block` shell, label + description + full-width
/// native `<select>`). Three concrete providers plus an `auto` entry
/// that clears the override and lets the server pick by tier. The
/// Free tier sees the cloud options listed but disabled (Pro+ suffix)
/// so the upgrade path is discoverable — clicking one shows a toast
/// instead of switching. Apple Silicon is detected server-side; on
/// Intel a small warning line surfaces because WhisperKit's Core ML
/// kernels are arm64-only and the pipeline silently falls back to
/// the cloud at runtime.
/// The picker now has TWO axes: cloud-vs-local provider + (for local)
/// which Whisper variant. We flatten them into ONE SettingsSelect so
/// the row reads as a single choice — easier than nested menus. The
/// list is:
///   • Auto (recommended) — clears the override
///   • Whisper {Turbo | Small | Base | Tiny} — pins `.whisperLocal`
///     AND a variant; meta shows `· 75 MB` / `· ready` per model
///   • Whisper Cloud (OpenAI) — pins `.whisper`
///   • Gemini 2.5 Flash — pins `.gemini`
/// Free tier sees the cloud rows disabled (locked toast on click);
/// every Whisper Local row stays selectable so the user can pick a
/// model size to download even before transcribing.
type PickerValue = "auto" | "gemini" | "whisper" | `whisperLocal:${string}`;

function TranscriptionProviderPicker({
  value, tier, variant, models, appleSilicon, disabled,
  onProviderChange, onVariantChange, onSettingsReplace, t,
}: {
  value: "auto" | "gemini" | "whisper" | "whisperLocal";
  tier: "free" | "pro" | "max";
  variant?: string;
  models: WhisperLocalModel[];
  appleSilicon: boolean;
  disabled?: boolean;
  onProviderChange: (v: "auto" | "gemini" | "whisper" | "whisperLocal") => void;
  onVariantChange: (v: string) => void;
  /// Replaces the parent's Settings snapshot after a /api/whisper-local/download
  /// call (the response carries a fresh state). Used so a `Download`
  /// click flips the inline button into "downloading…" without
  /// waiting for the next poll tick.
  onSettingsReplace: (next: Settings) => void;
  t: T;
}) {
  const free = tier === "free";
  const desc = free
    ? (t.settings_asr_desc_free ??
       "Local Whisper on your Mac: free, offline. Pro and Max unlock cloud models.")
    : (t.settings_asr_desc_paid ??
       "You can pin a different one.");
  const lockedToast = t.settings_asr_locked_toast ?? "Upgrade to Pro to use cloud models";
  const sufReady = t.settings_asr_suffix_ready ?? "ready";
  const sufPro = t.settings_asr_suffix_pro ?? "Pro+";

  // Compose the flat option list. Whisper Local variants come from
  // the server (`models`) so size labels and ready-state stay
  // authoritative across launches and partial downloads.
  const options: SettingsSelectOption<PickerValue>[] = [
    { value: "auto", label: t.settings_asr_auto ?? "Auto (recommended)" },
    ...models.map<SettingsSelectOption<PickerValue>>((m) => ({
      value: `whisperLocal:${m.id}` as PickerValue,
      label: m.label,
      meta: m.ready ? sufReady : m.size_label,
    })),
    {
      value: "whisper",
      label: t.settings_asr_cloud_whisper ?? "Whisper Cloud (OpenAI)",
      meta: free ? sufPro : undefined,
      disabled: free,
    },
    {
      value: "gemini",
      label: t.settings_asr_gemini ?? "Gemini 2.5 Flash",
      meta: free ? sufPro : undefined,
      disabled: free,
    },
  ];

  // Reconstruct the picker's current value from the two pieces of
  // server state. When provider is whisperLocal we glue the variant
  // id; otherwise it's just the provider name.
  const current: PickerValue = value === "whisperLocal"
    ? (`whisperLocal:${variant ?? (models[0]?.id ?? "openai_whisper-large-v3_turbo")}` as PickerValue)
    : value;

  const onChange = (v: PickerValue) => {
    if (v.startsWith("whisperLocal:")) {
      const id = v.slice("whisperLocal:".length);
      onProviderChange("whisperLocal");
      onVariantChange(id);
      return;
    }
    onProviderChange(v as "auto" | "gemini" | "whisper");
  };
  const onLocked = (_: PickerValue) => {
    try {
      window.dispatchEvent(new CustomEvent("corder-toast", { detail: { text: lockedToast } }));
    } catch { /* no-op */ }
  };

  // The model below the picker — the one that gets the Download
  // button. Always reflects the currently picked variant when the
  // provider is whisperLocal; nothing renders otherwise.
  const activeModel: WhisperLocalModel | undefined = value === "whisperLocal"
    ? models.find((m) => m.id === (variant ?? models[0]?.id))
    : undefined;

  return (
    <div className={"hk-block mic-block" + (disabled ? " is-loading" : "")}
         aria-label={t.settings_asr_label ?? "Transcription model"}>
      <div className="settings-row-label">
        {t.settings_asr_label ?? "Transcription model"}
      </div>
      <div className="settings-row-desc">{desc}</div>
      {!appleSilicon && (
        <div className="settings-row-desc" style={{ opacity: 0.75 }}>
          {t.settings_asr_intel_warn ??
            "Local Whisper isn't available on Intel Macs and transcription will fall back to the cloud."}
        </div>
      )}
      <SettingsSelect<PickerValue>
        value={current}
        options={options}
        disabled={disabled}
        onChange={onChange}
        onLockedClick={onLocked}
        ariaLabel={t.settings_asr_label ?? "Transcription model"}
      />
      {activeModel && (
        <WhisperLocalDownloadButton
          model={activeModel}
          onStart={async () => {
            try {
              const next = await downloadWhisperLocal(activeModel.id);
              onSettingsReplace(next);
            } catch { /* polling will surface it */ }
          }}
          t={t}
        />
      )}
    </div>
  );
}

/// Three-state CTA under the Transcription model picker:
///   idle      → primary green "Download model · 1.5 GB"
///   loading   → secondary outline pill with a green fill that grows
///               left → right as `progress` advances; label shows
///               "Downloading… 42%"
///   ready     → nothing rendered (the picker meta already shows
///               "ready"; a second CTA would be visual noise)
/// Single component because the geometry stays IDENTICAL across the
/// two visible states (same height/width/font); only the fill + label
/// flip. Same trick as a typical progress-button on the web.
function WhisperLocalDownloadButton({
  model, onStart, t,
}: {
  model: WhisperLocalModel;
  onStart: () => void | Promise<void>;
  t: T;
}) {
  if (model.ready) return null;
  const downloading = typeof model.progress === "number";
  const pct = downloading ? Math.max(0, Math.min(100, Math.round((model.progress ?? 0) * 100))) : 0;
  const label = downloading
    ? `${t.settings_asr_downloading ?? "Downloading…"} ${pct}%`
    : `${t.settings_asr_download_cta ?? "Download model"} · ${model.size_label}`;
  // Idle reuses `.clarify-btn.accent` so the visuals match
  // Dashboard's "Start recording" — same accent fill, same white
  // label, same hover. Loading overlays a fill + a second label
  // clipped to the bar so readability stays clean across both
  // halves of the progress.
  const cls = "clarify-btn accent wl-download-btn"
    + (downloading ? " is-loading" : "");
  return (
    <button
      type="button"
      className={cls}
      style={downloading ? ({ ["--wl-progress" as string]: `${pct}%` }) : undefined}
      onClick={downloading ? undefined : () => onStart()}
      disabled={downloading}
      aria-label={label}
    >
      {downloading && <span className="wl-download-btn-fill" aria-hidden />}
      <span className="wl-download-btn-label">{label}</span>
      {downloading && (
        <span className="wl-download-btn-label-fill" aria-hidden>{label}</span>
      )}
    </button>
  );
}

/// Language picker block. Same `.hk-block` shell as Microphone /
/// Transcription model, so all three "single select with explainer"
/// rows in Settings read identically. Uses `SettingsSelect` rather
/// than the full `LangPicker` (the latter carries SVG flags + a
/// search input that only earn their keep in the toolbar popover).
function LanguageBlock({
  lang, onChange, t,
}: {
  lang: Lang;
  onChange: (next: Lang) => void;
  t: T;
}) {
  const options: SettingsSelectOption<Lang>[] = LANGS.map((l) => ({
    value: l.code,
    label: l.native,
    meta: l.name !== l.native ? l.name : undefined,
  }));
  return (
    <div className="hk-block mic-block" aria-label={t.profile_language ?? "Language"}>
      <div className="settings-row-label">{t.profile_language ?? "Language"}</div>
      <div className="settings-row-desc">
        {t.settings_language_desc ?? "Pick the interface language."}
      </div>
      <SettingsSelect<Lang>
        value={lang}
        options={options}
        onChange={onChange}
        ariaLabel={t.profile_language ?? "Language"}
      />
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
