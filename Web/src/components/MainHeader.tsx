import React from "react";
import { Archive as ArchiveIcon, Settings as SettingsIcon, Bug, Plus, Square } from "lucide-react";

/// Filled (solid) twins of the Lucide outline icons used in the
/// toolbar's active state. Lucide ships only outlines; layering a
/// `fill="currentColor"` over the outline produced a busy "double
/// stroke" look (the inner outline strokes painted on top of the
/// fill), so the active variants are inline solid copies of the same
/// glyph silhouette, Heroicons Solid v2 paths re-traced to the
/// Lucide 24×24 grid. No extra dependency; only used in two places.
function SettingsFilled({ size = 16 }: { size?: number }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden
    >
      <path fillRule="evenodd" clipRule="evenodd" d="M11.078 2.25c-.917 0-1.699.663-1.85 1.567L9.05 4.889c-.02.12-.115.26-.297.348a7.493 7.493 0 0 0-.986.57c-.166.115-.334.126-.45.083L6.3 5.508a1.875 1.875 0 0 0-2.282.819l-.922 1.597a1.875 1.875 0 0 0 .432 2.385l.84.692c.095.078.17.229.154.43a7.598 7.598 0 0 0 0 1.139c.015.2-.059.352-.153.43l-.841.692a1.875 1.875 0 0 0-.432 2.385l.922 1.597a1.875 1.875 0 0 0 2.282.818l1.019-.382c.115-.043.283-.031.45.082.312.214.641.405.985.57.182.088.277.228.297.35l.178 1.071c.151.904.933 1.567 1.85 1.567h1.844c.916 0 1.699-.663 1.85-1.567l.178-1.072c.02-.12.114-.26.297-.349.344-.165.673-.356.985-.57.167-.114.335-.125.45-.082l1.02.382a1.875 1.875 0 0 0 2.28-.819l.923-1.597a1.875 1.875 0 0 0-.432-2.385l-.84-.692c-.095-.078-.17-.229-.154-.43a7.614 7.614 0 0 0 0-1.139c-.016-.2.059-.352.153-.43l.84-.692c.708-.582.891-1.59.433-2.385l-.922-1.597a1.875 1.875 0 0 0-2.282-.818l-1.02.382c-.114.043-.282.031-.449-.083a7.49 7.49 0 0 0-.985-.57c-.183-.087-.277-.227-.297-.348l-.179-1.072a1.875 1.875 0 0 0-1.85-1.567h-1.843ZM12 15.75a3.75 3.75 0 1 0 0-7.5 3.75 3.75 0 0 0 0 7.5Z" />
    </svg>
  );
}
function ArchiveFilled({ size = 16 }: { size?: number }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden
    >
      <path d="M3.375 3C2.339 3 1.5 3.84 1.5 4.875v.75c0 1.036.84 1.875 1.875 1.875h17.25c1.035 0 1.875-.84 1.875-1.875v-.75C22.5 3.839 21.66 3 20.625 3H3.375Z" />
      <path fillRule="evenodd" clipRule="evenodd" d="M3.087 9l.54 9.176A3 3 0 0 0 6.62 21h10.757a3 3 0 0 0 2.995-2.824L20.913 9H3.087Zm6.163 3.75A.75.75 0 0 1 10 12h4a.75.75 0 0 1 0 1.5h-4a.75.75 0 0 1-.75-.75Z" />
    </svg>
  );
}
import { UpdatePill } from "./UpdatePill";
import { ProfileMenu } from "./ProfileMenu";
import { Tooltip } from "./Tooltip";
import { submitLogs, hasBugEvents, getAccountUsage, openWelcome, startRecordingNow, stopRecordingNow, getRecordingState } from "../api";
import type { T } from "../i18n";

