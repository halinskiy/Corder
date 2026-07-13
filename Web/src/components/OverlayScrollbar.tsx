import React from "react";

/// One custom scrollbar, shared by the sidebar list and the transcript
/// pane. WebKit pins a native `::-webkit-scrollbar` inside the scroll
/// box, so it can NEVER sit centred on the sidebar/main divider, the
/// long-running "scrollbar is left of the line" bug. This draws our own
/// thin thumb as a `position: fixed` element whose horizontal CENTRE is
/// placed exactly on the scroll container's right edge (= the divider),
/// so it straddles the line on both panes identically. The native bar
/// is hidden via the `.ovsb-scroll` class on the container.
///
/// Fixed positioning (recomputed on scroll/resize/content-change) means
/// zero layout restructuring of the existing panes, the only structural
/// requirement is that the container carry `.ovsb-scroll`.
export function OverlayScrollbar({
  scrollRef,
  dividerRef,
  name,
}: {
  scrollRef: React.RefObject<HTMLElement | null>;
  /// Unique `view-transition-name` for the thumb. The thumb is
  /// position:fixed → its own layer, which WebKit composites LIVE above
  /// the theme View-Transition snapshots (it would blink at the wipe's
  /// start/end). A name makes WebKit capture it as an independent group
  /// so it rides the transition instead. MUST be unique per mounted
  /// instance, a duplicate name aborts the entire transition, so the
  /// shared `.ovsb-thumb` class can't carry it; each call site passes
  /// its own (e.g. "corder-sb-list", "corder-sb-transcript").
  name?: string;
  /// Optional element whose RIGHT edge is the true divider line. The
  /// sidebar's scroll box is ~1 px narrower than the sidebar itself, so
  /// centring on the scroll box lands 1 px inside the grey/white seam;
  /// pass the sidebar element here to centre on the actual seam. When
  /// omitted the scroll container's right edge is used (correct for the
  /// transcript pane, whose painted hairline IS at the box edge).
  dividerRef?: React.RefObject<HTMLElement | null>;
}) {
  const [box, setBox] = React.useState<{
    visible: boolean;
    left: number;
    top: number;
    height: number;
  }>({ visible: false, left: 0, top: 0, height: 0 });
  const drag = React.useRef<{ startY: number; startScroll: number } | null>(null);
  const [active, setActive] = React.useState(false);
  const raf = React.useRef<number | null>(null);

  const THUMB_W = 7;
  const MIN_THUMB = 40;

  const measure = React.useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;
    const { scrollTop, scrollHeight, clientHeight } = el;
    const rect = el.getBoundingClientRect();
    if (scrollHeight <= clientHeight + 1 || rect.height < 1) {
      setBox((b) => (b.visible ? { ...b, visible: false } : b));
      return;
    }
    const trackH = rect.height;
    const thumbH = Math.max(MIN_THUMB, (clientHeight / scrollHeight) * trackH);
    const maxThumbTop = Math.max(0, trackH - thumbH);
    const denom = scrollHeight - clientHeight;
    const top = denom > 0 ? (scrollTop / denom) * maxThumbTop : 0;
    const dividerX =
      dividerRef?.current?.getBoundingClientRect().right ?? rect.right;
    setBox({
      visible: true,
      // Centre the THUMB on the divider: left = dividerX − half width.
      left: dividerX - THUMB_W / 2,
      top: rect.top + top,
      height: thumbH,
    });
  }, [scrollRef, dividerRef]);

  // rAF-coalesced: scroll fires far faster than paint.
  const schedule = React.useCallback(() => {
    if (raf.current != null) return;
    raf.current = requestAnimationFrame(() => {
      raf.current = null;
      measure();
    });
  }, [measure]);

  React.useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    measure();
    el.addEventListener("scroll", schedule, { passive: true });
    const ro = new ResizeObserver(schedule);
    ro.observe(el);
    // Content height can change without a resize (list filter, transcript
    // load, banner open), watch the subtree too.
    const mo = new MutationObserver(schedule);
    mo.observe(el, { childList: true, subtree: true, characterData: true });
    window.addEventListener("resize", schedule);
    return () => {
      el.removeEventListener("scroll", schedule);
      ro.disconnect();
      mo.disconnect();
      window.removeEventListener("resize", schedule);
      if (raf.current != null) cancelAnimationFrame(raf.current);
    };
  }, [scrollRef, measure, schedule]);

  React.useEffect(() => {
    if (!drag.current) return;
    const onMove = (e: MouseEvent) => {
      const el = scrollRef.current;
      const d = drag.current;
      if (!el || !d) return;
      const { scrollHeight, clientHeight } = el;
      const rect = el.getBoundingClientRect();
      const thumbH = Math.max(
        MIN_THUMB,
        (clientHeight / scrollHeight) * rect.height
      );
      const usable = Math.max(1, rect.height - thumbH);
      const dy = e.clientY - d.startY;
      el.scrollTop =
        d.startScroll + (dy / usable) * (scrollHeight - clientHeight);
    };
    const onUp = () => {
      drag.current = null;
      setActive(false);
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    return () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
  }, [active, scrollRef]);

  if (!box.visible) return null;
  return (
    <div
      className={"ovsb-thumb" + (active ? " dragging" : "")}
      style={{
        left: box.left,
        top: box.top,
        height: box.height,
        width: THUMB_W,
        viewTransitionName: name,
      }}
      onMouseDown={(e) => {
        e.preventDefault();
        const el = scrollRef.current;
        if (!el) return;
        drag.current = { startY: e.clientY, startScroll: el.scrollTop };
        setActive(true);
      }}
    />
  );
}
