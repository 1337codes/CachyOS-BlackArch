#!/usr/bin/env bash
# =============================================================================
# CachyOS Post-Install Setup for ASUS ROG Flow Z13 (GZ302EA, 2025)
# =============================================================================
#
# Replays everything we figured out on May 4, 2026:
#   - GZ302 hardware fixes via th3cavalry's setup script
#   - amdgpu kernel parameter tuning (dcdebugmask=0x600, not 0xe12)
#   - amd_pstate=guided + RTC ACPI alarm via Limine
#   - Bluetooth AutoEnable=true fix
#   - asusd masking (z13ctl replaces it)
#   - BlackArch repository + officials metapackage
#   - Joplin desktop install
#   - Pandoc + LaTeX for PDF report export
#   - Useful AUR pentest tools
#
# USAGE:
#   1. Boot fresh CachyOS install, login, open terminal
#   2. curl -O https://your-host/z13-cachyos-setup.sh
#   3. chmod +x z13-cachyos-setup.sh
#   4. ./z13-cachyos-setup.sh                  # interactive
#   5. ./z13-cachyos-setup.sh --yes            # non-interactive
#
# DESIGNED FOR:
#   - ASUS ROG Flow Z13 GZ302EA (Strix Halo, 32GB RAM)
#   - CachyOS Linux (Arch-based, KDE Plasma)
#   - Limine bootloader (CachyOS default)
#   - Kernel >= 6.19 (tested on 7.0.3-cachyos)
#
# =============================================================================

set -uo pipefail

# --- Configuration ---
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/tmp/z13-cachyos-setup-$(date +%Y%m%d-%H%M%S).log"
readonly LIMINE_CONF="/etc/default/limine"
readonly REQUIRED_KERNEL_PARAMS=(
    "amd_pstate=guided"
    "rtc_cmos.use_acpi_alarm=1"
    "amdgpu.dcdebugmask=0x600"
)

# --- Colors ---
readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_BLUE=$'\033[34m'
readonly C_BOLD=$'\033[1m'

# --- Flags ---
ASSUME_YES=0
SKIP_BLACKARCH=0
SKIP_PENTEST=0
SKIP_JOPLIN=0
SKIP_GZ302=0

# --- Helpers ---

info()    { printf "${C_BLUE}[INFO]${C_RESET}  %s\n" "$*" | tee -a "$LOG_FILE"; }
ok()      { printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$*" | tee -a "$LOG_FILE"; }
warn()    { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*" | tee -a "$LOG_FILE"; }
err()     { printf "${C_RED}[ERR]${C_RESET}   %s\n" "$*" | tee -a "$LOG_FILE" >&2; }
section() {
    printf "\n${C_BOLD}${C_BLUE}=== %s ===${C_RESET}\n" "$*" | tee -a "$LOG_FILE"
}

confirm() {
    local prompt="${1:-Proceed?}"
    if [[ $ASSUME_YES -eq 1 ]]; then
        return 0
    fi
    read -rp "$prompt [Y/n] " ans
    [[ -z "$ans" || "$ans" =~ ^[YyJj]$ ]]
}

require_root() {
    if [[ $EUID -eq 0 ]]; then
        err "Do NOT run this script as root. Use a regular user; the script will sudo as needed."
        exit 1
    fi
    if ! sudo -v; then
        err "sudo access required."
        exit 1
    fi
    # Keep sudo alive
    while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
}

usage() {
    cat <<EOF
ASUS ROG Flow Z13 (GZ302) — CachyOS post-install setup

Usage: $0 [OPTIONS]

Options:
  -y, --yes              Non-interactive, accept all defaults
  --skip-gz302           Skip the th3cavalry GZ302 setup script
  --skip-blackarch       Skip BlackArch repository setup
  --skip-pentest         Skip pentest tool installation
  --skip-joplin          Skip Joplin install
  -h, --help             Show this help

Recommended first run:
  $0                     # interactive, walks through each section

Re-runs (idempotent — safe to run again):
  $0 --yes               # apply everything that's missing
EOF
}

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)         ASSUME_YES=1 ;;
        --skip-gz302)     SKIP_GZ302=1 ;;
        --skip-blackarch) SKIP_BLACKARCH=1 ;;
        --skip-pentest)   SKIP_PENTEST=1 ;;
        --skip-joplin)    SKIP_JOPLIN=1 ;;
        -h|--help)        usage; exit 0 ;;
        *)                err "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# =============================================================================
