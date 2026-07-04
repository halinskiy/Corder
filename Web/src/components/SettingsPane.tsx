import React from "react";
import { createPortal } from "react-dom";
import { X, Search, Loader2 } from "lucide-react";
import {
  getSettings, setSettings, getInstalledApps, appIconSrc,
  setTestTier, openRecordingsFolder, requestScreenRecording,
  type Settings, type InstalledApp, type AudioInputDevice,
} from "../api";
import { type T } from "../i18n";
import { SettingsSelect, type SettingsSelectOption } from "./SettingsSelect";
import { WhisperPrefetchPill } from "./WhisperPrefetchPill";
import { useTheme } from "../theme";

/// Settings page (right column, next to "Recording"). Toggles are
/// REAL: loaded from and persisted to /api/settings. Each change posts
/// only the changed field (debounced ~400 ms); the backend treats an
/// absent field as "unchanged" so a stale tab can't clobber the rest.
/// Audio (mic + system) deliberately has NO toggle — a transcription
/// recorder must capture audio, it's intrinsic; and mic/system stay
/// coupled because the dual-track pipeline assumes both exist. Video
/// IS optional.
/// Per-section scroll offset, remembered across close/reopen. Module-level (not
/// state) because both Settings panes stay MOUNTED (display-toggled) — WebKit
/// drops their scrollTop when the wrapper goes display:none, so we restore it
/// ourselves when the section becomes active again. Survives navigation within a
/// session; a relaunch starts at the top (fine).
const settingsScrollCache: Record<string, number> = {};

