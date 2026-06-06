#!/usr/bin/env bash
# PATH: install.sh
#
# WHAT: One-command installer for amdgpu-boot-audit.
#       Installs core dependencies, sets sudoers rules for dmesg,
#       copies scripts to /usr/local/bin, and installs the systemd
#       user service that runs boot-audit-db.sh on every boot.
#
# WHY:  The diagnostic session that produced these scripts required
#       multiple manual dependency resolution steps. This script
#       automates all of them so a fresh install is one command.
#
# MENTAL MODEL BEFORE: user must manually install sqlite3, set sudoers,
#       copy scripts, and create the systemd service.
# MENTAL MODEL AFTER:  bash install.sh does all of the above, verifies
#       each step, and prints a clear PASS/FAIL for every action.
#
# FAILURE MODE: if dnf is unavailable (non-Fedora), prints install
#       commands for the user and continues. Never exits nonzero on
#       missing optional dependencies.
#
# VERIFIES WITH: script prints "INSTALL COMPLETE" at the end with
#       a summary of every step's PASS/FAIL status.
#
# USAGE:
#   bash install.sh [--dry-run] [--no-service] [--no-sudoers]
#
# Source (Tier 2): systemctl(1) man page — user service installation.
#   https://man7.org/linux/man-pages/man1/systemctl.1.html
# Source (Tier 2): sudoers(5) man page — NOPASSWD syntax.
#   https://man7.org/linux/man-pages/man5/sudoers.5.html

set -Eeuo pipefail

###############################################################################
# Config
###############################################################################

DRY_RUN=0
NO_SERVICE=0
NO_SUDOERS=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=1 ;;
        --no-service)  NO_SERVICE=1 ;;
        --no-sudoers)  NO_SUDOERS=1 ;;
        --help|-h)
            grep "^# " "$0" | head -30 | sed 's/^# //'
            exit 0
            ;;
    esac
done

INSTALL_BIN="/usr/local/bin"
SUDOERS_FILE="/etc/sudoers.d/boot-audit"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/boot-audit.service"
DB_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/boot-audit"

PASS_COUNT=0
FAIL_COUNT=0
STEPS=()

###############################################################################
# Helpers
###############################################################################

LOG_PREFIX="[install]"
log()  { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX [WARN]  $*" >&2; }
pass() { echo "$LOG_PREFIX [PASS]  $*"; (( PASS_COUNT++ )) || true; STEPS+=("PASS: $*"); }
fail() { echo "$LOG_PREFIX [FAIL]  $*" >&2; (( FAIL_COUNT++ )) || true; STEPS+=("FAIL: $*"); }

# WHAT: run a command only if not in dry-run mode; log what would happen.
# WHY:  --dry-run allows verifying the install plan without making changes.
# Source (Tier 2): bash(1) — conditional execution patterns.
#   https://man7.org/linux/man-pages/man1/bash.1.html
run_cmd() {
    local desc="$1"; shift
    log "  STEP: $desc"
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  DRY-RUN: would run: $*"
        pass "$desc (dry-run)"
        return 0
    fi
    if "$@"; then
        pass "$desc"
    else
        fail "$desc (exit $?)"
    fi
}

###############################################################################
# Step 1: Detect package manager
###############################################################################

log "=========================================="
log "  amdgpu-boot-audit installer"
log "  $(date)"
log "=========================================="
echo ""

PKG_MGR="unknown"
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v zypper >/dev/null 2>&1; then
    PKG_MGR="zypper"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
fi

log "Package manager detected: $PKG_MGR"

###############################################################################
# Step 2: Install core dependencies
###############################################################################

log ""
log "── Step 2: Core dependencies ──────────────────────────────────────"

install_pkg() {
    # WHAT: install a package if not already present.
    # WHY:  idempotent — safe to run on a system where some deps are present.
    # FAILURE MODE: if package manager unavailable, prints manual command.
    local pkg="$1"
    local purpose="$2"

    if command -v "${3:-$pkg}" >/dev/null 2>&1; then
        pass "$pkg already installed ($purpose)"
        return 0
    fi

    log "  Installing: $pkg ($purpose)"

    case "$PKG_MGR" in
        dnf)
            run_cmd "Install $pkg" sudo dnf install -y "$pkg"
            ;;
        apt)
            run_cmd "Install $pkg" sudo apt-get install -y "$pkg"
            ;;
        zypper)
            run_cmd "Install $pkg" sudo zypper install -y "$pkg"
            ;;
        pacman)
            run_cmd "Install $pkg" sudo pacman -S --noconfirm "$pkg"
            ;;
        *)
            warn "Unknown package manager — install manually: $pkg"
            fail "Install $pkg (no package manager)"
            ;;
    esac
}

