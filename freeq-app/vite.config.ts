/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { execSync } from 'child_process'

// The freeq server's --web-addr (HTTP/WebSocket listener)
const FREEQ_WEB = process.env.FREEQ_WEB || 'http://127.0.0.1:8080'
const GIT_COMMIT = process.env.GIT_COMMIT || (() => {
  try { return execSync('git rev-parse --short HEAD').toString().trim() }
  catch { return 'unknown' }
})()

// When vite runs inside a boxd VM the dev server is reached via the
// `<vm>.boxd.sh` HTTPS proxy on :443, not directly on :5173 — vite's
// default HMR client URL (wss://<host>:5173) wouldn't connect. Pinning
// `clientPort: 443` makes the browser connect through the same proxy
// that served index.html, so HMR works end-to-end on preview envs.
// Localhost devs are unaffected: with boxd_vm_name unset we fall through
// to vite's auto-detection.
const ON_BOXD_VM = !!process.env.boxd_vm_name
const HMR_CONFIG = ON_BOXD_VM
  ? { clientPort: 443, protocol: 'wss' as const }
  : true

export default defineConfig({
  plugins: [react(), tailwindcss()],
  define: {
    '__FREEQ_TARGET__': JSON.stringify(FREEQ_WEB),
    '__GIT_COMMIT__': JSON.stringify(GIT_COMMIT),
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.{ts,tsx}'],
  },
  server: {
    host: '127.0.0.1',
    allowedHosts: ['.boxd.sh', '.boxd-stg.sh'],
    hmr: HMR_CONFIG,
    proxy: {
      '/irc': {
        target: FREEQ_WEB,
        ws: true,
        changeOrigin: false, // preserve browser Host so server builds localhost redirect URIs
      },
      '/api': {
        target: FREEQ_WEB,
        changeOrigin: false,
      },
      '/auth': {
        target: FREEQ_WEB,
        changeOrigin: false,
      },
      '/av': {
        target: FREEQ_WEB,
        ws: true,
        changeOrigin: false,
      },
      '/client-metadata.json': {
        target: FREEQ_WEB,
        changeOrigin: false,
      },
    },
  },
})
