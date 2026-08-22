#!/bin/bash
# Trimmed mirror of upstream 02_install_docker.sh + a caddy install/remove pair (Ubuntu idioms).
set -euo pipefail

# Install helper tools (no apt update before this -> no-prior-update guard fires)
apt install -y python3-pip

# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Add the Docker apt repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

# Refresh index now that the repo is registered
apt-get update -y

# Install Docker Engine
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Install and remove Caddy to exercise the remove/install pair
apt install -y caddy
apt remove -y caddy
