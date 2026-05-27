import React from "react";
import type { T } from "../i18n";

/// Real brand marks (official logo geometry) — shared by the profile
/// popover's Integrations category. Moved here out of SettingsPane so
/// the "coming soon" promos live in one place.
function GoogleLogo() {
  return (
    <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden>
      <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" />
      <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
      <path fill="#FBBC05" d="M5.84 14.1c-.22-.66-.35-1.36-.35-2.1s.13-1.44.35-2.1V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.83z" />
      <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84C6.71 7.31 9.14 5.38 12 5.38z" />
    </svg>
  );
}

function AppleLogo() {
  return (
    <svg className="promo-apple" viewBox="0 0 24 24" width="17" height="17" aria-hidden>
      <path fill="currentColor" d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}

function TelegramLogo() {
  return (
    <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden>
      <path fill="#29A9EB" d="M12 0a12 12 0 1 0 0 24 12 12 0 0 0 0-24z" />
      <path fill="#fff" d="M5.49 11.78c3.5-1.52 5.83-2.53 7-3.02 3.33-1.39 4.02-1.63 4.47-1.64.1 0 .32.02.46.14.12.1.15.22.17.32.01.09.03.28.02.43-.17 1.83-.93 6.28-1.31 8.33-.16.87-.48 1.16-.78 1.19-.66.06-1.16-.44-1.8-.86-1-.66-1.57-1.07-2.54-1.71-1.12-.74-.4-1.15.25-1.81.17-.17 3.04-2.79 3.1-3.03.01-.03.01-.14-.06-.2-.07-.06-.17-.04-.25-.02-.1.02-1.79 1.14-5.03 3.34-.48.33-.91.49-1.29.48-.43-.01-1.24-.24-1.85-.44-.75-.24-1.34-.37-1.29-.79.03-.21.33-.43.9-.65z" />
    </svg>
  );
}

function SlackLogo() {
  return (
    <svg viewBox="0 0 122.8 122.8" width="17" height="17" aria-hidden>
      <path d="M25.8 77.6c0 7.1-5.8 12.9-12.9 12.9S0 84.7 0 77.6s5.8-12.9 12.9-12.9h12.9v12.9zm6.5 0c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9v32.3c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V77.6z" fill="#E01E5A" />
      <path d="M45.2 25.8c-7.1 0-12.9-5.8-12.9-12.9S38.1 0 45.2 0s12.9 5.8 12.9 12.9v12.9H45.2zm0 6.5c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H12.9C5.8 58 0 52.2 0 45.1s5.8-12.9 12.9-12.9h32.3z" fill="#36C5F0" />
      <path d="M97 45.2c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9-5.8 12.9-12.9 12.9H97V45.2zm-6.5 0c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V12.9C64.7 5.8 70.5 0 77.6 0s12.9 5.8 12.9 12.9v32.3z" fill="#2EB67D" />
      <path d="M77.6 97c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9-12.9-5.8-12.9-12.9V97h12.9zm0-6.5c-7.1 0-12.9-5.8-12.9-12.9s5.8-12.9 12.9-12.9h32.3c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H77.6z" fill="#ECB22E" />
    </svg>
  );
}

function GoogleCalendarLogo() {
  return (
    <svg viewBox="0 0 200 200" width="17" height="17" aria-hidden>
      <path fill="#fff" d="M152.6 47.4H47.4v105.2h105.2z" />
      <path fill="#EA4335" d="M152.6 200 200 152.6h-47.4z" />
      <path fill="#FBBC04" d="M200 47.4h-47.4v105.2H200z" />
      <path fill="#34A853" d="M152.6 152.6H47.4V200h105.2z" />
      <path fill="#188038" d="M0 152.6v33.1C0 193.6 6.4 200 14.3 200h33.1v-47.4z" />
      <path fill="#1967D2" d="M200 47.4V14.3C200 6.4 193.6 0 185.7 0h-33.1v47.4z" />
      <path fill="#4285F4" d="M152.6 0H14.3C6.4 0 0 6.4 0 14.3v138.3h47.4V47.4h105.2z" />
      <text x="100" y="122" fontFamily="Arial, sans-serif" fontSize="66" fontWeight="bold" fill="#4285F4" textAnchor="middle">31</text>
    </svg>
  );
}

/// Integrations category for the profile popover. All "coming soon"
/// surfaces (was the SettingsPane "Coming soon" block). Compact rows —
/// logo + title + an inert SOON chip — clicking just nudges with a
/// "soon" toast (same as the other dormant profile items).
/// Full pane variant of the Integrations list — sibling of SettingsPane
/// in the detail right column. Each row is the same logo + title + SOON
/// chip, just inside the `.settings-rows` framed card so it visually
/// matches the toggle cards in the Settings tab.
export function IntegrationsPane({
  t, onActivate,
}: {
  t: T;
  onActivate: () => void;
}) {
  const items: { logo: React.ReactNode; title: string }[] = [
    { logo: <GoogleLogo />, title: t.settings_ext_title },
    { logo: <AppleLogo />, title: t.settings_mobile_title },
    { logo: <TelegramLogo />, title: t.settings_tg_title },
    { logo: <SlackLogo />, title: t.settings_integrations_title },
    { logo: <GoogleCalendarLogo />, title: t.settings_calendar_title },
  ];
  return (
    <div className="settings-pane">
      {items.map((it) => (
        <button
          key={it.title}
          className="integrations-row"
          onClick={onActivate}
        >
          <span className="integrations-row-logo">{it.logo}</span>
          <span className="integrations-row-title">{it.title}</span>
          <span className="promo-soon">{t.settings_ext_badge_soon}</span>
        </button>
      ))}
    </div>
  );
}
