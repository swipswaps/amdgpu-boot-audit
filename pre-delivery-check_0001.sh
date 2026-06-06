#!/usr/bin/env bash
# PATH: pre-delivery-check.sh
#
# WHAT: Mechanical pre-delivery audit for all scripts in this repo.
#       Catches Rule S (unjustified suppression), Rule L (missing log gates),
#       and syntax errors before any script is delivered or pushed.
#
# WHY:  The gh-push.sh auth check failure was caused by 2>/dev/null on a
#       verification command — a Rule S violation that prose self-check
#       missed. This script cannot be argued with: it either finds the
#       pattern or it does not.
#
# CONFIRMED VIOLATION IT WOULD HAVE CAUGHT (from session verbatim):
#   gh-push.sh line: "if ! gh auth status 2>/dev/null; then"
#   No SUPPRESS-REASON comment on the preceding line.
#   This script would have printed:
#     VIOLATION [line N]: if ! gh auth status 2>/dev/null; then
#   and exited 1, preventing delivery.
#
# MENTAL MODEL BEFORE: script may contain unjustified suppressions.
# MENTAL MODEL AFTER:  every suppression is either justified with a
#   SUPPRESS-REASON comment or flagged as a violation.
#
# FAILURE MODE: if this script itself is wrong, it will either report
#   false positives (overly strict — safe) or false negatives (misses
#   violations — run grep manually to verify).
#
# VERIFIES WITH: exit 0 + "PASS" printed = ready to deliver.
#   exit 1 + "FAIL" + violation list = do not deliver.
#
# USAGE:
#   bash pre-delivery-check.sh <script.sh> [script2.sh ...]
#   bash pre-delivery-check.sh *.sh
#
# Source (Tier 2): bash(1) man page — exit status conventions.
#   https://man7.org/linux/man-pages/man1/bash.1.html
# Source (Tier 2): grep(1) man page — pattern matching.
#   https://man7.org/linux/man-pages/man1/grep.1.html

set -euo pipefail

TOTAL_VIOLATIONS=0
FILES_CHECKED=0
FILES_FAILED=0

log()  { echo "[pre-delivery-check] $*"; }
pass() { echo "  PASS: $*"; }
# ALLOW-FAIL-REASON: (( TOTAL_VIOLATIONS++ )) || true — arithmetic
#   increment; || true prevents set -e on first increment from 0.
fail() { echo "  FAIL: $*" >&2; (( TOTAL_VIOLATIONS++ )) || true; }