export function SettingsPane({
  t,
  section = "general",
  active = true,
}: {
  t: T;
  /// Which slice of Settings to render. The parent surface owns the
  /// tab strip (General / Advanced) so it can sit alongside the
  /// Recording back-chip in MeetingView / Dashboard headers, instead
  /// of duplicating navigation inside this pane.
  section?: "general" | "advanced";
  /// Whether this section is the one currently shown. Both panes stay mounted
  /// (display-toggled), so this is how we know WHEN to restore the saved scroll
  /// offset (on the false→true flip). Defaults true for standalone callers.
  active?: boolean;
}) {
  const [s, setS] = React.useState<Settings | null>(null);
  const scrollRef = React.useRef<HTMLDivElement | null>(null);
  // Restore the remembered scroll offset when this section becomes active, so
  // reopening Settings lands where the user left off instead of at the top.
  // useLayoutEffect → set scrollTop before paint (no visible jump).
  React.useLayoutEffect(() => {
    if (!active) return;
    const el = scrollRef.current;
    if (!el) return;
    const saved = settingsScrollCache[section] ?? 0;
    el.scrollTop = saved;
  }, [active, section]);
  const [apps, setApps] = React.useState<InstalledApp[]>([]);
  const pending = React.useRef<Settings>({});
  const timer = React.useRef<number | null>(null);

  // Clear any pending debounced settings POST on unmount so the timer can't
  // fire a setState on an unmounted component (or flush a stale write).
  React.useEffect(() => () => {
    if (timer.current != null) window.clearTimeout(timer.current);
  }, []);

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

  const loaded = s != null;
  // Every toggle defaults ON until the real value loads (matches the
  // backend default, so no flicker to "off" then back).
  const on = (k: keyof Settings) => (s?.[k] as boolean | undefined) ?? true;

  // General vs Advanced split: the "every-day" settings (notifications,
  // mic, language, app lists, telemetry) live in
  // General. Toggles that flip core capture / pipeline behaviour
  // (video, auto-transcribe / -title / -summary / -chapters) and the
  // API-token reveal live in Advanced. The tab strip itself is owned
  // by the parent surface (MeetingView / Dashboard right-column
  // header), so this pane just renders the selected slice.

  return (
    <div
      className="settings-pane"
      ref={scrollRef}
      onScroll={(e) => { settingsScrollCache[section] = (e.currentTarget as HTMLDivElement).scrollTop; }}
    >
      <div style={{ display: section === "general" ? "contents" : "none" }}>
        {/* Recording equalizer (the floating HUD pill) — default ON. Same
            SoloCard + Toggle shell as Screen video recording, sits directly
            above it. Off suppresses the floating pill for the whole session
            (recording still starts/stops from the popover + in-app button). */}
        <SoloCard>
          <Toggle
            label={t.settings_hud_title ?? "Recording equalizer"}
            desc={t.settings_hud_desc ?? "Show the floating equalizer pill that hovers over your screen while recording."}
            checked={on("hud_enabled")}
            disabled={!loaded}
            onChange={(v) => patch({ hud_enabled: v })}
          />
        </SoloCard>

        {/* Screen video recording — local capture, fine for guests. */}
        <SoloCard>
          <Toggle
            label={t.settings_video}
            desc={t.settings_video_desc}
            checked={on("capture_video")}
            disabled={!loaded}
            onChange={(v) => {
              patch({ capture_video: v });
              // Broadcast immediately so the "Capture your screen too" ghost
              // panel shows/hides in the SAME frame as the toggle.
              try {
                window.dispatchEvent(new CustomEvent("corder-capture-video", { detail: v }));
              } catch { /* dev shell */ }
              // Screen video is now opt-in (default OFF). Enabling it is the
              // moment we ask for Screen Recording — the native bridge fires the
              // macOS permission prompt (or points to System Settings if already
              // asked). No more record-time permission surprise. Also warn that
              // it's a heavy HEVC encode.
              if (v) {
                requestScreenRecording();
                try {
                  window.dispatchEvent(new CustomEvent("corder-toast", {
                    detail: { title: t.settings_video_perf_toast, kind: "success" },
                  }));
                } catch { /* dev shell */ }
              }
            }}
          />
        </SoloCard>

        {/* High-resolution video — appears ONLY for a SIGNED-IN user who has
            screen video ON. Default OFF records a small 720p file to keep
            recordings tiny; ON records at the display's native resolution (up
            to 4K). Sign-in-gated because native-res files are large. */}
        {on("capture_video") && !!s?.user_email && (
          <SoloCard>
            <Toggle
              label={t.settings_video_hires_title ?? "Record in high resolution"}
              desc={t.settings_video_hires_desc ?? "Capture screen video at your display's native resolution (up to 4K). Off keeps recordings small."}
              checked={(s?.capture_video_hires as boolean | undefined) ?? false}
              disabled={!loaded}
              onChange={(v) => patch({ capture_video_hires: v })}
            />
          </SoloCard>
        )}

        <SoloCard>
          <ThemeToggleRow t={t} />
        </SoloCard>

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
            label={t.settings_launch_at_login_title ?? "Launch at login"}
            desc={t.settings_launch_at_login_desc ?? "Open Corder automatically when your Mac starts."}
            checked={(s?.launch_at_login as boolean | undefined) ?? false}
            disabled={!loaded}
            onChange={(v) => patch({ launch_at_login: v })}
          />
        </SoloCard>

        <SoloCard>
          <Toggle
            label={t.settings_telemetry_title ?? "Help improve Corder"}
            desc={t.settings_telemetry_desc ?? "Send anonymous diagnostic counts to the maintainer once a day."}
            checked={(s?.telemetry as boolean | undefined) ?? false}
            disabled={!loaded}
            onChange={(v) => patch({ telemetry: v })}
          />
        </SoloCard>

        {/* Microphone picker — moved here (was at the top of General) so it
            sits directly above the Recordings folder block. "System default"
            stays the first option (the value when mic_device_uid is empty);
            the choice applies to the NEXT recording (no live AVAudioEngine
            hot-swap). */}
        <SoloCard>
          <MicDevicePicker
            devices={s?.audio_input_devices ?? []}
            value={s?.mic_device_uid ?? ""}
            disabled={!loaded}
            onChange={(uid) => patch({ mic_device_uid: uid })}
            t={t}
          />
        </SoloCard>

        {/* Recordings folder — same vertical `.hk-block` shell as the
            Microphone block (label + desc + full-width control), only the
            control is an "Open" button instead of a dropdown, sized identically
            (full-width, backgroundless — matches the dropdown surface). Strict
            component reuse: same shell + the shared `.clarify-btn`. */}
        <SoloCard>
          <div className="hk-block">
            <div className="settings-row-label">{t.settings_recordings_folder_title ?? "Recordings folder"}</div>
            <div className="settings-row-desc recordings-folder-desc">
              {t.settings_recordings_folder_desc ?? "Open the folder with all your recordings in Finder."}
            </div>
            <button
              type="button"
              className="clarify-btn settings-open-btn"
              onClick={() => { openRecordingsFolder().catch(() => {}); }}
            >
              {t.settings_recordings_folder_open ?? "Open"}
            </button>
          </div>
        </SoloCard>

        {/* Subscription flip is an admin/QA-only lever — regular users
            must not be able to change their own tier from Settings. */}
        {s?.is_admin === true && (
          <>
            <div className="settings-divider" />
            <SoloCard>
              <TierTestRow t={t} s={s} patch={patch} />
            </SoloCard>
          </>
        )}
      </div>

      <div style={{ display: section === "advanced" ? "contents" : "none" }}>
        {/* Transcription model picker — ADMIN-ONLY. Normal users have no
            model choice (the hard provider lock pins them to Groq cloud +
            on-device), so the whole block is hidden for non-admins; only
            admins (who can benchmark cloud models) see and use it. */}
        {s?.is_admin === true && (
          <SoloCard>
            <div className="hk-block mic-block">
              <div className="settings-row-label">{t.settings_model_label ?? "Transcription model"}</div>
              <div className="settings-row-desc">{t.settings_model_desc ?? "Which model the next recording is transcribed with."}</div>
              <WhisperPrefetchPill t={t} />
            </div>
          </SoloCard>
        )}

        <SoloCard>
          <Toggle
            label={t.settings_autotranscribe}
            desc={t.settings_autotranscribe_desc}
            checked={on("auto_transcribe")}
            disabled={!loaded}
            onChange={(v) => patch({ auto_transcribe: v })}
          />
        </SoloCard>

        {/* Auto-title / Auto-summary / Auto-chapters are cloud features (need
            sign-in). They live in the Advanced tab, which is hidden wholesale for
            guests (see MeetingView/Dashboard), so no per-row guard needed here. */}
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

        <SoloCard>
          <Toggle
            label={t.settings_auto_chapters_title ?? "Auto-chapters"}
            desc={t.settings_auto_chapters_desc ?? "Split a finished transcript."}
            checked={on("auto_chapters")}
            disabled={!loaded}
            onChange={(v) => patch({ auto_chapters: v })}
          />
        </SoloCard>

        {/* Transcription-language picker removed — transcription is always
            Auto-detect for everyone, so there's nothing to choose. */}

        {/* API access (MCP/REST token) removed from Settings — the
            MCP server / public API isn't a product surface we're
            promoting. the `/mcp-token` endpoint stays server-side
            for a future power-user reintroduction. */}

        <div className="settings-divider" />
        {/* "Always offer to record" (whitelist) block removed per request —
            only the "Never offer to record" (blacklist) list remains. The
            meeting_whitelist field stays in the backend, just not editable. */}
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

// TranscriptionLanguageRow + TRANSCRIPTION_LANGS were removed — transcription
// is always Auto-detect for everyone now, so the picker (and its curated
// spoken-language list) is gone. The backend `transcription_language` field
// stays "" (auto) and the WhisperTranscriber only forces a language when it's
// non-empty, so dropping the UI keeps everyone on auto.

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
  const [pos, setPos] = React.useState<{ top?: number; bottom?: number; left: number; width: number; maxHeight: number } | null>(null);

  const place = React.useCallback(() => {
    const r = addRef.current?.getBoundingClientRect();
    if (!r) return;
    const margin = 16;
    const spaceBelow = window.innerHeight - r.bottom - margin;
    const spaceAbove = r.top - margin;
    // Flip the picker ABOVE the Add button when there isn't enough room below
    // (it sits at the bottom of the settings pane and was overflowing off the
    // window edge, with the results unreachable). Cap the height to whatever
    // side it opens on so the list scrolls instead of clipping.
    if (spaceBelow < 220 && spaceAbove > spaceBelow) {
      setPos({ bottom: window.innerHeight - r.top + 6, left: r.left, width: r.width, maxHeight: spaceAbove });
    } else {
      setPos({ top: r.bottom + 6, left: r.left, width: r.width, maxHeight: spaceBelow });
    }
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
          style={{ position: "fixed", top: pos.top, bottom: pos.bottom, left: pos.left, width: pos.width, maxHeight: pos.maxHeight, zIndex: 9999 }}
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

/// Test-mode tier switch — Upgrade flips `app_metadata.tier=max`,
/// Downgrade flips it back to free. Hits a Worker endpoint that
/// calls Supabase admin with the service role, then refreshes the
/// local session so the change shows up everywhere without a
/// relaunch. INTERIM: removed before real billing ships.
function TierTestRow({
  t, s, patch,
}: {
  t: T;
  s: Settings | null;
  patch: (p: Settings) => void;
}) {
  const tier = (s?.tier ?? "free");
  const paid = tier === "pro" || tier === "max";
  const [busy, setBusy] = React.useState(false);
  // Which plan the user wants to upgrade INTO. Surfaced as a secondary
  // dropdown under the primary CTA, same shape as the model picker
  // (`Whisper Turbo • 1.5 GB`) under Start recording. Hidden once the
  // user IS on a paid tier — Downgrade has only one destination.
  const [pickedPlan, setPickedPlan] = React.useState<"pro" | "max">("max");
  const click = async () => {
    setBusy(true);
    // Floor on how long the spinner stays visible. Avatar / picker /
    // other tier-derived surfaces refresh via their own 1-3 s poll;
    // dropping the spinner the instant the POST returns made the
    // UI feel like nothing happened (Костя: «она мгновенно
    // пропадает, а аватар ещё не успел поменяться»). 2.5 s buys
    // enough headroom for every consumer's next tick.
    const minSpinUntil = Date.now() + 2500;
    try {
      const next = await setTestTier(paid ? "free" : pickedPlan);
      const narrowed: "free" | "pro" | "max" =
        next === "max" || next === "pro" ? next : "free";
      patch({ tier: narrowed });
      try {
        const fresh = await getSettings();
        const reconciled: "free" | "pro" | "max" =
          fresh.tier === "max" || fresh.tier === "pro" ? fresh.tier : "free";
        patch({ tier: reconciled });
      } catch { /* next poll catches up */ }
    } catch {
      // Silent fail keeps the row visible for retry.
    }
    const remaining = Math.max(0, minSpinUntil - Date.now());
    if (remaining > 0) {
      await new Promise((r) => window.setTimeout(r, remaining));
    }
    setBusy(false);
  };
  const planLabel = pickedPlan === "max"
    ? (t.settings_tier_plan_max ?? "Max")
    : (t.settings_tier_plan_pro ?? "Pro");
  return (
    <div className={"hk-block mic-block" + (s == null ? " is-loading" : "")} aria-label={paid ? "Downgrade" : "Upgrade"}>
      <div className="settings-row-label">
        {paid
          ? (t.settings_tier_downgrade_label ?? "Downgrade")
          : (t.settings_tier_upgrade_label ?? "Upgrade")}
      </div>
      <div className="settings-row-desc">
        {paid
          ? (t.settings_tier_downgrade_desc ?? "Free Features")
          : (
              pickedPlan === "max"
                ? (t.settings_tier_upgrade_desc_max ?? "Max Features")
                : (t.settings_tier_upgrade_desc_pro ?? "Pro Features")
            )}
      </div>
      <button
        type="button"
        className={"clarify-btn bigbtn-full tier-flip-btn " + (paid ? "danger" : "accent")}
        style={{ marginTop: 8 }}
        disabled={busy || s == null}
        aria-busy={busy}
        onClick={click}
      >
        {busy ? (
          <Loader2
            size={18}
            strokeWidth={2.5}
            className="tier-flip-spin"
            aria-hidden
          />
        ) : (
          <span>
            {paid
              ? (t.settings_tier_downgrade_btn ?? "Downgrade")
              : (t.settings_tier_upgrade_btn ?? "Upgrade")}
          </span>
        )}
      </button>
      {!paid && (
        <div style={{ marginTop: 8 }}>
          <SettingsSelect<"pro" | "max">
            value={pickedPlan}
            options={[
              { value: "pro", label: t.settings_tier_plan_pro ?? "Pro" },
              { value: "max", label: t.settings_tier_plan_max ?? "Max" },
            ]}
            onChange={setPickedPlan}
            ariaLabel={planLabel}
            disabled={busy}
          />
        </div>
      )}
    </div>
  );
}

/// Theme block — same shell as `MicDevicePicker` (label + desc +
/// SettingsSelect). Three options: System (follow macOS),
/// Light, Dark. The view-transition radial wipe still fires; the
/// origin is the centre of the SettingsSelect trigger pill (we
/// stash a ref on it so the option-click handler can grab a real
/// rect even though the option lives in a portal).
function ThemeToggleRow({ t }: { t: T }) {
  const { isDark, setMode } = useTheme();
  const rowRef = React.useRef<HTMLDivElement | null>(null);
  // A plain switch like "System notifications": ON = dark, OFF = light.
  // The view-transition radial wipe still fires; origin is the row centre.
  return (
    <div ref={rowRef}>
      <Toggle
        label={t.settings_theme_enable_dark ?? "Dark theme"}
        desc={t.settings_theme_enable_dark_desc ?? "Dark interface."}
        checked={isDark}
        onChange={(v) => {
          const r = rowRef.current?.getBoundingClientRect();
          const origin = r ? { x: r.left + r.width / 2, y: r.top + r.height / 2 } : undefined;
          setMode(v ? "dark" : "light", origin);
        }}
      />
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
