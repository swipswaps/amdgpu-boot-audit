// PATH: src/App.tsx
//
// WHAT: root React component — router, nav, offline detection, and all four pages.
//       Aesthetic: terminal/forensic dark theme. Monospace font, amber accent,
//       kernel-log green for healthy status, red for failures.
//       Inspired by the evidence-first debugging methodology in this session.
//
// WHY:  single-file App.tsx for maintainability — four pages are small enough
//       that splitting into separate files adds navigation complexity without
//       benefit. receipts-ocr uses the same approach for its main App.tsx.
//
// MENTAL MODEL BEFORE: user must run CLI commands to see boot history.
// MENTAL MODEL AFTER:  browser dashboard shows boot history, failure patterns,
//       diffs, and the latest AI prompt — all in one place.
//
// Source (Tier 4): swipswaps/receipts-ocr src/App.tsx — component structure.
//   https://github.com/swipswaps/receipts-ocr/blob/main/src/App.tsx
// Source (Tier 2): react-router-dom docs — BrowserRouter + Routes + Route.
//   https://reactrouter.com/en/main/start/overview

import React, { useState, useEffect, useCallback } from 'react'
import { BrowserRouter, Routes, Route, NavLink, useNavigate } from 'react-router-dom'
import { BASE_PATH, HEALTH_URL, HEALTH_POLL_MS } from './config'
import type { BootSnapshot, KnownFailure, DiffResponse, PromptResponse } from './types'
import { fetchBoots, fetchFailures, fetchDiff, fetchPrompt, fetchBoot } from './services/api'
import { OfflineBanner } from './components/OfflineBanner'

// ─── Colour helpers ──────────────────────────────────────────────────────────

// WHAT: map amdgpu_status values to colour tokens for the boot history table.
// WHY:  at-a-glance colour coding is the primary UX value of the dashboard.
//       green=healthy, red=failed, orange=partial/absent.
function statusColor(status: BootSnapshot['amdgpu_status']): string {
  switch (status) {
    case 'bound':   return '#00ff88'
    case 'failed':  return '#ff4444'
    case 'partial': return '#ffaa00'
    case 'absent':  return '#ff7700'
    default:        return '#666'
  }
}

function severityColor(sev: string | null): string {
  switch (sev) {
    case 'CATASTROPHIC': return '#ff2222'
    case 'MODERATE':     return '#ff8800'
    case 'CONNECTOR':    return '#ffcc00'
    case 'MONITOR':      return '#88aaff'
    case 'USERSPACE':    return '#aa88ff'
    default:             return '#666'
  }
}

// ─── Shared CSS-in-JS tokens ─────────────────────────────────────────────────

const MONO = "'JetBrains Mono', 'Fira Code', monospace"
const SANS = "'Space Grotesk', system-ui, sans-serif"
const BG = '#0a0a0f'
const SURFACE = '#111118'
const BORDER = '#222233'
const AMBER = '#ffb800'
const TEXT = '#ccccdd'

const cardStyle: React.CSSProperties = {
  background: SURFACE,
  border: `1px solid ${BORDER}`,
  borderRadius: '8px',
  padding: '20px',
  marginBottom: '16px',
}

const labelStyle: React.CSSProperties = {
  fontFamily: MONO,
  fontSize: '11px',
  color: '#555577',
  letterSpacing: '0.12em',
  textTransform: 'uppercase',
  marginBottom: '4px',
}

const valueStyle: React.CSSProperties = {
  fontFamily: MONO,
  fontSize: '13px',
  color: TEXT,
  wordBreak: 'break-all',
}

// ─── Offline detection hook ───────────────────────────────────────────────────

