// PATH: vite.config.ts
//
// WHAT: Vite build configuration for the boot-audit GitHub Pages frontend.
// WHY:  GitHub Pages hosts project pages at a subdirectory URL:
//       https://swipswaps.github.io/amdgpu-boot-audit/
//       Without setting base, all asset links point to the domain root
//       and the page loads blank.
//
// CONFIRMED FAILURE MODE (from search results verbatim):
//   "Asset links are referencing the files in the domain root, whereas our
//    project is located in <ROOT>/vite-deploy-demo. This is how the links
//    should look: ❌ Bad https://sitek94.github.io/assets/favicon.svg
//    ✅ Good https://sitek94.github.io/vite-deploy-demo/assets/favicon.svg"
//   Source (Tier 4): sitek94/vite-deploy-demo — base config explanation.
//     https://github.com/sitek94/vite-deploy-demo
//
// VERIFIES WITH: after build, dist/index.html contains
//   src="/amdgpu-boot-audit/assets/..." not src="/assets/..."
//
// Source (Tier 2): Vite docs — "base: Public base path when served in dev or production."
//   https://vitejs.dev/config/shared-options.html#base

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],

  // WHAT: set base path to the repo name for GitHub Pages subdirectory hosting.
  // WHY:  GitHub Pages project pages are served at /<repo-name>/, not /.
  //       Vite uses this to prefix all asset URLs in the built HTML.
  base: '/amdgpu-boot-audit/',

  build: {
    // WHAT: output directory matches GitHub Actions deploy workflow expectation.
    // WHY:  deploy.yml uploads ./dist — this confirms the output path.
    outDir: 'dist',
    sourcemap: false,
  },

  server: {
    port: 5173,
    // WHAT: proxy API calls to local Docker during development.
    // WHY:  avoids CORS issues during local dev — browser talks to 5173,
    //       Vite proxies /api/* to localhost:5002.
    // Source (Tier 2): Vite docs — "proxy maps dev server paths to backend."
    //   https://vitejs.dev/config/server-options.html#server-proxy
    proxy: {
      '/api': {
        target: 'http://localhost:5002',
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
})
