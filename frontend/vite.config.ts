import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev server proxies API calls to the Haskell server on :8080 so `npm run dev`
// (on :5173) talks to it. `npm run build` emits ./dist, which the Haskell server
// serves directly in normal use.
export default defineConfig({
  plugins: [react()],
  build: { outDir: "dist" },
  server: {
    proxy: {
      "/api": "http://localhost:8080",
    },
  },
});
