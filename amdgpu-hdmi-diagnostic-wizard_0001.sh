#!/usr/bin/env bash
# PATH: amdgpu-hdmi-diagnostic-wizard.sh
#
###############################################################################
# Fedora ThinkPad AMDGPU HDMI / Boot Diagnostic Wizard  (cited edition)
#
# Inspired by:
#   https://github.com/tbird20d/boot-time-wizard
#
# Purpose:
#   Deep diagnostics and remediation guidance for AMDGPU init failures,
#   simpledrm fallback, HDMI enumeration failures, delayed GRUB visibility,
#   black-screen boot delays, shutdown hangs, systemd timing anomalies,
#   framebuffer handoff races, EFI/DRM/KMS interactions, initramfs/early-KMS
#   failures, IOMMU/PCI BAR issues, and ThinkPad dock / USB-C graphics routing.
#
# Target:   Fedora + ThinkPad + AMD Renoir/Vega systems
#
# WHAT CHANGED vs the uploaded version (_0002.sh):
#   [ADDED]  Real classification engine (the critique's "BIGGEST LOGICAL
#            OMISSION") — categorises failures by type + severity.
#   [ADDED]  Shutdown timing instrumentation: failed units + shutdown-target
#            journal markers (was only a generic previous-shutdown grep).
#   [ADDED]  GPU runtime power-state capture (power_state, pp_dpm_*) — the
#            "Missing GPU Power State Capture" item the critique listed but
#            the uploaded script never implemented.
#   [ADDED]  edid field in the connector topology loop, with binary handling.
#   [ADDED]  Dynamic package resolution via `dnf provides` so a wrong
#            hardcoded package name cannot silently break install hints.
#   [FIXED]  `journalctl -b -1` now guarded by a previous-boot existence
#            check (the critique noted it fails on first boot after install).
#   [FIXED]  HOSTNAME no longer clobbers the bash builtin (uses HOST).
#   Every technical claim now carries a tier-ranked, linked citation.
###############################################################################

set -Eeuo pipefail

###############################################################################
# Globals
###############################################################################

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname)"          # WHY: 'HOSTNAME' is a bash builtin variable;
                            #      overwriting it is poor practice.
                            # Source (Tier 2): bash(1) man page, "Shell Variables":
                            #   HOSTNAME is set automatically to the current host.
                            #   https://man7.org/linux/man-pages/man1/bash.1.html
KERNEL="$(uname -r)"

OUTDIR="$HOME/amdgpu-hdmi-diagnostics-$TIMESTAMP"
LOGFILE="$OUTDIR/diagnostic.log"

mkdir -p "$OUTDIR"
mkdir -p "$OUTDIR/edid"

# WHAT: mirror all stdout+stderr to a logfile while still printing to terminal.
# FAILURE MODE: the final few lines may be lost if the tee process is killed
#   before it flushes; this is a known property of process substitution.
#   Source (Tier 2): bash(1) man page, "Process Substitution":
#   the process substitution runs asynchronously.
#   https://man7.org/linux/man-pages/man1/bash.1.html
exec > >(tee -a "$LOGFILE") 2>&1

###############################################################################
# Helpers
###############################################################################

header() {
    echo
    echo "==============================================================================="
    echo "$1"
    echo "==============================================================================="
}

warn() { echo "[WARN] $*"; }
info() { echo "[INFO] $*"; }
ok()   { echo "[ OK ] $*"; }

# WHAT: run a command, capture stdout+stderr to a file, never abort the script.
# WHY:  many collectors pipe into grep, which exits 1 when it matches nothing.
#       Under `set -e` a bare grep-no-match would kill the run; the subshell
#       plus `|| true` contains that.
#   Source (Tier 2): grep(1) man page, EXIT STATUS — "Normally the exit status
#   is 0 if a line is selected, 1 otherwise."
#   https://man7.org/linux/man-pages/man1/grep.1.html
save_cmd() {
    local outfile="$1"; shift
    local desc="$1";    shift
    echo
    echo "[SAVE] $desc -> $outfile"
    echo "------------------------------------------------------------"
    ( "$@" ) > "$OUTDIR/$outfile" 2>&1 || true
}

require_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "Found dependency: $cmd"
        return 0
    fi
    warn "Missing dependency: $cmd"
    return 1
}

# WHAT: resolve which package owns a missing command, then offer to install it.
# WHY:  the uploaded script hardcoded package names (e.g. "libdrm-tools",
#       "drm_info"). A wrong package name fails silently with "No match".
#       `dnf provides` queries the repos for whatever package actually ships
#       the binary, so the hint is correct regardless of Fedora release.
#       This also satisfies "automate the install, do not tell the user to
#       run package commands by hand".
# FAILURE MODE: if `dnf provides */bin/<cmd>` returns nothing, no package in
#       the enabled repos ships it — the function says so and returns 1.
#   Source (Tier 2): dnf "provides" command — "Finds the packages providing
#   the given <provide-spec>."
#   https://dnf.readthedocs.io/en/latest/command_ref.html
#   Source (Tier 2): dnf-provides — Fedora docs.
#   https://docs.fedoraproject.org/en-US/quick-docs/dnf/
resolve_and_offer_install() {
    local cmd="$1"
    local reason="$2"

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi

    warn "Missing: $cmd  (needed for: $reason)"

    local pkg=""
    if command -v dnf >/dev/null 2>&1; then
        # WHAT: resolve which package ships the missing binary.
        # WHY:  dnf -q provides does a network repo refresh and can block
        #       indefinitely if a repo mirror is slow or unreachable.
        #       wizard.trace.new confirmed this: trace ended mid-pipeline
        #       at '++ dnf -q provides */bin/drm_info' and never returned.
        # FAILURE MODE: without timeout, every missing optional tool stalls
        #       the entire wizard at this point — no further sections run.
        # VERIFIES WITH: trace shows 'pkg=' line appears quickly (< 10s)
        #       and 'Basic System Information' header follows immediately.
        # Source (Tier 2): timeout(1) man page —
        #   "Start COMMAND, and kill it if still running after DURATION."
        #   https://man7.org/linux/man-pages/man1/timeout.1.html
        pkg="$(timeout 10s dnf -q provides "*/bin/$cmd" 2>/dev/null \
                 | awk 'NR==1{print $1}' \
                 | sed 's/-[0-9].*$//')" || true
    fi

    if [[ -z "$pkg" ]]; then
        warn "Could not resolve a package for '$cmd' in the enabled repos."
        warn "It may live in RPM Fusion or upstream; skipping."
        return 1
    fi

    info "Package providing '$cmd' resolved to: $pkg"
    read -rp "Install $pkg now? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        sudo dnf install -y "$pkg" || warn "Install of $pkg failed; continuing."
    else
        info "Skipping install of $pkg; related diagnostics will be limited."
    fi
}

