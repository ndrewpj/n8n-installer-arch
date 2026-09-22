#!/bin/bash
# =============================================================================
# 06_run_services.sh - Service launcher
# =============================================================================
# Starts all selected services using Docker Compose via start_services.py.
#
# Pre-flight checks:
#   - Verifies .env, docker-compose.yml, and Caddyfile exist
#   - Ensures Docker daemon is running
#   - Makes start_services.py executable if needed
#
# The actual service orchestration is handled by start_services.py which:
#   - Starts services in correct dependency order
#   - Handles profile-based service selection
#   - Manages health checks and startup timeouts
#
# Usage: bash scripts/06_run_services.sh
# =============================================================================

set -e

# Source the utilities file and initialize paths
source "$(dirname "$0")/utils.sh"
init_paths

cd "$PROJECT_ROOT"

# Check required files
log_subheader "Pre-flight Checks"
require_file "$ENV_FILE" ".env file not found in project root."
require_file "$PROJECT_ROOT/docker-compose.yml" "docker-compose.yml file not found in project root."
require_file "$PROJECT_ROOT/Caddyfile" "Caddyfile not found in project root. Reverse proxy might not work."
require_file "$PROJECT_ROOT/start_services.py" "start_services.py file not found in project root."

# Remove legacy custom-tls.conf that causes duplicate host errors
# This is needed for users upgrading from older versions
# TODO: Remove this cleanup block after v3.0 release (all users migrated)
OLD_TLS_CONFIG="$PROJECT_ROOT/caddy-addon/custom-tls.conf"
if [[ -f "$OLD_TLS_CONFIG" ]]; then
    log_warning "Removing obsolete custom-tls.conf (causes duplicate host errors)"
    rm -f "$OLD_TLS_CONFIG"
fi

# Ensure TLS snippet exists (auto-create from template if missing)
TLS_SNIPPET="$PROJECT_ROOT/caddy-addon/tls-snippet.conf"
TLS_TEMPLATE="$PROJECT_ROOT/caddy-addon/tls-snippet.conf.example"
if [[ ! -f "$TLS_SNIPPET" ]] && [[ -f "$TLS_TEMPLATE" ]]; then
    cp "$TLS_TEMPLATE" "$TLS_SNIPPET"
    log_info "Created tls-snippet.conf from template (Let's Encrypt mode)"
fi

# Check if Docker daemon is running
if ! docker info > /dev/null 2>&1; then
  log_error "Docker daemon is not running. Please start Docker and try again."
  exit 1
fi

# Ensure start_services.py is executable
if [ ! -x "$PROJECT_ROOT/start_services.py" ]; then
  log_warning "start_services.py is not executable. Making it executable..."
  chmod +x "$PROJECT_ROOT/start_services.py"
fi

# Keep the Supabase API gateway bound to loopback (issue #108). Must run before
# start_services.py, which is what prepares supabase/docker/.env and starts the
# Supabase stack. Covers both fresh install and 'make update'.
harden_supabase_gateway_bind

log_subheader "Starting Services"
log_info "Launching services using start_services.py..."
# Execute start_services.py
"$PROJECT_ROOT/start_services.py"

exit 0
