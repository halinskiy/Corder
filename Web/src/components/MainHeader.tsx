import React from "react";
import { Moon, Archive as ArchiveIcon, Settings as SettingsIcon, Bug } from "lucide-react";
import { UpdatePill } from "./UpdatePill";
import { ProfileMenu } from "./ProfileMenu";
import { Tooltip } from "./Tooltip";
import { useTheme } from "../theme";
import { submitLogs } from "../api";
import type { T } from "../i18n";

/// Single source of truth for the main pane's top strip — breadcrumb
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
  t,
}: {
  breadcrumb: React.ReactNode;
  onOpenArchive: () => void;
  /// True when the Archive surface is currently shown — the Archive
  /// toolbar button lights up as `.active` and a second click leaves
  /// Archive (the button itself is the toggle, replaces the old
  /// "< Library" back affordance).
  archiveOpen?: boolean;
  /// True when the user's archive is empty — disables the Archive
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
  /// Fires when the user clicks "Dashboard" in the profile popover —
  /// always returns to the landing surface (parent clears activeId).
  onOpenDashboard: () => void;
  onToast: (
    msg: string,
    kind?: "success" | "error",
    opts?: { action?: { label: string; onClick: () => void }; durationMs?: number; countdown?: boolean }
  ) => void;
  t: T;
}) {
  return (
    <div className="main-header">
      <div className="breadcrumb">{breadcrumb}</div>
      <div className="spacer" />
      <div className="toolbar">
        <UpdatePill t={t} onToast={onToast} />
        <SubmitLogsButton t={t} onToast={onToast} />
        <ThemeSwitch t={t} />
        {/* Settings now sits in the toolbar where the LangPicker used
            to live — the language switcher moved into the profile
            popover (rare action, not worth a top-bar slot). The two
            shortcuts share the same icon-button shell. */}
        <Tooltip label={t.profile_account}>
          <button
            className={"toolbar-icon-btn" + (settingsOpen ? " active" : "")}
            onClick={onOpenSettings}
            aria-label={t.profile_account}
            aria-pressed={settingsOpen}
          >
            <SettingsIcon size={16} strokeWidth={2} />
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
            <ArchiveIcon size={16} strokeWidth={2} />
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

function ThemeSwitch({ t }: { t: T }) {
  const { toggle } = useTheme();
  return (
    <Tooltip label={t.btn_theme_title}>
      <button
        className="toolbar-icon-btn"
        onClick={toggle}
        aria-label={t.btn_theme_title}
      >
        <Moon size={16} strokeWidth={2} />
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
  const [busy, setBusy] = React.useState(false);
  // 10-second send-with-undo, same UX as the archive flow. The
  // actual `submitLogs()` POST fires when the countdown elapses,
  // not when the button is clicked — so an accidental click never
  // ships the log. Undo cancels the timer and nothing leaves the Mac.
  const pendingRef = React.useRef<number | null>(null);
  const onClick = () => {
    if (busy || pendingRef.current !== null) return;
    const cancel = () => {
      if (pendingRef.current !== null) {
        window.clearTimeout(pendingRef.current);
        pendingRef.current = null;
      }
      setBusy(false);
    };
    setBusy(true);
    pendingRef.current = window.setTimeout(async () => {
      pendingRef.current = null;
      try {
        await submitLogs();
        onToast(t.submit_logs_success ?? "Logs sent. Thanks!", "success");
      } catch {
        onToast(t.submit_logs_failed ?? "Couldn't send the log. Try again.", "error");
      } finally {
        setBusy(false);
      }
    }, 10_000);
    onToast(
      t.submit_logs_pending ?? "Sending log in 10s…",
      "success",
      {
        action: { label: t.toast_undo, onClick: cancel },
        durationMs: 10_000,
        countdown: true,
      }
    );
  };
  return (
    <Tooltip label={t.submit_logs_title ?? "Send a bug report"}>
      <button
        className="toolbar-icon-btn"
        onClick={onClick}
        aria-label={t.submit_logs_title ?? "Send a bug report"}
        disabled={busy}
      >
        <Bug size={16} strokeWidth={2} />
      </button>
    </Tooltip>
  );
}