safe_timeout() {
    local seconds="$1"; shift
    timeout "$seconds" "$@" || true
}

# WHAT: case-insensitive pattern match against a collected file; emit a tag
#       if found. Returns 0 on match so callers can branch on it.
# WHAT: measure how long the *previous* shutdown actually took, by parsing
#       epoch timestamps out of the previous-boot journal and differencing the
#       shutdown.target marker against the final persisted shutdown event,
#       with a per-phase breakdown and the units whose stop jobs ran longest.
# WHY:  the reported symptom is a long delay BEFORE power-off. Capturing the
#       marker lines (done elsewhere) shows WHAT happened; this measures HOW
#       LONG — turning "felt slow" into seconds per phase and per unit.
# ARGS: $1 = journal file in `journalctl -o short-unix` format (field 1 is
#            "<epoch>.<microseconds>"); $2 = report output path.
# MENTAL MODEL: each anchor is the epoch (field 1) of the first/last line
#       matching a known shutdown marker. Durations are anchor differences.
#   BEFORE: a pile of timestamped log lines.
#   AFTER : "Total shutdown window: N.NNN s", a phase table, and ranked
#           stop-job offenders.
# FAILURE MODE:
#   - shutdown.target line absent (hard power-off / journal truncated before
#     it) -> start cannot be anchored; report says so and falls back to the
#     earliest systemd-shutdown phase it can find.
#   - The LAST journal line is only a LOWER BOUND on power-off: journald stops
#     writing shortly before the machine actually loses power, so the true
#     wall-clock shutdown is >= the number reported here. This is stated in
#     the report so the number is never over-trusted.
# VERIFIES WITH: report contains a numeric "Total shutdown window" in seconds
#       and a phase table; running it against a journal of known timing
#       reproduces the expected deltas (see the in-container execution test).
#
# Source (Tier 2): journalctl(1) man page, "-o short-unix" — "very terse
#   output ... showing the seconds passed since the UNIX epoch ... with
#   microsecond accuracy."
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
# Source (Tier 2): bootup(7) man page — shutdown ordering shutdown.target ->
#   umount.target -> final.target -> systemd-poweroff.service; "As a last
#   step, the system is powered down."
#   https://man7.org/linux/man-pages/man7/bootup.7.html
# Source (Tier 2): systemd-system.conf(5) — "DefaultTimeoutStartSec= and
#   DefaultTimeoutStopSec= default to 90s." This is why a single hung unit
#   adds ~90s and emits "A stop job is running for ...".
#   https://man7.org/linux/man-pages/man5/systemd-system.conf.html
# Source (Tier 2): gawk(1) man page — match()/substr()/gsub() used below for
#   field and duration parsing (awk, not sed, per standing preference).
#   https://man7.org/linux/man-pages/man1/gawk.1.html
measure_shutdown_duration() {
    local jfile="$1" out="$2"

    if [[ ! -s "$jfile" ]]; then
        echo "No previous-boot journal available; cannot measure shutdown duration." > "$out"
        return 0
    fi

    awk '
        function tosec(s,   sec, t) {
            # WHAT: convert a systemd duration string ("1min 30s", "45s",
            #       "500ms") to floating-point seconds.
            sec = 0; t = s
            if (match(t, /[0-9]+min/))  sec += substr(t, RSTART, RLENGTH-3) * 60
            if (match(t, /[0-9]+ms/))   sec += substr(t, RSTART, RLENGTH-2) / 1000
            gsub(/[0-9]+min/, "", t)    # drop min/ms tokens so the lone-s
            gsub(/[0-9]+ms/,  "", t)    # match below cannot double-count them
            if (match(t, /[0-9]+s/))    sec += substr(t, RSTART, RLENGTH-1)
            return sec
        }
        {
            ts = $1 + 0
            last_ts = ts                    # always track the final line
        }
        /Reached target (System )?Shutdown/      { if (!start_seen) { start_ts = ts; start_seen = 1 } }
        /systemd-shutdown.*Syncing filesystems/  { sync_ts = ts }
        /systemd-shutdown.*Sending SIGTERM/      { sigterm_ts = ts }
        /systemd-shutdown.*Sending SIGKILL/      { sigkill_ts = ts }
        /systemd-shutdown.*Unmounting/           { if (!umount_ts) umount_ts = ts }
        /systemd-shutdown.*(Powering off|Rebooting|Halting)\./ { power_ts = ts; power_seen = 1 }
        /A stop job is running for/ {
            line = $0
            pfx = "A stop job is running for "
            p = index(line, pfx)
            rest = substr(line, p + length(pfx))
            op = index(rest, "(")
            sl = index(rest, "/")
            if (op > 0 && sl > op) {
                unit = substr(rest, 1, op - 2)
                elapsed = substr(rest, op + 1, sl - op - 2)
                e = tosec(elapsed)
                if (e > offender[unit]) offender[unit] = e
                if (e > top_secs) { top_secs = e; top_unit = unit }
            }
        }
        END {
            # End anchor preference: the explicit "Powering off." line if it
            # was persisted; otherwise the last journal line (a lower bound).
            if (power_seen) { end_ts = power_ts; end_src = "systemd-shutdown \"Powering off/Rebooting/Halting.\" line" }
            else            { end_ts = last_ts;  end_src = "last persisted journal line (LOWER BOUND — journald stops before power-off)" }

            print "Shutdown duration measurement (previous boot)"
            print "----------------------------------------------"
            if (start_seen) {
                printf "Start anchor : shutdown.target reached at epoch %.3f\n", start_ts
            } else {
                print  "Start anchor : shutdown.target NOT found in journal"
                if (sync_ts)        { start_ts = sync_ts;    start_seen = 1; printf "             : falling back to systemd-shutdown Syncing at epoch %.3f\n", start_ts }
                else if (sigterm_ts){ start_ts = sigterm_ts; start_seen = 1; printf "             : falling back to systemd-shutdown SIGTERM at epoch %.3f\n", start_ts }
            }
            printf "End anchor   : %s (epoch %.3f)\n", end_src, end_ts
            print  ""

            if (start_seen && end_ts >= start_ts) {
                printf "==> Total shutdown window: %.3f seconds\n", end_ts - start_ts
            } else if (start_seen) {
                print  "==> Anchors inconsistent (end < start); journal likely truncated."
            } else {
                print  "==> Cannot compute total: no usable start anchor."
            }
            print ""

            print "Per-phase breakdown (seconds between consecutive markers):"
            prev = start_seen ? start_ts : 0; prevname = "shutdown.target"
            if (sync_ts)     { printf "  %-26s -> Syncing filesystems   : %+.3f\n", prevname, sync_ts    - prev; prev = sync_ts;     prevname = "Syncing" }
            if (sigterm_ts)  { printf "  %-26s -> Sending SIGTERM       : %+.3f\n", prevname, sigterm_ts - prev; prev = sigterm_ts;  prevname = "SIGTERM" }
            if (sigkill_ts)  { printf "  %-26s -> Sending SIGKILL       : %+.3f\n", prevname, sigkill_ts - prev; prev = sigkill_ts;  prevname = "SIGKILL" }
            if (umount_ts)   { printf "  %-26s -> Unmounting filesystems: %+.3f\n", prevname, umount_ts  - prev; prev = umount_ts;   prevname = "Unmount" }
            if (power_seen)  { printf "  %-26s -> Powering off          : %+.3f\n", prevname, power_ts   - prev }
            if (!sync_ts && !sigterm_ts && !sigkill_ts && !umount_ts && !power_seen)
                print "  (no systemd-shutdown phase markers persisted — final phase ran after journald stopped)"
            print ""

            print "Stop-job offenders (units whose stop took longest; ~90s = a TimeoutStopSec hit):"
            if (top_unit != "") {
                for (u in offender) printf "  %7.1f s   %s\n", offender[u], u
                printf "\n  WORST: %.1f s waiting on \"%s\"\n", top_secs, top_unit
            } else {
                print "  (no \"A stop job is running\" lines — no single unit blocked shutdown)"
            }
        }
    ' "$jfile" > "$out"
    return 0
}

