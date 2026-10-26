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
      rows.forEach((row, i) => {
        const layer = Math.min(i, 1);
        row.style.setProperty("--stack-y", `${-7 + layer * 7 - row.offsetTop}px`);
        row.style.setProperty("--stack-scale-x", String(i < layerCount ? Math.max(0, (row.offsetWidth - 16 * (layer + 1)) / row.offsetWidth) : 0.96));
        row.style.setProperty("--stack-scale-y", String(i < layerCount ? 14 / row.offsetHeight : 0.96));
      });
      const height = head.offsetHeight + (expanded ? body.offsetHeight : layerCount * 7);
      // Read the presented height before cancelling so a reversal starts at its current frame.
      const from = root.getBoundingClientRect().height;
      const changed = root.style.height !== `${height}px` || expandedRef.current !== expanded;
      expandedRef.current = expanded;
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
      </div>
      <div className="meeting-stack-recordings" id={bodyId} ref={bodyRef} aria-hidden={!expanded}>
        {children.map((child, i) => (
          <div key={child.key} className={"meeting-stack-entry"
            + (i < layerCount ? " meeting-stack-layer" : "")
            + (i === 1 && layerCount > 1 ? " meeting-stack-layer-back" : "")}
            style={{ "--stack-delay": `${Math.min(i, 6) * 35}ms`, zIndex: children.length - i } as React.CSSProperties}>
            <div className="meeting-stack-entry-content">{child}</div>
          </div>
        ))}
        <div className="meeting-stack-footer">
          <button className="meeting-stack-less" onClick={onCollapse}>{showLess}</button>
        </div>
      </div>
    </div>
  );
}
