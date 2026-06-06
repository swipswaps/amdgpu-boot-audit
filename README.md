# amdgpu-boot-audit

> Forensic diagnostics, persistent database tracking, and AI-ready prompt
> generation for AMD GPU boot failures on Fedora Linux.

---

## What This Is

Two scripts that grew out of a real ThinkPad / AMD Renoir (Ryzen 4000-series APU)
debugging session. The GPU was failing every warm reboot with:

```
workqueue: Failed to create a rescuer kthread for wq "amdgpu-reset-dev": -EINTR
[drm:amdgpu_reset_create_reset_domain] *ERROR* Failed to allocate wq for amdgpu_reset_domain!
amdgpu 0000:04:00.0: amdgpu: Fatal error during GPU init
amdgpu 0000:04:00.0: probe with driver amdgpu failed with error -12
```

Root cause: a stale ACPI interrupt carrying over from the previous session
interrupted the kernel thread creation inside `amdgpu_reset_create_reset_domain()`
during the next reboot. A full cold boot (power off ≥ 10 seconds) clears it.

These scripts automate all the evidence collection that took multiple manual
sessions to assemble, so future failures are diagnosed from history, not from scratch.

---

## Contents

| File | Purpose |
|------|---------|
| `amdgpu-hdmi-diagnostic-wizard.sh` | Deep one-shot diagnostic collector — gathers 40+ evidence files, classifies failures by severity, measures shutdown timing, captures GPU/DRM/connector/EDID/firmware state |
| `boot-audit-db.sh` | Persistent SQLite database of every boot's GPU state, diff against last working state, and AI-ready prompt generator |
| `requirements.txt` | Runtime dependency list with install commands |
| `install.sh` | One-command install + systemd user service setup |
| `CONTRIBUTING.md` | How to add new failure patterns and citation requirements |

---

## Quick Start

```bash
# Clone
git clone https://github.com/swipswaps/amdgpu-boot-audit.git
cd amdgpu-boot-audit

# Install dependencies (Fedora)
bash install.sh

# Run the full diagnostic wizard (first time / acute failure)
bash amdgpu-hdmi-diagnostic-wizard.sh

# Run the audit + save this boot as a working baseline
bash boot-audit-db.sh --save-working

# On next failure: diff against the working baseline
bash boot-audit-db.sh --diff

# Generate an AI-ready diagnostic prompt from the database
bash boot-audit-db.sh --prompt-only
```

---

## The Two Scripts in Detail

### `amdgpu-hdmi-diagnostic-wizard.sh`

Collects everything in one run. Output goes to
`~/amdgpu-hdmi-diagnostics-<timestamp>/`. Key sections:

- **Dependency checks** — core tools + optional tools via `timeout`-guarded `dnf provides`
- **GPU / DRM diagnostics** — `xrandr`, `lsmod`, `/proc/fb`, DRM sysfs tree
- **DRM connector topology** — per-connector status, EDID presence/size, dpms, modes
- **GPU runtime power state** — `power_state`, `pp_dpm_sclk`, `pp_dpm_mclk`, `gpu_busy_percent`
- **EDID extraction** — binary-safe, records presence/size without dumping raw bytes
- **Kernel logs** — `sudo dmesg` with fallback to `journalctl -k` when `dmesg_restrict=1`
- **Shutdown timing instrumentation** — awk-parsed epoch timestamps, per-phase breakdown, stop-job offender detection
- **Failure Classification Engine** — CATASTROPHIC / MODERATE / CONNECTOR / MONITOR / USERSPACE / TOPOLOGY tags
- **Recommended diagnostic kernel parameters** — with full citations

All `journalctl` calls are capped with `head -n 50000` to prevent the
90–150 MB journal stalls confirmed during development.

### `boot-audit-db.sh`

Persistent across boots. Database at `~/.local/share/boot-audit/boot_audit.db`.

```
boot_snapshots    — one row per boot: kernel, cmdline, amdgpu_status,
                    boot_type (cold/warm), connector_name, EDID, renderer
grub_snapshots    — GRUB env + cmdline config + grub.cfg sha256 hash
known_failures    — every failure pattern match with verbatim evidence
working_states    — manually marked good-boot baselines
```

**Flags:**

```
(bare)           Collect + detect + write snapshot + generate prompt
--save-working   Mark this boot as a known-good working state
--diff           Show field-by-field diff vs last working state
--prompt-only    Regenerate prompt from last DB snapshot (no collection)
--help           Show usage
```

**Generated prompt** (`~/boot-audit-prompts/diagnostic-prompt-<ts>.txt`) includes:
- Verbatim dmesg GPU lines
- Boot history table (last 10 boots)
- Diff against last working state
- All GRUB/kernel parameters
- Failure patterns detected
- Backup/restore command reference
- Pre-filled solution request in the citation-required format

---

## Known Root Cause: `kthread -EINTR` on Warm Reboot