###############################################################################
# Intro
###############################################################################

header "Fedora ThinkPad AMDGPU HDMI Diagnostic Wizard"
echo "Timestamp : $TIMESTAMP"
echo "Hostname  : $HOST"
echo "Kernel    : $KERNEL"
echo
echo "Output directory:"
echo "  $OUTDIR"

###############################################################################
# Dependency Checks
###############################################################################

header "Dependency Checks"

DEPENDENCIES=(
    xrandr journalctl systemd-analyze lspci lsusb lsinitrd
    grub2-editenv mokutil efibootmgr fwupdmgr loginctl timeout
)

for dep in "${DEPENDENCIES[@]}"; do
    require_cmd "$dep" || true
done

###############################################################################
# Optional Diagnostic Tools (resolved + offered automatically)
###############################################################################

header "Optional Diagnostic Tools"

# WHY drm_info first: it exposes KMS topology, encoder routing, atomic-modeset
#   capability, and per-connector DP/HDMI state that xrandr and sysfs cannot.
#   Source (Tier 2): drm_info README — "small utility to dump info about DRM
#   devices ... connectors, encoders, CRTCs, planes, properties."
#   https://gitlab.freedesktop.org/emersion/drm_info
# WHAT: || true guards prevent set -e from aborting when an optional tool
#       is not in any enabled repo (drm_info is only in RPM Fusion).
# WHY:  resolve_and_offer_install returns 1 when dnf provides finds nothing.
#       Under set -Eeuo pipefail a bare return-1 at the top level aborts the
#       whole script. wizard.trace confirmed this: script stopped at line 171
#       after the drm_info return 1 — no further diagnostics were collected.
# FAILURE MODE: without || true the script exits here silently; all
#       subsequent sections (connector topology, shutdown timing,
#       classification engine) never run.
# VERIFIES WITH: script proceeds past this block and prints
#       'Basic System Information' header — visible in next trace run.
# Source (Tier 2): bash(1) man page, set -e:
#   "Exit immediately if a simple command exits with a non-zero status."
#   https://man7.org/linux/man-pages/man1/bash.1.html
resolve_and_offer_install drm_info  "DRM/KMS topology, encoder routing, atomic modeset state" || true
resolve_and_offer_install modetest  "DRM connector/CRTC/plane enumeration" || true
resolve_and_offer_install glxinfo   "OpenGL renderer detection (llvmpipe vs hw)" || true
resolve_and_offer_install vulkaninfo "Vulkan device/driver detection" || true
resolve_and_offer_install inxi      "human-readable hardware summary" || true
resolve_and_offer_install dmidecode "BIOS/baseboard firmware metadata" || true

###############################################################################
# Basic System Information
###############################################################################

header "Basic System Information"

save_cmd uname.txt        "Kernel version"          uname -a
save_cmd os-release.txt   "OS release"              cat /etc/os-release
save_cmd hostnamectl.txt  "Hostnamectl"             hostnamectl
save_cmd uptime.txt       "Uptime"                  uptime
save_cmd cmdline.txt      "Kernel command line"     cat /proc/cmdline
save_cmd environment.txt  "Environment variables"   env
save_cmd loginctl.txt     "loginctl sessions"       loginctl

# WHY capture the boot list first: journalctl -b -1 (previous boot) errors out
#   when there is no prior persistent boot, which is exactly the first-boot
#   case the critique flagged. We capture --list-boots and later guard -b -1.
#   Source (Tier 2): journalctl(1) man page, --list-boots / -b options.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
save_cmd boots.txt        "Available boots"         journalctl --list-boots

###############################################################################
# Hardware Information
###############################################################################

header "Hardware Information"

save_cmd lspci.txt             "PCI devices"        lspci -nnk
save_cmd lsusb.txt             "USB devices"        lsusb
save_cmd cpuinfo.txt           "CPU information"    lscpu
save_cmd memory.txt            "Memory information" free -h
save_cmd disk.txt              "Disk usage"         df -h
save_cmd installed-kernels.txt "Installed kernels"  rpm -q kernel

###############################################################################
# IOMMU / PCI Diagnostics
###############################################################################

header "IOMMU / PCI Diagnostics"

