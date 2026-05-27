import React from "react";
import { Moon, Archive as ArchiveIcon, Settings as SettingsIcon } from "lucide-react";
import { UpdatePill } from "./UpdatePill";
import { ProfileMenu } from "./ProfileMenu";
import { useTheme } from "../theme";
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
  onOpenSettings,
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
  /// Fires when the user clicks "Settings" in the profile popover.
  /// Parent decides what "open Settings" means in the current context
  /// (right-pane tab in MeetingView, right-section toggle on Dashboard).
  onOpenSettings: () => void;
  /// Fires when the user clicks "Dashboard" in the profile popover —
  /// always returns to the landing surface (parent clears activeId).
  onOpenDashboard: () => void;
  onToast: (msg: string, kind?: "success" | "error") => void;
  t: T;
}) {
  return (
    <div className="main-header">
      <div className="breadcrumb">{breadcrumb}</div>
      <div className="spacer" />
      <div className="toolbar">
        <UpdatePill t={t} onToast={onToast} />
        <ThemeSwitch t={t} />
        {/* Settings now sits in the toolbar where the LangPicker used
            to live — the language switcher moved into the profile
            popover (rare action, not worth a top-bar slot). The two
            shortcuts share the same icon-button shell. */}
        <button
          className="toolbar-icon-btn"
          onClick={onOpenSettings}
          title={t.profile_account}
          aria-label={t.profile_account}
        >
          <SettingsIcon size={16} strokeWidth={2} />
        </button>
        <button
          className={"toolbar-icon-btn" + (archiveOpen ? " active" : "")}
          onClick={onOpenArchive}
          title={t.archive_open_title}
          aria-label={t.btn_archive}
          aria-pressed={archiveOpen}
        >
          <ArchiveIcon size={16} strokeWidth={2} />
        </button>
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
    <button
      className="toolbar-icon-btn"
      onClick={toggle}
      title={t.btn_theme_title}
      aria-label={t.btn_theme_title}
    >
      <Moon size={16} strokeWidth={2} />
    </button>
  );
}
