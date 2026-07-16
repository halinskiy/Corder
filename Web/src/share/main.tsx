import React from "react";
import { createRoot } from "react-dom/client";
import { SharePage } from "./SharePage";
import "../styles.css";

// The app mirrors the macOS appearance through a native bridge; a browser has
// no such signal, so the share page follows the OS preference directly. Same
// `.dark` class on <html> that `theme.ts` toggles in-app, so every token in
// styles.css resolves identically.
function applyTheme(dark: boolean) {
  document.documentElement.classList.toggle("dark", dark);
}
const mq = window.matchMedia("(prefers-color-scheme: dark)");
applyTheme(mq.matches);
mq.addEventListener("change", (e) => applyTheme(e.matches));

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <SharePage />
  </React.StrictMode>,
);