# Core required packages (Fedora names; adjust for other distros)
install_pkg "sqlite"        "database backend"           "sqlite3"
install_pkg "pciutils"      "GPU PCI enumeration"        "lspci"
install_pkg "usbutils"      "USB device enumeration"     "lsusb"
install_pkg "xorg-x11-server-utils" "xrandr display info" "xrandr"
install_pkg "grub2-tools"   "GRUB environment access"    "grub2-editenv"
install_pkg "grubby"        "kernel arg management"      "grubby"
install_pkg "mokutil"       "Secure Boot status"         "mokutil"
install_pkg "efibootmgr"    "EFI boot entries"           "efibootmgr"
install_pkg "fwupd"         "firmware metadata"          "fwupdmgr"
install_pkg "glx-utils"     "OpenGL renderer detection"  "glxinfo"
install_pkg "vulkan-tools"  "Vulkan device detection"    "vulkaninfo"
install_pkg "dmidecode"     "BIOS/board metadata"        "dmidecode"

###############################################################################
# Step 3: Copy scripts to /usr/local/bin
###############################################################################

log ""
log "── Step 3: Install scripts ─────────────────────────────────────────"

SCRIPTS=(amdgpu-hdmi-diagnostic-wizard.sh boot-audit-db.sh)

for script in "${SCRIPTS[@]}"; do
    if [[ -f "./$script" ]]; then
        run_cmd "Copy $script to $INSTALL_BIN" \
            sudo cp "./$script" "$INSTALL_BIN/$script"
        run_cmd "Set executable: $script" \
            sudo chmod +x "$INSTALL_BIN/$script"
    else
        fail "Script not found in current directory: $script"
        warn "Run install.sh from the repo root directory."
    fi
done

###############################################################################
# Step 4: sudoers rule for dmesg
###############################################################################

log ""
log "── Step 4: sudoers rule for dmesg (dmesg_restrict bypass) ─────────"
log "  Reason: Fedora 38+ sets kernel.dmesg_restrict=1 by default."
log "  Without this rule, dmesg output is empty for unprivileged users"
log "  and the GPU diagnosis is blind."
log "  Source: https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html"

if [[ $NO_SUDOERS -eq 1 ]]; then
    warn "Skipping sudoers setup (--no-sudoers). Add manually:"
    warn "  echo '%wheel ALL=(ALL) NOPASSWD: /usr/bin/dmesg' | sudo tee $SUDOERS_FILE"
else
    SUDOERS_CONTENT="# boot-audit: allow dmesg and dmidecode without password
# Source: kernel.org sysctl kernel.dmesg_restrict
# https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
%wheel ALL=(ALL) NOPASSWD: /usr/bin/dmesg
%wheel ALL=(ALL) NOPASSWD: /usr/sbin/dmidecode"

    if [[ -f "$SUDOERS_FILE" ]]; then
        pass "sudoers rule already exists: $SUDOERS_FILE"
    else
        if [[ $DRY_RUN -eq 1 ]]; then
            log "  DRY-RUN: would write $SUDOERS_FILE"
            pass "sudoers rule (dry-run)"
        else
            echo "$SUDOERS_CONTENT" | sudo tee "$SUDOERS_FILE" > /dev/null
            sudo chmod 440 "$SUDOERS_FILE"
            # Validate the file before it takes effect
            if sudo visudo -c -f "$SUDOERS_FILE" 2>/dev/null; then
                pass "sudoers rule written and validated: $SUDOERS_FILE"
            else
                sudo rm -f "$SUDOERS_FILE"
                fail "sudoers rule failed validation — removed. Add manually."
            fi
        fi
    fi
