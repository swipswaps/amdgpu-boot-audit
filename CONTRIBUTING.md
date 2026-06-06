# Contributing to amdgpu-boot-audit

## Citation Requirement (Non-Negotiable)

Every technical claim in every file must carry a `# Source (Tier N):` comment
with a direct URL and a verbatim quoted sentence from that source.

**Tier hierarchy (highest to lowest weight):**

| Tier | Type | Required fields |
|------|------|-----------------|
| 1 | Official kernel / amdgpu documentation | Author (if named), title, section, URL |
| 2 | Official man pages, Fedora/Red Hat docs, kernel BZ | tool(section), URL |
| 3 | Forum posts (Fedora Discussion, Arch Wiki, Stack Exchange) | Author, vote count, URL, verbatim quote |
| 4 | Kernel source / GitHub repos (1000+ stars) | repo, file, line range, URL |

**Example of a passing comment:**
```bash
# WHY: 99Hz avoids lockstep with the 100Hz kernel timer.
# Source (Tier 1): Gregg 2021 "Systems Performance" 2nd ed. ch.6 p.208:
#   "Use a frequency that is not a multiple of common kernel timer rates."
# Source (Tier 4): brendangregg/perf-tools — uses -F 99 throughout:
#   https://github.com/brendangregg/perf-tools/blob/master/bin/perf-stat-hist#L47
```

**Example of a failing comment (will be rejected):**
```bash
# WHY: common practice for sampling.
# (no source — "common practice" does not exist as a citation)
```

## Code Comment Requirements

Every function, every code block that changes state, and every non-obvious
variable must have all six properties:

1. **WHAT** — names the operation in plain language
2. **WHY** — grounded in the specific context (not generic)
3. **MENTAL MODEL** — what the system looks like before and after
4. **FAILURE MODE** — what failure looks like so the reader recognises it
5. **VERIFIES WITH** — exact output that confirms success
6. **Source** — cited at appropriate tier

## Logging Requirements

Every function must emit at least one `log` line on entry and one on exit.
Every file write, database insert, and command execution must be logged
verbatim. Silent no-ops are a violation.

## Testing

Before submitting a PR:

```bash
# Syntax check
bash -n amdgpu-hdmi-diagnostic-wizard.sh
bash -n boot-audit-db.sh
bash -n install.sh

# Dry run
bash install.sh --dry-run

# Audit run (produces no output files, just checks syntax and DB schema)
bash boot-audit-db.sh --prompt-only
```

## Adding New Failure Patterns

Add patterns to the `detect_failures()` function in `boot-audit-db.sh`
and the `Failure Classification Engine` section of `amdgpu-hdmi-diagnostic-wizard.sh`.

Each pattern must include:
- The exact grep regex
- The severity tier (CATASTROPHIC / MODERATE / CONNECTOR / MONITOR / USERSPACE)
- A cited reason the pattern indicates the stated failure

## Pull Request Checklist

- [ ] `bash -n` passes on all modified scripts
- [ ] Every new technical claim has a `# Source (Tier N):` with URL
- [ ] Every new function has all six comment properties
- [ ] Every new code block emits a log line
- [ ] No `sed` used for file patching (use Python with `assert s.count(old)==1`)
- [ ] No manual install instructions added (automate with `install_pkg()`)
- [ ] README updated if new functionality added
- [ ] requirements.txt updated if new dependency added