/// Single source of truth for the main pane's top strip, breadcrumb
/// on the left, global controls on the right. Used by both the
/// Dashboard (`activeId === null`) and MeetingView slots so the
/// header is pixel-identical (same height, same buttons, same order)
/// regardless of what's in the body below.
///
/// The breadcrumb is passed as JSX so each caller can render its own
/// (Dashboard: just `Dashboard` as the current crumb; MeetingView:
/// `Recordings > [click-to-rename title]`). Toolbar items stay shared:
/// Update pill, theme switch, language switch, Archive opener, Profile.
export function MainHeader({
  breadcrumb,
  onOpenArchive,
  archiveOpen,
  archiveEmpty,
  onOpenSettings,
  settingsOpen,
  onOpenDashboard,
  onToast,
  hideRecordButton,
  t,
}: {
  breadcrumb: React.ReactNode;
  onOpenArchive: () => void;
  /// True when the Archive surface is currently shown, the Archive
  /// toolbar button lights up as `.active` and a second click leaves
  /// Archive (the button itself is the toggle, replaces the old
  /// "< Library" back affordance).
  archiveOpen?: boolean;
  /// True when the user's archive is empty, disables the Archive
  /// toolbar button so it can't open a panel with nothing in it.
  archiveEmpty?: boolean;
  /// Fires when the user clicks "Settings" in the profile popover.
  /// Parent decides what "open Settings" means in the current context
  /// (right-pane tab in MeetingView, right-section toggle on Dashboard).
  onOpenSettings: () => void;
  /// True when the Right-pane is currently showing Settings. Lights
  /// up the Settings toolbar icon as `.active`, mirroring how
  /// `archiveOpen` lights up the Archive icon.
  settingsOpen?: boolean;
  /// Fires when the user clicks "Dashboard" in the profile popover
  /// always returns to the landing surface (parent clears activeId).
  onOpenDashboard: () => void;
  onToast: (
    msg: string,
    kind?: "success" | "error",
    opts?: { action?: { label: string; onClick: () => void }; durationMs?: number; countdown?: boolean }
  ) => void;
  /// Hide the record "+" button, used on the empty Welcome, which has its
  /// own Start CTA, so the toolbar "+" is redundant there. Defaults to shown.
  hideRecordButton?: boolean;
  t: T;
}) {
  return (
    <div className="main-header">
      {!hideRecordButton && <HeaderRecordButton onToast={onToast} t={t} />}
      <div className="breadcrumb">{breadcrumb}</div>
      <div className="spacer" />
      <div className="toolbar">
        <UpdatePill t={t} onToast={onToast} />
        <GuestSessionCounter />
        <SubmitLogsButton t={t} onToast={onToast} />
        {/* ThemeSwitch moved into Settings → General as a real toggle
            row; the toolbar slot was visual noise next to controls the
            user touches once a year. */}
        {/* Settings now sits in the toolbar where the LangPicker used
            to live, the language switcher moved into the profile
            popover (rare action, not worth a top-bar slot). The two
            shortcuts share the same icon-button shell. */}
        <Tooltip label={t.profile_account}>
          <button
            className={"toolbar-icon-btn" + (settingsOpen ? " active" : "")}
            onClick={onOpenSettings}
            aria-label={t.profile_account}
            aria-pressed={settingsOpen}
          >
            {settingsOpen ? <SettingsFilled size={16} /> : <SettingsIcon size={16} strokeWidth={2} />}
          </button>
        </Tooltip>
        <Tooltip
          label={archiveEmpty ? (t.archive_empty_tooltip ?? "Archive is empty")
                              : t.archive_open_title}>
          <button
            className={"toolbar-icon-btn" + (archiveOpen ? " active" : "")}
            onClick={onOpenArchive}
            aria-label={t.btn_archive}
            aria-pressed={archiveOpen}
            disabled={archiveEmpty && !archiveOpen}
          >
            {archiveOpen ? <ArchiveFilled size={16} /> : <ArchiveIcon size={16} strokeWidth={2} />}
          </button>
        </Tooltip>
        <span className="toolbar-sep" />
        <ProfileMenu
          onToast={onToast}
          onOpenSettings={onOpenSettings}
          onOpenDashboard={onOpenDashboard}
          t={t}
        />
      </div>
    </div>
  );
}

