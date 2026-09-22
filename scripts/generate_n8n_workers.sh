#!/bin/bash
# Generates docker-compose.n8n-workers.yml with N worker-runner pairs and
# prometheus/targets/n8n.json with the scrape targets for n8n main and the workers
# Usage: N8N_WORKER_COUNT=3 bash scripts/generate_n8n_workers.sh
#
# Idempotent: with the n8n profile active both files are rewritten from scratch.
# With the profile inactive only the targets file is removed - the compose file
# stays because start_services.py uses its presence to stop leftover workers.

set -euo pipefail

# Source the utilities file and initialize paths
source "$(dirname "$0")/utils.sh"
init_paths

OUTPUT_FILE="$PROJECT_ROOT/docker-compose.n8n-workers.yml"
TARGETS_FILE="$PROJECT_ROOT/prometheus/targets/n8n.json"

# Load values from .env if not already set in the environment
if [[ -f "$ENV_FILE" ]]; then
    [[ -z "${N8N_WORKER_COUNT:-}" ]] && N8N_WORKER_COUNT=$(read_env_var "N8N_WORKER_COUNT")
    [[ -z "${COMPOSE_PROFILES:-}" ]] && COMPOSE_PROFILES=$(read_env_var "COMPOSE_PROFILES")
else
    log_warning ".env not found at $ENV_FILE - reading N8N_WORKER_COUNT and COMPOSE_PROFILES from the environment only"
fi
N8N_WORKER_COUNT=${N8N_WORKER_COUNT:-1}
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"

if ! is_profile_active "n8n"; then
    log_info "n8n profile not active (COMPOSE_PROFILES='$COMPOSE_PROFILES') - nothing to generate"
    if [[ -f "$TARGETS_FILE" ]]; then
        log_info "Removing $TARGETS_FILE"
        rm -f "$TARGETS_FILE" || { log_error "Failed to remove $TARGETS_FILE - Prometheus keeps scraping n8n targets that no longer exist"; exit 1; }
    fi
    exit 0
fi

# Validate N8N_WORKER_COUNT
if ! [[ "$N8N_WORKER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    log_error "N8N_WORKER_COUNT must be a positive integer, got: '$N8N_WORKER_COUNT'"
    exit 1
fi

log_info "Generating n8n worker-runner pairs configuration..."
log_info "N8N_WORKER_COUNT=$N8N_WORKER_COUNT"

# Overwrite file (idempotent)
cat > "$OUTPUT_FILE" << 'EOF'
# Auto-generated file for n8n worker-runner pairs
# Regenerate with: bash scripts/generate_n8n_workers.sh
# DO NOT EDIT MANUALLY - this file is overwritten on each run

services:
EOF

for i in $(seq 1 "$N8N_WORKER_COUNT"); do
cat >> "$OUTPUT_FILE" << EOF
  n8n-worker-$i:
    extends:
      file: docker-compose.yml
      service: n8n-worker-template
    container_name: n8n-worker-$i
    profiles: ["n8n"]
    restart: unless-stopped
    depends_on:
      n8n:
        condition: service_healthy
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy

  n8n-runner-$i:
    extends:
      file: docker-compose.yml
      service: n8n-runner-template
    container_name: n8n-runner-$i
    profiles: ["n8n"]
    restart: unless-stopped
    network_mode: "service:n8n-worker-$i"
    depends_on:
      n8n-worker-$i:
        condition: service_healthy

EOF
done

log_info "Generated $OUTPUT_FILE with $N8N_WORKER_COUNT worker-runner pair(s)"

# Prometheus scrape targets: n8n main plus every worker, each group with its job label
workers=""
for i in $(seq 1 "$N8N_WORKER_COUNT"); do
    workers+="${workers:+, }\"n8n-worker-$i:5678\""
done
targets_json="[{\"labels\": {\"job\": \"n8n\"}, \"targets\": [\"n8n:5678\"]}, {\"labels\": {\"job\": \"n8n-worker\"}, \"targets\": [$workers]}]"
# Temp file + mv: Prometheus watches this file and must never read it half-written
if ! { mkdir -p "$(dirname "$TARGETS_FILE")" && echo "$targets_json" > "$TARGETS_FILE.tmp" && mv -f "$TARGETS_FILE.tmp" "$TARGETS_FILE"; }; then
    log_error "Failed to write $TARGETS_FILE - Prometheus will not scrape n8n. Check permissions on $(dirname "$TARGETS_FILE")."
    exit 1
fi

log_info "Generated $TARGETS_FILE (n8n main + $N8N_WORKER_COUNT worker target(s))"
