// PATH: src/components/OfflineBanner.tsx
//
// WHAT: banner shown when the local Docker backend is not reachable.
//       Mirrors receipts-ocr DockerStatus.tsx — "Self-healing Docker Status —
//       Auto-fallback to Tesseract.js when backend unavailable."
//
// WHY:  the frontend is served from GitHub Pages (always available) but
//       depends on a local Docker container that may not be running.
//       A clear banner tells the user exactly what to do.
//
// FAILURE MODE: if this component does not render when Docker is down,
//   the user sees an empty page with no explanation.
//
// VERIFIES WITH: stop Docker (docker compose stop), reload the page —
//   banner appears with exact start commands.
//
// Source (Tier 4): swipswaps/receipts-ocr src/components/DockerStatus.tsx.
//   https://github.com/swipswaps/receipts-ocr/blob/main/src/components/DockerStatus.tsx

import React from 'react'

interface Props {
  // WHAT: the last successful row count — shown when Docker goes offline
  //       mid-session so the user knows data was loaded.
  lastRowCount?: number
}

export function OfflineBanner({ lastRowCount }: Props): React.ReactElement {
  console.log('[OfflineBanner] ENTER render: lastRowCount=', lastRowCount)

  return (
    <div style={{
      background: 'linear-gradient(135deg, #1a0a0a 0%, #2d1010 100%)',
      border: '1px solid #ff4444',
      borderRadius: '8px',
      padding: '20px 24px',
      marginBottom: '24px',
      fontFamily: "'JetBrains Mono', monospace",
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '12px', marginBottom: '12px' }}>
        <span style={{ fontSize: '20px' }}>⚠</span>
        <span style={{ color: '#ff6666', fontWeight: 700, fontSize: '14px', letterSpacing: '0.1em' }}>
          LOCAL DOCKER NOT RUNNING
        </span>
        {lastRowCount !== undefined && lastRowCount > 0 && (
          <span style={{ color: '#666', fontSize: '12px' }}>
            (cached: {lastRowCount} boots)
          </span>
        )}
      </div>
      <div style={{ color: '#aaa', fontSize: '13px', lineHeight: '1.8' }}>
        <div>The boot-audit API is not reachable at <code style={{ color: '#ff9966' }}>localhost:5002</code>.</div>
        <div style={{ marginTop: '12px', color: '#888', fontSize: '12px' }}>Start the backend:</div>
        <pre style={{
          background: '#0d0d0d',
          border: '1px solid #333',
          borderRadius: '4px',
          padding: '12px',
          marginTop: '8px',
          color: '#88ff88',
          fontSize: '12px',
          overflowX: 'auto',
        }}>
{`cd amdgpu-boot-audit
docker compose up -d
# Wait ~10s, then reload this page`}
        </pre>
        <div style={{ marginTop: '8px', color: '#666', fontSize: '11px' }}>
          If Docker is running but the banner persists, check:{' '}
          <code style={{ color: '#ff9966' }}>docker compose logs boot-audit-api</code>
        </div>
      </div>
    </div>
  )
}