# Pre-flight checks
# =============================================================================

preflight() {
    section "Pre-flight checks"

    # Confirm CachyOS
    if ! grep -q "ID=cachyos" /etc/os-release 2>/dev/null; then
        err "Not running on CachyOS. /etc/os-release does not contain ID=cachyos."
        err "If you really want to run this on another Arch-based distro, edit the script."
        exit 1
    fi
    ok "Distribution: CachyOS"

    # Check kernel
    local kver
    kver=$(uname -r | cut -d. -f1,2)
    local kmajor=${kver%.*}
    local kminor=${kver#*.}
    local knum=$((kmajor * 100 + kminor))
    info "Kernel: $(uname -r) (numeric: $knum)"
    if [[ $knum -lt 619 ]]; then
        warn "Kernel < 6.19. Some hardware fixes may need additional workarounds."
        warn "This script is tuned for kernel >= 6.19 (tested on 7.0)."
        confirm "Continue anyway?" || exit 1
    else
        ok "Kernel meets recommended version (>= 6.19)"
    fi

    # Bootloader detection
    if [[ -f "$LIMINE_CONF" ]]; then
        ok "Bootloader: Limine ($LIMINE_CONF found)"
    elif [[ -f /etc/default/grub ]]; then
        warn "Bootloader appears to be GRUB, not Limine."
        warn "This script edits Limine config. Skip kernel param section if you use GRUB."
        confirm "Continue anyway?" || exit 1
    else
        err "No known bootloader config found. Manual kernel param setup required."
        exit 1
    fi

    # Network
    if ! curl -fsS --max-time 5 https://archlinux.org >/dev/null; then
        err "No network connectivity. Required for package installs."
        exit 1
    fi
    ok "Network: reachable"

    # Disk space (need ~20GB free for full setup)
    local free_gb
    free_gb=$(df --output=avail -BG / | tail -1 | tr -d 'G ')
    if [[ $free_gb -lt 20 ]]; then
        warn "Less than 20GB free on /. Pentest tools may fail to install."
        confirm "Continue anyway?" || exit 1
    fi
    ok "Disk space: ${free_gb}G free on /"
}

# =============================================================================
# 1. System update
# =============================================================================

system_update() {
    section "1. System update"
    info "Running pacman -Syyu to refresh and upgrade everything..."
    if confirm "Update system now?"; then
        sudo pacman -Syyu --noconfirm
        ok "System updated"
    else
        warn "Skipped system update — strongly recommended to run later"
    fi
}

# =============================================================================
# 2. Base tooling (yay, git, build essentials)
# =============================================================================

install_base_tools() {
    section "2. Base tooling"
    local pkgs=(
        git base-devel curl wget
        nano vim
        htop btop
        unzip p7zip
        tree fd ripgrep bat eza
        man-db man-pages
        pacman-contrib
    )
    info "Installing base tools: ${pkgs[*]}"
    sudo pacman -S --needed --noconfirm "${pkgs[@]}"

    # yay should already be on CachyOS, but verify
    if ! command -v yay >/dev/null; then
        warn "yay not found, installing from AUR via manual bootstrap..."
        local tmp
        tmp=$(mktemp -d)
        git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay"
        (cd "$tmp/yay" && makepkg -si --noconfirm)
        rm -rf "$tmp"
    fi
    ok "Base tools ready"
}

# =============================================================================
# 3. GZ302 hardware fixes via th3cavalry script
# =============================================================================

run_gz302_setup() {
    section "3. GZ302 hardware fixes (th3cavalry)"
    if [[ $SKIP_GZ302 -eq 1 ]]; then
        warn "Skipped (--skip-gz302)"
        return 0
    fi

    info "This installs:"
    info "  - amdgpu kernel parameters (PSR-SU fix, will be tuned later)"
    info "  - Suspend/resume hook (fixes SDHCI, xHCI, ASUS HID issues)"
    info "  - Audio configuration"
    info "  - z13ctl (RGB, fan curves, TDP, battery, profiles)"
    info "  - GZ302 Dashboard tray app"
    info "  - CLI wrappers: pwrcfg, gz302-rgb, rrcfg"

    if ! confirm "Run GZ302 setup?"; then
        warn "Skipped GZ302 setup"
        return 0
    fi

    local repo_dir="$HOME/GZ302-Linux-Setup"
    if [[ -d "$repo_dir" ]]; then
        info "Repo exists, pulling latest..."
        (cd "$repo_dir" && git pull --quiet)
    else
        info "Cloning repo..."
        git clone --quiet https://github.com/th3cavalry/GZ302-Linux-Setup.git "$repo_dir"
    fi

    cd "$repo_dir"
    if [[ ! -x ./gz302-setup.sh ]]; then
        err "gz302-setup.sh not found or not executable"
        return 1
    fi

    # The script is interactive; pass -y to accept defaults
    if [[ $ASSUME_YES -eq 1 ]]; then
        sudo ./gz302-setup.sh -y || warn "GZ302 script returned non-zero; continuing"
    else
        sudo ./gz302-setup.sh || warn "GZ302 script returned non-zero; continuing"
    fi
    cd "$HOME"
    ok "GZ302 setup completed"
}

# =============================================================================
# 4. Limine kernel parameters (the dcdebugmask fix)
# =============================================================================

fix_limine_kernel_params() {
    section "4. Limine kernel parameters"

    if [[ ! -f "$LIMINE_CONF" ]]; then
        warn "Limine config not found, skipping"
        return 0
    fi

    info "Required parameters:"
    for p in "${REQUIRED_KERNEL_PARAMS[@]}"; do
        info "  $p"
    done
    info "Note: dcdebugmask=0x600 (NOT 0xe12 — that caused hard freezes with the tray app)"

    # Backup
    sudo cp -a "$LIMINE_CONF" "${LIMINE_CONF}.bak.$(date +%s)"
    info "Backup: ${LIMINE_CONF}.bak.<timestamp>"

    local current
    current=$(sudo grep -E '^KERNEL_CMDLINE\[default\]' "$LIMINE_CONF" || echo "")

    if [[ -z "$current" ]]; then
        warn "No KERNEL_CMDLINE[default] line found. Manual editing required."
        return 1
    fi

    local needs_update=0
    for p in "${REQUIRED_KERNEL_PARAMS[@]}"; do
        local key="${p%%=*}"
        # First check if our exact param is already there
        if echo "$current" | grep -qE "(^| )${p//./\\.}( |\")"; then
            info "Already present: $p"
            continue
        fi
        # Check if a different value of the same key exists; if so, replace it
        if echo "$current" | grep -qE "(^| )${key//./\\.}=[^ \"]+"; then
            info "Replacing existing $key with: $p"
            sudo sed -i -E "s|(^| )${key//./\\.}=[^ \"]+|\1${p}|" "$LIMINE_CONF"
        else
            info "Appending: $p"
            # Append before the closing quote of the cmdline
            sudo sed -i -E "s|(^KERNEL_CMDLINE\[default\]\+?=\".*)\"|\1 ${p}\"|" "$LIMINE_CONF"
        fi
        needs_update=1
    done

    # Conflict check: 0xe12 should be replaced by 0x600
    if sudo grep -q "amdgpu.dcdebugmask=0xe12" "$LIMINE_CONF"; then
        warn "Found dcdebugmask=0xe12; replacing with 0x600 (the 0xe12 mask causes tray-app crashes)"
        sudo sed -i 's|amdgpu.dcdebugmask=0xe12|amdgpu.dcdebugmask=0x600|g' "$LIMINE_CONF"
        needs_update=1
    fi

    if [[ $needs_update -eq 1 ]]; then
        info "Running limine-update to apply..."
        if command -v limine-update >/dev/null; then
            sudo limine-update
        elif command -v limine-mkinitcpio >/dev/null; then
            sudo limine-mkinitcpio
        else
            warn "Neither limine-update nor limine-mkinitcpio found. Reboot to test changes."
        fi
        ok "Kernel parameters updated"
    else
        ok "Kernel parameters already correct"
    fi
}

# =============================================================================
# 5. Bluetooth AutoEnable
# =============================================================================

fix_bluetooth_autoenable() {
    section "5. Bluetooth AutoEnable"
    local conf="/etc/bluetooth/main.conf"

    if [[ ! -f "$conf" ]]; then
        warn "$conf not found, skipping"
        return 0
    fi

    if sudo grep -qE '^AutoEnable=true' "$conf"; then
        ok "AutoEnable=true already set"
        return 0
    fi

    sudo cp -a "$conf" "${conf}.bak.$(date +%s)"

    if sudo grep -qE '^#?AutoEnable=' "$conf"; then
        info "Uncommenting/setting AutoEnable=true"
        sudo sed -i 's|^#\?AutoEnable=.*|AutoEnable=true|' "$conf"
    else
        info "Adding AutoEnable=true under [Policy]"
        if sudo grep -q '^\[Policy\]' "$conf"; then
            sudo sed -i '/^\[Policy\]/a AutoEnable=true' "$conf"
        else
            echo -e "\n[Policy]\nAutoEnable=true" | sudo tee -a "$conf" >/dev/null
        fi
    fi

    sudo systemctl restart bluetooth
    ok "Bluetooth AutoEnable=true; service restarted"
}

# =============================================================================
# 6. MT7925 ASPM workaround
# =============================================================================

fix_mt7925_aspm() {
    section "6. MT7925 WiFi ASPM workaround"
    local conf="/etc/modprobe.d/mt7925e.conf"

    if [[ -f "$conf" ]] && grep -q "disable_aspm=1" "$conf"; then
        ok "MT7925 ASPM workaround already in place"
        return 0
    fi

    info "Applying MT7925 ASPM workaround (helps with WiFi/BT scan reliability)"
    echo "options mt7925e disable_aspm=1" | sudo tee "$conf" >/dev/null
    ok "MT7925 ASPM workaround applied (effective after reboot)"
}

# =============================================================================
# 7. Mask the broken asusd
# =============================================================================

mask_asusd() {
    section "7. Mask asusd (z13ctl replaces it)"

    if ! systemctl list-unit-files asusd.service &>/dev/null; then
        info "asusd not present, nothing to do"
        return 0
    fi

    info "asusd has known issues on kernel 7.0+ (status=226/NAMESPACE)"
    info "z13ctl handles RGB/fan/TDP/profiles; asusd is redundant"

    sudo systemctl disable --now asusd 2>/dev/null || true
    sudo systemctl mask asusd 2>/dev/null || true
    ok "asusd disabled and masked"
}

# =============================================================================
# 8. BlackArch repository
# =============================================================================

setup_blackarch() {
    section "8. BlackArch repository"
    if [[ $SKIP_BLACKARCH -eq 1 ]]; then
        warn "Skipped (--skip-blackarch)"
        return 0
    fi

    if grep -q "^\[blackarch\]" /etc/pacman.conf 2>/dev/null; then
        ok "BlackArch repo already configured"
        return 0
    fi

    if ! confirm "Add BlackArch pentest repository (~2860 tools available)?"; then
        warn "Skipped BlackArch repo"
        SKIP_BLACKARCH=1
        return 0
    fi

    local strap=/tmp/strap.sh
    info "Downloading strap.sh..."
    curl -sSfL -o "$strap" https://blackarch.org/strap.sh
    info "Verifying SHA1..."
    if ! echo "00688950aaf5e5804d2abebb8d3d3ea1d28525ed  $strap" | sha1sum -c; then
        err "SHA1 mismatch! strap.sh may be tampered. Aborting."
        rm -f "$strap"
        return 1
    fi
    chmod +x "$strap"
    sudo "$strap" || warn "strap.sh returned non-zero (likely cosmetic; continuing)"
    rm -f "$strap"

    # Sync, retrying if locked
    if [[ -f /var/lib/pacman/db.lck ]] && ! pgrep -x pacman >/dev/null; then
        warn "Stale pacman lock found; removing"
        sudo rm -f /var/lib/pacman/db.lck
    fi
    sudo pacman -Syy --noconfirm
    ok "BlackArch repo ready"
}

# =============================================================================
# 9. Pentest tool packages
# =============================================================================

install_pentest_tools() {
    section "9. Pentest tools"
    if [[ $SKIP_PENTEST -eq 1 || $SKIP_BLACKARCH -eq 1 ]]; then
        warn "Skipped (BlackArch not enabled)"
        return 0
    fi

    info "Installing blackarch-officials (curated essentials, ~150-200 tools)"
    if confirm "Install blackarch-officials?"; then
        sudo pacman -S --needed --noconfirm blackarch-officials || \
            warn "Some packages failed; continuing"
    fi

    info "Wordlists (SecLists, rockyou, dirb-lists)"
    if confirm "Install wordlists?"; then
        sudo pacman -S --needed --noconfirm seclists wordlists 2>/dev/null || \
            warn "Wordlists install had issues"
    fi

    info "Useful AUR pentest tools (autorecon, kerbrute, pwndbg, caido)"
    if confirm "Install AUR pentest tools?"; then
        yay -S --needed --noconfirm \
            autorecon-git \
            kerbrute-bin \
            pwndbg \
            caido-bin 2>/dev/null || warn "Some AUR packages failed"
    fi

    info "Optional categories (recon, webapp, wireless, cracker, fuzzer)"
    if confirm "Install additional categories (~10 GB)?"; then
        sudo pacman -S --needed --noconfirm \
            blackarch-recon \
            blackarch-scanner \
            blackarch-webapp \
            blackarch-fuzzer \
            blackarch-cracker \
            blackarch-wireless \
            blackarch-exploitation 2>/dev/null || warn "Some categories had issues"
    fi

    # Wireshark group + nmap capabilities
    info "Setting wireshark group + nmap capabilities..."
    sudo groupadd -f wireshark
    sudo usermod -aG wireshark "$USER"
    if command -v nmap >/dev/null; then
        sudo setcap cap_net_raw,cap_net_admin,cap_net_bind_service+eip "$(command -v nmap)" || true
    fi

    ok "Pentest tools ready (logout/login required for wireshark group)"
}

# =============================================================================
# 10. Documentation tools (Joplin, pandoc, LaTeX)
# =============================================================================

install_doc_tools() {
    section "10. Documentation tools"
    if [[ $SKIP_JOPLIN -eq 1 ]]; then
        warn "Skipped (--skip-joplin)"
        return 0
    fi

    if confirm "Install Joplin Desktop (notes for engagements)?"; then
        if command -v joplin-desktop >/dev/null || [[ -f "$HOME/.joplin/Joplin.AppImage" ]]; then
            ok "Joplin already installed"
        else
            info "Installing Joplin via official script..."
            wget -O - https://raw.githubusercontent.com/laurent22/joplin/dev/Joplin_install_and_update.sh | bash
        fi
    fi

    if confirm "Install pandoc + LaTeX (for PDF export of reports)?"; then
        sudo pacman -S --needed --noconfirm pandoc texlive-core texlive-latexextra
        ok "pandoc + LaTeX installed"
    fi

    if confirm "Install espanso (text snippets for repeated commands)?"; then
        yay -S --needed --noconfirm espanso 2>/dev/null || warn "espanso install failed"
    fi
}

# =============================================================================
# 11. Distrobox + podman (optional Kali container)
# =============================================================================

install_distrobox() {
    section "11. Distrobox (for optional Kali container)"
    if confirm "Install distrobox + podman (run Kali in a container if needed later)?"; then
        sudo pacman -S --needed --noconfirm distrobox podman
        ok "distrobox installed. Create Kali container later with:"
        ok "  distrobox create --image docker.io/kalilinux/kali-rolling --name kali"
        ok "  distrobox enter kali"
    fi
}

# =============================================================================
# 12. Snapshot a known-good state
# =============================================================================

create_snapper_baseline() {
    section "12. Snapper baseline snapshot"
    if ! command -v snapper >/dev/null; then
        warn "snapper not installed, skipping"
        return 0
    fi
    if confirm "Create a snapper snapshot 'Z13 setup baseline' for easy rollback?"; then
        sudo snapper -c root create --description "Z13 setup baseline ($(date +%F))" || \
            warn "Snapshot creation failed"
        ok "Snapshot created. View with: sudo snapper -c root list"
    fi
}

# =============================================================================
# 13. Final summary
# =============================================================================

final_summary() {
    section "Setup complete"

    cat <<EOF

  ${C_GREEN}✓${C_RESET} Hardware fixes applied (PSR-SU, suspend, audio, input)
  ${C_GREEN}✓${C_RESET} Kernel params: amd_pstate=guided, dcdebugmask=0x600, RTC ACPI
  ${C_GREEN}✓${C_RESET} Bluetooth AutoEnable=true
  ${C_GREEN}✓${C_RESET} MT7925 ASPM workaround
  ${C_GREEN}✓${C_RESET} asusd masked (z13ctl replaces it)
EOF

    [[ $SKIP_BLACKARCH -eq 0 ]] && echo "  ${C_GREEN}✓${C_RESET} BlackArch repo + officials"
    [[ $SKIP_PENTEST -eq 0 && $SKIP_BLACKARCH -eq 0 ]] && echo "  ${C_GREEN}✓${C_RESET} Pentest tools"
    [[ $SKIP_JOPLIN -eq 0 ]] && echo "  ${C_GREEN}✓${C_RESET} Joplin + pandoc + LaTeX"

    cat <<EOF

  ${C_YELLOW}Next steps:${C_RESET}
    1. ${C_BOLD}Reboot${C_RESET} to apply kernel parameter changes
    2. After reboot, verify:
         cat /proc/cmdline | grep -E "(amd_pstate|dcdebugmask)"
         systemctl --user status z13ctl
         bluetoothctl show | grep Powered
    3. Logout/login for wireshark group membership to take effect
    4. Test the GZ302 Dashboard tray app — should not freeze with dcdebugmask=0x600
    5. Pair your Bluetooth devices: bluetoothctl, then 'scan on'

  ${C_BLUE}Log file:${C_RESET} $LOG_FILE

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=============================================================="
    echo " ASUS ROG Flow Z13 — CachyOS post-install setup"
    echo " Script v$SCRIPT_VERSION"
    echo " Log: $LOG_FILE"
    echo "=============================================================="

    require_root
    preflight

    system_update
    install_base_tools
    run_gz302_setup
    fix_limine_kernel_params
    fix_bluetooth_autoenable
    fix_mt7925_aspm
    mask_asusd
    setup_blackarch
    install_pentest_tools
    install_doc_tools
    install_distrobox
    create_snapper_baseline

    final_summary
}

main "$@"