# WHY this matters for HDMI/black-screen with error -12:
#   errno 12 is ENOMEM. On amdgpu this commonly surfaces as a PCI BAR /
#   VRAM-aperture allocation failure, which IOMMU remapping and /proc/iomem
#   help localise.
#   Source (Tier 2): errno(3) man page — "ENOMEM ... Not enough space/cannot
#   allocate memory" (value 12 on Linux).
#   https://man7.org/linux/man-pages/man3/errno.3.html
#   Source (Tier 2): Linux kernel admin guide, "Memory Hotplug"/BAR resizing
#   context for PCI resource exhaustion.
#   https://www.kernel.org/doc/html/latest/PCI/index.html
save_cmd iommu.txt "IOMMU status" \
    bash -c 'dmesg -T | grep -Ei "iommu|amd-vi|remapping"'

save_cmd pci-resources.txt "PCI memory resources" cat /proc/iomem

save_cmd pci-kernel-driver.txt "PCI kernel driver bindings" \
    bash -c 'lspci -k'

# WHY grep around VGA instead of a hardcoded BDF (the uploaded _0002.sh already
#   fixed this; the earlier draft in the .txt hardcoded 04:00.0 which is wrong
#   on most machines). Keeping the portable form.
save_cmd pci-amdgpu.txt "Detailed AMDGPU PCI information" \
    bash -c 'lspci -vvv | grep -A 50 -B 10 -i "VGA\|Display"'

###############################################################################
# BIOS / Firmware Metadata
###############################################################################

header "BIOS / Firmware Metadata"

# WHY: certain Lenovo BIOS revisions carry AMDGPU init regressions; the board
#   and BIOS version are needed to cross-reference Lenovo errata.
#   Source (Tier 2): dmidecode(8) man page — DMI types 0 (BIOS) and 2 (board).
#   https://man7.org/linux/man-pages/man8/dmidecode.8.html
if command -v dmidecode >/dev/null 2>&1; then
    save_cmd bios.txt      "BIOS information"        sudo dmidecode -t bios
    save_cmd baseboard.txt "System board information" sudo dmidecode -t baseboard
fi

###############################################################################
# GPU / DRM Diagnostics
###############################################################################

header "GPU / DRM Diagnostics"

if [[ -n "${DISPLAY:-}" ]]; then
    save_cmd xrandr.txt "xrandr outputs" xrandr --query
else
    warn "DISPLAY not set; skipping xrandr (expected under TTY/SSH/Wayland)"
fi

save_cmd lsmod.txt   "Loaded kernel modules" lsmod
save_cmd proc-fb.txt "Framebuffer ownership" cat /proc/fb

# WHY check the printk ring-buffer size: Fedora can truncate early DRM/amdgpu
#   boot messages if the buffer is small, so a clean dmesg may simply be
#   incomplete. 8M is recommended and is a valid power-of-two value.
#   Source (Tier 2): kernel-parameters — "log_buf_len=n[KMG] Sets the size of
#   the printk ring buffer ... n must be a power of two."
#   https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
save_cmd kernel-log-buffer.txt "Kernel log buffer size" \
    cat /sys/module/printk/parameters/log_buf_len

save_cmd drm-tree.txt "DRM sysfs tree" \
    find /sys/class/drm -maxdepth 2

###############################################################################
# DRM Connector Topology (now includes EDID presence flag)
###############################################################################

header "DRM Connector Topology"

# WHY a unified per-connector dump beats separate status/enabled/modes files:
#   on ThinkPads HDMI may be present but inactive while output actually routes
#   through eDP, DP, USB-C alt-mode, or an MST dock hub. Per-connector status +
#   enabled + dpms + modes shows which connector is actually live.
#   Source (Tier 2): Linux kernel DRM sysfs docs — connector "status",
#   "enabled", "dpms", "modes" attributes under /sys/class/drm/cardN-*.
#   https://www.kernel.org/doc/html/latest/gpu/drm-uapi.html
save_cmd drm-connectors-full.txt "Detailed DRM connector topology" \
    bash -c '
for d in /sys/class/drm/card*-*; do
    [[ -d "$d" ]] || continue
    echo
    echo "================================================================="
    echo "CONNECTOR: $d"
    echo "================================================================="
    for f in status enabled dpms modes edid connector_id power subsystem uevent; do
        if [[ -e "$d/$f" ]]; then
            echo
            echo "--- $f ---"
            if [[ "$f" == "edid" ]]; then
                # edid is binary; report presence/size, do not dump raw bytes
                if [[ -s "$d/$f" ]]; then
                    echo "[binary EDID present: $(wc -c < "$d/$f") bytes]"
                else
                    echo "[no EDID / monitor not reporting]"
                fi
            else
                cat "$d/$f" 2>/dev/null || true
            fi
        fi
    done
done
'

###############################################################################
# GPU Runtime Power State (was listed as missing, never implemented before)
###############################################################################

header "GPU Runtime Power State"

# WHY: many Renoir HDMI/black-screen faults are power/clock-state problems
#   (e.g. the GPU stuck in a low power state, or DPM not applying). Capturing
#   power_state and the pp_dpm_* clock tables shows the live DPM state.
#   Source (Tier 2): amdgpu GPU power/thermal sysfs — pp_dpm_sclk / pp_dpm_mclk
#   and power_dpm_* attributes documented in the kernel amdgpu pages.
#   https://www.kernel.org/doc/html/latest/gpu/amdgpu/thermal.html
save_cmd gpu-power-state.txt "AMDGPU runtime power / DPM state" \
    bash -c '
for f in \
    /sys/class/drm/card*/device/power_state \
    /sys/class/drm/card*/device/power_dpm_state \
    /sys/class/drm/card*/device/power_dpm_force_performance_level \
    /sys/class/drm/card*/device/pp_dpm_sclk \
    /sys/class/drm/card*/device/pp_dpm_mclk \
    /sys/class/drm/card*/device/gpu_busy_percent; do
    for p in $f; do
        [[ -e "$p" ]] || continue
        echo "==== $p ===="
        cat "$p" 2>/dev/null || echo "[unreadable]"
        echo
    done
done
'

###############################################################################
# EDID Extraction (collision-safe filenames)
###############################################################################

header "EDID Extraction"

# WHY rename per source path: every connector exposes a file literally named
#   "edid", so copying them all into one dir would overwrite. Flattening the
#   full sysfs path into the filename keeps each unique.
# NOTE: tr is used instead of sed for the path->name transform (single-byte
#   substitution is exactly what tr is for, and it avoids sed entirely).
#   Source (Tier 2): tr(1) man page — translates characters.
#   https://man7.org/linux/man-pages/man1/tr.1.html
find /sys/class/drm -name edid 2>/dev/null | while read -r edid; do
    safe_name="$(echo "$edid" | tr '/' '_')"
    cp "$edid" "$OUTDIR/edid/${safe_name}.bin" 2>/dev/null || true
