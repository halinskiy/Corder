import React from "react";
import { createRoot } from "react-dom/client";
import { SharePage } from "./SharePage";
import "./share.css";

// Light only, on purpose. Measured across the category (2026-07-16): Loom,
// Granola, Otter and tl;dv all hard-pin light on their public pages; the one
// dark exception (Fathom) is dark everywhere, not just on shares. This page
// used to follow the visitor's OS theme, which nobody does — a share link is a
// page of the product, and it should look the same to everyone who opens it.
// So we never add the `.dark` class that styles.css keys its dark tokens off.

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <SharePage />
  </React.StrictMode>,
);