// WHAT: polls /health every HEALTH_POLL_MS and returns {isOnline, rowCount}.
// WHY:  lets the app react to Docker starting/stopping without page reload.
//       mirrors receipts-ocr dockerHealthService.ts — "Health monitoring with
//       pause during OCR."
// Source (Tier 2): React docs — useEffect for side effects with cleanup.
//   https://react.dev/reference/react/useEffect
function useDockerStatus(): { isOnline: boolean; rowCount: number } {
  console.log('[useDockerStatus] ENTER')
  const [isOnline, setIsOnline] = useState(false)
  const [rowCount, setRowCount] = useState(0)

  const check = useCallback(async () => {
    console.log('[useDockerStatus] checking health...')
    try {
      const res = await fetch(HEALTH_URL)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.json()
      console.log('[useDockerStatus] online: row_count=', data.row_count)
      setIsOnline(true)
      setRowCount(data.row_count ?? 0)
    } catch (err) {
      console.log('[useDockerStatus] offline:', err)
      setIsOnline(false)
    }
  }, [])

  useEffect(() => {
    console.log('[useDockerStatus] starting poll interval')
    check()
    const interval = setInterval(check, HEALTH_POLL_MS)
    return () => {
      console.log('[useDockerStatus] cleanup: clearing interval')
      clearInterval(interval)
    }
  }, [check])

  return { isOnline, rowCount }
}

// ─── Page: Boot History ───────────────────────────────────────────────────────

