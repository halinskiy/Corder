import React from "react";
import { Usage, getUsage } from "../api";
import type { T } from "../i18n";

interface Props {
  t: T;
  /// Bump to force a re-fetch (after a transcription completes, etc.).
  reloadSignal?: number;
}

/// Dashboard "Usage" card. Two rows — Advanced (cloud transcription
/// minutes) + Local Whisper (always unlimited) — each with a thin
/// progress bar underneath. Limited tiers render a real fill; the
/// Max tier (and the Local row for every tier) gets a shimmer band
/// that drifts left → right so the bar visibly *does something* even
/// when there's no quota to consume.
export function UsageBars({ t, reloadSignal }: Props) {
  const [usage, setUsage] = React.useState<Usage | null>(null);
  const [error, setError] = React.useState(false);

  React.useEffect(() => {
    let alive = true;
    getUsage()
      .then((u) => { if (alive) setUsage(u); })
      .catch(() => { if (alive) setError(true); });
    return () => { alive = false; };
  }, [reloadSignal]);

  if (error || !usage) return null;

  return (
    <div className="settings-rows dash-stats-card dash-usage-card">
      <div className="dash-usage-header">
        <div className="clarify-body">{t.usage_title ?? "Monthly usage"}</div>
        <div className="dash-sub">{t.usage_subtitle ?? "Transcription minutes this month."}</div>
      </div>
      <UsageRow
        label={t.usage_advanced ?? "Advanced transcription"}
        used={usage.advanced.used_seconds}
        limit={usage.advanced.limit_seconds}
      />
      <UsageRow
        label={t.usage_local ?? "Local Models"}
        used={usage.local.used_seconds}
        limit={usage.local.limit_seconds}
      />
    </div>
  );
}

interface RowProps {
  label: string;
  used: number;
  limit: number | null;
}

function fmtRemaining(sec: number): string {
  if (sec < 60) return `${Math.max(0, Math.round(sec))}s`;
  const m = Math.round(sec / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  const r = m % 60;
  return r === 0 ? `${h}h` : `${h}h ${r}m`;
}

function UsageRow({ label, used, limit }: RowProps) {
  // `== null` covers both null AND undefined (Swift omits the key
  // entirely when the optional is nil — the parsed JSON has no
  // `limit_seconds` at all on the Max tier — and `=== null` would miss).
  const unlimited = limit == null;
  // The bar visualises REMAINING quota: starts full (100 %) and
  // drains left → right as the user consumes minutes. Unlimited
  // rows are pinned full — there's nothing to drain. Limited rows
  // map fill = (limit - used) / limit, clamped to [0, 100].
  const remainingSec = unlimited ? 0 : Math.max(0, (limit as number) - used);
  const remainingPct = unlimited || (limit ?? 0) === 0
    ? 100
    : Math.min(100, Math.max(0, ((limit as number) - used) / (limit as number) * 100));
  const widthVar = `${remainingPct}%`;
  const value = unlimited ? "unlimited" : `${fmtRemaining(remainingSec)} left`;

  // No progress bar — pure two-column row identical to the Stats
  // card above (Recordings / Total recorded / This week). Same
  // `dash-stat-row` shell so the typography, padding and hairline
  // dividers match without us having to redeclare any of it.
  void remainingPct;
  void widthVar;
  return (
    <div className="dash-stat-row">
      <div className="settings-row-label">{label}</div>
      <div className="dash-stat-value">{value}</div>
    </div>
  );
}