check_script() {
    # WHAT: run all audit rules against one script file.
    # WHY:  centralised per-file logic so output is grouped by file.
    # MENTAL MODEL BEFORE: script unchecked.
    # MENTAL MODEL AFTER:  all suppressions and log gates verified.
    # FAILURE MODE: if file is not readable, prints error and skips.
    # VERIFIES WITH: "PASS: <file>" printed for clean files.
    # Source (Tier 2): bash(1) — "Compound Commands."
    #   https://man7.org/linux/man-pages/man1/bash.1.html

    local script="$1"
    local file_violations=0

    log "Checking: $script"
    (( FILES_CHECKED++ )) || true

    if [[ ! -f "$script" ]]; then
        fail "$script: file not found"
        (( FILES_FAILED++ )) || true
        return 1
    fi

    # ── Rule S: Suppression audit ──────────────────────────────────────────
    # WHAT: find every 2>/dev/null, >/dev/null, || true without justification.
    # WHY:  these patterns hide output that verification commands need to show.
    #       Confirmed failure: gh auth status 2>/dev/null hid success on stderr.
    # SUPPRESS-REASON (for grep -n itself): grep exits 1 on no match —
    #   || true prevents set -e from aborting the audit when clean scripts
    #   have zero suppressions to report.
    # VERIFIES WITH: zero "VIOLATION" lines printed for this section.
    # Source (Tier 2): grep(1) EXIT STATUS — "1 if no lines were selected."
    #   https://man7.org/linux/man-pages/man1/grep.1.html
    echo "  --- Rule S: Suppression audit ---"

    local suppression_violations=0
    while IFS= read -r match; do
        local lineno="${match%%:*}"
        local line_text="${match#*:}"
        local prev=$(( lineno - 1 ))
        local prev_text
        # SUPPRESS-REASON: sed -n exits 0 even on missing line numbers —
#   it returns empty string, never errors. The 2>/dev/null suppresses
#   the impossible case of a bad file descriptor only.
        prev_text="$(sed -n "${prev}p" "$script" 2>/dev/null)"
        local justified=0

        # Skip comment lines — they document suppressions, not use them
        # SUPPRESS-REASON: grep -q exits 1 when not a comment — || true
        #   prevents set -e abort; we want to continue checking.
        echo "$line_text" | grep -qE "^\s*#" && justified=1
        # Skip arithmetic counters — (( x++ )) || true cannot hide output
        echo "$line_text" | grep -qE "^\s*\(\(" && justified=1
        # Justified: look back up to 3 lines for a justification comment.
        # WHY: multi-line commands (grep -cE \ ... || true) place the
#   || true 2-3 lines below the ALLOW-FAIL-REASON comment.
        # SUPPRESS-REASON: sed -n with multi-line range — same as above.
        local look_start=$(( lineno > 3 ? lineno - 3 : 1 ))
        local context
        context="$(sed -n "${look_start},$((lineno-1))p" "$script" 2>/dev/null)"
        echo "$context" | grep -qE \
            "SUPPRESS-REASON|ALLOW-FAIL-REASON" && justified=1
        # command -v is always justified — existence check by convention
        echo "$match" | grep -q "command -v" && justified=1

        if [[ $justified -eq 0 ]]; then
            echo "  VIOLATION [line $lineno]: $(echo "$match" | cut -c1-120)"
            echo "    PREV [line $prev]: $prev_text"
            (( file_violations++ )) || true
            (( suppression_violations++ )) || true
        fi
    # ALLOW-FAIL-REASON: grep exits 1 when no suppressions found in a clean
#   script. || true prevents set -e from aborting the audit itself.
    done < <(grep -n "2>/dev/null\|>/dev/null\b\||| true" "$script" || true)

    if [[ $suppression_violations -eq 0 ]]; then
        pass "Rule S: no unjustified suppressions"
    fi

    # ── Rule L: Log gate audit ─────────────────────────────────────────────
    # WHAT: find functions that write state (DB, files, commands) without
    #       a log() call in their body.
    # WHY:  silent state changes are Rule 11 violations — they execute but
    #       produce no visible effect.
    # SUPPRESS-REASON: grep -n exits 1 when no functions found — || true
    #   prevents abort on scripts with no functions.
    # VERIFIES WITH: zero "missing log()" lines for this section.
    # Source (Tier 2): bash(1) — "Shell Functions."
    #   https://man7.org/linux/man-pages/man1/bash.1.html
    echo "  --- Rule L: Log gate audit ---"

    local log_violations=0
    while IFS= read -r fn_line; do
        local fn_lineno="${fn_line%%:*}"
        local fn_name
        fn_name="$(echo "$fn_line" | grep -oP '\w+(?=\s*\(\))')" || fn_name="unknown"
        # Extract up to 60 lines of function body for analysis
        local fn_body
        # SUPPRESS-REASON: sed -n with line range returns empty on out-of-range;
#   never errors. 2>/dev/null suppresses impossible fd errors only.
        fn_body="$(sed -n "$((fn_lineno)),$((fn_lineno+60))p" "$script" 2>/dev/null)"

        # Only check functions that visibly change state
        if echo "$fn_body" | grep -qE \
            "sqlite3|cp |mv |rm |tee |echo.*>|git |gh |systemctl|grubby|dnf|apt"; then
            if ! echo "$fn_body" | grep -qE "log |echo \[|printf"; then
                echo "  VIOLATION: ${fn_name}() at line $fn_lineno writes state but has no log() call"
                (( file_violations++ )) || true
                (( log_violations++ )) || true
            fi
        fi
    # ALLOW-FAIL-REASON: grep exits 1 when script has no function definitions.
#   || true prevents abort on scripts with only inline code.
    done < <(grep -n "^[a-z_][a-z_0-9]*() {" "$script" || true)

    if [[ $log_violations -eq 0 ]]; then
        pass "Rule L: all state-changing functions have log() calls"
    fi

    # ── Syntax check ───────────────────────────────────────────────────────
    # WHAT: bash -n catches syntax errors before execution.
    # WHY:  syntax errors abort scripts mid-run with no cleanup.
    # VERIFIES WITH: "PASS: bash -n" printed, exit 0 from bash -n.
    # Source (Tier 2): bash(1) — "-n: Read commands but do not execute them."
    #   https://man7.org/linux/man-pages/man1/bash.1.html
    echo "  --- Syntax check ---"
    if bash -n "$script" 2>&1; then
        pass "bash -n: syntax OK"
    else
        fail "bash -n: syntax error in $script"
        (( file_violations++ )) || true
    fi

    # ── Citation spot check ────────────────────────────────────────────────
    # WHAT: warn if technical keywords appear without any Source comment.
    # WHY:  scripts referencing journalctl, sqlite3, dmesg etc. must cite them.
    # SUPPRESS-REASON: grep exits 1 when pattern not found — || true prevents
    #   abort. This is a warning only, not a hard violation.
    # Source (Tier 1): See compliance-prompt.md Rule C for tier definitions.
    echo "  --- Citation spot check ---"
    local tech_claims
    # ALLOW-FAIL-REASON: grep -c exits 1 when pattern has 0 matches.
#   || true prevents abort; count of 0 is a valid diagnostic result.
    tech_claims="$(grep -cE \
        "journalctl|sqlite3|dmesg|grubby|amdgpu|kthread" "$script" || true)"
    local source_comments
    # ALLOW-FAIL-REASON: grep -c exits 1 on 0 matches — valid result.
    source_comments="$(grep -cE "# Source \(Tier" "$script" || true)"

    if [[ "$tech_claims" -gt 0 && "$source_comments" -eq 0 ]]; then
        echo "  WARN: $tech_claims technical keyword(s) found, 0 Source comments"
        echo "        Add # Source (Tier N): comments per Rule C"
    else
        pass "Citations: $source_comments Source comments for $tech_claims technical keywords"
    fi

    # ── Per-file result ────────────────────────────────────────────────────
    echo ""
    if [[ $file_violations -eq 0 ]]; then
        pass "$script — 0 violations — READY TO DELIVER"
    else
        fail "$script — $file_violations violation(s) — DO NOT DELIVER"
        (( TOTAL_VIOLATIONS += file_violations )) || true
        (( FILES_FAILED++ )) || true
    fi
    echo ""
}

