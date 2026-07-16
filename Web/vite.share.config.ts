import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/// Build config for the PUBLIC share page (share.getcorder.com), kept separate
/// from `vite.config.ts` (the in-app bundle that Swifter serves) so the two
/// never share an outDir or an entry. `share.html` is emitted as `index.html`
/// by the rename step in `Scripts/build-share.sh`, because Vercel serves a
/// directory root, not a named page.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist-share",
    emptyOutDir: true,
    assetsDir: "assets",
    rollupOptions: {
      input: "share.html",
    },
  },
  base: "/",
});
