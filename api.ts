// PATH: src/services/api.ts
//
// WHAT: centralised API client — all fetch() calls to the local Docker backend.
//       Every function logs entry, exit, and elapsed time to the browser console.
//
// WHY:  Rule L requires every function to log entry and exit.
//       Centralising all fetch calls means error handling is consistent
//       and the offline state is detected in one place.
//       Mirrors receipts-ocr src/services/ocrService.ts pattern.
//
// FAILURE MODE: if Docker is not running, every function throws an Error
//   with message "Failed to fetch". The caller (useApi hook) catches this
//   and sets isOffline=true.
//
// VERIFIES WITH: browser console shows "[api] ENTER fetchBoots" and
//   "[api] EXIT fetchBoots: count=2 elapsed=12ms" on page load.
//
// Source (Tier 4): swipswaps/receipts-ocr src/services/ocrService.ts — fetch pattern.
//   https://github.com/swipswaps/receipts-ocr/blob/main/src/services/ocrService.ts
// Source (Tier 2): MDN Fetch API — "fetch() returns a Promise."
//   https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API

import { API_BASE } from '../config'
import type {
  BootSnapshot, WorkingState, KnownFailure,
  HealthResponse, DiffResponse, PromptResponse, GrubSnapshot,
} from '../types'

const TAG = '[api]'

// WHAT: generic fetch helper with timing, logging, and error surfacing.
// WHY:  avoids repeating try/catch and JSON parse in every function.
//       Error messages from the Flask backend are surfaced verbatim.
// FAILURE MODE: throws Error on non-ok HTTP status or network failure.
//   Error message includes HTTP status and URL for debuggability.
// Source (Tier 2): MDN Response.ok — "true if status is 200-299."
//   https://developer.mozilla.org/en-US/docs/Web/API/Response/ok
async function apiFetch<T>(path: string): Promise<T> {
  console.log(`${TAG} ENTER apiFetch: path=${path}`)
  const t0 = performance.now()
  const url = `${API_BASE}${path}`

  const res = await fetch(url)
  if (!res.ok) {
    const body = await res.text()
    throw new Error(`HTTP ${res.status} from ${url}: ${body}`)
  }
  const data = await res.json() as T
  const elapsed = Math.round(performance.now() - t0)
  console.log(`${TAG} EXIT apiFetch: path=${path} elapsed=${elapsed}ms`)
  return data
}

// WHAT: check if the local Docker backend is running and DB is readable.
// WHY:  the frontend polls this every HEALTH_POLL_MS to show/hide the
//       offline banner without requiring a page reload.
// VERIFIES WITH: returns {status:"ok",row_count:N} when Docker is running.
export async function fetchHealth(): Promise<HealthResponse> {
  console.log(`${TAG} ENTER fetchHealth`)
  const t0 = performance.now()
  const result = await apiFetch<HealthResponse>('/health')
  console.log(`${TAG} EXIT fetchHealth: status=${result.status} elapsed=${Math.round(performance.now()-t0)}ms`)
  return result
}

// WHAT: fetch all boot snapshots, newest first.
// VERIFIES WITH: returns array with at least 2 rows (from document 18).
export async function fetchBoots(): Promise<BootSnapshot[]> {
  console.log(`${TAG} ENTER fetchBoots`)
  const t0 = performance.now()
  const data = await apiFetch<{ boots: BootSnapshot[]; count: number }>('/boots')
  console.log(`${TAG} EXIT fetchBoots: count=${data.count} elapsed=${Math.round(performance.now()-t0)}ms`)
  return data.boots
}

// WHAT: fetch a single boot snapshot by ID.
export async function fetchBoot(id: number): Promise<BootSnapshot> {
  console.log(`${TAG} ENTER fetchBoot: id=${id}`)
  const t0 = performance.now()
  const result = await apiFetch<BootSnapshot>(`/boots/${id}`)
  console.log(`${TAG} EXIT fetchBoot: id=${id} status=${result.amdgpu_status} elapsed=${Math.round(performance.now()-t0)}ms`)
  return result
}

// WHAT: fetch all working_states rows.
export async function fetchWorking(): Promise<WorkingState[]> {
  console.log(`${TAG} ENTER fetchWorking`)
  const t0 = performance.now()
  const data = await apiFetch<{ working_states: WorkingState[]; count: number }>('/working')
  console.log(`${TAG} EXIT fetchWorking: count=${data.count} elapsed=${Math.round(performance.now()-t0)}ms`)
  return data.working_states
}

// WHAT: fetch all known_failures rows.
export async function fetchFailures(): Promise<KnownFailure[]> {
  console.log(`${TAG} ENTER fetchFailures`)
  const t0 = performance.now()
  const data = await apiFetch<{ failures: KnownFailure[]; count: number }>('/failures')
  console.log(`${TAG} EXIT fetchFailures: count=${data.count} elapsed=${Math.round(performance.now()-t0)}ms`)
  return data.failures
}

// WHAT: diff two boot snapshots by ID pair.
export async function fetchDiff(idA: number, idB: number): Promise<DiffResponse> {
  console.log(`${TAG} ENTER fetchDiff: idA=${idA} idB=${idB}`)
  const t0 = performance.now()
  const result = await apiFetch<DiffResponse>(`/diff/${idA}/${idB}`)
  console.log(`${TAG} EXIT fetchDiff: changed=${result.changed_count} elapsed=${Math.round(performance.now()-t0)}ms`)
  return result
}

// WHAT: fetch the latest generated diagnostic prompt file contents.
export async function fetchPrompt(): Promise<PromptResponse> {
  console.log(`${TAG} ENTER fetchPrompt`)
  const t0 = performance.now()
  const result = await apiFetch<PromptResponse>('/prompt/latest')
  console.log(`${TAG} EXIT fetchPrompt: chars=${result.char_count} elapsed=${Math.round(performance.now()-t0)}ms`)
  return result
}

// WHAT: fetch all GRUB snapshots.
export async function fetchGrub(): Promise<GrubSnapshot[]> {
  console.log(`${TAG} ENTER fetchGrub`)
  const t0 = performance.now()
  const data = await apiFetch<{ grub_snapshots: GrubSnapshot[]; count: number }>('/grub')
  console.log(`${TAG} EXIT fetchGrub: count=${data.count} elapsed=${Math.round(performance.now()-t0)}ms`)
  return data.grub_snapshots
}