###############################################################################
# Main
###############################################################################

main() {
    # WHAT: iterate over all provided scripts, run check_script on each.
    # WHY:  single entry point ensures all scripts are checked before any
    #       are delivered.
    # FAILURE MODE: if no arguments provided, prints usage and exits 1.
    # VERIFIES WITH: "OVERALL RESULT: PASS" printed at end.
    # Source (Tier 2): bash(1) — Positional Parameters.
    #   https://man7.org/linux/man-pages/man1/bash.1.html

    log "ENTER main: checking ${#@} file(s): $*"

    if [[ $# -eq 0 ]]; then
        echo "USAGE: bash pre-delivery-check.sh <script.sh> [script2.sh ...]"
        echo "       bash pre-delivery-check.sh *.sh"
        exit 1
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  Pre-Delivery Compliance Check"
    echo "  $(date)"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    for script in "$@"; do
        check_script "$script"
    done

    echo "════════════════════════════════════════════════════════════════"
    echo "  OVERALL RESULT"
    echo "  Files checked: $FILES_CHECKED"
    echo "  Files failed:  $FILES_FAILED"
    echo "  Total violations: $TOTAL_VIOLATIONS"
    echo ""
    if [[ $TOTAL_VIOLATIONS -eq 0 ]]; then
        echo "  PASS — all scripts ready to deliver"
    else
        echo "  FAIL — $TOTAL_VIOLATIONS violation(s) across $FILES_FAILED file(s)"
        echo "         Fix all VIOLATION lines before delivering"
    fi
    echo "════════════════════════════════════════════════════════════════"

    log "EXIT main: TOTAL_VIOLATIONS=$TOTAL_VIOLATIONS"
    [[ $TOTAL_VIOLATIONS -eq 0 ]]
}

main "$@"
