import React from "react";

interface Props {
  expanded: boolean;
  header: React.ReactElement;
  children: React.ReactElement[];
  onCollapse: () => void;
  showLess: string;
}

export function MeetingStack({ expanded, header, children, onCollapse, showLess }: Props) {
  const rootRef = React.useRef<HTMLDivElement>(null);
  const headerRef = React.useRef<HTMLDivElement>(null);
  const bodyRef = React.useRef<HTMLDivElement>(null);
  const animationRef = React.useRef<Animation | null>(null);
  const initialized = React.useRef(false);
  const expandedRef = React.useRef(expanded);
  const [reducedMotion, setReducedMotion] = React.useState(
    () => window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
  const bodyId = React.useId();
  const layerCount = Math.min(2, children.length - 1);

  React.useEffect(() => {
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReducedMotion(media.matches);
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  React.useLayoutEffect(() => {
    const root = rootRef.current!;
    const head = headerRef.current!;
    const body = bodyRef.current!;
    if (!expanded && body.contains(document.activeElement)) {
      head.querySelector<HTMLElement>('[role="button"]')?.focus({ preventScroll: true });
    }
    body.inert = !expanded;
    const measure = () => {
      const rows = Array.from(body.querySelectorAll<HTMLElement>(":scope > .meeting-stack-entry"));
      rows.forEach((row) => {
        // Collapsed rows sit under the header card, so they rise out of it.
        row.style.setProperty("--stack-y", `${-row.offsetTop - row.offsetHeight / 2}px`);
      });
      const height = head.offsetHeight + (expanded ? body.offsetHeight : layerCount * 5);
      // Read the presented height before cancelling so a reversal starts at its current frame.
      const from = root.getBoundingClientRect().height;
      const changed = root.style.height !== `${height}px` || expandedRef.current !== expanded;
      const justCollapsed = expandedRef.current && !expanded;
      expandedRef.current = expanded;
      // Collapsing from the sticky header deep in a long stack: bring the
      // stack's top back into view so the list doesn't jump past it.
      if (justCollapsed) {
        const list = root.closest(".sidebar-list");
        if (list && root.getBoundingClientRect().top < list.getBoundingClientRect().top) {
          list.scrollTo({ top: list.scrollTop + root.getBoundingClientRect().top - list.getBoundingClientRect().top - 8,
            behavior: reducedMotion ? "auto" : "smooth" });
        }
      }
      if (reducedMotion) animationRef.current?.cancel();
      if (!changed) return;
      animationRef.current?.cancel();
      root.style.height = `${height}px`;
      if (initialized.current && !reducedMotion && Math.abs(from - height) > 0.1) {
        animationRef.current = root.animate(
          [{ height: `${from}px` }, { height: `${height}px` }],
          { duration: expanded ? 500 : 320, easing: expanded
            ? "cubic-bezier(0.34, 1.42, 0.5, 1)" : "cubic-bezier(0.2, 0.8, 0.2, 1)" }
        );
      }
      initialized.current = true;
      root.dataset.ready = "true";
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(head);
    observer.observe(body);
    return () => observer.disconnect();
  }, [expanded, reducedMotion, children.length, layerCount]);

  React.useEffect(() => () => animationRef.current?.cancel(), []);

  return (
    <div className="meeting-stack-wrap" ref={rootRef} data-expanded={expanded}>
      <div className="meeting-stack-header" ref={headerRef}>
        {React.cloneElement(header, { "aria-controls": bodyId })}
        {layerCount > 0 && <span className="meeting-stack-plate" aria-hidden />}
        {layerCount > 1 && <span className="meeting-stack-plate meeting-stack-plate-back" aria-hidden />}
      </div>
      <div className="meeting-stack-recordings" id={bodyId} ref={bodyRef} aria-hidden={!expanded}>
        {children.map((child, i) => (
          <div key={child.key} className="meeting-stack-entry"
            style={{ "--stack-delay": `${Math.min(i, 6) * 35}ms`, zIndex: children.length - i } as React.CSSProperties}>
            <div className="meeting-stack-entry-content">{child}</div>
          </div>
        ))}
        <div className="meeting-stack-footer">
          <button type="button" className="clarify-btn bigbtn-full" onClick={onCollapse}>{showLess}</button>
        </div>
      </div>
    </div>
  );
}
