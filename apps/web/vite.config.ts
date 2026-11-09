import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const restTarget = process.env.VITE_REST_PROXY ?? "http://localhost:3000";
const mcpTarget = process.env.VITE_MCP_PROXY ?? "http://localhost:8080";
const hmrClientPort = process.env.VITE_HMR_CLIENT_PORT ? Number(process.env.VITE_HMR_CLIENT_PORT) : undefined;

export default defineConfig({
  plugins: [
    react(),
    {
      name: "agent-boards-health",
      configureServer(server) {
        server.middlewares.use("/health", (_request, response) => {
          response.setHeader("Content-Type", "application/json");
          response.end(JSON.stringify({ ok: true, service: "agent-boards", mode: "vite-hmr" }));
        });
      },
    },
  ],
  server: {
    host: "0.0.0.0",
    port: 5173,
    strictPort: true,
    hmr: hmrClientPort ? { clientPort: hmrClientPort } : undefined,
    watch: process.env.VITE_USE_POLLING === "true" ? { usePolling: true, interval: 180 } : undefined,
    proxy: {
      "/api": { target: restTarget, rewrite: (path) => path.replace(/^\/api/, "") },
      "/mcp/health": { target: mcpTarget, rewrite: () => "/health" },
      "/mcp": { target: mcpTarget },
    },
  },
});
