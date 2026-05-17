import React from "react";

/// Thin vertical drag strip. Reports the cumulative pointer delta in px
/// (positive = moved right) on every move while dragging. The parent
/// clamps and stores the resulting width. Double-click resets.
export function ResizeHandle({
  className,
  onDrag,
  onReset,
  title,
}: {
  className: string;
  onDrag: (dx: number) => void;
  onReset?: () => void;
  title?: string;
}) {
  const last = React.useRef(0);

  const onPointerDown = (e: React.PointerEvent) => {
    e.preventDefault();
    last.current = e.clientX;
    const move = (ev: PointerEvent) => {
      const dx = ev.clientX - last.current;
      last.current = ev.clientX;
      onDrag(dx);
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      document.body.classList.remove("resizing");
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    document.body.classList.add("resizing");
  };

  return (
    <div
      className={"resizer " + className}
      role="separator"
      aria-orientation="vertical"
      title={title}
      onPointerDown={onPointerDown}
      onDoubleClick={onReset}
    >
      <span className="resizer-grip" />
    </div>
  );
}
