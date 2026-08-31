import React from "react";
import { Copy } from "lucide-react";
import { copyText } from "../clipboard";
import { Tooltip } from "./Tooltip";

/// Toolbar copy button with visible success feedback: on a successful copy
/// the circle fills accent green and a checkmark draws in for ~1.8s, then it
/// reverts to the plain Copy icon. The toast still fires (via `onToast`), the
/// button state is the at-a-glance confirmation right under the cursor.
///
/// `getText` may be async (the transcript is fetched from the server); it is
/// raced against an 8s timeout so a starved request can never leave the
/// button silently dead: the user gets the error toast instead.
export function CopyIconButton({
  getText, onToast, okText, failText, label, disabled = false,
}: {
  getText: () => string | Promise<string>;
  onToast?: (msg: string, kind?: "success" | "error") => void;
  okText: string;
  failText: string;
  label: string;
  disabled?: boolean;
}) {
  const [copied, setCopied] = React.useState(false);
  const busyRef = React.useRef(false);
  const revertTimer = React.useRef<number | null>(null);
  React.useEffect(() => () => {
    if (revertTimer.current) window.clearTimeout(revertTimer.current);
  }, []);

  const click = async () => {
    if (busyRef.current) return;
    busyRef.current = true;
    try {
      const text = await Promise.race([
        Promise.resolve(getText()),
        new Promise<string>((_, reject) =>
          window.setTimeout(() => reject(new Error("copy source timeout")), 8000)),
      ]);
      await copyText(text);
      setCopied(true);
      onToast?.(okText, "success");
      if (revertTimer.current) window.clearTimeout(revertTimer.current);
      revertTimer.current = window.setTimeout(() => setCopied(false), 1800);
    } catch {
      onToast?.(failText, "error");
    } finally {
      busyRef.current = false;
    }
  };

  return (
    <Tooltip label={label}>
      <button
        className={"toolbar-icon-btn" + (copied ? " copied" : "")}
        onClick={click}
        disabled={disabled}
        aria-label={label}
      >
        {copied ? <CheckDraw /> : <Copy size={16} strokeWidth={2} />}
      </button>
    </Tooltip>
  );
}

// Checkmark that draws itself in (stroke-dashoffset animation, see
// `.copy-check-path` in styles.css).
function CheckDraw() {
  return (
    <svg
      viewBox="0 0 16 16"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path className="copy-check-path" d="M3 8.5l3.4 3.4L13 4.6" />
    </svg>
  );
}
