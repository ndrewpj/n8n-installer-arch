#!/bin/bash
# =============================================================================
# 01_system_preparation.sh - System preparation and security hardening
# =============================================================================
# Prepares the host for running Docker services. Supports two package families
# (auto-detected via /etc/os-release in utils.sh):
#   - debian  : Ubuntu / Debian (apt)
#   - arch    : Arch Linux / CachyOS (pacman)
#
#   - Updates system packages and installs essential CLI tools
#   - Configures UFW firewall (allows SSH, HTTP, HTTPS; denies other incoming)
#   - Enables Fail2Ban for SSH brute-force protection
#   - Sets up automatic security updates (Debian/Ubuntu only; Arch is rolling)
#   - Configures vm.max_map_count for Elasticsearch (required by RAGFlow)
#
# Required: Must be run as root (sudo)
# =============================================================================

set -e

# Source the utilities file and initialize paths
source "$(dirname "$0")/utils.sh"
init_paths

# Source git utilities
source "$SCRIPT_DIR/git.sh"

detect_distro
log_info "Detected distribution: ${DISTRO_ID} (package family: ${PKG_FAMILY})"
if [ "$PKG_FAMILY" = "unknown" ]; then
    log_error "Unsupported distribution '${DISTRO_ID}'. This installer supports Ubuntu/Debian and Arch/CachyOS."
    exit 1
fi

if [ "$PKG_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive

    # System Update
    log_subheader "System Update"
    log_info "Updating package list..."
    apt update -y
    log_info "Enabling universe repository..."
    apt install -y software-properties-common
    add-apt-repository universe -y
    log_info "Upgrading the system..."
    apt upgrade -y

    # Installing Basic Utilities
    log_subheader "Installing Utilities"
    log_info "Installing standard CLI tools..."
    apt install -y \
      git curl make ufw fail2ban python3 psmisc whiptail \
      build-essential ca-certificates gnupg lsb-release openssl \
      apt-transport-https python3-dotenv python3-yaml
else
    # Arch / CachyOS
    log_subheader "System Update"
    log_info "Refreshing mirrors and upgrading the system (pacman -Syu)..."
    pacman -Syu --noconfirm

    # Installing Basic Utilities
    # whiptail ships in libnewt; build-essential equivalent is base-devel;
    # python-dotenv / python-yaml are the Arch package names of python3-dotenv /
    # python3-yaml. archlinux-keyring is refreshed before the upgrade above can
    # matter and again here, so a stale signing key does not break the install.
    # No universe repo or apt-transport-https equivalent exists.
    log_subheader "Installing Utilities"
    log_info "Refreshing the Arch signing keyring..."
    pacman -S --noconfirm --needed archlinux-keyring || log_warning "Could not refresh archlinux-keyring; continuing."
    log_info "Installing standard CLI tools..."
    pacman -S --noconfirm --needed \
      git curl make ufw fail2ban python psmisc libnewt \
      base-devel ca-certificates gnupg openssl unzip htop \
      python-dotenv python-yaml
fi

# Configure git to use rebase on pull (prevents merge commits during updates)
git_configure_pull_rebase

# Configuring Firewall (UFW)
# 'ufw' is the same userspace tool on both families; on Arch the ufw.service
# unit persists the rules across reboot, so enable it explicitly.
log_subheader "Firewall (UFW)"
log_info "Configuring firewall..."
echo "y" | ufw reset
ufw --force enable
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow http
ufw allow https
if [ "$PKG_FAMILY" = "arch" ]; then
    systemctl enable ufw
    systemctl restart ufw
fi
ufw reload
ufw status

# Configuring Fail2Ban
log_subheader "Fail2Ban"
log_info "Enabling brute-force protection..."
if [ "$PKG_FAMILY" = "arch" ]; then
    # Arch ships fail2ban with no jail enabled. Enable the sshd jail through a
    # .local drop-in (preserved across package upgrades) if nothing enables it yet.
    if [ ! -f /etc/fail2ban/jail.d/sshd.local ] && ! grep -qs '^enabled[[:space:]]*=[[:space:]]*true' /etc/fail2ban/jail.d/sshd.conf 2>/dev/null; then
        log_info "Enabling the sshd jail via /etc/fail2ban/jail.d/sshd.local..."
        install -d /etc/fail2ban/jail.d
        printf '[sshd]\nenabled = true\n' > /etc/fail2ban/jail.d/sshd.local
    fi
fi
systemctl enable fail2ban
sleep 1
systemctl restart fail2ban
sleep 1
fail2ban-client status
fail2ban-client status sshd

# Automatic Security Updates
log_subheader "Security Updates"
if [ "$PKG_FAMILY" = "debian" ]; then
    log_info "Enabling automatic security updates..."
    apt install -y unattended-upgrades
    # Automatic confirmation for dpkg-reconfigure
    echo "y" | dpkg-reconfigure --priority=low unattended-upgrades
else
    # Arch/CachyOS is a rolling-release distro: there is no unattended-upgrades
    # equivalent. CachyOS ships its own update tooling (e.g. cachyos-settings /
    # the Calamares-provided updater); regular 'pacman -Syu' (run by
    # 'make update') is the supported path.
    log_info "Arch-based system: skipping unattended-upgrades (rolling release). Run 'make update' / 'pacman -Syu' regularly."
fi

# Configure vm.max_map_count for Elasticsearch (required for RAGFlow)
log_subheader "Kernel Parameters"
log_info "Configuring vm.max_map_count for Elasticsearch..."
CURRENT_VALUE=$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")
if [[ "$CURRENT_VALUE" -lt 262144 ]]; then
  log_info "Setting vm.max_map_count=262144 (current: $CURRENT_VALUE)..."
  sysctl -w vm.max_map_count=262144

  # Make it permanent
  if [ "$PKG_FAMILY" = "arch" ]; then
    # systemd-sysctl drop-in (the Arch-idiomatic location)
    if [ ! -f /etc/sysctl.d/99-elasticsearch.conf ]; then
      install -d /etc/sysctl.d
      echo "vm.max_map_count=262144" > /etc/sysctl.d/99-elasticsearch.conf
      log_info "Added /etc/sysctl.d/99-elasticsearch.conf for persistence"
    fi
  elif ! grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    log_info "Added vm.max_map_count to /etc/sysctl.conf for persistence"
  fi
else
  log_info "vm.max_map_count already configured (current: $CURRENT_VALUE)"
fi

exit 0
