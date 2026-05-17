import React from "react";
import { Blocks, CalendarClock } from "lucide-react";
import { getSettings, setSettings } from "../api";
import type { T } from "../i18n";

/// Real brand marks (official logo geometry) so the promos read as the
/// actual integrations, not generic glyphs.
function GoogleLogo() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden>
      <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" />
      <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
      <path fill="#FBBC05" d="M5.84 14.1c-.22-.66-.35-1.36-.35-2.1s.13-1.44.35-2.1V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.83z" />
      <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84C6.71 7.31 9.14 5.38 12 5.38z" />
    </svg>
  );
}

function AppleLogo() {
  return (
    <svg viewBox="0 0 24 24" width="21" height="21" aria-hidden>
      <path fill="currentColor" d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}

function TelegramLogo() {
  return (
    <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden>
      <path fill="#29A9EB" d="M12 0a12 12 0 1 0 0 24 12 12 0 0 0 0-24z" />
      <path fill="#fff" d="M5.49 11.78c3.5-1.52 5.83-2.53 7-3.02 3.33-1.39 4.02-1.63 4.47-1.64.1 0 .32.02.46.14.12.1.15.22.17.32.01.09.03.28.02.43-.17 1.83-.93 6.28-1.31 8.33-.16.87-.48 1.16-.78 1.19-.66.06-1.16-.44-1.8-.86-1-.66-1.57-1.07-2.54-1.71-1.12-.74-.4-1.15.25-1.81.17-.17 3.04-2.79 3.1-3.03.01-.03.01-.14-.06-.2-.07-.06-.17-.04-.25-.02-.1.02-1.79 1.14-5.03 3.34-.48.33-.91.49-1.29.48-.43-.01-1.24-.24-1.85-.44-.75-.24-1.34-.37-1.29-.79.03-.21.33-.43.9-.65z" />
    </svg>
  );
}

/// First-pass Settings page (right column, next to "Recording"). This
/// is a visual draft: toggles are local state only and not yet wired to
/// the backend — we'll make them functional in a later pass. Everything
/// Corder does is on by default; Pro-only capabilities aren't offered.
export function SettingsPane({
  t,
  onToast,
}: {
  t: T;
  onToast: (msg: string, kind?: "success" | "error") => void;
}) {
  const [vocab, setVocab] = React.useState("");
  const [vocabDirty, setVocabDirty] = React.useState(false);

  React.useEffect(() => {
    getSettings()
      .then((s) => {
        setVocab(s.vocabulary ?? "");
      })
      .catch(() => {});
  }, []);

  const saveVocab = async () => {
    if (!vocabDirty) return;
    try {
      const s = await setSettings({ vocabulary: vocab });
      setVocab(s.vocabulary ?? "");
      setVocabDirty(false);
      onToast(t.settings_saved, "success");
    } catch {
      onToast(t.toast_settings_failed, "error");
    }
  };

  return (
    <div className="settings-pane">
      <Section title={t.settings_sec_notifications}>
        <Toggle
          label={t.settings_notifications}
          desc={t.settings_notifications_desc}
          defaultOn
        />
      </Section>

      <Section title={t.settings_sec_capture}>
        <Toggle label={t.settings_video} desc={t.settings_video_desc} defaultOn />
        <Toggle
          label={t.settings_system_audio}
          desc={t.settings_system_audio_desc}
          defaultOn
        />
        <Toggle label={t.settings_mic} desc={t.settings_mic_desc} defaultOn />
      </Section>

      <Section title={t.settings_sec_transcription}>
        <Toggle
          label={t.settings_autotranscribe}
          desc={t.settings_autotranscribe_desc}
          defaultOn
        />
        <Toggle
          label={t.settings_autotitle}
          desc={t.settings_autotitle_desc}
          defaultOn
        />
      </Section>

      <div className="settings-section">
        <div className="settings-section-title">{t.settings_sec_recognition}</div>
        <div className="settings-field">
          <textarea
            className="settings-textarea"
            rows={3}
            placeholder={t.settings_vocab_placeholder}
            value={vocab}
            onChange={(e) => { setVocab(e.target.value); setVocabDirty(true); }}
            onBlur={saveVocab}
          />
          <div className="settings-field-hint">{t.settings_vocab_hint}</div>
        </div>
      </div>

      <div className="settings-section">
        <div className="settings-section-title">{t.settings_sec_privacy}</div>
        <div className="settings-privacy">{t.settings_privacy_body}</div>
      </div>

      <div className="settings-section">
        <div className="settings-section-title">{t.settings_sec_soon}</div>
        <div className="settings-ext-list">
          <PromoCard
            logo={<GoogleLogo />}
            title={t.settings_ext_title}
            desc={t.settings_ext_desc}
            badge={t.settings_ext_badge_soon}
          />
          <PromoCard
            logo={<AppleLogo />}
            title={t.settings_mobile_title}
            desc={t.settings_mobile_desc}
            badge={t.settings_ext_badge_soon}
          />
          <PromoCard
            logo={<TelegramLogo />}
            title={t.settings_tg_title}
            desc={t.settings_tg_desc}
            badge={t.settings_ext_badge_soon}
          />
          <PromoCard
            logo={<Blocks size={20} strokeWidth={1.75} />}
            title={t.settings_integrations_title}
            desc={t.settings_integrations_desc}
            badge={t.settings_ext_badge_soon}
          />
          <PromoCard
            logo={<CalendarClock size={20} strokeWidth={1.75} />}
            title={t.settings_calendar_title}
            desc={t.settings_calendar_desc}
            badge={t.settings_ext_badge_soon}
          />
        </div>
      </div>

      <div className="settings-pro-note">{t.settings_pro_note}</div>
    </div>
  );
}

/// Dormant "coming soon" promo (extension / mobile / Telegram bot).
/// Real brand logo, full-width text, an inert grey SOON chip — no
/// dead CTA button (it only squeezed the text into a thin column).
function PromoCard({
  logo, title, desc, badge,
}: {
  logo: React.ReactNode;
  title: string;
  desc: string;
  badge: string;
}) {
  return (
    <div className="promo" aria-disabled>
      <div className="promo-head">
        <div className="promo-logo">{logo}</div>
        <div className="promo-title-row">
          <span className="promo-title">{title}</span>
          <span className="promo-soon">{badge}</span>
        </div>
      </div>
      <div className="promo-desc">{desc}</div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="settings-section">
      <div className="settings-section-title">{title}</div>
      <div className="settings-rows">{children}</div>
    </div>
  );
}

function Toggle({
  label, desc, defaultOn,
}: {
  label: string;
  desc: string;
  defaultOn: boolean;
}) {
  const [on, setOn] = React.useState(defaultOn);
  // The whole row is the hit target (hover-highlights like a sidebar
  // session; click anywhere toggles). The switch is purely visual.
  return (
    <div
      className="settings-row"
      role="switch"
      aria-checked={on}
      aria-label={label}
      tabIndex={0}
      onClick={() => setOn((v) => !v)}
      onKeyDown={(e) => {
        if (e.key === " " || e.key === "Enter") { e.preventDefault(); setOn((v) => !v); }
      }}
    >
      <div className="settings-row-text">
        <div className="settings-row-label">{label}</div>
        <div className="settings-row-desc">{desc}</div>
      </div>
      <span className={"set-switch" + (on ? " on" : "")} aria-hidden>
        <span className="set-switch-thumb" />
      </span>
    </div>
  );
}