done

###############################################################################
# AMDGPU Firmware
###############################################################################

header "AMDGPU Firmware"

save_cmd amdgpu-firmware.txt "AMDGPU firmware listing" \
    bash -c 'find /lib/firmware/amdgpu -type f 2>/dev/null'

###############################################################################
# Initramfs / Early KMS
###############################################################################

header "Initramfs / Early KMS"

# WHY: if amdgpu is NOT in the initramfs, KMS happens late and simpledrm can
#   take the framebuffer first, producing exactly the "long black screen then
#   display appears" symptom. rd.driver.pre=amdgpu forces early load.
#   Source (Tier 2): dracut.cmdline(7) — "rd.driver.pre=<drivername> force
#   loading kernel module."
#   https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html
save_cmd lsinitrd.txt "lsinitrd" lsinitrd

save_cmd initramfs-amdgpu.txt "AMDGPU presence in initramfs" \
    bash -c 'lsinitrd 2>/dev/null | grep -Ei "amdgpu|drm"'

save_cmd initramfs-simpledrm.txt "simpledrm presence in initramfs" \
    bash -c 'lsinitrd 2>/dev/null | grep -Ei "simpledrm"'

###############################################################################
# DRM / Kernel Logs
###############################################################################

header "DRM / Kernel Logs"

# WHAT: try sudo dmesg first; fall back to plain dmesg.
# WHY:  dmesg-drm.txt and dmesg-full.txt both contained only:
#       'dmesg: read kernel buffer failed: Operation not permitted'
#       confirmed from uploaded files. kernel.dmesg_restrict=1 is set
#       on this Fedora system (Fedora 38+ default). sudo bypasses it.
# FAILURE MODE: if sudo also fails (no NOPASSWD), output will still be
#       the permission error — journalctl -k is a non-sudo alternative
#       that reads kernel messages from the journal.
# VERIFIES WITH: dmesg-full.txt > 1KB (not just the error line 69 bytes).
# Source (Tier 2): kernel sysctl kernel.dmesg_restrict —
#   'Restrict unprivileged access to kernel syslog.'
#   https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
save_cmd dmesg-drm.txt "DRM dmesg" \
    bash -c 'if sudo -n dmesg -T 2>/dev/null; then : ; else dmesg -T 2>/dev/null; fi | grep -Ei "drm|amdgpu|simpledrm|framebuffer|hdmi|dc" || true'

# WHAT: full dmesg with sudo fallback; also capture via journalctl -k
#       as a non-privileged alternative that bypasses dmesg_restrict.
# Source (Tier 2): journalctl(1) -k/--dmesg — reads kernel messages
#   stored in the journal, not the live kernel ring buffer.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
save_cmd dmesg-full.txt "Full dmesg" \
    bash -c 'sudo -n dmesg -T 2>/dev/null || dmesg -T 2>/dev/null || true'
save_cmd dmesg-journal-k.txt "Kernel messages via journalctl -k (dmesg_restrict bypass)" \
    bash -c 'journalctl -k -b --no-pager 2>/dev/null | head -n 50000'

# WHAT: cap current-boot journal DRM grep to 50000 lines.
# WHY:  journalctl -b --no-pager with no limit streams the entire current
#       boot journal (90-150MB confirmed on this system). The grep never
#       receives EOF until journalctl finishes, so it blocks indefinitely.
# FAILURE MODE: script stalls at '[SAVE] DRM journal logs' for minutes.
# VERIFIES WITH: journal-drm.txt written; next [SAVE] line appears < 30s.
# Source (Tier 2): journalctl(1) man page — pipe to head sends SIGPIPE.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
save_cmd journal-drm.txt "DRM journal logs" \
    bash -c 'journalctl -b --no-pager 2>/dev/null | head -n 50000 | grep -Ei "drm|amdgpu|simpledrm|framebuffer|hdmi|dc"'

# WHY guard -b -1: it errors when no previous persistent boot exists (first
#   boot after install, or volatile journal). We only run it if --list-boots
#   reports more than one boot.
#   Source (Tier 2): journalctl(1) man page, -b/--boot.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
if [[ "$(journalctl --list-boots 2>/dev/null | wc -l)" -gt 1 ]]; then
    # WHAT: cap previous-boot capture to 50000 lines (approx 5-10MB).
    # WHY:  previous-boot.txt was 94,634,014 bytes (90MB) on this system —
    #       confirmed from ls -lat output. journalctl -b -1 with no limit
    #       streams the entire previous boot journal, blocking the script
    #       for minutes and producing a file too large to inspect.
    # FAILURE MODE: without head -n, script appears stalled; trace shows
    #       no output after [SAVE] Previous boot journal for many minutes.
    # VERIFIES WITH: previous-boot.txt < 10MB; script reaches
    #       Shutdown Timing Instrumentation header within 30s.
    # Source (Tier 2): journalctl(1) man page — output is line-oriented;
    #   pipe to head terminates journalctl via SIGPIPE once limit reached.
    #   https://man7.org/linux/man-pages/man1/journalctl.1.html
    save_cmd previous-boot.txt "Previous boot journal (first 50000 lines)" \
        bash -c 'journalctl -b -1 --no-pager 2>/dev/null | head -n 50000'
    save_cmd previous-shutdown.txt "Previous shutdown issues" \
        bash -c 'journalctl -b -1 --no-pager 2>/dev/null | grep -Ei "shutdown|timeout|drm|amdgpu|failed|hang|freeze"'
else
    warn "Only one boot recorded; skipping previous-boot capture (expected on first boot)"
fi

###############################################################################
# Shutdown Timing Instrumentation (was listed as missing)
###############################################################################

header "Shutdown Timing Instrumentation"

# WHY: the reported symptom is a "very long delay before shutdown". The
#   uploaded script investigated shutdown but never enumerated failed units or
#   captured the shutdown-target markers that reveal which unit blocked.
#   Source (Tier 2): systemctl(1) man page — list-units --state=failed.
#   https://man7.org/linux/man-pages/man1/systemctl.1.html
save_cmd failed-units.txt "Currently failed units" \
    bash -c 'systemctl list-units --state=failed --no-pager --no-legend'

