import React from "react";
import { getUpcoming, connectCalendar, type UpcomingEvent } from "../api";
import { formatDate } from "../format";
import type { Lang, T } from "../i18n";

/// Official Google Meet logo (2020), straight from Wikimedia Commons.
/// Rendered ~24px wide; the 87.5×72 viewBox keeps its native aspect.
function GoogleMeetLogo() {
  return (
    <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 87.5 72" width="24" height="20" aria-hidden>
      <path fill="#00832d" d="M49.5 36l8.53 9.75 11.47 7.33 2-17.02-2-16.64-11.69 6.44z" />
      <path fill="#0066da" d="M0 51.5V66c0 3.315 2.685 6 6 6h14.5l3-10.96-3-9.54-9.95-3z" />
      <path fill="#e94235" d="M20.5 0L0 20.5l10.55 3 9.95-3 2.95-9.41z" />
      <path fill="#2684fc" d="M20.5 20.5H0v31h20.5z" />
      <path fill="#00ac47" d="M82.6 8.68L69.5 19.42v33.66l13.16 10.79c1.97 1.54 4.85.135 4.85-2.37V11c0-2.535-2.945-3.925-4.91-2.32zM49.5 36v15.5h-29V72h43c3.315 0 6-2.685 6-6V53.08z" />
      <path fill="#ffba00" d="M63.5 0h-43v20.5h29V36l20-16.57V6c0-3.315-2.685-6-6-6z" />
    </svg>
  );
}

/// Forward-looking mirror of the Recent list: meetings pulled from the
/// user's connected calendar, grouped by day, with the nearest one
/// surfaced as a highlighted "Up next" card. Reuses the Recent list's
/// `.dash-recent-card` vocabulary so past + future read as one family.
/// Until calendar access is granted the pane shows a Connect state; the
/// live data wiring (Google `calendar.readonly` provider token → events)
/// lands once the OAuth scope is in place, `getUpcoming` already returns
/// the `{connected, events}` contract this renders against.
export function UpcomingPane({
  t, lang,
}: {
  t: T;
  lang: Lang;
}) {
  const [loading, setLoading] = React.useState(true);
  const [connected, setConnected] = React.useState(false);
  const [events, setEvents] = React.useState<UpcomingEvent[]>([]);
  const [connecting, setConnecting] = React.useState(false);
  const aliveRef = React.useRef(true);

  React.useEffect(() => {
    aliveRef.current = true;
    getUpcoming()
      .then((r) => { if (aliveRef.current) { setConnected(r.connected); setEvents(r.events ?? []); } })
      .catch(() => { if (aliveRef.current) { setConnected(false); setEvents([]); } })
      .finally(() => { if (aliveRef.current) setLoading(false); });
    return () => { aliveRef.current = false; };
  }, []);

  // Connect → open the Google OAuth in the browser, then poll the cache
  // (~2.5 min) until the callback has fetched the events. Stops on connect.
  const onConnect = async () => {
    setConnecting(true);
    try { await connectCalendar(); } catch { /* the browser tab still opened in most cases */ }
    const deadline = Date.now() + 150_000;
    const tick = async () => {
      if (!aliveRef.current) return;
      try {
        const r = await getUpcoming();
        if (r.connected) { setConnected(true); setEvents(r.events ?? []); setConnecting(false); return; }
      } catch { /* keep polling */ }
      if (Date.now() < deadline) setTimeout(tick, 4000);
      else setConnecting(false);
    };
    setTimeout(tick, 4000);
  };

  if (loading) {
    return (
      <div className="dash-recent-stack">
        <div className="dash-recent-card ghost" aria-hidden>
          <div className="dash-recent-row">
            <div className="dash-recent-title-row">
              <div className="dash-recent-title">&nbsp;</div>
            </div>
            <div className="dash-recent-meta">&nbsp;</div>
          </div>
        </div>
      </div>
    );
  }

  // Empty: distinguish "calendar not connected" (offer connect) from
  // "connected but nothing scheduled" (informational).
  if (events.length === 0) {
    return (
      <div className="trans-banner clarify-banner dash-banner">
        <div className="clarify-text">
          <div className="clarify-body">
            {connected
              ? (t.upcoming_none ?? "No upcoming meetings")
              : (t.upcoming_connect_title ?? "See your upcoming meetings")}
          </div>
          <div className="dash-sub">
            {connected
              ? (t.upcoming_none_sub ?? "Nothing scheduled in the next 30 days.")
              : (t.upcoming_connect_sub ?? "Calendar sync is on the way, your upcoming meetings will show up here.")}
          </div>
        </div>
        {!connected && (
          <div className="clarify-actions clarify-actions-stack">
            <button
              type="button"
              className="clarify-btn accent dash-primary-btn"
              onClick={onConnect}
              disabled={connecting}
            >
              {connecting
                ? (t.upcoming_connecting ?? "Waiting for Google…")
                : (t.upcoming_connect_cta ?? "Connect calendar")}
            </button>
          </div>
        )}
      </div>
    );
  }

  // Just the future meetings, chronological. No section headers, no
  // "up next" highlight, a plain ordered list (Kostya's call).
  const sorted = [...events].sort((a, b) => a.start_ms - b.start_ms);

  // Exact date + time (e.g. "Jun 12, 11:00"), not a duration. `formatDate`
  // already folds today/yesterday and appends the clock.
  const metaOf = (ev: UpcomingEvent): string => formatDate(ev.start_ms, lang);

  // A row, not a boxed card: full-width hairline dividers, text inset 20px.
  // Meeting-service logo on the left (Google Meet for now), title in
  // `.clarify-body` (18/300, the "Ready when you are" voice), time in
  // `.meeting-title` (14/500, the sidebar session-title voice).
  const row = (ev: UpcomingEvent) => (
    <button
      key={ev.id}
      type="button"
      className="upcoming-row"
      onClick={() => {
        const open = (window as unknown as { corderOpenExternal?: (u: string) => void }).corderOpenExternal;
        if (ev.join_url && open) open(ev.join_url);
      }}
    >
      <span className="upcoming-icon"><GoogleMeetLogo /></span>
      <span className="upcoming-row-text">
        <div className="clarify-body">{ev.title?.trim() || (t.upcoming_untitled ?? "Untitled meeting")}</div>
        <div className="meeting-title upcoming-time">{metaOf(ev)}</div>
      </span>
    </button>
  );

  return (
    <div className="upcoming-list">
      {sorted.map((ev) => row(ev))}
    </div>
  );
}