/// Leftmost header action: a single button that TOGGLES recording.
/// Idle → green circle with a white "+", click starts a recording (same
/// /api/recording/start gate as the menu-bar Start: guest cap, permissions).
/// Recording → red circle with a white stop square, click stops it. Mirrors
/// the menu-bar control inside the app (a tester noted the only way to start
/// a meeting was the menu bar). Self-polls recording state (like the other
/// header widgets) and flips optimistically on click for instant feedback.
function HeaderRecordButton({
  onToast,
  t,
}: {
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}) {
  const [recording, setRecording] = React.useState(false);
  React.useEffect(() => {
    let alive = true;
    const tick = () => {
      getRecordingState().then((s) => { if (alive) setRecording(!!s.active); }).catch(() => {});
    };
    tick();
    const id = window.setInterval(tick, 1500);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  const onClick = async () => {
    if (recording) {
      setRecording(false); // optimistic
      try { await stopRecordingNow(); }
      catch { setRecording(true); onToast(t.toast_settings_failed ?? "Couldn't stop recording.", "error"); }
    } else {
      setRecording(true); // optimistic
      try {
        await startRecordingNow();
        // Tell the shell to jump straight into the freshly-started session
        // (main.tsx selects it), so the user lands on the live recording
        // immediately instead of waiting for the next state poll.
        window.dispatchEvent(new CustomEvent("corder-recording-started"));
      }
      catch { setRecording(false); onToast(t.toast_settings_failed ?? "Couldn't start recording.", "error"); }
    }
  };

  const label = recording
    ? (t.header_stop_recording ?? "Stop recording")
    : (t.header_new_recording ?? "New recording");
  return (
    <Tooltip label={label}>
      <button
        type="button"
        className={"toolbar-icon-btn header-new-btn" + (recording ? " is-recording" : "")}
        onClick={onClick}
        aria-label={label}
      >
        {recording
          ? <Square size={11} strokeWidth={2} fill="currentColor" />
          : <Plus size={16} strokeWidth={2.5} />}
      </button>
    </Tooltip>
  );
}

/// "N left" badge sitting left of the report button. Shown ONLY to a
/// signed-out (guest) user: guests may hold up to a fixed number of
/// recordings at once, and this is the live remaining count. At zero,
/// pressing Start anywhere (menu bar or in-app) offers sign-in
/// instead of recording; deleting a recording frees a slot. Signed-in
/// users are unlimited, so the badge renders nothing for them. Clicking
/// it opens the in-app sign-in modal. Self-contained + polled so the
/// header doesn't have to thread account state down from the parent.
function GuestSessionCounter() {
  const [left, setLeft] = React.useState<number | null>(null);
  const [isGuest, setIsGuest] = React.useState(false);
  React.useEffect(() => {
    let alive = true;
    const tick = () => {
      getAccountUsage().then((u) => {
        if (!alive) return;
        if (u && u.is_guest) { setIsGuest(true); setLeft(u.sessions_left); }
        else { setIsGuest(false); setLeft(null); }
      }).catch(() => {});
    };
    tick();
    // Poll often enough that creating / deleting a recording updates the
    // count within a couple seconds without a manual refresh.
    const id = window.setInterval(tick, 4000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  if (!isGuest || left == null) return null;
  // Always the neutral pill, never the green "is-low" treatment when running
  // out (Kostya: "1 left" should look like "5 left", white, not green).
  return (
    <Tooltip label="Sign in to unlock more">
      <button
        type="button"
        className="guest-quota"
        onClick={() => { openWelcome().catch(() => {}); }}
        aria-label="Sign in to unlock more"
      >
        {left} left
      </button>
    </Tooltip>
  );
}

/// Sends the tail of `/tmp/corder.log` to the maintainer via the
/// Cloudflare Worker (→ Resend email). Replaces "ask the user to run
/// a curl in the terminal", which nobody actually does. Disabled
/// while a previous submit is in flight so a double-click doesn't
/// fire two emails.
function SubmitLogsButton({
  t,
  onToast,
}: {
  t: T;
  onToast: (
    msg: string,
    kind?: "success" | "error",
    opts?: { action?: { label: string; onClick: () => void }; durationMs?: number; countdown?: boolean }
  ) => void;
}) {
  // Rate-limit to 1 report per hour. A user mashing the Bug icon
  // used to fill the maintainer's inbox in seconds; the localStorage
  // timestamp is enforced here client-side. A second guard lives on
  // the Worker (TODO) so this can't be bypassed by a fresh install.
  const SUBMIT_COOLDOWN_MS = 60 * 60 * 1000;
  const LAST_SUBMIT_KEY = "corder.lastSubmitLogsAt";
  const readCooldownEnd = (): number => {
    try {
      const lastAt = parseInt(localStorage.getItem(LAST_SUBMIT_KEY) ?? "0", 10) || 0;
      return lastAt + SUBMIT_COOLDOWN_MS;
    } catch { return 0; }
  };
  // 10-second send-with-undo, same UX as the archive flow. The
  // actual `submitLogs()` POST fires when the countdown elapses,
  // not when the button is clicked, so an accidental click never
  // ships the log. Undo cancels the timer and nothing leaves the Mac.
  const pendingRef = React.useRef<number | null>(null);
  // `now` is the only state driving visibility, bumped every 30 s and
  // on every send/undo. The button stays unmounted whenever
  //   `now < cooldownEnd` (post-send rate-limit) OR a send is in flight
  //   (`pendingRef !== null`).
  const [now, setNow] = React.useState(() => Date.now());
  const [pending, setPending] = React.useState(false);
  // Whether the current log has any bug-flagged event lines. We poll
  // the backend so the button only appears when there's actually
  // something worth shipping, fewer noise emails for the maintainer.
  const [hasEvents, setHasEvents] = React.useState(false);
  React.useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(id);
  }, []);
  React.useEffect(() => {
    let alive = true;
    const tick = () => {
      hasBugEvents().then((v) => { if (alive) setHasEvents(v); }).catch(() => {});
    };
    tick();
    const id = window.setInterval(tick, 60_000);
    return () => { alive = false; window.clearInterval(id); };
  }, []);

  const cooldownEnd = readCooldownEnd();
  const inCooldown = now < cooldownEnd;
  // The button DISAPPEARS the instant the user clicks it: while the
  // 10-s undo window is open, while the POST is in flight, and for the
  // full 60-min cooldown after a successful send. `hasEvents` is now
  // true whenever there's ANY log to send (the backend stopped gating
  // on error lines), a transcription-QUALITY bug throws no error, so
  // gating here hid the report button exactly when we needed it.
  if (pending || inCooldown || !hasEvents) return null;

  const onClick = async () => {
    // Send immediately, no 10s countdown / Undo window. The button unmounts
    // while `pending` (see the gate above) and pendingRef guards a double-fire.
    if (pendingRef.current !== null) return;
    pendingRef.current = 1;
    setPending(true);
    try {
      await submitLogs();
      try { localStorage.setItem(LAST_SUBMIT_KEY, String(Date.now())); } catch {}
      onToast(t.submit_logs_success ?? "Logs sent. Thanks!", "success");
    } catch {
      // Failed send still costs a cooldown so a flapping endpoint can't be
      // hammered. Clearing the localStorage entry lets the user retry sooner.
      try { localStorage.setItem(LAST_SUBMIT_KEY, String(Date.now())); } catch {}
      onToast(t.submit_logs_failed ?? "Couldn't send the log. Try again.", "error");
    } finally {
      // Re-render to flip from `pending` to `inCooldown` (button stays hidden
      // only the gating reason changes).
      pendingRef.current = null;
      setPending(false);
      setNow(Date.now());
    }
  };
  return (
    <Tooltip label={t.submit_logs_title ?? "Send a bug report"}>
      <button
        className="toolbar-icon-btn"
        onClick={onClick}
        aria-label={t.submit_logs_title ?? "Send a bug report"}
      >
        <Bug size={16} strokeWidth={2} />
      </button>
    </Tooltip>
  );
}