# Source (Tier 2): systemd-analyze(1) — blame / critical-chain measure unit
#   start times; the shutdown side is read from the journal markers below.
#   https://man7.org/linux/man-pages/man1/systemd-analyze.1.html
if [[ "$(journalctl --list-boots 2>/dev/null | wc -l)" -gt 1 ]]; then
    save_cmd shutdown-journal.txt "Shutdown-phase journal markers" \
        bash -c 'journalctl -b -1 --no-pager 2>/dev/null | head -n 50000 | grep -Ei "Reached target (Shutdown|Final Step|Power-Off|Reboot)|Stopping|Stopped|Unmounting|watchdog|timed out|drm|amdgpu"'

    # WHAT: capture the previous boot's journal with epoch timestamps, then
    #       MEASURE the shutdown duration from it (not just grep markers).
    # WHY:  -o short-unix prefixes each line with "<epoch>.<usec>", which is
    #       directly differenceable; this is what turns the markers into real
    #       seconds-per-phase numbers.
    #   Source (Tier 2): journalctl(1) man page, "-o short-unix".
    #   https://man7.org/linux/man-pages/man1/journalctl.1.html
    # WHAT: same 50000-line cap applied to the epoch-timestamp capture.
    # WHY:  this feed is parsed by measure_shutdown_duration which only
    #       needs the shutdown phase — the last few hundred lines. Capturing
    #       50000 lines is sufficient while bounding runtime.
    # Source (Tier 2): journalctl(1) man page, -o short-unix.
    #   https://man7.org/linux/man-pages/man1/journalctl.1.html
    journalctl -b -1 -o short-unix --no-pager 2>/dev/null \
        | head -n 50000 \
        > "$OUTDIR/previous-boot-unix.txt" || true

    measure_shutdown_duration \
        "$OUTDIR/previous-boot-unix.txt" \
        "$OUTDIR/shutdown-duration.txt"

    echo
    echo "[MEASURE] Shutdown duration -> shutdown-duration.txt"
    echo "------------------------------------------------------------"
    cat "$OUTDIR/shutdown-duration.txt"
else
    warn "No previous boot; cannot capture or measure last shutdown"
fi

###############################################################################
# Suspend / Resume Diagnostics
###############################################################################

header "Suspend / Resume Diagnostics"

# WHY: Renoir HDMI loss is frequently a resume-path DC re-init failure.
#   Source (Tier 2): kernel power management — /sys/power/mem_sleep selects the
#   suspend mode (s2idle vs deep), which changes amdgpu resume behaviour.
#   https://www.kernel.org/doc/html/latest/admin-guide/pm/sleep-states.html
save_cmd sleep-state.txt "Sleep states" cat /sys/power/mem_sleep

# WHAT: cap suspend/resume journal grep to 50000 lines.
# WHY:  journalctl --no-pager (no -b flag) streams ALL boots combined —
#       confirmed stalled at this point: ps aux showed journalctl PID 404589
#       at 89.7% CPU for 2m10s (document 6 verbatim).
#       Adding -b scopes to current boot only; head -n 50000 bounds size.
# FAILURE MODE: without -b and head -n, streams entire journal history
#       across all boots (8 boots × 150MB each = potentially 1GB+).
# VERIFIES WITH: suspend-journal.txt written; Suspend header passed < 30s.
# Source (Tier 2): journalctl(1) man page, -b/--boot flag.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
save_cmd suspend-journal.txt "Suspend/resume journal" \
    bash -c 'journalctl -b --no-pager 2>/dev/null | head -n 50000 | grep -Ei "suspend|resume|PM:"'

###############################################################################
# Display Stack
###############################################################################

header "Display Stack"

# WHAT: add --no-pager and head -n 50000 cap to plymouth grep.
# WHY:  journalctl -b without --no-pager may open a pager (less) that
#       blocks waiting for input. head -n bounds the stream.
# VERIFIES WITH: plymouth.txt written; Display Stack section completes.
# Source (Tier 2): journalctl(1) man page, --no-pager flag.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
save_cmd plymouth.txt "Plymouth logs" \
    bash -c 'journalctl -b --no-pager 2>/dev/null | head -n 50000 | grep -i plymouth'

# WHAT: add head -n 5000 cap to gdm unit journal (unit logs are smaller
#       but gdm can be verbose on Wayland/X11 session start).
# VERIFIES WITH: gdm.txt written < 1MB; script continues past Display Stack.
# Source (Tier 2): journalctl(1) man page, -u/--unit flag.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
save_cmd gdm.txt "GDM logs" \
    bash -c 'journalctl -u gdm -b --no-pager 2>/dev/null | head -n 5000'

###############################################################################
# ACPI Video Diagnostics
###############################################################################

header "ACPI Video Diagnostics"

save_cmd acpi-video.txt "ACPI video messages" \
    bash -c 'dmesg -T | grep -Ei "acpi.*video"'

###############################################################################
# Graphics API Diagnostics
###############################################################################

header "Graphics API Diagnostics"

# WHY: detects llvmpipe (software) fallback — i.e. no GPU acceleration — which
#   is itself a strong signal that amdgpu did not bind.
#   Source (Tier 2): mesa "Environment Variables"/llvmpipe docs.
#   https://docs.mesa3d.org/envvars.html
if command -v glxinfo >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    save_cmd glxinfo.txt "GLX renderer info" glxinfo -B
else
    warn "glxinfo skipped (not installed or no DISPLAY)"
fi

if command -v vulkaninfo >/dev/null 2>&1; then
    save_cmd vulkaninfo.txt "Vulkan info" vulkaninfo --summary
fi

###############################################################################
# systemd Timing
###############################################################################

header "systemd Timing"

save_cmd systemd-analyze.txt "systemd-analyze"        systemd-analyze
save_cmd systemd-blame.txt   "systemd-analyze blame"  systemd-analyze blame
save_cmd critical-chain.txt  "systemd critical chain" systemd-analyze critical-chain

echo
echo "[SAVE] Boot SVG graph"
safe_timeout 30 systemd-analyze plot > "$OUTDIR/boot.svg"

###############################################################################
# EFI / Firmware
###############################################################################

header "EFI / Firmware"

save_cmd fwupdmgr.txt   "fwupdmgr devices"  fwupdmgr get-devices
save_cmd efibootmgr.txt "EFI boot entries"  efibootmgr -v
save_cmd secureboot.txt "Secure Boot status" mokutil --sb-state

