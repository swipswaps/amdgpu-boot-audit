// PATH: src/config.ts
//
// WHAT: centralised API base URL configuration.
//       Mirrors the receipts-ocr pattern confirmed from README verbatim:
//       "Created src/config.ts with centralized API_BASE export"
//       "All 5 services now use consistent backend URL detection"
//       "GitHub Pages correctly uses localhost:5002 for local Docker"
//
// WHY:  the frontend is served from swipswaps.github.io (static).
//       It must connect to the user's LOCAL Docker container running on
//       their machine. The base URL is always localhost:5002 because
//       that is where docker-compose.yml binds the API port.
//
// MENTAL MODEL: frontend is remote (GitHub Pages), backend is local (Docker).
//   The user's browser fetches the frontend from GitHub, then the JS
//   inside the browser makes API calls to localhost:5002 on the user's
//   own machine. This is identical to the receipts-ocr pattern.
//
// FAILURE MODE: if Docker is not running, all fetch() calls to API_BASE
//   fail with "Failed to fetch". The useApi hook catches this and
//   sets isOffline=true, triggering the offline banner.
//
// VERIFIES WITH: console.log(API_BASE) in browser devtools shows
//   "http://localhost:5002" when Docker is running.
//
// Source (Tier 4): swipswaps/receipts-ocr src/config.ts — centralized API_BASE.
//   https://github.com/swipswaps/receipts-ocr/blob/main/src/config.ts

// WHAT: API base URL pointing to the local Docker container.
// WHY:  port 5002 is confirmed in docker-compose.yml and app.py.
//       Using an env var (VITE_API_BASE) allows override during local dev
//       without rebuilding: VITE_API_BASE=http://localhost:5002 npm run dev
// Source (Tier 2): Vite docs — "VITE_ prefixed env vars are exposed to client."
//   https://vitejs.dev/guide/env-and-mode.html
export const API_BASE: string =
  import.meta.env.VITE_API_BASE ?? 'http://localhost:5002'

// WHAT: GitHub Pages base path — must match vite.config.ts base option.
// WHY:  react-router-dom uses this as the basename so routes work under
//       /amdgpu-boot-audit/ instead of /.
// Source (Tier 2): Vite docs — base option. https://vitejs.dev/config/shared-options.html#base
export const BASE_PATH: string = '/amdgpu-boot-audit'

// WHAT: health check URL used by useDockerStatus hook.
// WHY:  polling /health every 10s lets the frontend detect when Docker
//       starts or stops without requiring a page reload.
export const HEALTH_URL: string = `${API_BASE}/health`

// WHAT: polling interval in milliseconds for health checks.
// WHY:  10 seconds balances responsiveness against network noise.
//       receipts-ocr uses similar interval for dockerHealthService.
export const HEALTH_POLL_MS = 10_000
