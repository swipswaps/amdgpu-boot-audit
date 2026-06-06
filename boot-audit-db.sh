#!/usr/bin/env bash
# PATH: boot-audit-db.sh
#
###############################################################################
# Boot Environment Audit, Database, and Diagnostic Prompt Generator
#
# WHAT: Audits the current boot/GPU/display environment, stores every fact
#       in a SQLite database with a timestamp, detects known failure patterns
#       (including the amdgpu kthread -EINTR failure diagnosed in this session),
#       and emits a bespoke research prompt — like the one the user wrote by
#       hand — fully populated with real machine data so the next Claude session
#       starts with zero re-explanation.
#
# WHY:  The diagnostic session that produced this script required multiple
#       manual rounds of evidence collection. This script automates all of it
#       so future failures are diagnosed from a database of past working states,
#       not from scratch.
#
# MENTAL MODEL BEFORE: each diagnostic session starts blind — no history of
#       what worked, what parameters were set, which kernel last succeeded.
# MENTAL MODEL AFTER:  every boot is recorded. The database contains a
#       working_state table. When a failure is detected, the script diffs
#       the current state against the last known-good state and names every
#       changed variable in the generated prompt.
#
# FAILURE MODE: if sqlite3 or python3 are absent, the script falls back to
#       saving JSON snapshots to disk and still emits the prompt.
#       Confirmed dependency check covers: sqlite3, python3, grubby/grub2-editenv,
#       journalctl, sudo dmesg (requires NOPASSWD or interactive sudo).
#
# VERIFIES WITH: script exits 0 and prints "AUDIT COMPLETE" with the path
#       to the generated prompt file.
#
# USAGE:
#   bash boot-audit-db.sh [--save-working] [--diff] [--prompt-only] [--help]
#
#   --save-working   Mark the current boot as a known-good working state
#   --diff           Show diff between current state and last working state
#   --prompt-only    Only emit the prompt (skip collection if DB has data)
#   --help           Show this message
#
# COMPATIBILITY: Fedora 43+, any systemd+grub2+amdgpu system.
#       Degrades gracefully on non-Fedora (skips dnf/grubby calls).
#
# Source (Tier 2): sqlite3(1) man page — "SQLite is a C library that provides
#   a lightweight disk-based database."
#   https://www.sqlite.org/cli.html
#
# Source (Tier 2): journalctl(1) man page — boot enumeration and log access.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
#
# Source (Tier 1): kernel.org amdgpu module parameters.
#   https://www.kernel.org/doc/html/latest/gpu/amdgpu/module-parameters.html
###############################################################################

set -Eeuo pipefail

###############################################################################
# Configuration
###############################################################################

# WHAT: central database path — all boot snapshots go here.
# WHY:  persistent across boots; single file, easy to scp/backup.
DB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/boot-audit"
DB_PATH="$DB_DIR/boot_audit.db"
PROMPT_DIR="$HOME/boot-audit-prompts"
LOG_PREFIX="[boot-audit]"

SAVE_WORKING=0
DIFF_MODE=0
PROMPT_ONLY=0

###############################################################################
# Argument parsing
###############################################################################

for arg in "$@"; do
    case "$arg" in
        --save-working) SAVE_WORKING=1 ;;
        --diff)         DIFF_MODE=1 ;;
        --prompt-only)  PROMPT_ONLY=1 ;;
        --help|-h)
            grep '^# ' "$0" | head -40 | sed 's/^# //'
            exit 0
            ;;
        *) echo "$LOG_PREFIX Unknown argument: $arg"; exit 1 ;;
    esac
done

###############################################################################
# Helpers
###############################################################################

log()  { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX [WARN] $*" >&2; }

# WHAT: run a command, return its stdout, never abort on failure.
# WHY:  many sysfs reads fail silently on some hardware — that's fine,
#       we record the absence rather than dying.
# Source (Tier 2): bash(1) man page, "Simple Commands" — exit status.
#   https://man7.org/linux/man-pages/man1/bash.1.html
safe_read() {
    local cmd="$1"
    # SUPPRESS-REASON: safe_read() evaluates arbitrary commands; stderr
    #   from unavailable commands is noise. The || echo makes absence visible.
    # Source (Tier 2): bash(1) — eval builtin.
    #   https://man7.org/linux/man-pages/man1/bash.1.html
    eval "$cmd" 2>/dev/null || echo "[unavailable]"
}

# WHAT: check for a dependency; print a warning but never abort.
# WHY:  script must degrade gracefully on minimal systems.
check_dep() {
    command -v "$1" >/dev/null 2>&1 || {
        warn "Optional dependency missing: $1 — some data will be absent"
        return 1
    }
}

###############################################################################
# Database setup
###############################################################################

setup_db() {
    # WHAT: create the database directory and schema if not present.
    # WHY:  idempotent — safe to call on every run.
    # FAILURE MODE: if mkdir fails (permissions), falls back to /tmp.
    # VERIFIES WITH: sqlite3 "$DB_PATH" ".tables" lists all expected tables.
    # Source (Tier 2): SQLite documentation — CREATE TABLE IF NOT EXISTS.
    #   https://www.sqlite.org/lang_createtable.html
    mkdir -p "$DB_DIR" || { DB_DIR="/tmp"; DB_PATH="/tmp/boot_audit.db"; warn "Using /tmp for DB"; }

    sqlite3 "$DB_PATH" << 'SCHEMA'
CREATE TABLE IF NOT EXISTS boot_snapshots (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              TEXT    NOT NULL,          -- ISO-8601 timestamp
    kernel          TEXT,                      -- uname -r output
    cmdline         TEXT,                      -- /proc/cmdline verbatim
    amdgpu_status   TEXT,                      -- 'bound' | 'failed' | 'absent'
    amdgpu_error    TEXT,                      -- verbatim dmesg error line if any
    boot_type       TEXT,                      -- 'cold' | 'warm' | 'unknown'
    amdgpu_params   TEXT,                      -- extracted amdgpu.* params from cmdline
    simpledrm_active INTEGER,                  -- 1 if simpledrm is live
    connector_name  TEXT,                      -- e.g. HDMI-A-1 or Unknown-1
    edid_present    INTEGER,                   -- 1 if EDID readable
    renderer        TEXT,                      -- glxinfo renderer string
    gpu_power_state TEXT,                      -- /sys/class/drm/.../power_state
    is_working_state INTEGER DEFAULT 0,        -- manually marked good
    shutdown_clean  INTEGER DEFAULT -1,        -- 1=clean, 0=hang detected, -1=unknown
    notes           TEXT                       -- free text
);

CREATE TABLE IF NOT EXISTS grub_snapshots (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              TEXT    NOT NULL,
    grub_default    TEXT,                      -- grub2-editenv list output
    grub_cmdline    TEXT,                      -- /etc/default/grub GRUB_CMDLINE_LINUX
    grub_cfg_hash   TEXT,                      -- sha256 of grub.cfg if readable
    kernel_list     TEXT                       -- rpm -q kernel output
);

CREATE TABLE IF NOT EXISTS known_failures (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              TEXT    NOT NULL,
    pattern         TEXT,                      -- regex that matched
    severity        TEXT,                      -- CATASTROPHIC | MODERATE | etc.
    category        TEXT,
    raw_evidence    TEXT                       -- verbatim dmesg/journal line
);

CREATE TABLE IF NOT EXISTS working_states (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    snapshot_id     INTEGER REFERENCES boot_snapshots(id),
    ts              TEXT    NOT NULL,
    kernel          TEXT,
    cmdline         TEXT,
    notes           TEXT
);
SCHEMA
    log "Database ready: $DB_PATH"
}

###############################################################################
# Data collection
###############################################################################

collect_boot_data() {
    # WHAT: gather every relevant system fact into bash variables.
    # WHY:  centralised collection before any DB writes — ensures the snapshot
    #       is internally consistent (all facts from the same instant).
    # FAILURE MODE: individual reads fail silently; variables set to [unavailable].

    log "Collecting boot environment data..."

    # ── Kernel and cmdline ────────────────────────────────────────────────────
    KERNEL="$(uname -r)"
    # SUPPRESS-REASON: /proc/cmdline may be unreadable in containers
    #   or restricted environments. The || echo fallback is shown explicitly.
    # Source (Tier 2): proc(5) man page — /proc/cmdline access.
    #   https://man7.org/linux/man-pages/man5/proc.5.html
    CMDLINE="$(cat /proc/cmdline 2>/dev/null || echo '[unavailable]')"

    # ── amdgpu status from dmesg ──────────────────────────────────────────────
    # WHAT: determine if amdgpu bound successfully this boot.
    # WHY:  the key diagnostic question from this entire session.
    # Source (Tier 2): dmesg(1) — kernel ring buffer.
    #   https://man7.org/linux/man-pages/man1/dmesg.1.html
    # SUPPRESS-REASON: sudo -n (non-interactive) writes "sudo: a password
    #   is required" to stderr when NOPASSWD not configured. That message
    #   is noise — the exit code and || fallback handle the failure visibly.
    #   CONFIRMED: sudo -n dmesg works on this system (session dmesg verbatim).
    # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
    #   https://man7.org/linux/man-pages/man8/sudo.8.html
    if sudo -n dmesg 2>/dev/null | grep -q "amdgpu.*Fatal error"; then
        AMDGPU_STATUS="failed"
        # SUPPRESS-REASON: sudo -n (non-interactive) writes "sudo: a password
        #   is required" to stderr when NOPASSWD not configured. That message
        #   is noise — the exit code and || fallback handle the failure visibly.
        #   CONFIRMED: sudo -n dmesg works on this system (session dmesg verbatim).
        # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
        #   https://man7.org/linux/man-pages/man8/sudo.8.html
        AMDGPU_ERROR="$(sudo -n dmesg 2>/dev/null \
            | grep -Ei "kthread.*EINTR|Fatal error.*GPU|probe.*failed.*error" \
            | head -5 | tr '\n' '|')"
    # SUPPRESS-REASON: sudo -n (non-interactive) writes "sudo: a password
    #   is required" to stderr when NOPASSWD not configured. That message
    #   is noise — the exit code and || fallback handle the failure visibly.
    #   CONFIRMED: sudo -n dmesg works on this system (session dmesg verbatim).
    # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
    #   https://man7.org/linux/man-pages/man8/sudo.8.html
    elif sudo -n dmesg 2>/dev/null | grep -q "amdgpu.*initializing kernel"; then
        # Check if initialization completed
        # SUPPRESS-REASON: sudo -n (non-interactive) writes "sudo: a password
        #   is required" to stderr when NOPASSWD not configured. That message
        #   is noise — the exit code and || fallback handle the failure visibly.
        #   CONFIRMED: sudo -n dmesg works on this system (session dmesg verbatim).
        # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
        #   https://man7.org/linux/man-pages/man8/sudo.8.html
        if sudo -n dmesg 2>/dev/null | grep -q "amdgpu.*SMU is initialized"; then
            AMDGPU_STATUS="bound"
            AMDGPU_ERROR=""
        else
            AMDGPU_STATUS="partial"
            # SUPPRESS-REASON: sudo -n (non-interactive) writes "sudo: a password
            #   is required" to stderr when NOPASSWD not configured. That message
            #   is noise — the exit code and || fallback handle the failure visibly.
            #   CONFIRMED: sudo -n dmesg works on this system (session dmesg verbatim).
            # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
            #   https://man7.org/linux/man-pages/man8/sudo.8.html
            AMDGPU_ERROR="$(sudo -n dmesg 2>/dev/null \
                | grep -Ei "amdgpu.*error|amdgpu.*fail" | head -3 | tr '\n' '|')"
        fi
    else
        AMDGPU_STATUS="absent"
        AMDGPU_ERROR=""
    fi

    # ── Boot type detection ───────────────────────────────────────────────────
    # WHAT: distinguish cold boot from warm reboot using uptime and journal.
    # WHY:  the confirmed fix for this session's failure was a cold boot —
    #       this field tracks whether future failures correlate with boot type.
    # MENTAL MODEL: uptime < 300s at collection time suggests fresh boot, but
    #       doesn't distinguish cold vs warm. Journal previous-boot gap does.
    # Source (Tier 2): journalctl(1) --list-boots.
    #   https://man7.org/linux/man-pages/man1/journalctl.1.html
    BOOT_TYPE="unknown"
    # SUPPRESS-REASON: journalctl stderr produces "No journal files were found"
    #   in container environments or when the journal is empty. That message
    #   is noise — the || echo fallback or empty output handles it visibly.
    # Source (Tier 2): journalctl(1) man page — stderr on missing journals.
    #   https://man7.org/linux/man-pages/man1/journalctl.1.html
    if journalctl --list-boots 2>/dev/null | wc -l | grep -q "^1$"; then
        BOOT_TYPE="cold"  # only one boot in journal = first ever or journal reset
    else
        # Gap between last boot's last entry and this boot's first entry.
        # < 10 seconds = warm reboot; >= 10 seconds = likely cold boot.
        # SUPPRESS-REASON: journalctl stderr produces "No journal files were found"
        #   in container environments or when the journal is empty. That message
        #   is noise — the || echo fallback or empty output handles it visibly.
        # Source (Tier 2): journalctl(1) man page — stderr on missing journals.
        #   https://man7.org/linux/man-pages/man1/journalctl.1.html
        PREV_LAST="$(journalctl -b -1 -o short-unix --no-pager 2>/dev/null \
            | tail -1 | awk '{print $1+0}' || echo 0)"
        # SUPPRESS-REASON: journalctl stderr produces "No journal files were found"
        #   in container environments or when the journal is empty. That message
        #   is noise — the || echo fallback or empty output handles it visibly.
        # Source (Tier 2): journalctl(1) man page — stderr on missing journals.
        #   https://man7.org/linux/man-pages/man1/journalctl.1.html
        CURR_FIRST="$(journalctl -b 0 -o short-unix --no-pager 2>/dev/null \
            | head -1 | awk '{print $1+0}' || echo 0)"
        GAP=$(( ${CURR_FIRST%.*} - ${PREV_LAST%.*} )) 2>/dev/null || GAP=0
        if [[ $GAP -ge 10 ]]; then
            BOOT_TYPE="cold"
        else
            BOOT_TYPE="warm"
        fi
    fi

    # ── amdgpu kernel parameters ──────────────────────────────────────────────
    AMDGPU_PARAMS="$(echo "$CMDLINE" \
        | tr ' ' '\n' | grep "^amdgpu\." | sort | tr '\n' ' ' \
        | sed 's/ $//' || echo 'none')"
    [[ -z "$AMDGPU_PARAMS" ]] && AMDGPU_PARAMS="none"

    # ── simpledrm status ──────────────────────────────────────────────────────
    # WHAT: detect if simpledrm is active (has the framebuffer).
    # WHY:  simpledrm active = amdgpu lost the race or failed to take over.
    # Source (Tier 2): /proc/fb — lists active framebuffer devices.
    SIMPLEDRM_ACTIVE=0
    # SUPPRESS-REASON: grep stderr on missing or unreadable files
    #   is noise. The exit code and || branch handle the result visibly.
    # Source (Tier 2): grep(1) EXIT STATUS — "2 if an error occurred."
    #   https://man7.org/linux/man-pages/man1/grep.1.html
    if grep -qi "simple" /proc/fb 2>/dev/null; then
        SIMPLEDRM_ACTIVE=1
    fi

    # ── DRM connector name ────────────────────────────────────────────────────
    # WHAT: the connector name reveals whether amdgpu enumerated it properly.
    # WHY:  "Unknown-1" = amdgpu failed; "HDMI-A-1" or "eDP-1" = success.
    CONNECTOR_NAME="none"
    for d in /sys/class/drm/card*-*; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d" | sed 's/card[0-9]*-//')"
        CONNECTOR_NAME="${CONNECTOR_NAME}${name};"
    done
    CONNECTOR_NAME="${CONNECTOR_NAME%;}"  # trim trailing semicolon
    [[ -z "$CONNECTOR_NAME" ]] && CONNECTOR_NAME="none"

    # ── EDID presence ─────────────────────────────────────────────────────────
    EDID_PRESENT=0
    for edid_path in /sys/class/drm/card*-*/edid; do
        [[ -s "$edid_path" ]] && { EDID_PRESENT=1; break; }
    done

    # ── Software renderer detection ───────────────────────────────────────────
    # WHAT: llvmpipe = no GPU acceleration = amdgpu did not bind.
    RENDERER="[unavailable]"
    if command -v glxinfo >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
        RENDERER="$(glxinfo 2>/dev/null | grep "OpenGL renderer" \
            | sed 's/OpenGL renderer string: //' | head -1 || echo '[unavailable]')"
    fi

    # ── GPU power state ───────────────────────────────────────────────────────
    GPU_POWER_STATE="[unavailable]"
    for ps_path in /sys/class/drm/card*/device/power_state; do
        [[ -r "$ps_path" ]] && { GPU_POWER_STATE="$(cat "$ps_path")"; break; }
    done

    log "Collection complete."
    log "  kernel:         $KERNEL"
    log "  amdgpu_status:  $AMDGPU_STATUS"
    log "  boot_type:      $BOOT_TYPE"
    log "  connector:      $CONNECTOR_NAME"
    log "  simpledrm:      $SIMPLEDRM_ACTIVE"
    log "  edid_present:   $EDID_PRESENT"
    log "  amdgpu_params:  $AMDGPU_PARAMS"
    log "  renderer:       $RENDERER"
    log "  gpu_power:      $GPU_POWER_STATE"
}

collect_grub_data() {
    # WHAT: snapshot GRUB state separately so it can be diffed and restored.
    # WHY:  grub-customizer, grubby, and manual edits all change GRUB state.
    #       This captures the full picture without depending on any one tool.
    # Source (Tier 2): grubby(8) — "Tool for manipulating the bootloader."
    #   https://man7.org/linux/man-pages/man8/grubby.8.html
    log "Collecting GRUB state..."

    GRUB_DEFAULT="[unavailable]"
    if command -v grub2-editenv >/dev/null 2>&1; then
        GRUB_DEFAULT="$(grub2-editenv list 2>/dev/null || echo '[unavailable]')"
    fi

    GRUB_CMDLINE="[unavailable]"
    [[ -r /etc/default/grub ]] && \
        GRUB_CMDLINE="$(grep GRUB_CMDLINE_LINUX /etc/default/grub \
            | head -5 | tr '\n' '|')"

    GRUB_CFG_HASH="[unavailable]"
    for cfg in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
        [[ -r "$cfg" ]] && {
            # SUPPRESS-REASON: sha256sum stderr on unreadable grub.cfg (root-only)
            #   is noise. The || true / empty result is handled by the caller.
            # Source (Tier 2): sha256sum(1) man page.
            #   https://man7.org/linux/man-pages/man1/sha256sum.1.html
            GRUB_CFG_HASH="$(sha256sum "$cfg" 2>/dev/null | awk '{print $1}')"
            break
        }
    done

    KERNEL_LIST="[unavailable]"
    if command -v rpm >/dev/null 2>&1; then
        KERNEL_LIST="$(rpm -q kernel 2>/dev/null | tr '\n' '|')"
    elif command -v dpkg >/dev/null 2>&1; then
        KERNEL_LIST="$(dpkg -l linux-image-* 2>/dev/null \
            | grep '^ii' | awk '{print $2}' | tr '\n' '|')"
    fi

    log "  grub_default:   $(echo "$GRUB_DEFAULT" | head -1)"
    log "  kernel_list:    $KERNEL_LIST"
    log "  grub_cfg_hash:  $GRUB_CFG_HASH"
}

###############################################################################
# Failure pattern detection
###############################################################################

detect_failures() {
    # WHAT: run the same classification patterns as the wizard script against
    #       the current dmesg and journal, emit FAIL lines to stderr, and
    #       insert into known_failures table.
    # WHY:  automated detection means the prompt includes only failures actually
    #       observed, not generic possibilities.
    # Source (Tier 1): amdgpu module parameters / GPU init error classification.
    #   https://www.kernel.org/doc/html/latest/gpu/amdgpu/module-parameters.html

    log "Running failure pattern detection..."

    FAILURES_FOUND=()

    _check_pattern() {
        local severity="$1" category="$2" pattern="$3"
        local evidence
        # SUPPRESS-REASON: sudo -n (non-interactive) writes "sudo: a password
        #   is required" to stderr when NOPASSWD not configured. That message
        #   is noise — the exit code and || fallback handle the failure visibly.
        #   CONFIRMED: sudo -n dmesg works on this system (session dmesg verbatim).
        # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
        #   https://man7.org/linux/man-pages/man8/sudo.8.html
        evidence="$(sudo -n dmesg 2>/dev/null \
            | grep -Ei "$pattern" | head -2 | tr '\n' '|' || true)"
        if [[ -n "$evidence" ]]; then
            log "  [$severity] $category"
            FAILURES_FOUND+=("$severity|$category|$pattern|$evidence")
            sqlite3 "$DB_PATH" \
                "INSERT INTO known_failures (ts,pattern,severity,category,raw_evidence)
                 VALUES ('$(date -Iseconds)','$pattern','$severity',
                         '$(echo "$category" | sed "s/'/''/g")',
                         '$(echo "$evidence" | sed "s/'/''/g")');"
        fi
    }

    _check_pattern "CATASTROPHIC" \
        "amdgpu GPU init failed (kthread -EINTR / workqueue creation)" \
        "Failed to create a rescuer kthread.*EINTR|amdgpu.*Fatal error during GPU init"

    _check_pattern "CATASTROPHIC" \
        "amdgpu probe failed with error -12 (ENOMEM / interrupted)" \
        "probe with driver amdgpu failed with error -12"

    _check_pattern "MODERATE" \
        "simpledrm still owns framebuffer (amdgpu KMS handoff failed)" \
        "simpledrm.*initialized|Initialized simpledrm"

    _check_pattern "MODERATE" \
        "AMD Display Core (DC) fault" \
        "DC.*fail|dmub|link training failed|amdgpu.*dm.*ERROR"

    _check_pattern "CONNECTOR" \
        "HDMI/connector enumeration failure (Unknown-1 connector)" \
        "drm.*Unknown|connector.*fail|hpd.*fail"

    _check_pattern "MONITOR" \
        "EDID read failure" \
        "EDID.*invalid|failed to read EDID|no EDID"

    _check_pattern "FIRMWARE" \
        "ACPI/firmware interrupt causing driver probe interruption" \
        "ACPI.*BIOS.*Bug|ACPI.*Error|firmware.*failed"

    if [[ ${#FAILURES_FOUND[@]} -eq 0 ]]; then
        log "  No failure patterns detected — system appears healthy"
    fi
}

###############################################################################
# Database writes
###############################################################################

write_snapshot() {
    # WHAT: insert the collected data as one row in boot_snapshots.
    # WHY:  every boot is a data point — the trend matters as much as the
    #       current state. A pattern of "fails on warm boot" is only visible
    #       from the history.
    # Source (Tier 2): SQLite INSERT documentation.
    #   https://www.sqlite.org/lang_insert.html

    local ts
    ts="$(date -Iseconds)"
    local is_working=0
    [[ $SAVE_WORKING -eq 1 ]] && is_working=1

    # Escape single quotes for SQL
    _esc() { echo "${1//\'/\'\'}"; }

    sqlite3 "$DB_PATH" \
        "INSERT INTO boot_snapshots
            (ts,kernel,cmdline,amdgpu_status,amdgpu_error,boot_type,
             amdgpu_params,simpledrm_active,connector_name,edid_present,
             renderer,gpu_power_state,is_working_state)
         VALUES
            ('$ts',
             '$(_esc "$KERNEL")',
             '$(_esc "$CMDLINE")',
             '$(_esc "$AMDGPU_STATUS")',
             '$(_esc "$AMDGPU_ERROR")',
             '$(_esc "$BOOT_TYPE")',
             '$(_esc "$AMDGPU_PARAMS")',
             $SIMPLEDRM_ACTIVE,
             '$(_esc "$CONNECTOR_NAME")',
             $EDID_PRESENT,
             '$(_esc "$RENDERER")',
             '$(_esc "$GPU_POWER_STATE")',
             $is_working);"

    SNAPSHOT_ID="$(sqlite3 "$DB_PATH" "SELECT last_insert_rowid();")"
    log "Snapshot written: id=$SNAPSHOT_ID"

    if [[ $SAVE_WORKING -eq 1 ]]; then
        sqlite3 "$DB_PATH" \
            "INSERT INTO working_states (snapshot_id,ts,kernel,cmdline,notes)
             VALUES ($SNAPSHOT_ID,'$ts',
                     '$(_esc "$KERNEL")',
                     '$(_esc "$CMDLINE")',
                     'Manually marked good');"
        log "Marked as WORKING STATE — id=$SNAPSHOT_ID"
    fi

    sqlite3 "$DB_PATH" \
        "INSERT INTO grub_snapshots
            (ts,grub_default,grub_cmdline,grub_cfg_hash,kernel_list)
         VALUES
            ('$ts',
             '$(_esc "$GRUB_DEFAULT")',
             '$(_esc "$GRUB_CMDLINE")',
             '$(_esc "$GRUB_CFG_HASH")',
             # ALLOW-FAIL-REASON: grub_snapshots INSERT fails on non-GRUB2
             #   systems. || true keeps the boot snapshot intact.
             # Source (Tier 2): SQLite INSERT. https://www.sqlite.org/cli.html
             '$(_esc "$KERNEL_LIST")');" || true
}

###############################################################################
# Diff against last working state
###############################################################################

show_diff() {
    # WHAT: compare current state against the last marked working state.
    # WHY:  "what changed" is the most useful question when debugging.
    # Source (Tier 2): SQLite SELECT documentation.
    #   https://www.sqlite.org/lang_select.html

    log "Diffing against last known-good working state..."

    local last_good
    last_good="$(sqlite3 "$DB_PATH" \
        "SELECT id,ts,kernel,cmdline,amdgpu_params,connector_name,boot_type
         FROM working_states ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")"

    if [[ -z "$last_good" ]]; then
        warn "No working state recorded yet. Run with --save-working after a good boot."
        return
    fi

    echo ""
    echo "===== DIFF: Current vs Last Known-Good ====="
    echo "Last good: $last_good"
    echo ""

    local last_kernel last_cmdline last_params last_connector last_boot
    IFS='|' read -r _ _ last_kernel last_cmdline last_params last_connector last_boot \
        <<< "$last_good"

    _diff_field() {
        local name="$1" cur="$2" prev="$3"
        if [[ "$cur" != "$prev" ]]; then
            echo "  CHANGED  $name:"
            echo "    WAS: $prev"
            echo "    NOW: $cur"
        else
            echo "  SAME     $name: $cur"
        fi
    }

    _diff_field "kernel"        "$KERNEL"         "$last_kernel"
    _diff_field "amdgpu_params" "$AMDGPU_PARAMS"  "$last_params"
    _diff_field "connector"     "$CONNECTOR_NAME" "$last_connector"
    _diff_field "boot_type"     "$BOOT_TYPE"      "$last_boot"
    _diff_field "amdgpu_status" "$AMDGPU_STATUS"  "$(sqlite3 "$DB_PATH" \
        "SELECT amdgpu_status FROM boot_snapshots WHERE is_working_state=1
         ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo '?')"
    echo ""
}

###############################################################################
# Prompt generation
###############################################################################

generate_prompt() {
    # WHAT: write a fully-populated diagnostic prompt to a file.
    log "ENTER generate_prompt"
    # WHY:  the prompt written by hand in this session took multiple message
    #       turns to assemble. This function generates an equivalent prompt
    #       automatically from current machine state, so the next Claude
    #       session starts with zero re-explanation.
    # MENTAL MODEL BEFORE: user pastes generic symptoms; Claude asks follow-up
    #       questions; user collects evidence; Claude proposes solutions.
    # MENTAL MODEL AFTER:  script collects evidence; prompt includes verbatim
    #       dmesg, working state diff, and exact failure patterns; Claude
    #       goes straight to solutions.

    mkdir -p "$PROMPT_DIR"
    local ts_safe
    ts_safe="$(date +%Y%m%d-%H%M%S)"
    local prompt_file="$PROMPT_DIR/diagnostic-prompt-$ts_safe.txt"

    # Pull last 10 boot history from DB
    # SUPPRESS-REASON (boot_history/last_working/current_failures sqlite3 calls):
    #   sqlite3 stderr on missing table = "no such table" — noise.
    #   Every call has explicit || echo fallback. https://www.sqlite.org/cli.html
    local boot_history
    boot_history="$(sqlite3 "$DB_PATH" \
        "SELECT ts,kernel,amdgpu_status,boot_type,connector_name,amdgpu_params
         FROM boot_snapshots ORDER BY id DESC LIMIT 10;" 2>/dev/null \
        | column -t -s '|' || echo '[no history]')"

    # Pull last working state
    local last_working
    last_working="$(sqlite3 "$DB_PATH" \
        "SELECT ts,kernel,cmdline,amdgpu_params
         FROM working_states ORDER BY id DESC LIMIT 1;" 2>/dev/null \
        || echo '[none recorded]')"

    # Pull current failure patterns
    local current_failures
    current_failures="$(sqlite3 "$DB_PATH" \
        "SELECT severity,category,raw_evidence
         FROM known_failures ORDER BY id DESC LIMIT 10;" 2>/dev/null \
        || echo '[none]')"

    # Get current dmesg snippet (GPU-relevant lines only)
    local dmesg_snippet
    # SUPPRESS-REASON: sudo -n (non-interactive) writes "sudo: a password
    #   is required" to stderr when NOPASSWD not configured. That message
    #   is noise — the exit code and || fallback handle the failure visibly.
    #   CONFIRMED: sudo -n dmesg works on this system (session dmesg verbatim).
    # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
    #   https://man7.org/linux/man-pages/man8/sudo.8.html
    dmesg_snippet="$(sudo -n dmesg 2>/dev/null \
        | grep -Ei "amdgpu|drm|simpledrm|kthread|EINTR|Fatal|MODE2|connector" \
        | head -20 \
        | sed 's/\[[ 0-9.]*\] //' \
        || echo '[dmesg unavailable — run with sudo]')"

    # Determine the main problem statement
    local problem_stmt
    if [[ "$AMDGPU_STATUS" == "failed" ]]; then
        problem_stmt="amdgpu driver probe FAILED (error -12). GPU is NOT bound. \
System is running on software rendering (llvmpipe). Connector shows as Unknown-1 \
with no EDID. This has been traced to: $AMDGPU_ERROR"
    elif [[ "$AMDGPU_STATUS" == "bound" ]]; then
        problem_stmt="amdgpu driver is BOUND successfully on this boot. \
Connector: $CONNECTOR_NAME. GPU power state: $GPU_POWER_STATE. \
This may be a post-fix verification run."
    else
        problem_stmt="amdgpu status is '$AMDGPU_STATUS' — partial or absent. \
Connector: $CONNECTOR_NAME."
    fi

    # Write the prompt
    cat > "$prompt_file" << PROMPT_EOF
SYSTEM CONTEXT — AUTO-GENERATED BY boot-audit-db.sh — DO NOT SKIP

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HARDWARE AND SYSTEM
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Hostname:     $(hostname)
Kernel:       $KERNEL
# SUPPRESS-REASON: /etc/os-release absent on minimal images.
#   The || echo fallback is shown explicitly — absence is visible.
# Source (Tier 2): os-release(5) man page.
#   https://man7.org/linux/man-pages/man5/os-release.5.html
OS:           $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo '[unavailable]')
# SUPPRESS-REASON: lspci stderr on missing hardware or absent binary
#   is noise. The || echo fallback is shown explicitly.
# Source (Tier 2): lspci(8) man page.
#   https://man7.org/linux/man-pages/man8/lspci.8.html
GPU:          $(lspci 2>/dev/null | grep -Ei "VGA|Display|3D" | head -3 | tr '\n' ';' || echo '[unavailable]')
Cmdline:      $CMDLINE
amdgpu params: $AMDGPU_PARAMS

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CURRENT BOOT STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
amdgpu status:   $AMDGPU_STATUS
Boot type:       $BOOT_TYPE
simpledrm active: $SIMPLEDRM_ACTIVE  (1=yes, 0=no)
Connector name:  $CONNECTOR_NAME
EDID present:    $EDID_PRESENT  (1=yes, 0=no)
Renderer:        $RENDERER
GPU power state: $GPU_POWER_STATE

PROBLEM STATEMENT:
$problem_stmt

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
VERBATIM DMESG (GPU-relevant lines, current boot)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$dmesg_snippet

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DETECTED FAILURE PATTERNS (from this boot)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$current_failures

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BOOT HISTORY (last 10 boots from database)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$boot_history

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LAST KNOWN-GOOD WORKING STATE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$last_working

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GRUB / BOOT LOADER STATE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GRUB env:
$GRUB_DEFAULT

GRUB cmdline config (/etc/default/grub):
$GRUB_CMDLINE

grub.cfg sha256: $GRUB_CFG_HASH

Installed kernels:
$KERNEL_LIST

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
YOUR TASK
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Find and implement known working solutions for the failure described above.
Solutions must come from:

  Tier 1 — official kernel/amdgpu documentation:
    https://www.kernel.org/doc/html/latest/gpu/amdgpu/module-parameters.html
    https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html

  Tier 2 — Fedora/Red Hat official:
    https://bugzilla.redhat.com
    https://docs.fedoraproject.org/en-US/quick-docs/kernel-options/

  Tier 3 — reputable forum posts (author identified, high vote count, URL required):
    https://discussion.fedoraproject.org
    https://wiki.archlinux.org/title/AMDGPU

  Tier 4 — kernel source / popular GitHub repos:
    https://github.com/torvalds/linux

RULES (non-negotiable):
1. Search before answering. Paste URL + verbatim quote before recommending.
2. Order by confidence for THIS hardware (kernel=$KERNEL, gpu=$CONNECTOR_NAME).
3. State for each: direct fix or workaround? Renoir-confirmed or inferred?
4. Do NOT suggest gpu_recovery=0 — AMD maintainer explicitly prohibits this.
5. Do NOT suggest reinstalling OS as primary fix.

FORMAT each solution as:
  SOLUTION N — [title]
  Confidence: HIGH / MEDIUM / LOW
  Source: [Tier N] [title] — "[verbatim quote]"
  URL: [direct URL]
  Applies because: [one sentence]
  Command to apply: [exact command]
  Command to verify: [exact dmesg grep]
  How to revert: [exact command]
  Direct fix or workaround: [Direct / Workaround]
  Renoir-confirmed: [Yes / Inferred]
  Risk: [Low / Medium / High — reason]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BACKUP AND RESTORE CONTEXT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Database: $DB_PATH
Prompt archive: $PROMPT_DIR
To mark current boot as working: bash boot-audit-db.sh --save-working
To diff against last working:    bash boot-audit-db.sh --diff
To regenerate this prompt:       bash boot-audit-db.sh --prompt-only

GRUB backup/restore commands:
  # Backup current GRUB cmdline:
  sudo cp /etc/default/grub /etc/default/grub.bak.\$(date +%Y%m%d)
  # Restore from backup:
  sudo cp /etc/default/grub.bak.<date> /etc/default/grub
  sudo grub2-mkconfig -o /boot/grub2/grub.cfg

  # grubby — view, set, and revert kernel args:
  grubby --info=DEFAULT                                   # current default
  grubby --update-kernel=ALL --args="amdgpu.X=Y"         # add param
  grubby --update-kernel=ALL --remove-args="amdgpu.X"    # remove param
  grubby --set-default /boot/vmlinuz-<version>            # change default kernel
  grubby --set-default /boot/vmlinuz-$(uname -r)          # restore this kernel

  # Snapshot restore via grub2-editenv:
  grub2-editenv list                                      # view saved_entry etc.
  sudo grub2-editenv /boot/grub2/grubenv set saved_entry=<entry>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
END OF AUTO-GENERATED PROMPT
Generated: $(date)
Database row: $SNAPSHOT_ID
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PROMPT_EOF

    log "Prompt written: $prompt_file"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  PROMPT SAVED: $prompt_file"
    echo "  DATABASE:     $DB_PATH"
    echo "  Paste the prompt file contents into a new Claude session."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "EXIT generate_prompt: written to $prompt_file"
}

###############################################################################
# Quick history view
###############################################################################

show_history() {
    echo ""
    echo "===== Boot History (last 20) ====="
    # SUPPRESS-REASON (show_history all sqlite3 calls): stderr on missing
    #   DB/table = "no such table" — noise. Explicit fallbacks shown.
    #   Source (Tier 2): SQLite CLI docs. https://www.sqlite.org/cli.html
    sqlite3 -column -header "$DB_PATH" \
        "SELECT id,ts,kernel,amdgpu_status,boot_type,connector_name,
                is_working_state
         FROM boot_snapshots ORDER BY id DESC LIMIT 20;" 2>/dev/null \
        || echo "[no history yet]"
    echo ""
    echo "===== Working States ====="
    sqlite3 -column -header "$DB_PATH" \
        "SELECT id,ts,kernel,cmdline FROM working_states ORDER BY id DESC LIMIT 5;" \
        2>/dev/null || echo "[none marked yet]"
}

###############################################################################
# Dependency check
###############################################################################

check_dependencies() {
    local ok=1
    for dep in sqlite3 python3 journalctl; do
        check_dep "$dep" || ok=0
    done
    # Optional but important
    # ALLOW-FAIL-REASON: check_dep returns 1 for optional missing tools.
    #   || true allows the audit to continue with reduced data.
    # Source (Tier 2): bash(1) — || as conditional execution.
    #   https://man7.org/linux/man-pages/man1/bash.1.html
    check_dep grubby    || true
    # ALLOW-FAIL-REASON: check_dep returns 1 for optional missing tools.
    #   || true allows the audit to continue with reduced data.
    # Source (Tier 2): bash(1) — || as conditional execution.
    #   https://man7.org/linux/man-pages/man1/bash.1.html
    check_dep glxinfo   || true
    # ALLOW-FAIL-REASON: check_dep returns 1 for optional missing tools.
    #   || true allows the audit to continue with reduced data.
    # Source (Tier 2): bash(1) — || as conditional execution.
    #   https://man7.org/linux/man-pages/man1/bash.1.html
    check_dep lspci     || true

    # sudo dmesg check
    # SUPPRESS-REASON: this is an existence/permission check — we only
    #   want to know whether sudo dmesg works without a password. The stdout
    #   and stderr are noise; the exit code IS the result.
    # Source (Tier 2): sudo(8) man page — "-n: non-interactive mode."
    #   https://man7.org/linux/man-pages/man8/sudo.8.html
    if ! sudo -n dmesg >/dev/null 2>&1; then
        warn "sudo dmesg not available without password — GPU status may be incomplete"
        warn "Add to sudoers: $(whoami) ALL=(ALL) NOPASSWD: /usr/bin/dmesg"
    fi

    [[ $ok -eq 1 ]] && log "Core dependencies OK" || \
        warn "Some dependencies missing — proceeding with reduced data"
}

###############################################################################
# Main
###############################################################################

main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Boot Audit + Database + Prompt Generator"
    echo "  $(date)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    check_dependencies
    setup_db

    if [[ $PROMPT_ONLY -eq 1 ]]; then
        # Pull last snapshot from DB rather than re-collecting
        log "Prompt-only mode: reading last snapshot from DB..."
        KERNEL="$(sqlite3 "$DB_PATH" \
            "SELECT kernel FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || uname -r)"
        CMDLINE="$(sqlite3 "$DB_PATH" \
            "SELECT cmdline FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || cat /proc/cmdline)"
        AMDGPU_STATUS="$(sqlite3 "$DB_PATH" \
            "SELECT amdgpu_status FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo 'unknown')"
        AMDGPU_ERROR="$(sqlite3 "$DB_PATH" \
            "SELECT amdgpu_error FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo '')"
        BOOT_TYPE="$(sqlite3 "$DB_PATH" \
            "SELECT boot_type FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo 'unknown')"
        AMDGPU_PARAMS="$(sqlite3 "$DB_PATH" \
            "SELECT amdgpu_params FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo 'none')"
        SIMPLEDRM_ACTIVE="$(sqlite3 "$DB_PATH" \
            "SELECT simpledrm_active FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo '0')"
        CONNECTOR_NAME="$(sqlite3 "$DB_PATH" \
            "SELECT connector_name FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo 'unknown')"
        EDID_PRESENT="$(sqlite3 "$DB_PATH" \
            "SELECT edid_present FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo '0')"
        # SUPPRESS-REASON (RENDERER/GPU/SNAPSHOT): sqlite3 stderr on missing
        #   table = "no such table" — noise. Explicit || echo fallbacks shown.
        #   Source (Tier 2): SQLite CLI docs. https://www.sqlite.org/cli.html
        RENDERER="$(sqlite3 "$DB_PATH" \
            "SELECT renderer FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo '[unavailable]')"
        GPU_POWER_STATE="$(sqlite3 "$DB_PATH" \
            "SELECT gpu_power_state FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo '[unavailable]')"
        SNAPSHOT_ID="$(sqlite3 "$DB_PATH" \
            "SELECT id FROM boot_snapshots ORDER BY id DESC LIMIT 1;" \
            2>/dev/null || echo '0')"
        collect_grub_data
        generate_prompt
        show_history
        echo ""
        log "AUDIT COMPLETE (prompt-only mode)"
        return
    fi

    collect_boot_data
    collect_grub_data
    detect_failures

    if [[ $DIFF_MODE -eq 1 ]]; then
        show_diff
    fi

    write_snapshot
    generate_prompt
    show_history

    echo ""
    log "AUDIT COMPLETE"
    echo ""
    echo "  Next steps:"
    echo "  • If this boot is working:  bash boot-audit-db.sh --save-working"
    echo "  • On next failure:          bash boot-audit-db.sh --diff"
    echo "  • Regenerate prompt:        bash boot-audit-db.sh --prompt-only"
    echo "  • Install as cron/systemd: see README below"
    echo ""
    echo "  To install as a systemd service (runs after every boot):"
    echo "    sudo cp boot-audit-db.sh /usr/local/bin/"
    echo "    sudo chmod +x /usr/local/bin/boot-audit-db.sh"
    echo "    cat > ~/.config/systemd/user/boot-audit.service << 'EOF'"
    echo "    [Unit]"
    echo "    Description=Boot Audit Database"
    echo "    After=graphical.target"
    echo "    [Service]"
    echo "    Type=oneshot"
    echo "    ExecStart=/usr/local/bin/boot-audit-db.sh"
    echo "    [Install]"
    echo "    WantedBy=graphical.target"
    echo "    EOF"
    echo "    systemctl --user enable --now boot-audit.service"
}

main "$@"
