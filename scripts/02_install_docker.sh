#!/bin/bash
# =============================================================================
# 02_install_docker.sh - Docker and Docker Compose installation
# =============================================================================
# Installs Docker Engine and the Docker Compose plugin:
#   - Skips installation if Docker is already present
#   - debian family: adds Docker's official GPG key and APT repository and
#     installs docker-ce, docker-ce-cli, containerd.io, and the compose plugin
#   - arch family:   installs the distro 'docker', 'docker-compose' (CLI plugin),
#     'docker-buildx' and 'docker-scan' packages from the official repositories
#     (no third-party repo needed; the daemon is the 'docker' package)
#   - Adds the invoking user to the 'docker' group
#   - Includes retry logic for package commands (handles lock contention)
#
# Required: Must be run as root (sudo)
# =============================================================================

set -e

# Source the utilities file
source "$(dirname "$0")/utils.sh"
init_paths

detect_distro
log_info "Detected distribution: ${DISTRO_ID} (package family: ${PKG_FAMILY})"
if [ "$PKG_FAMILY" = "unknown" ]; then
    log_error "Unsupported distribution '${DISTRO_ID}'. This installer supports Ubuntu/Debian and Arch/CachyOS."
    exit 1
fi

# 1. Preparing the environment
if [ "$PKG_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    APT_OPTIONS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef -y"
fi

# Configuration for package-command retry logic
PKG_RETRY_COUNT=10
PKG_RETRY_WAIT=10

# Lock files held by the package manager while it is running.
pkg_lock_busy() {
    if [ "$PKG_FAMILY" = "debian" ]; then
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
            || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
            || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
            || fuser /var/cache/apt/archives/lock >/dev/null 2>&1
    else
        # pacman guards its database with a single lock file
        fuser /var/lib/pacman/db.lck >/dev/null 2>&1
    fi
}

# Function to run package manager commands with retries for lock acquisition
run_pkg_with_retry() {
    local cmd_str="$*"

    for ((i=1; i<=PKG_RETRY_COUNT; i++)); do
        # Check for package-manager locks using fuser
        if pkg_lock_busy; then
            sleep $PKG_RETRY_WAIT
            continue
        fi

        # No lock detected, attempt the command (safe argument passing without eval)
        if "$@"; then
            return 0
        else
            local exit_code=$?
            if [ $i -lt $PKG_RETRY_COUNT ]; then
                sleep $PKG_RETRY_WAIT
            else
                return $exit_code
            fi
        fi
    done

    log_error "Failed to acquire lock or run command after $PKG_RETRY_COUNT attempts: $cmd_str"
    return 1
}


# Check if Docker is already installed
log_subheader "Docker Check"
if command -v docker &> /dev/null; then
    log_info "Docker is already installed."
    docker --version
    # Check for Docker Compose plugin
    if docker compose version &> /dev/null; then
        docker compose version
    else
        log_error "Docker Compose plugin not found. Consider reinstalling or checking the installation."
        exit 1
    fi

    # Get the original user who invoked sudo
    ORIGINAL_USER=${SUDO_USER:-$(whoami)}
    # Skip user operations if we're root and SUDO_USER is not set
    if [ "$ORIGINAL_USER" != "root" ] && id "$ORIGINAL_USER" &>/dev/null; then
        # Check docker group membership
        if groups "$ORIGINAL_USER" | grep &> /dev/null '\bdocker\b'; then
            log_info "User '$ORIGINAL_USER' is already in the docker group."
        else
            log_info "Adding user '$ORIGINAL_USER' to the docker group..."
            usermod -aG docker "$ORIGINAL_USER"
        fi
    else
        log_warning "Could not identify a non-root user. Docker will only be available for the root user."
    fi

    exit 0
fi

if [ "$PKG_FAMILY" = "arch" ]; then
    # ------------------------------------------------------------------------
    # Arch / CachyOS: everything comes from the official repositories.
    #   docker          - daemon + CLI (pulls containerd as a dependency)
    #   docker-compose  - the 'docker compose' CLI plugin
    #   docker-buildx   - the 'docker buildx' CLI plugin
    #   docker-scan     - the 'docker scan' CLI plugin (optional, matches the
    #                     docker-ce package set on Ubuntu)
    # No GPG key / repo file is added: the distro packages are already signed.
    # ------------------------------------------------------------------------
    log_subheader "Docker Installation"
    log_info "Installing Docker, Compose and Buildx from the Arch repositories..."
    run_pkg_with_retry pacman -S --noconfirm --needed \
        docker docker-compose docker-buildx docker-scan \
        || { log_error "Failed to install Docker packages."; exit 1; }

    log_subheader "Docker Service"
    log_info "Enabling and starting the Docker daemon (systemd)..."
    systemctl enable docker
    systemctl start docker

    # 6. Adding the user to the Docker group
    log_subheader "User Configuration"
    ORIGINAL_USER=${SUDO_USER:-$(whoami)}
    log_info "Adding user '$ORIGINAL_USER' to the docker group..."
    if id "$ORIGINAL_USER" &>/dev/null; then
        usermod -aG docker "$ORIGINAL_USER"
    fi

    # 7. Verifying the installation
    log_info "Verifying Docker installation..."
    docker --version
    docker compose version

    exit 0
fi

# 2. Updating and installing dependencies
log_subheader "Dependencies"
log_info "Installing necessary dependencies..."
run_pkg_with_retry apt-get update -qq
run_pkg_with_retry apt-get install -qq $APT_OPTIONS \
  ca-certificates \
  curl \
  gnupg \
  lsb-release || { log_error "Failed to install dependencies."; exit 1; }

# 3. Adding Docker's GPG key
log_subheader "Docker Repository"
log_info "Adding Docker's GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# 4. Adding the Docker repository
log_info "Adding the official Docker APT repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. Installing Docker and Docker Compose
log_subheader "Docker Installation"
log_info "Installing Docker Engine and Compose Plugin..."
run_pkg_with_retry apt-get update -qq
run_pkg_with_retry apt-get install -qq $APT_OPTIONS \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin || { log_error "Failed to install Docker packages."; exit 1; }

# 6. Adding the user to the Docker group
log_subheader "User Configuration"
ORIGINAL_USER=${SUDO_USER:-$(whoami)}
log_info "Adding user '$ORIGINAL_USER' to the docker group..."
if id "$ORIGINAL_USER" &>/dev/null; then
    usermod -aG docker "$ORIGINAL_USER"
fi

# 7. Verifying the installation
log_info "Verifying Docker installation..."
docker --version
docker compose version

exit 0