fi

###############################################################################
# Step 5: Create database directory
###############################################################################

log ""
log "── Step 5: Database directory ──────────────────────────────────────"

run_cmd "Create DB directory: $DB_DIR" mkdir -p "$DB_DIR"

###############################################################################
# Step 6: systemd user service
###############################################################################

log ""
log "── Step 6: systemd user service ────────────────────────────────────"
log "  Service runs boot-audit-db.sh after graphical.target on every boot."
log "  Source: systemctl(1) — https://man7.org/linux/man-pages/man1/systemctl.1.html"

if [[ $NO_SERVICE -eq 1 ]]; then
    warn "Skipping service setup (--no-service)."
else
    run_cmd "Create service directory" mkdir -p "$SERVICE_DIR"

    SERVICE_CONTENT="[Unit]
Description=Boot Audit Database — amdgpu state tracker
Documentation=https://github.com/swipswaps/amdgpu-boot-audit
After=graphical.target

[Service]
Type=oneshot
ExecStart=$INSTALL_BIN/boot-audit-db.sh
StandardOutput=journal
StandardError=journal
# Source: systemd.service(5) — Type=oneshot for single-run tasks.
# https://www.freedesktop.org/software/systemd/man/systemd.service.html

[Install]
WantedBy=graphical.target"

    if [[ $DRY_RUN -eq 1 ]]; then
        log "  DRY-RUN: would write $SERVICE_FILE"
        pass "systemd service (dry-run)"
    else
        echo "$SERVICE_CONTENT" > "$SERVICE_FILE"
        pass "Service file written: $SERVICE_FILE"
        if systemctl --user daemon-reload 2>/dev/null; then
            pass "systemd user daemon reloaded"
        else
            warn "daemon-reload failed (no graphical session?) — relogin or run manually"
        fi
        if systemctl --user enable boot-audit.service 2>/dev/null; then
            pass "boot-audit.service enabled"
        else
            fail "Could not enable service — run: systemctl --user enable boot-audit.service"
        fi
    fi
fi

###############################################################################
# Step 7: Run initial audit
###############################################################################

log ""
log "── Step 7: Initial boot audit ──────────────────────────────────────"

if command -v boot-audit-db.sh >/dev/null 2>&1 || \
   [[ -x "$INSTALL_BIN/boot-audit-db.sh" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        log "  DRY-RUN: would run: boot-audit-db.sh --save-working"
        pass "Initial audit (dry-run)"
    else
        log "  Running initial audit and marking this boot as working state..."
        if "$INSTALL_BIN/boot-audit-db.sh" --save-working; then
            pass "Initial audit complete — working state recorded"
        else
            fail "Initial audit failed — check output above"
        fi
    fi
else
    fail "boot-audit-db.sh not found in PATH after install"
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  INSTALL SUMMARY"
echo "══════════════════════════════════════════════════════════════════"
for step in "${STEPS[@]}"; do
    echo "  $step"
done
echo ""
echo "  PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo "  INSTALL COMPLETE — no failures"
    echo ""
    echo "  Next steps:"
    echo "    • On this (working) boot:  boot-audit-db.sh --save-working"
    echo "    • On next failure:         boot-audit-db.sh --diff"
    echo "    • Generate AI prompt:      boot-audit-db.sh --prompt-only"
    echo "    • View boot history:       sqlite3 ~/.local/share/boot-audit/boot_audit.db"
    echo "         .headers on"
    echo "         SELECT ts,kernel,amdgpu_status,boot_type FROM boot_snapshots;"
else
    echo "  INSTALL COMPLETE WITH $FAIL_COUNT FAILURE(S) — review FAIL lines above"
fi
echo "══════════════════════════════════════════════════════════════════"