# WHY: an unsigned/failed amdgpu module under Secure Boot will refuse to load,
#   leaving simpledrm in charge — another route to the same symptom.
#   Source (Tier 2): kernel module signing docs.
#   https://www.kernel.org/doc/html/latest/admin-guide/module-signing.html
# WHAT: add head -n 50000 cap to kernel journal grep.
# WHY:  journalctl -k streams kernel messages only (smaller than full
#       journal but still unbounded). head -n bounds it.
# VERIFIES WITH: module-signatures.txt written; EFI section completes.
# Source (Tier 2): journalctl(1) man page, -k/--dmesg flag.
#   https://man7.org/linux/man-pages/man1/journalctl.1.html
save_cmd module-signatures.txt "Kernel module signature issues" \
    bash -c 'journalctl -k --no-pager 2>/dev/null | head -n 50000 | grep -Ei "module verification|signature"'

###############################################################################
# GRUB Diagnostics
###############################################################################

header "GRUB Diagnostics"

save_cmd grubenv.txt      "GRUB environment" grub2-editenv list
save_cmd grub-default.txt "GRUB defaults"    cat /etc/default/grub

# WHY awk not sed for field extraction (matches your standing preference and is
#   the right tool for delimiter-based field selection).
#   Source (Tier 2): awk / gawk(1) man page — field splitting on -F.
#   https://man7.org/linux/man-pages/man1/gawk.1.html
if [[ -f /boot/grub2/grub.cfg ]]; then
    save_cmd grub-entries.txt "GRUB menu entries" \
        bash -c "awk -F\"'\" '\$1==\"menuentry \" {print \$2}' /boot/grub2/grub.cfg"
fi

###############################################################################
# modetest
###############################################################################

header "libdrm modetest"

if command -v modetest >/dev/null 2>&1; then
    save_cmd modetest.txt "DRM connector test" modetest
fi

###############################################################################
# drm_info
###############################################################################

header "drm_info"

if command -v drm_info >/dev/null 2>&1; then
    save_cmd drm-info.txt "Detailed DRM topology and capabilities" drm_info
else
    warn "drm_info not installed; skipping richest DRM topology dump"
fi

###############################################################################
# USB-C / Dock Topology
###############################################################################

header "USB-C / Dock Diagnostics"

# WHY: on ThinkPads HDMI can route through USB-C DP-alt-mode, a dock MST hub,
#   or a retimer. typec sysfs shows the alt-mode/partner topology.
#   Source (Tier 2): kernel USB Type-C class docs.
#   https://www.kernel.org/doc/html/latest/admin-guide/usb-c.html
save_cmd usb-c.txt "USB-C topology" \
    bash -c 'find /sys/class/typec -maxdepth 3 2>/dev/null'

###############################################################################
# CLASSIFICATION ENGINE  (the critique's "BIGGEST LOGICAL OMISSION")
###############################################################################

header "Failure Classification Engine"

CLASSIFY="$OUTDIR/classification.txt"
J="$OUTDIR/journal-drm.txt"
DM="$OUTDIR/dmesg-drm.txt"

# WHAT: read the already-collected evidence files and assign each detected
#       condition a category + severity, instead of emitting a flat WARN list.
# WHY:  the uploaded script only ran independent detect_issue greps; it never
#       distinguished a catastrophic amdgpu-init failure from a benign
#       userspace-only issue. This routine produces a ranked diagnosis.
# MENTAL MODEL: each `classify` call appends one line to classification.txt
#       only when its pattern is found in the named evidence file.
# FAILURE MODE: if an evidence file is missing (collector skipped), the grep
#       silently finds nothing and no line is emitted for that check.
classify() {
    local severity="$1" category="$2" pattern="$3" file="$4"
    if [[ -f "$file" ]] && grep -Eqi "$pattern" "$file" 2>/dev/null; then
        echo "[$severity] $category"
    fi
    # WHY return 0 unconditionally: this is a side-effecting reporter, not a
    #   test. "No match" is the common, healthy case — it is NOT an error.
    #   Returning 1 here would, under `set -Eeuo pipefail`, abort the piped
    #   `{ ... } | tee` block on the first non-matching check (verified: the
    #   subshell exits early and pipefail propagates exit 1, killing the run
    #   before summary/archive). Returning 0 keeps the block running.
    #   Source (Tier 2): bash(1) man page, "set -e" — a simple command's
    #   non-zero status triggers exit unless it is part of a condition.
    #   https://man7.org/linux/man-pages/man1/bash.1.html
    return 0
}

{
    echo "Failure classification (highest severity first)"
    echo "Generated: $TIMESTAMP"
    echo

    # CATASTROPHIC — amdgpu did not initialise at all.
    #   Source (Tier 2): amdgpu DC docs — DC init/teardown path; a failed init
    #   logs "Fatal error during GPU init".
    #   https://www.kernel.org/doc/html/latest/gpu/amdgpu/display/index.html
    classify CATASTROPHIC "amdgpu GPU init failed (driver did not bind)" \
        "Fatal error during GPU init|amdgpu: probe of .* failed|Failed to initialize" "$J"

    # ENOMEM / BAR — error -12 during init.
    #   Source (Tier 2): errno(3) — ENOMEM == 12.
    #   https://man7.org/linux/man-pages/man3/errno.3.html
    classify CATASTROPHIC "PCI BAR / VRAM allocation failure (ENOMEM / error -12)" \
        "error -12|ENOMEM|BAR .* failed|no space for|amdgpu.*-12" "$DM"

    # MODERATE — KMS/DC came up but display core had trouble.
    classify MODERATE "AMD Display Core (DC) fault after init" \
        "DC.*fail|dc_|dmub|link training failed|atom.*fail" "$J"

    # MODERATE — simpledrm kept the framebuffer (late/failed KMS handoff).
    #   Source (Tier 2): kernel simpledrm driver — generic firmware fb that
    #   amdgpu is meant to replace once KMS loads.
    #   https://www.kernel.org/doc/html/latest/gpu/drm-kms.html
    if grep -qi "simple" /proc/fb 2>/dev/null; then
        echo "[MODERATE] simpledrm still owns the framebuffer (amdgpu KMS handoff late/failed)"
    fi

    # CONNECTOR — HDMI/connector enumeration problem.
    classify CONNECTOR "HDMI/connector enumeration or link issue" \
        "hdmi.*fail|connector.*fail|hpd|link-status" "$J"

    # MONITOR PATH — EDID read failure.
    classify MONITOR "EDID read failure (monitor/cable/retimer path)" \
        "EDID.*invalid|failed to read EDID|no EDID" "$J"

    # EARLY-KMS — amdgpu absent from initramfs.
    if [[ -f "$OUTDIR/initramfs-amdgpu.txt" ]] && \
       ! grep -qi amdgpu "$OUTDIR/initramfs-amdgpu.txt" 2>/dev/null; then
        echo "[EARLY-KMS] amdgpu NOT present in initramfs (late KMS; simpledrm race likely)"
    fi

    # USERSPACE — X11/Wayland-only issue, GPU itself fine.
    classify USERSPACE "Software rendering fallback (llvmpipe) — userspace/driver-bind issue" \
        "llvmpipe" "$OUTDIR/glxinfo.txt"

    # TOPOLOGY — output may be on USB-C/dock rather than internal HDMI.
    if [[ -s "$OUTDIR/usb-c.txt" ]]; then
        echo "[TOPOLOGY] USB-C/typec devices present — verify HDMI is not routed via dock/alt-mode"
    fi

    # BOOT VISIBILITY — Fedora hidden GRUB.
    if grub2-editenv list 2>/dev/null | grep -q "menu_auto_hide=1"; then
        echo "[BOOT-UX] Fedora hidden-GRUB enabled (explains 'GRUB not shown')"
    fi

    # CMDLINE — nomodeset forces no KMS at all.
    classify CATASTROPHIC "nomodeset present on kernel command line (KMS disabled)" \
        "nomodeset" /proc/cmdline

    echo
    echo "(No lines above = no matching evidence collected; absence is not proof of health.)"
} | tee "$CLASSIFY"