Confirmed on **RENOIR 0x1002:0x1636** (ThinkPad, subsystem `0x17AA:0x507F`):

The kernel's `kthread_create()` calls `wait_for_completion_killable()` internally.
On a warm reboot, a pending signal or ACPI interrupt from the previous session
can still be live when amdgpu's module probe runs. That signal interrupts the
wait, `kthread_create()` returns `-EINTR`, and the entire amdgpu probe fails
with `-ENOMEM` (error -12) — which is the generic error propagated up the
call stack from `amdgpu_reset_create_reset_domain()`.

**Fix:** full power-off (≥ 10 seconds), then cold boot. Clears all residual
hardware/firmware interrupt state.

**Status:** unfixed in kernel 6.19.10 as of June 2026.
Tracked: [Fedora BZ #2372819](https://bugzilla.redhat.com/show_bug.cgi?id=2372819)

**Do NOT use `amdgpu.gpu_recovery=0`** — AMD maintainer Christian König
states verbatim: *"Setting gpu_recovery to 0 in a production environment is
NOT supported at all and should never be done."*
([LKML January 2025](https://lkml.iu.edu/hypermail/linux/kernel/2501.0/05196.html))

---

## GRUB Backup and Restore

```bash
# Backup current GRUB cmdline before any changes
sudo cp /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d)

# Restore from backup
sudo cp /etc/default/grub.bak.<date> /etc/default/grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# grubby — view, add, and remove kernel args non-destructively
grubby --info=DEFAULT                                    # current default
grubby --update-kernel=ALL --args="amdgpu.X=Y"          # add param
grubby --update-kernel=ALL --remove-args="amdgpu.X"     # remove param
grubby --set-default /boot/vmlinuz-<version>             # change default kernel
grubby --set-default /boot/vmlinuz-$(uname -r)           # restore this kernel

# grub2-editenv — inspect saved boot variables
grub2-editenv list
sudo grub2-editenv /boot/grub2/grubenv set saved_entry=<entry>
```

---

## Install as Systemd User Service (auto-audit every boot)

```bash
sudo cp boot-audit-db.sh /usr/local/bin/boot-audit-db.sh
sudo chmod +x /usr/local/bin/boot-audit-db.sh

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/boot-audit.service << 'EOF'
[Unit]
Description=Boot Audit Database — amdgpu state tracker
After=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/boot-audit-db.sh

[Install]
WantedBy=graphical.target
EOF

systemctl --user enable --now boot-audit.service
systemctl --user status boot-audit.service
```

---

## Citation Policy

Every technical claim in every script carries a `# Source (Tier N):` comment
with a direct URL and verbatim quote. Tiers:

| Tier | Source type | Example |
|------|-------------|---------|
| 1 | Official kernel / amdgpu docs | kernel.org amdgpu module parameters |
| 2 | Official man pages, Fedora docs, Red Hat BZ | journalctl(1), grubby(8) |
| 3 | Reputable forum posts (author + vote count + URL) | Fedora Discussion, Arch Wiki |
| 4 | Kernel source, popular GitHub repos (1000+ stars) | torvalds/linux |

Pull requests without citations for new technical claims will not be merged.

---

## Compatibility

| Distro | Status |
|--------|--------|
| Fedora 43+ | ✅ Primary target |
| Fedora 40–42 | ✅ Tested patterns apply |
| RHEL 9 / CentOS Stream 9 | ⚠️ `grubby` works; `dnf provides` path differs |
| openSUSE Tumbleweed | ⚠️ Replace `dnf` with `zypper`; rest is portable |
| Arch Linux | ⚠️ Replace `rpm -q kernel` with `pacman -Q linux` |
| Ubuntu / Debian | ⚠️ Replace `dnf`/`rpm`/`grubby` with `apt`/`dpkg`/`update-grub` |
| Non-AMD GPU | ❌ AMD Renoir / RDNA specific |

---

## License

MIT — see `LICENSE`.

---

## References

- [kernel.org — amdgpu module parameters](https://www.kernel.org/doc/html/latest/gpu/amdgpu/module-parameters.html)
- [kernel.org — kernel parameters](https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html)
- [Fedora BZ #2372819 — amdgpu probe -EINTR on Renoir](https://bugzilla.redhat.com/show_bug.cgi?id=2372819)
- [LKML — Christian König on gpu_recovery=0](https://lkml.iu.edu/hypermail/linux/kernel/2501.0/05196.html)
- [LKML — Thomas Perrot / Bootlin amdgpu -EINTR thread](https://lkml.rescloud.iu.edu/2401.1/05335.html)
- [Arch Wiki — AMDGPU](https://wiki.archlinux.org/title/AMDGPU)
- [journalctl(1) man page](https://man7.org/linux/man-pages/man1/journalctl.1.html)
- [grubby(8) man page](https://man7.org/linux/man-pages/man8/grubby.8.html)
- [SQLite CLI documentation](https://www.sqlite.org/cli.html)
