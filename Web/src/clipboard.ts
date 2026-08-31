/// Clipboard via the native bridge. WKWebView blocks both
/// `navigator.clipboard.writeText` and `document.execCommand('copy')` in our
/// Library window, so we ask Swift to write to NSPasteboard
/// (`window.corderCopy`, injected by LibraryWindow). Falls back to the web
/// APIs when the bridge isn't available (e.g. running in a regular browser
/// during dev with `npm run dev`).
export async function copyText(text: string): Promise<void> {
  const native = (window as unknown as { corderCopy?: (t: string) => boolean }).corderCopy;
  if (typeof native === "function") {
    if (native(text)) return;
  }
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return;
    }
  } catch { /* fall through to execCommand */ }
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  const ok = document.execCommand("copy");
  document.body.removeChild(ta);
  if (!ok) throw new Error("clipboard unavailable");
}
