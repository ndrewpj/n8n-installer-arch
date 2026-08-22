#!/bin/bash
# Trimmed mirror of upstream 01_system_preparation.sh (Ubuntu idioms).
set -euo pipefail

# Update package list
apt update -y

# Upgrade all packages
apt upgrade -y

# Install base tools
apt install -y git curl make ufw fail2ban python3 psmisc whiptail build-essential ca-certificates gnupg lsb-release openssl apt-transport-https python3-dotenv python3-yaml

# Non-interactive mode
DEBIAN_FRONTEND=noninteractive

# Enable unattended upgrades
apt install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades
