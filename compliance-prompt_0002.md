# LLM Compliance Enforcement Prompt — amdgpu-boot-audit
# Version: 2
#
# WHAT: Drop-in first message for any Claude session working on this repo.
#       Mechanically prevents the evasion patterns confirmed in this session.
#
# CONFIRMED VIOLATIONS THIS PROMPT FIXES (from session evidence verbatim):
#
#   1. gh-push.sh used `gh auth status 2>/dev/null` — Rule 15 violation.
#      Result: logged-in user was rejected. User output verbatim:
#        "[gh-push] [FAIL] gh CLI not authenticated. Run: gh auth login"
#      while `gh auth status` (without suppression) showed:
#        "✓ Logged in to github.com account swipswaps (keyring)"
#
#   2. install.sh used `systemctl 2>/dev/null` on verification commands —
#      hidden errors made install failures invisible.
#
#   3. Comments lacked FAILURE MODE property — the exact failure that
#      2>/dev/null causes was not documented, so it was not caught.
#
# HOW TO USE:
#   Paste this entire file as your first message in a new Claude session.
#   Then describe your task. Claude must comply with all rules below
#   before writing a single line of code.

---

## MANDATORY RULES — APPLY BEFORE EVERY RESPONSE, NO EXCEPTIONS

### RULE 0 — SELF-CHECK BEFORE EVERY RESPONSE

Silently run this checklist against your draft before delivering.
If any item fails, rewrite. Do not deliver a response that fails any item.
For every item, quote the specific evidence that passes it.
"I believe this passes" is not evidence.

```
SELF-CHECK:
- [ ] Every factual claim traces to explicit context in this conversation
- [ ] Every shell command block starts with # WHY:, # ASSUMES:, # VERIFIES WITH:
- [ ] Every function has all six comment properties (Rule D below)
- [ ] Every 2>/dev/null is JUSTIFIED with a # SUPPRESS-REASON: comment (Rule S)
- [ ] Every || true is JUSTIFIED with a # ALLOW-FAIL-REASON: comment (Rule S)
- [ ] Every code block that changes state emits a log() call (Rule L)
- [ ] Every technical claim has # Source (Tier N): URL + verbatim quote (Rule C)
- [ ] No file patched with sed — Python + assert s.count(old)==1 only (Rule P)
- [ ] No function truncated or uses placeholder (Rule E)
- [ ] Changed regions read back verbatim after every patch (Rule V)
- [ ] Response ends with command block — SELF-CHECK appears before it (Rule 12)
- [ ] Every request component listed as COVERED or NOT COVERED (Rule 23)
- [ ] Pre-delivery suppression audit run (Rule S audit below)
```

---

### RULE S — SUPPRESSION IS A VIOLATION UNLESS EXPLICITLY JUSTIFIED

**The confirmed failure:** `gh auth status 2>/dev/null` hid the success output
that lives on stderr. The script rejected an authenticated user because the
evidence of authentication was suppressed before the check ran.

**The rule:** Every `2>/dev/null`, `>/dev/null`, and `|| true` requires a
`# SUPPRESS-REASON:` or `# ALLOW-FAIL-REASON:` comment immediately above it
stating exactly what output is being suppressed and why showing it would be
wrong. No exceptions.

**The three legitimate categories — all others are violations:**

```
CATEGORY 1 — EXISTENCE CHECK (command -v)
  # SUPPRESS-REASON: command -v produces "not found" on stderr when the
  #   binary is absent — that stderr IS the check result, represented by
  #   the exit code. Showing it would double-report what the if-branch handles.
  if command -v sqlite3 >/dev/null 2>&1; then

CATEGORY 2 — EXPLICIT FALLBACK SHOWN TO USER
  # SUPPRESS-REASON: /proc/cmdline may be unreadable in containers.
  #   The fallback '[unavailable]' is shown in the output — the user
  #   sees the absence explicitly rather than an error message.
  CMDLINE="$(cat /proc/cmdline 2>/dev/null || echo '[unavailable]')"

CATEGORY 3 — NON-INTERACTIVE SUDO (sudo -n)
  # SUPPRESS-REASON: sudo -n stderr produces "sudo: a password is required"
  #   when NOPASSWD is not configured. That message is noise — the exit code
  #   and the || fallback handle the failure path visibly.
  #   CONFIRMED: sudo -n dmesg works on this system (session output verbatim:
  #   "[Fri Jun  5 16:35:26 2026] Linux version 6.19.10...")
  sudo -n dmesg -T 2>/dev/null || journalctl -k -b --no-pager
```

**Verification check — run on every script before delivery:**

```bash
# WHAT: find every suppression without a justification comment.
# WHY:  mechanical check catches what prose self-check misses.
# VERIFIES WITH: zero lines of output = no unjustified suppressions.
grep -n "2>/dev/null\|>/dev/null\||| true" "$script" | while IFS= read -r line; do
    lineno="${line%%:*}"
    prev_lineno=$(( lineno - 1 ))
    prev="$(sed -n "${prev_lineno}p" "$script")"
    if ! echo "$prev" | grep -q "SUPPRESS-REASON\|ALLOW-FAIL-REASON\|command -v\|# WHY"; then
        echo "VIOLATION line $lineno: $line"
        echo "  Previous line: $prev"
    fi
done
```

**Verification commands (gh, systemctl, visudo) must NEVER suppress output:**

```bash
# WRONG — hides the error that tells you what failed:
if ! gh auth status 2>/dev/null; then fail "not authenticated"; fi
if systemctl --user daemon-reload 2>/dev/null; then pass "ok"; fi

# CORRECT — all output visible, failure message includes what was seen:
if ! gh auth status; then fail "not authenticated — see output above"; fi
if systemctl --user daemon-reload; then pass "ok"; else fail "daemon-reload failed — see output above"; fi
```

---

### RULE L — EVERY CODE BLOCK IS LOGGED AND DISPLAYED

Every function, every branch that changes state, every file write, every
command that is not a pure read must emit a `log` line visible in the terminal.

```bash
# WRONG — silent state change:
sqlite3 "$DB_PATH" "INSERT INTO ..."

# CORRECT — logged state change:
log "Writing snapshot to DB: kernel=$KERNEL amdgpu=$AMDGPU_STATUS"
sqlite3 "$DB_PATH" "INSERT INTO ..." \
    && log "DB write OK: $(sqlite3 "$DB_PATH" 'SELECT last_insert_rowid();')" \
    || { log "[FAIL] DB write failed"; return 1; }
```

The `log` function must tee to both terminal AND logfile:

```bash
# CORRECT log function — never suppress, always show:
LOG_FILE="${LOG_FILE:-/tmp/boot-audit-$(date +%Y%m%d-%H%M%S).log}"
log() {
    # SUPPRESS-REASON: none — log is explicitly for display.
    # tee writes to both terminal (stdout) and logfile simultaneously.
    # Source (Tier 2): tee(1) man page — "read from stdin, write to files and stdout"
    #   https://man7.org/linux/man-pages/man1/tee.1.html
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"
}
```

---

### RULE D — SIX COMMENT PROPERTIES, ALL REQUIRED

Every function and every non-trivial block must have all six:

```bash
function_name() {
    # WHAT: <plain-language description of the operation>
    # WHY:  <specific reason grounded in THIS project — not generic>
    # MENTAL MODEL BEFORE: <system state before this runs>
    # MENTAL MODEL AFTER:  <system state after>
    # FAILURE MODE: <what failure looks like — SPECIFICALLY including
    #               what happens if any suppression here hides an error>
    # VERIFIES WITH: <exact output or file that confirms success>
    # Source (Tier N): <title> — "<verbatim quoted sentence>"
    #   <direct URL>

    log "ENTER ${FUNCNAME[0]}: arg1=$1 arg2=${2:-unset}"
    # ... body ...
    log "EXIT ${FUNCNAME[0]}: result=$RESULT"
}
```

The FAILURE MODE property must explicitly state: *"if 2>/dev/null is used here,
the failure will be invisible because..."* whenever suppression is present.

---

### RULE E — EMIT COMPLETE CODE, NO TRUNCATION

Never:
- `# ... rest of function unchanged ...`
- `# TODO`
- `[existing code here]`
- Stopping mid-function
- "Due to length I'll summarise"
- Emitting only the changed section without the surrounding context

Always emit the complete file. If the file is long, emit it in sequential
complete blocks with explicit section markers:

```
# === BLOCK 1 of 3: lines 1-300 ===
[complete code]
# === END BLOCK 1 ===
```

---

### RULE C — EVERY TECHNICAL CLAIM CARRIES A CITATION

Format:
```bash
# Source (Tier N): <title> — "<verbatim quoted sentence from that source>"
#   <direct URL>
```

Tiers:
| Tier | Type | Required |
|------|------|----------|
| 1 | kernel.org official docs | section name, URL |
| 2 | man pages, Fedora/RH docs, BZ | tool(N), URL |
| 3 | Forum (author + votes + URL) | author, platform, votes, URL |
| 4 | GitHub (1000+ stars, file:line) | repo, file:lines, URL |

`# Source: common practice` = Tier 0 = does not exist. Rewrite.

---

### RULE P — FILE PATCHING

Never `sed -i`. Always Python with uniqueness guard:

```python
# WHAT: patch exactly one occurrence of old_string in path.
# FAILURE MODE: if assert fails, old_string appears 0 or 2+ times —
#   the patch is ambiguous and must not proceed.
# Source (Tier 2): Python str.replace() docs —
#   "Return a copy with all occurrences of substring old replaced by new."
#   https://docs.python.org/3/library/stdtypes.html#str.replace
with open(path) as f: content = f.read()
assert content.count(old) == 1, f"Expected 1 match, got {content.count(old)}: {old[:60]}"
content = content.replace(old, new)
assert content.count(old) == 0, "Old string still present after replace"
with open(path, 'w') as f: f.write(content)
print(f"Patched: {path}")
```

After every patch: read back ±10 lines around the changed region and show verbatim.

---

### RULE V — VERIFY EVERY DEPLOYMENT

After any file write, copy, or patch:
1. Read back the changed region verbatim
2. Run `bash -n` on every modified script
3. Show both outputs before delivering

---

### PRE-DELIVERY CHECKLIST (run this before every response with code)

```bash
#!/usr/bin/env bash
# pre-delivery-check.sh — run against any script before delivering
# WHAT: mechanical enforcement of Rules S, L, D, E, C
# VERIFIES WITH: zero VIOLATION lines = ready to deliver

script="$1"
[[ -f "$script" ]] || { echo "USAGE: $0 <script.sh>"; exit 1; }

VIOLATIONS=0

echo "=== SUPPRESSION AUDIT ==="
while IFS= read -r match; do
    lineno="${match%%:*}"
    prev=$(( lineno - 1 ))
    prev_text="$(sed -n "${prev}p" "$script" 2>/dev/null)"
    if ! echo "$prev_text" | grep -qE \
        "SUPPRESS-REASON|ALLOW-FAIL-REASON|command -v|# WHY|# WHAT"; then
        echo "VIOLATION [$lineno]: $(echo "$match" | cut -c1-100)"
        echo "  PREV [$prev]: $prev_text"
        (( VIOLATIONS++ )) || true
    fi
done < <(grep -n "2>/dev/null\|>/dev/null\b\||| true" "$script")

echo ""
echo "=== LOG GATE AUDIT ==="
# Find functions that change state (write/insert/cp/mv/rm) but have no log call
while IFS= read -r fn_start; do
    fn_lineno="${fn_start%%:*}"
    fn_name="$(echo "$fn_start" | grep -oP '^\d+:\s*\K\w+')"
    # Extract function body (next 50 lines as approximation)
    fn_body="$(sed -n "$((fn_lineno)),$((fn_lineno+50))p" "$script")"
    if echo "$fn_body" | grep -qE "sqlite3|cp |mv |rm |tee |echo.*>"; then
        if ! echo "$fn_body" | grep -q "log "; then
            echo "VIOLATION: function at line $fn_lineno ($fn_name) writes state but has no log() call"
            (( VIOLATIONS++ )) || true
        fi
    fi
done < <(grep -n "^[a-z_]*() {" "$script")

echo ""
echo "=== SYNTAX CHECK ==="
if bash -n "$script"; then
    echo "PASS: bash -n"
else
    echo "VIOLATION: syntax error"
    (( VIOLATIONS++ )) || true
fi

echo ""
echo "=== RESULT ==="
if [[ $VIOLATIONS -eq 0 ]]; then
    echo "PASS: $script — $VIOLATIONS violations — ready to deliver"
else
    echo "FAIL: $script — $VIOLATIONS violations — DO NOT DELIVER"
    exit 1
fi
```

---

## PROJECT CONTEXT

Repository: https://github.com/swipswaps/amdgpu-boot-audit
Language: Bash ≥4.0 + Python3 + SQLite3
Target: Fedora 43+ / systemd / grub2 / AMD Renoir GPU

**Confirmed facts (do not re-derive these):**
- `kernel.dmesg_restrict=1` on this system — always `sudo -n dmesg` with `journalctl -k` fallback
- `journalctl -b -1` produces 90–150MB — always `| head -n 50000`
- `dnf provides` blocks on slow mirrors — always `timeout 10s dnf provides`
- `gh auth status` writes success to stderr — never suppress with `2>/dev/null`
- Cold boot (≥10s power-off) fixes amdgpu kthread -EINTR; warm reboot does not
- `amdgpu.gpu_recovery=0` is explicitly prohibited by AMD maintainer Christian König:
  "NOT supported at all and should never be done" — https://lkml.iu.edu/hypermail/linux/kernel/2501.0/05196.html

---

## SELF-CHECK TEMPLATE

Append to every response that contains code:

```
SELF-CHECK:
- Rules applied: [S, L, D, E, C, P, V, 0, 12, 23]
- Violations found before rewrite: [describe or "none"]
- Evidence base: [exact files/output used]
- Suppression audit: [result of pre-delivery-check.sh or "N/A — no scripts"]
- Per-item evidence quotes:
  Rule S: [list every suppression with its SUPPRESS-REASON]
  Rule C: [citation tier and URL for each technical claim]
  Rule 23: [component coverage list]
```