function BootHistoryPage(): React.ReactElement {
  console.log('[BootHistoryPage] ENTER render')
  const [boots, setBoots] = useState<BootSnapshot[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const navigate = useNavigate()

  useEffect(() => {
    console.log('[BootHistoryPage] ENTER useEffect: fetching boots')
    setLoading(true)
    fetchBoots()
      .then(data => {
        console.log('[BootHistoryPage] EXIT fetchBoots: count=', data.length)
        setBoots(data)
        setError(null)
      })
      .catch(err => {
        console.error('[BootHistoryPage] ERROR fetchBoots:', err)
        setError(String(err))
      })
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <div style={{ color: AMBER, fontFamily: MONO, padding: '20px' }}>loading boot history...</div>
  if (error)   return <div style={{ color: '#ff4444', fontFamily: MONO, padding: '20px' }}>ERROR: {error}</div>

  return (
    <div>
      <h2 style={{ fontFamily: SANS, color: AMBER, fontSize: '18px', marginBottom: '20px', fontWeight: 600 }}>
        Boot History <span style={{ color: '#444', fontWeight: 400 }}>({boots.length} records)</span>
      </h2>

      {boots.map(b => (
        <div key={b.id} style={{
          ...cardStyle,
          cursor: 'pointer',
          borderColor: b.amdgpu_status === 'failed' ? '#ff444433' : BORDER,
          transition: 'border-color 0.15s',
        }}
          onClick={() => {
            console.log('[BootHistoryPage] click: boot id=', b.id)
            navigate(`/diff?a=${b.id}`)
          }}
          onMouseEnter={e => (e.currentTarget.style.borderColor = AMBER + '66')}
          onMouseLeave={e => (e.currentTarget.style.borderColor = b.amdgpu_status === 'failed' ? '#ff444433' : BORDER)}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: '8px' }}>
            <div style={{ display: 'flex', gap: '16px', alignItems: 'center' }}>
              <span style={{ fontFamily: MONO, fontSize: '12px', color: '#444' }}>#{b.id}</span>
              <span style={{
                fontFamily: MONO,
                fontSize: '12px',
                color: statusColor(b.amdgpu_status),
                fontWeight: 700,
                letterSpacing: '0.05em',
              }}>
                {b.amdgpu_status?.toUpperCase() ?? 'UNKNOWN'}
              </span>
              {b.is_working_state === 1 && (
                <span style={{ color: '#ffcc00', fontSize: '12px' }} title="marked as working state">★</span>
              )}
              <span style={{ fontFamily: MONO, fontSize: '11px', color: '#446' }}>
                {b.boot_type}
              </span>
            </div>
            <span style={{ fontFamily: MONO, fontSize: '11px', color: '#444' }}>
              {b.ts?.replace('T', ' ').slice(0, 19)}
            </span>
          </div>

          <div style={{ marginTop: '12px', display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '8px' }}>
            <div>
              <div style={labelStyle}>kernel</div>
              <div style={{ ...valueStyle, fontSize: '12px' }}>{b.kernel ?? '—'}</div>
            </div>
            <div>
              <div style={labelStyle}>renderer</div>
              <div style={{ ...valueStyle, fontSize: '11px', color: '#889' }}>
                {b.renderer?.slice(0, 60) ?? '—'}
              </div>
            </div>
            <div>
              <div style={labelStyle}>connector</div>
              <div style={{ ...valueStyle, fontSize: '11px' }}>
                {b.connector_name?.split(';').filter(Boolean).join(', ') ?? '—'}
              </div>
            </div>
            <div>
              <div style={labelStyle}>gpu power</div>
              <div style={{ ...valueStyle, fontSize: '12px', color: b.gpu_power_state === 'D0' ? '#00ff88' : '#ff7700' }}>
                {b.gpu_power_state ?? '—'}
              </div>
            </div>
          </div>

          {b.amdgpu_error && (
            <div style={{
              marginTop: '12px',
              padding: '8px 12px',
              background: '#1a0505',
              border: '1px solid #ff222233',
              borderRadius: '4px',
              fontFamily: MONO,
              fontSize: '11px',
              color: '#ff8888',
            }}>
              {b.amdgpu_error.split('|').filter(Boolean).map((e, i) => (
                <div key={i}>{e}</div>
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  )
}

// ─── Page: Diff ───────────────────────────────────────────────────────────────

function DiffPage(): React.ReactElement {
  console.log('[DiffPage] ENTER render')
  const [idA, setIdA] = useState('')
  const [idB, setIdB] = useState('')
  const [diff, setDiff] = useState<DiffResponse | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Pre-fill from query params (?a=N)
  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const a = params.get('a')
    if (a) {
      console.log('[DiffPage] pre-fill from query param: a=', a)
      setIdA(a)
    }
  }, [])

  const runDiff = useCallback(async () => {
    const a = parseInt(idA), b = parseInt(idB)
    if (isNaN(a) || isNaN(b)) {
      setError('Enter two valid integer boot IDs')
      return
    }
    console.log('[DiffPage] ENTER runDiff: a=', a, 'b=', b)
    setLoading(true)
    setError(null)
    try {
      const result = await fetchDiff(a, b)
      console.log('[DiffPage] EXIT runDiff: changed=', result.changed_count)
      setDiff(result)
    } catch (err) {
      console.error('[DiffPage] ERROR runDiff:', err)
      setError(String(err))
    } finally {
      setLoading(false)
    }
  }, [idA, idB])

  const inputStyle: React.CSSProperties = {
    background: '#0d0d15',
    border: `1px solid ${BORDER}`,
    borderRadius: '4px',
    padding: '8px 12px',
    color: TEXT,
    fontFamily: MONO,
    fontSize: '14px',
    width: '80px',
  }

  return (
    <div>
      <h2 style={{ fontFamily: SANS, color: AMBER, fontSize: '18px', marginBottom: '20px', fontWeight: 600 }}>
        Boot Diff
      </h2>

      <div style={{ ...cardStyle, display: 'flex', gap: '16px', alignItems: 'center', flexWrap: 'wrap' }}>
        <div>
          <div style={labelStyle}>Boot ID A</div>
          <input style={inputStyle} value={idA}
            onChange={e => { console.log('[DiffPage] idA changed:', e.target.value); setIdA(e.target.value) }}
            placeholder="e.g. 1" />
        </div>
        <div style={{ color: '#444', fontFamily: MONO, fontSize: '18px', paddingTop: '20px' }}>↔</div>
        <div>
          <div style={labelStyle}>Boot ID B</div>
          <input style={inputStyle} value={idB}
            onChange={e => { console.log('[DiffPage] idB changed:', e.target.value); setIdB(e.target.value) }}
            placeholder="e.g. 2" />
        </div>
        <button
          onClick={runDiff}
          disabled={loading}
          style={{
            marginTop: '20px',
            background: AMBER,
            color: '#000',
            border: 'none',
            borderRadius: '4px',
            padding: '8px 20px',
            fontFamily: MONO,
            fontSize: '13px',
            fontWeight: 700,
            cursor: loading ? 'wait' : 'pointer',
          }}>
          {loading ? 'comparing...' : 'DIFF'}
        </button>
      </div>

      {error && <div style={{ color: '#ff4444', fontFamily: MONO, fontSize: '13px', marginBottom: '16px' }}>{error}</div>}

      {diff && (
        <div>
          <div style={{ fontFamily: MONO, fontSize: '12px', color: '#444', marginBottom: '12px' }}>
            Boot #{diff.boot_a.id} ({diff.boot_a.ts?.slice(0,19)})
            {' ↔ '}
            Boot #{diff.boot_b.id} ({diff.boot_b.ts?.slice(0,19)})
            {' — '}
            <span style={{ color: diff.changed_count > 0 ? '#ff8800' : '#00ff88' }}>
              {diff.changed_count} changed
            </span>
            {', '}
            <span style={{ color: '#444' }}>{diff.same_count} same</span>
          </div>

          {diff.changed.length > 0 && (
            <div style={cardStyle}>
              <div style={{ ...labelStyle, marginBottom: '12px' }}>Changed Fields</div>
              {diff.changed.map(f => (
                <div key={f.field} style={{
                  display: 'grid',
                  gridTemplateColumns: '160px 1fr 1fr',
                  gap: '8px',
                  padding: '8px 0',
                  borderBottom: `1px solid ${BORDER}`,
                  alignItems: 'start',
                }}>
                  <div style={{ fontFamily: MONO, fontSize: '12px', color: AMBER }}>{f.field}</div>
                  <div style={{ fontFamily: MONO, fontSize: '11px', color: '#ff8888' }}>
                    <div style={{ color: '#445', fontSize: '10px', marginBottom: '2px' }}>A</div>
                    {String(f.boot_a ?? '—')}
                  </div>
                  <div style={{ fontFamily: MONO, fontSize: '11px', color: '#88ff88' }}>
                    <div style={{ color: '#445', fontSize: '10px', marginBottom: '2px' }}>B</div>
                    {String(f.boot_b ?? '—')}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// ─── Page: Failures ───────────────────────────────────────────────────────────

function FailuresPage(): React.ReactElement {
  console.log('[FailuresPage] ENTER render')
  const [failures, setFailures] = useState<KnownFailure[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    console.log('[FailuresPage] ENTER useEffect: fetching failures')
    fetchFailures()
      .then(data => {
        console.log('[FailuresPage] EXIT fetchFailures: count=', data.length)
        setFailures(data)
        setError(null)
      })
      .catch(err => {
        console.error('[FailuresPage] ERROR fetchFailures:', err)
        setError(String(err))
      })
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <div style={{ color: AMBER, fontFamily: MONO, padding: '20px' }}>loading failure patterns...</div>
  if (error)   return <div style={{ color: '#ff4444', fontFamily: MONO, padding: '20px' }}>ERROR: {error}</div>

  return (
    <div>
      <h2 style={{ fontFamily: SANS, color: AMBER, fontSize: '18px', marginBottom: '20px', fontWeight: 600 }}>
        Known Failures <span style={{ color: '#444', fontWeight: 400 }}>({failures.length} detected)</span>
      </h2>

      {failures.length === 0 && (
        <div style={{ ...cardStyle, color: '#00ff88', fontFamily: MONO, fontSize: '13px' }}>
          ✓ No failure patterns detected in the database.
        </div>
      )}

      {failures.map(f => (
        <div key={f.id} style={{
          ...cardStyle,
          borderLeft: `3px solid ${severityColor(f.severity)}`,
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '12px' }}>
            <span style={{
              fontFamily: MONO,
              fontSize: '11px',
              fontWeight: 700,
              color: severityColor(f.severity),
              letterSpacing: '0.1em',
              background: severityColor(f.severity) + '22',
              padding: '2px 8px',
              borderRadius: '3px',
            }}>
              {f.severity ?? 'UNKNOWN'}
            </span>
            <span style={{ fontFamily: MONO, fontSize: '10px', color: '#444' }}>
              {f.ts?.replace('T', ' ').slice(0, 19)}
            </span>
          </div>

          <div style={{ fontFamily: SANS, fontSize: '14px', color: TEXT, marginBottom: '8px' }}>
            {f.category}
          </div>

          {f.raw_evidence && (
            <pre style={{
              background: '#0a0a0a',
              border: `1px solid ${BORDER}`,
              borderRadius: '4px',
              padding: '10px',
              fontFamily: MONO,
              fontSize: '11px',
              color: '#888',
              overflowX: 'auto',
              margin: 0,
            }}>
              {f.raw_evidence.split('|').filter(Boolean).join('\n')}
            </pre>
          )}
        </div>
      ))}
    </div>
  )
}

// ─── Page: Prompt ─────────────────────────────────────────────────────────────

function PromptPage(): React.ReactElement {
  console.log('[PromptPage] ENTER render')
  const [prompt, setPrompt] = useState<PromptResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    console.log('[PromptPage] ENTER useEffect: fetching prompt')
    fetchPrompt()
      .then(data => {
        console.log('[PromptPage] EXIT fetchPrompt: chars=', data.char_count)
        setPrompt(data)
        setError(null)
      })
      .catch(err => {
        console.error('[PromptPage] ERROR fetchPrompt:', err)
        setError(String(err))
      })
      .finally(() => setLoading(false))
  }, [])

  const copyPrompt = useCallback(async () => {
    if (!prompt) return
    console.log('[PromptPage] ENTER copyPrompt: chars=', prompt.char_count)
    await navigator.clipboard.writeText(prompt.content)
    setCopied(true)
    console.log('[PromptPage] EXIT copyPrompt: copied to clipboard')
    setTimeout(() => setCopied(false), 2000)
  }, [prompt])

  if (loading) return <div style={{ color: AMBER, fontFamily: MONO, padding: '20px' }}>loading prompt...</div>

  if (error) return (
    <div>
      <h2 style={{ fontFamily: SANS, color: AMBER, fontSize: '18px', marginBottom: '20px', fontWeight: 600 }}>
        Diagnostic Prompt
      </h2>
      <div style={{ ...cardStyle, color: '#ff8866', fontFamily: MONO, fontSize: '13px' }}>
        {error.includes('no prompt files') ? (
          <>
            <div>No prompt files found yet.</div>
            <div style={{ marginTop: '8px', color: '#666' }}>Generate one:</div>
            <pre style={{
              marginTop: '8px', background: '#0d0d0d', border: `1px solid ${BORDER}`,
              borderRadius: '4px', padding: '10px', color: '#88ff88', fontSize: '12px',
            }}>bash boot-audit-db.sh --prompt-only</pre>
          </>
        ) : error}
      </div>
    </div>
  )

  return (
    <div>
      <h2 style={{ fontFamily: SANS, color: AMBER, fontSize: '18px', marginBottom: '4px', fontWeight: 600 }}>
        Diagnostic Prompt
      </h2>
      <div style={{ fontFamily: MONO, fontSize: '11px', color: '#444', marginBottom: '20px' }}>
        {prompt?.filename} — {prompt?.char_count?.toLocaleString()} chars
      </div>

      <div style={{ marginBottom: '16px' }}>
        <button
          onClick={copyPrompt}
          style={{
            background: copied ? '#00ff88' : AMBER,
            color: '#000',
            border: 'none',
            borderRadius: '4px',
            padding: '10px 24px',
            fontFamily: MONO,
            fontSize: '13px',
            fontWeight: 700,
            cursor: 'pointer',
            transition: 'background 0.2s',
          }}>
          {copied ? '✓ COPIED' : 'COPY TO CLIPBOARD'}
        </button>
        <span style={{ marginLeft: '12px', fontFamily: MONO, fontSize: '11px', color: '#444' }}>
          Paste into a new Claude session to start diagnosis
        </span>
      </div>

      <pre style={{
        background: SURFACE,
        border: `1px solid ${BORDER}`,
        borderRadius: '8px',
        padding: '20px',
        fontFamily: MONO,
        fontSize: '11px',
        color: '#889',
        overflowX: 'auto',
        overflowY: 'auto',
        maxHeight: '60vh',
        lineHeight: '1.6',
        whiteSpace: 'pre-wrap',
        wordBreak: 'break-word',
      }}>
        {prompt?.content}
      </pre>
    </div>
  )
}

// ─── Nav + Layout ─────────────────────────────────────────────────────────────

function NavBar(): React.ReactElement {
  console.log('[NavBar] ENTER render')
  const linkStyle = ({ isActive }: { isActive: boolean }): React.CSSProperties => ({
    fontFamily: MONO,
    fontSize: '12px',
    letterSpacing: '0.08em',
    color: isActive ? AMBER : '#556',
    textDecoration: 'none',
    padding: '6px 14px',
    borderRadius: '4px',
    background: isActive ? AMBER + '15' : 'transparent',
    transition: 'color 0.15s, background 0.15s',
  })

  return (
    <nav style={{
      background: SURFACE,
      borderBottom: `1px solid ${BORDER}`,
      padding: '0 24px',
      display: 'flex',
      alignItems: 'center',
      gap: '4px',
      height: '48px',
    }}>
      <span style={{
        fontFamily: MONO,
        fontSize: '13px',
        color: AMBER,
        fontWeight: 700,
        marginRight: '24px',
        letterSpacing: '0.04em',
      }}>
        ⚡ amdgpu-boot-audit
      </span>
      <NavLink to="/"        style={linkStyle} end>BOOTS</NavLink>
      <NavLink to="/diff"    style={linkStyle}>DIFF</NavLink>
      <NavLink to="/failures" style={linkStyle}>FAILURES</NavLink>
      <NavLink to="/prompt"  style={linkStyle}>PROMPT</NavLink>
    </nav>
  )
}

// ─── Root ─────────────────────────────────────────────────────────────────────

export default function App(): React.ReactElement {
  console.log('[App] ENTER render')
  const { isOnline, rowCount } = useDockerStatus()

  return (
    <BrowserRouter basename={BASE_PATH}>
      <div style={{ minHeight: '100vh', background: BG, color: TEXT }}>
        <NavBar />
        <main style={{ maxWidth: '1100px', margin: '0 auto', padding: '32px 24px' }}>
          {!isOnline && <OfflineBanner lastRowCount={rowCount} />}
          <Routes>
            <Route path="/"         element={<BootHistoryPage />} />
            <Route path="/diff"     element={<DiffPage />} />
            <Route path="/failures" element={<FailuresPage />} />
            <Route path="/prompt"   element={<PromptPage />} />
          </Routes>
        </main>
        <footer style={{
          textAlign: 'center',
          padding: '20px',
          fontFamily: MONO,
          fontSize: '10px',
          color: '#333',
          borderTop: `1px solid ${BORDER}`,
          marginTop: '40px',
        }}>
          amdgpu-boot-audit — evidence-first GPU diagnostics for Fedora
        </footer>
      </div>
    </BrowserRouter>
  )
}