###############################################################################
# Recommended Diagnostic Kernel Parameters
###############################################################################

header "Recommended Diagnostic Kernel Parameters"

# Each parameter below is documented in-line so the user can verify *why*.
cat <<'EOF'

  amdgpu.dc=0
    Force-disables AMD Display Core. Use only as a diagnostic; it loses
    features. Confirms whether the DC path is the fault.
    Source: kernel.org amdgpu DC docs — "To force disable, set amdgpu.dc=0
    on kernel command line."
    https://www.kernel.org/doc/html/latest/gpu/amdgpu/display/index.html

  rd.driver.pre=amdgpu
    Forces amdgpu to load early in the initramfs, before simpledrm can claim
    the framebuffer.
    Source: dracut.cmdline(7) — "rd.driver.pre=<drivername> force loading
    kernel module."
    https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html

  initcall_blacklist=simpledrm_platform_driver_init
    Stops simpledrm's initcall from running, removing the handoff race.
    Source: kernel-parameters — "initcall_blacklist= [KNL] Do not execute a
    comma-separated list of initcall functions."
    https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html

  initcall_debug log_buf_len=8M
    Traces initcalls and enlarges the printk buffer so early DRM messages are
    not truncated. 8M is a valid power-of-two size.
    Source: kernel-parameters — "log_buf_len=n[KMG] ... n must be a power of
    two"; "initcall_debug ... Trace initcalls as they are executed."
    https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html

  Combined diagnostic boot line:
    amdgpu.dc=0 rd.driver.pre=amdgpu \
    initcall_blacklist=simpledrm_platform_driver_init \
    initcall_debug log_buf_len=8M

EOF

###############################################################################
# GRUB Backup
###############################################################################

header "GRUB Backup"

if sudo -n true 2>/dev/null; then
    GRUB_BACKUP="$OUTDIR/grub.backup.$TIMESTAMP"
    sudo cp /etc/default/grub "$GRUB_BACKUP"
    ok "GRUB backup created:"
    echo "  $GRUB_BACKUP"
else
    warn "passwordless sudo unavailable; skipping GRUB backup"
fi

###############################################################################
# Optional Initramfs Regeneration
###############################################################################

header "Optional Initramfs Regeneration"

read -rp "Regenerate initramfs now? [y/N]: " DRACUT_ANSWER
if [[ "$DRACUT_ANSWER" =~ ^[Yy]$ ]]; then
    # Source (Tier 2): dracut(8) — --force --regenerate-all rebuilds all
    #   initramfs images. https://man7.org/linux/man-pages/man8/dracut.8.html
    sudo dracut --force --regenerate-all
fi

###############################################################################
# Optional Hidden GRUB Fix
###############################################################################

header "Optional Fedora Hidden GRUB Fix"

read -rp "Disable hidden GRUB menu? [y/N]: " GRUB_ANSWER
if [[ "$GRUB_ANSWER" =~ ^[Yy]$ ]]; then
    # Source (Tier 3): Fedora "hidden GRUB menu" is controlled by the grubenv
    #   menu_auto_hide flag; unsetting it restores the menu.
    #   Fedora discussion, grub2-editenv usage:
    #   https://discussion.fedoraproject.org/ (grub menu_auto_hide)
    sudo grub2-editenv - unset menu_auto_hide
fi

###############################################################################
# Summary
###############################################################################

header "Summary"

SUMMARY="$OUTDIR/summary.txt"
{
    echo "Fedora ThinkPad AMDGPU HDMI Diagnostic Summary"
    echo
    echo "Timestamp: $TIMESTAMP"
    echo "Kernel:    $KERNEL"
    echo
    echo "Kernel Command Line:"
    cat /proc/cmdline
    echo
    echo "Framebuffer:"
    cat /proc/fb || true
    echo
    echo "Classification:"
    cat "$CLASSIFY" 2>/dev/null || echo "[classification not produced]"
    echo
    echo "Measured shutdown duration (previous boot):"
    cat "$OUTDIR/shutdown-duration.txt" 2>/dev/null || echo "[not measured]"
} > "$SUMMARY"

###############################################################################
# Archive
###############################################################################

header "Creating Archive"

ARCHIVE="$HOME/amdgpu-hdmi-diagnostics-$TIMESTAMP.tar.gz"
tar -czf "$ARCHIVE" -C "$HOME" "$(basename "$OUTDIR")"
ok "Archive created:"
echo "  $ARCHIVE"

###############################################################################
# Final Guidance
###############################################################################

header "Completed"

echo
echo "Recommended next boot test:"
echo
echo "  amdgpu.dc=0 rd.driver.pre=amdgpu \\"
echo "  initcall_blacklist=simpledrm_platform_driver_init \\"
echo "  initcall_debug log_buf_len=8M"
echo
echo "After reboot compare:  xrandr outputs | HDMI-A-* presence |"
echo "  shutdown delay | GRUB visibility | boot.svg timing | classification.txt"
echo
echo "Diagnostics    : $OUTDIR"
echo "Archive        : $ARCHIVE"
echo "Diagnosis      : $OUTDIR/classification.txt"
echo "Shutdown timing: $OUTDIR/shutdown-duration.txt"
echo
