#!/bin/bash

set -e

# Source the utilities file
source "$(dirname "$0")/utils.sh"

# Function to run pacman commands with retries for lock acquisition
run_pacman_with_retry() {
    local cmd_str="$*"
    local retries=10
    local wait_time=10 # seconds

    for ((i=1; i<=retries; i++)); do
        # Check for pacman lock
        if [[ -f /var/lib/pacman/db.lck ]]; then
            log_info "Pacman lock found, waiting..."
            sleep $wait_time
            continue
        fi

        # No lock detected, attempt the command
        if eval pacman "$@"; then
            return 0 # Success
        else
            local exit_code=$?
            if [ $i -lt $retries ]; then
                sleep $wait_time
            else
                return $exit_code # Failed after retries
            fi
        fi
    done

    log_error "Failed to acquire lock or run command after $retries attempts: pacman $cmd_str"
    return 1 # Failed after retries
}

# Function to check if yay is available
check_yay() {
    if ! command -v yay &> /dev/null; then
        log_info "yay (AUR helper) not found, installing..."
        # Install yay if not present
        run_pacman_with_retry -S --needed --noconfirm git base-devel
        
        # Create a temporary directory for building yay
        temp_dir=$(mktemp -d)
        cd "$temp_dir"
        
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
        
        # Clean up
        cd /
        rm -rf "$temp_dir"
    fi
}

log_info "Preparing Docker installation for Arch Linux..."

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    log_info "Docker is already installed."
    docker --version
    
    # Check for Docker Compose (both plugin and standalone)
    if docker-compose version &> /dev/null; then
        log_info "Docker Compose plugin found:"
        docker-compose version
    elif command -v docker-compose &> /dev/null; then
        log_info "Docker Compose standalone found:"
        docker-compose --version
    else
        log_warning "Docker Compose not found. It will be installed."
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
            log_info "Note: User will need to log out and back in for group changes to take effect."
        fi
    else
        log_warning "Could not identify a non-root user. Docker will only be available for the root user."
    fi

    exit 0
fi

# Update system first
log_info "Updating system packages..."
run_pacman_with_retry -Syu --noconfirm

# Install Docker from official repositories
log_info "Installing Docker from official Arch repositories..."
run_pacman_with_retry -S --needed --noconfirm \
    docker \
    docker-compose \
    containerd \
    runc

# Enable and start Docker service
log_info "Enabling and starting Docker service..."
systemctl enable --now docker.service
systemctl enable --now containerd.service

# Alternatively, install Docker Compose plugin via yay (more up-to-date)
if command -v yay &> /dev/null || (check_yay && command -v yay &> /dev/null); then
    log_info "Installing Docker Compose plugin from AUR (for latest version)..."
    yay -S --needed --noconfirm docker-compose-bin
fi

# Add user to docker group
ORIGINAL_USER=${SUDO_USER:-$(whoami)}
log_info "Adding user '$ORIGINAL_USER' to the docker group..."

if id "$ORIGINAL_USER" &>/dev/null; then
    if ! groups "$ORIGINAL_USER" | grep -q '\bdocker\b'; then
        usermod -aG docker "$ORIGINAL_USER"
        log_info "Note: User will need to log out and back in for group changes to take effect."
    else
        log_info "User '$ORIGINAL_USER' is already in the docker group."
    fi
fi

# Verify installation
log_info "Verifying Docker installation..."
docker --version

# Check for Docker Compose (try plugin first, then standalone)
if docker-compose version &> /dev/null; then
    log_info "Docker Compose plugin:"
    docker-compose version
elif command -v docker-compose &> /dev/null; then
    log_info "Docker Compose standalone:"
    docker-compose --version
else
    log_error "Docker Compose installation failed."
    exit 1
fi

# Optional: Test Docker installation
log_info "Testing Docker installation with hello-world..."
if docker run --rm hello-world &>/dev/null; then
    log_info "Docker installation successful!"
else
    log_warning "Docker installation might have issues. Please check the service status with: sudo systemctl status docker"
fi

exit 0