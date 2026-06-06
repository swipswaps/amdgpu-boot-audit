// PATH: src/types.ts
//
// WHAT: TypeScript interfaces matching the boot_audit.db schema and
//       Flask API response shapes exactly.
// WHY:  strong typing catches field name mismatches at compile time
//       rather than at runtime. receipts-ocr README documents "Fixed field
//       name mismatch (total_amount vs total)" as issue #30 — typed
//       interfaces would have caught this at build time.
// Source (Tier 4): swipswaps/receipts-ocr src/types.ts — same pattern.
//   https://github.com/swipswaps/receipts-ocr/blob/main/src/types.ts

// WHAT: maps boot_snapshots table columns verbatim.
// WHY:  field names must match exactly what the Flask /boots endpoint returns.
//       Confirmed schema from boot-audit-db.sh CREATE TABLE statement.
export interface BootSnapshot {
  id: number
  ts: string
  kernel: string | null
  cmdline: string | null
  amdgpu_status: 'bound' | 'failed' | 'partial' | 'absent' | null
  amdgpu_error: string | null
  boot_type: 'cold' | 'warm' | 'unknown' | null
  amdgpu_params: string | null
  simpledrm_active: number  // SQLite stores as 0/1
  connector_name: string | null
  edid_present: number      // SQLite stores as 0/1
  renderer: string | null
  gpu_power_state: string | null
  is_working_state: number  // SQLite stores as 0/1
  shutdown_clean: number    // -1=unknown, 0=hang, 1=clean
  notes: string | null
}

// WHAT: maps working_states table columns.
export interface WorkingState {
  id: number
  snapshot_id: number | null
  ts: string
  kernel: string | null
  cmdline: string | null
  notes: string | null
}

// WHAT: maps known_failures table columns.
export interface KnownFailure {
  id: number
  ts: string
  pattern: string | null
  severity: 'CATASTROPHIC' | 'MODERATE' | 'CONNECTOR' | 'MONITOR'
            | 'USERSPACE' | 'TOPOLOGY' | 'FIRMWARE' | string | null
  category: string | null
  raw_evidence: string | null
}

// WHAT: maps grub_snapshots table columns.
export interface GrubSnapshot {
  id: number
  ts: string
  grub_default: string | null
  grub_cmdline: string | null
  grub_cfg_hash: string | null
  kernel_list: string | null
}

// WHAT: /health endpoint response shape.
export interface HealthResponse {
  status: 'ok' | 'error'
  db_path?: string
  db_exists?: boolean
  row_count?: number
  timestamp?: string
  reason?: string
}

// WHAT: /diff/<id_a>/<id_b> response shape.
export interface DiffField {
  field: string
  boot_a: unknown
  boot_b: unknown
}

export interface DiffSameField {
  field: string
  value: unknown
}

export interface DiffResponse {
  boot_a: { id: number; ts: string }
  boot_b: { id: number; ts: string }
  changed_count: number
  same_count: number
  changed: DiffField[]
  same: DiffSameField[]
}

// WHAT: /prompt/latest response shape.
export interface PromptResponse {
  filename: string
  path: string
  content: string
  char_count: number
}
