// PATH: src/main.tsx
//
// WHAT: React application entry point — mounts App into #root div.
// WHY:  Vite requires a main.tsx entry point that bootstraps the React tree.
// Source (Tier 2): Vite docs — "main.tsx is the default entry point."
//   https://vitejs.dev/guide/#index-html-and-project-root

import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'

// WHAT: global CSS reset — removes browser default margins/padding.
// WHY:  avoids unexpected layout shifts from browser defaults.
const style = document.createElement('style')
style.textContent = `
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: #0a0a0f; color: #ccccdd; }
  ::-webkit-scrollbar { width: 6px; height: 6px; }
  ::-webkit-scrollbar-track { background: #111; }
  ::-webkit-scrollbar-thumb { background: #333; border-radius: 3px; }
  ::-webkit-scrollbar-thumb:hover { background: #ffb800; }
`
document.head.appendChild(style)

console.log('[main] ENTER: mounting React app')

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)

console.log('[main] EXIT: React app mounted')
