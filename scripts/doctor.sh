#!/bin/bash

# System diagnostics script for Selfhost AI
# Checks DNS, SSL, containers, disk space, memory, and configuration

# Source the utilities file and initialize paths
source "$(dirname "$0")/utils.sh"
init_paths

# Counters for summary
ERRORS=0
WARNINGS=0
OK=0

# Wrapper functions that also count results
count_ok() {
    print_ok "$1"
    OK=$((OK + 1))
}

count_warning() {
    print_warning "$1"
    WARNINGS=$((WARNINGS + 1))
}

count_error() {
    print_error "$1"
    ERRORS=$((ERRORS + 1))
}

# Header
log_box "Selfhost AI System Diagnostics"

# Check if .env file exists
log_subheader "Configuration"

if [ -f "$ENV_FILE" ]; then
    count_ok ".env file exists"

    # Load environment variables
    load_env

    # Check required variables
    if [ -n "$USER_DOMAIN_NAME" ]; then
        count_ok "USER_DOMAIN_NAME is set: $USER_DOMAIN_NAME"
    else
        count_error "USER_DOMAIN_NAME is not set"
    fi

    if [ -n "$LETSENCRYPT_EMAIL" ]; then
        count_ok "LETSENCRYPT_EMAIL is set"
    else
        count_warning "LETSENCRYPT_EMAIL is not set (SSL certificates may not work)"
    fi

    if [ -n "$COMPOSE_PROFILES" ]; then
        count_ok "Active profiles: $COMPOSE_PROFILES"
    else
        count_warning "No service profiles are active"
    fi

    # Renamed in 1.13: the bare 'comfyui' profile activates nothing, so the
    # old container keeps running untouched by restarts (or nothing runs at all).
    if is_profile_active "comfyui"; then
        count_error "The 'comfyui' profile was replaced by comfyui-nvidia / comfyui-amd / comfyui-cpu in 1.13 — ComfyUI is not managed by this stack until you run 'make update' and pick a hardware profile."
    fi

    # Ollama API exposure: when OLLAMA_HOSTNAME points at a real domain, the Caddy
    # bearer-token gate needs a non-empty OLLAMA_CADDY_API_TOKEN to be usable. With
    # an empty token the matcher becomes "Bearer " (trailing space); Go trims
    # trailing whitespace from header values, so no request can ever match and the
    # endpoint rejects everything with 401 (fail-closed, but non-functional).
    if [ -n "$OLLAMA_HOSTNAME" ] && [ "$OLLAMA_HOSTNAME" != "yourdomain.com" ] && [[ "$OLLAMA_HOSTNAME" != *".yourdomain.com" ]]; then
        if [ -n "$OLLAMA_CADDY_API_TOKEN" ]; then
            count_ok "OLLAMA_CADDY_API_TOKEN is set (Ollama API is token-protected)"
        else
            count_error "OLLAMA_HOSTNAME is set but OLLAMA_CADDY_API_TOKEN is empty — the Ollama endpoint will reject all requests (401). Run 'make update' to regenerate the token."
        fi
    fi

    # n8n-MCP refuses to start in http mode without AUTH_TOKEN or AUTH_TOKEN_FILE
    # (the entrypoint exits 1). This stack only ever sets AUTH_TOKEN, and Caddy
    # would otherwise gate on a bare "Bearer " and 401 everything.
    if is_profile_active "n8n-mcp" && [ -z "$N8N_MCP_AUTH_TOKEN" ]; then
        count_error "n8n-mcp profile is active but N8N_MCP_AUTH_TOKEN is empty — the container exits on startup and the endpoint would reject all requests (401). Run 'make update' to generate the token."
    fi

    # Multi-instance Ollama: extra instances are pinned to explicit GPU IDs, but
    # instance 1 falls back to a count-based reservation, so Docker can hand it a
    # GPU already pinned to ollama2 and the two then fight over the same VRAM.
    if [ "${OLLAMA_INSTANCE_COUNT:-1}" -gt 1 ] 2>/dev/null && is_profile_active "gpu-nvidia"; then
        if [ -n "$OLLAMA_GPU_DEVICES" ]; then
            count_ok "OLLAMA_GPU_DEVICES is set (all $OLLAMA_INSTANCE_COUNT Ollama instances are GPU-pinned)"
        else
            count_warning "OLLAMA_INSTANCE_COUNT=$OLLAMA_INSTANCE_COUNT but OLLAMA_GPU_DEVICES is empty — the first Ollama instance is not pinned and may share a GPU with ollama2. Set OLLAMA_GPU_DEVICES in .env (e.g. 0)."
        fi
    fi

    # Crawl4AI 0.9+ binds loopback only when CRAWL4AI_API_TOKEN is empty, so the
    # container looks "Up" while other containers get connection refused. A
    # healthcheck cannot catch this (localhost works either way), so check here.
    if is_profile_active "crawl4ai"; then
        if [ -n "$CRAWL4AI_API_TOKEN" ]; then
            count_ok "CRAWL4AI_API_TOKEN is set (Crawl4AI listens on the Docker network)"
        else
            count_error "crawl4ai profile is active but CRAWL4AI_API_TOKEN is empty — Crawl4AI binds loopback only and other containers cannot reach it. Run 'make update' to generate the token."
        fi
    fi

else
    count_error ".env file not found at $ENV_FILE"
    print_info "Run 'make install' to set up the environment."
    exit 1
fi

# Check Docker
log_subheader "Docker"

if command -v docker &> /dev/null; then
    count_ok "Docker is installed"

    if docker info &> /dev/null; then
        count_ok "Docker daemon is running"
    else
        count_error "Docker daemon is not running or not accessible"
    fi
else
    count_error "Docker is not installed"
fi

if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
    count_ok "Docker Compose is available"
else
    count_warning "Docker Compose is not available"
fi

# n8n Assistant sandbox: the runner must run under the isolation .env promises
if is_profile_active "n8n-sandbox"; then
    SANDBOX_RUNTIME="${N8N_SANDBOX_RUNNER_RUNTIME:-runc}"
    SANDBOX_PRIVILEGED="${N8N_SANDBOX_RUNNER_PRIVILEGED:-false}"
    if [ "$SANDBOX_RUNTIME" = "sysbox-runc" ] && [ "$SANDBOX_PRIVILEGED" = "true" ]; then
        count_error "N8N_SANDBOX_RUNNER_RUNTIME=sysbox-runc together with N8N_SANDBOX_RUNNER_PRIVILEGED=true - Sysbox rejects privileged containers. Run 'make update' to let the installer rewrite both values."
    fi
    if ! docker info &> /dev/null; then
        count_warning "Docker is not accessible, so the n8n sandbox runner isolation could not be checked."
    else
        if [ "$SANDBOX_RUNTIME" = "sysbox-runc" ]; then
            if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"sysbox-runc"'; then
                count_error "N8N_SANDBOX_RUNNER_RUNTIME=sysbox-runc but Docker has no sysbox-runc runtime - sandbox-runner-1 cannot start. Run 'sudo bash scripts/setup_sysbox.sh', then 'make restart'."
            elif command -v systemctl &> /dev/null && ! systemctl is-active --quiet sysbox 2>/dev/null; then
                count_error "The sysbox service is not running - sandbox-runner-1 cannot start (systemctl status sysbox)."
            fi
        fi
        if ! docker inspect sandbox-runner-1 &> /dev/null; then
            count_warning "The sandbox-runner-1 container does not exist, so its isolation could not be checked. Run 'make restart'."
        else
            RUNNER_STATE="$(docker inspect sandbox-runner-1 --format '{{.HostConfig.Runtime}} {{.HostConfig.Privileged}} {{.State.Status}}' 2>/dev/null)"
            case "$RUNNER_STATE" in
                "sysbox-runc false running") count_ok "n8n sandbox runner is running, isolated with sysbox-runc" ;;
                *" true running") count_warning "n8n sandbox runner runs PRIVILEGED (root-equivalent on this host). Install Sysbox with 'sudo bash scripts/setup_sysbox.sh', then 'make update'." ;;
                *" running") count_error "n8n sandbox runner is neither sysbox-isolated nor privileged ($RUNNER_STATE) - Docker-in-Docker cannot work. Run 'make update'." ;;
                *) count_error "n8n sandbox runner is not running (${RUNNER_STATE##* }) - see 'docker logs sandbox-runner-1'." ;;
            esac
        fi
    fi
fi

# Check disk space
log_subheader "Disk Space"

DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')

if [ "$DISK_USAGE" -lt 80 ]; then
    count_ok "Disk usage: ${DISK_USAGE}% (${DISK_AVAIL} available)"
elif [ "$DISK_USAGE" -lt 90 ]; then
    count_warning "Disk usage: ${DISK_USAGE}% (${DISK_AVAIL} available) - Consider freeing space"
else
    count_error "Disk usage: ${DISK_USAGE}% (${DISK_AVAIL} available) - Critical!"
fi

# Check Docker disk usage
DOCKER_DISK=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)
if [ -n "$DOCKER_DISK" ]; then
    print_info "Docker using: $DOCKER_DISK"
fi

# Check memory
log_subheader "Memory"

if command -v free &> /dev/null; then
    MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
    MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
    MEM_AVAIL=$(free -h | awk '/^Mem:/ {print $7}')
    MEM_PERCENT=$(free | awk '/^Mem:/ {printf("%.0f", $3/$2 * 100)}')

    if [ "$MEM_PERCENT" -lt 80 ]; then
        count_ok "Memory usage: ${MEM_PERCENT}% (${MEM_AVAIL} available of ${MEM_TOTAL})"
    elif [ "$MEM_PERCENT" -lt 90 ]; then
        count_warning "Memory usage: ${MEM_PERCENT}% (${MEM_AVAIL} available)"
    else
        count_error "Memory usage: ${MEM_PERCENT}% - High memory pressure!"
    fi
else
    print_info "Memory info not available (free command not found)"
fi

# Check containers
log_subheader "Containers"

RUNNING=$(docker ps -q 2>/dev/null | wc -l)
TOTAL=$(docker ps -aq 2>/dev/null | wc -l)

print_info "$RUNNING of $TOTAL containers running"

# Check for containers with high restart counts
HIGH_RESTARTS=0
while read -r line; do
    if [ -n "$line" ]; then
        name=$(echo "$line" | cut -d'|' -f1)
        restarts=$(echo "$line" | cut -d'|' -f2)
        if [ "$restarts" -gt 3 ]; then
            count_warning "$name has restarted $restarts times"
            HIGH_RESTARTS=$((HIGH_RESTARTS + 1))
        fi
    fi
done < <(docker ps --format '{{.Names}}|{{.Status}}' 2>/dev/null | while read container; do
    name=$(echo "$container" | cut -d'|' -f1)
    restarts=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo "0")
    echo "$name|$restarts"
done)

if [ "$HIGH_RESTARTS" -eq 0 ]; then
    count_ok "No containers with excessive restarts"
fi

# Check unhealthy containers
UNHEALTHY=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null)
if [ -n "$UNHEALTHY" ]; then
    for container in $UNHEALTHY; do
        count_error "Container $container is unhealthy"
    done
else
    count_ok "No unhealthy containers"
fi

# Open WebUI storage backend (issue #105)
# Two things can silently put a Postgres-configured instance back on SQLite,
# which looks like total data loss to the user: a missing 'openwebui' database,
# or a compose invocation that forgot docker-compose.open-webui-postgres.yml.
# The second check inspects the running container, not just .env.
if is_profile_active "open-webui" && [ "${OPEN_WEBUI_DATABASE:-sqlite}" = "postgres" ]; then
    # Probe reachability first, otherwise a stopped postgres, an unreachable
    # daemon or a permissions problem all get reported as "database missing",
    # sending the user to 'make update', which cannot fix any of them.
    if ! docker exec postgres pg_isready -U postgres >/dev/null 2>&1; then
        count_error "Cannot reach the postgres container to verify the 'openwebui' database. Check: docker compose -p localai logs postgres"
    elif docker exec postgres psql -U postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='openwebui'" 2>/dev/null | grep -q 1; then
        count_ok "Open WebUI database 'openwebui' exists"
    else
        count_error "OPEN_WEBUI_DATABASE=postgres but the 'openwebui' database is missing - run 'make update' to create it"
    fi

    # Same care as above: a container that was never created makes 'docker
    # inspect' fail, which must not be reported as "it is on SQLite".
    if ! docker inspect open-webui >/dev/null 2>&1; then
        count_warning "The open-webui container does not exist, so its storage backend could not be checked. Start the stack with 'make start'."
    elif docker inspect open-webui --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep -q '^DATABASE_URL=postgresql://'; then
        count_ok "Open WebUI is running against PostgreSQL"
    else
        count_error "OPEN_WEBUI_DATABASE=postgres but the running open-webui container has no PostgreSQL DATABASE_URL - it is on SQLite and will look empty. Run 'make restart'."
    fi
fi

# Check DNS resolution
log_subheader "DNS Resolution"

check_dns() {
    local hostname="$1"
    local varname="$2"

    if [ -z "$hostname" ] || [ "$hostname" == "yourdomain.com" ] || [[ "$hostname" == *".yourdomain.com" ]]; then
        return
    fi

    if host "$hostname" &> /dev/null; then
        count_ok "$varname ($hostname) resolves"
    else
        count_error "$varname ($hostname) does not resolve"
    fi
}

# Only check if we have a real domain
if [ -n "$USER_DOMAIN_NAME" ] && [ "$USER_DOMAIN_NAME" != "yourdomain.com" ]; then
    check_dns "$N8N_HOSTNAME" "N8N_HOSTNAME"
    check_dns "$GRAFANA_HOSTNAME" "GRAFANA_HOSTNAME"
    check_dns "$PORTAINER_HOSTNAME" "PORTAINER_HOSTNAME"
    check_dns "$WELCOME_HOSTNAME" "WELCOME_HOSTNAME"
else
    print_info "Skipping DNS checks (no domain configured)"
fi

# Check SSL (Caddy)
log_subheader "SSL/Caddy"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "caddy"; then
    count_ok "Caddy container is running"

    # Check if Caddy can reach the config
    if docker exec caddy caddy validate --config /etc/caddy/Caddyfile &> /dev/null; then
        count_ok "Caddyfile is valid"
    else
        count_warning "Caddyfile validation failed (may be fine if using default)"
    fi
else
    count_warning "Caddy container is not running"
fi

# Check exposed host ports
# Docker publishes ports in the nat table, BEFORE ufw's INPUT chain, so a
# 0.0.0.0 bind is reachable from the internet even with 'ufw default deny
# incoming'. Everything in this stack is meant to be reached through Caddy.
if is_profile_active "supabase"; then
    log_subheader "Exposed Ports"

    GW_NAME=$(docker ps --filter 'name=^supabase-envoy$' --filter 'name=^supabase-kong$' \
                        --format '{{.Names}}' 2>/dev/null)
    GW_PORTS=$(docker ps --filter 'name=^supabase-envoy$' --filter 'name=^supabase-kong$' \
                         --format '{{.Ports}}' 2>/dev/null)
    if [ -z "$GW_NAME" ]; then
        count_warning "Supabase API gateway container not found (expected supabase-envoy)"
    elif [ -z "$GW_PORTS" ]; then
        # Running with no published ports at all is the most locked-down setup,
        # not a problem - do not report it as one.
        count_ok "Supabase API gateway publishes no host ports"
    elif echo "$GW_PORTS" | grep -Eq '(^|, )(0\.0\.0\.0|:::|\[::\]):'; then
        count_warning "Supabase API gateway publishes on all interfaces ($GW_PORTS). Set API_GW_HTTP_PORT=127.0.0.1:8000 in .env and run 'make restart'."
    else
        count_ok "Supabase API gateway is not exposed on all interfaces"
    fi
fi

# Check key services
log_subheader "Key Services"

check_service() {
    local container="$1"
    local port="$2"
    # Profile that enables the container, when it differs from the container name
    local profile="${3:-$container}"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        count_ok "$container is running"
    else
        if is_profile_active "$profile" || [ "$container" == "postgres" ] || [ "$container" == "redis" ] || [ "$container" == "caddy" ]; then
            count_error "$container is not running (but expected)"
        fi
    fi
}

check_service "postgres" "5432"
check_service "redis" "6379"
check_service "caddy" "80"

if is_profile_active "n8n"; then
    check_service "n8n" "5678"
fi

# Extra Ollama instances. Not via check_service: that helper assumes the
# container name matches the profile name, which is false for Ollama.
# Scans up to the supported maximum, not just the configured count, so that
# surplus instances are reported too: 'make restart' does not regenerate the
# compose file, so lowering OLLAMA_INSTANCE_COUNT by hand and restarting leaves
# the extra containers running and holding GPUs.
# Clamped so the count quoted in the messages below is the number of instances
# that actually exist. The generator caps at OLLAMA_MAX_INSTANCES in memory and
# never writes the capped value back, so .env can still say 99.
OLLAMA_DOCTOR_COUNT="$(normalized_ollama_instance_count)"
# Gated on an Ollama profile: a leftover OLLAMA_INSTANCE_COUNT after deselecting
# Ollama must not produce hard errors for containers that should not exist.
if is_profile_active "gpu-nvidia" || is_profile_active "gpu-amd" || is_profile_active "cpu"; then
for (( i = 2; i <= OLLAMA_MAX_INSTANCES; i++ )); do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^ollama${i}$"; then
        if [ "$i" -le "$OLLAMA_DOCTOR_COUNT" ]; then
            count_ok "ollama${i} is running"
        else
            count_warning "ollama${i} is running but OLLAMA_INSTANCE_COUNT=$OLLAMA_DOCTOR_COUNT - it is holding a GPU it should not. Run 'bash scripts/generate_ollama_instances.sh' then 'make restart'."
        fi
    elif [ "$i" -le "$OLLAMA_DOCTOR_COUNT" ]; then
        count_error "ollama${i} is not running (OLLAMA_INSTANCE_COUNT=$OLLAMA_DOCTOR_COUNT)"
    fi
done
fi

if is_profile_active "monitoring"; then
    check_service "grafana" "3000" "monitoring"
    check_service "prometheus" "9090" "monitoring"
fi

# n8n metrics reach Prometheus only through the generated targets file. A missing
# or outdated file is otherwise invisible: the job simply has no targets.
if is_profile_active "monitoring" && is_profile_active "n8n"; then
    N8N_TARGETS_FILE="$PROJECT_ROOT/prometheus/targets/n8n.json"
    WORKER_COUNT="${N8N_WORKER_COUNT:-1}"
    if ! [[ "$WORKER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        count_error "N8N_WORKER_COUNT='$WORKER_COUNT' in .env is not a positive integer - worker generation fails with this value."
    elif [ ! -f "$N8N_TARGETS_FILE" ]; then
        count_error "Prometheus n8n targets file is missing - n8n metrics are not collected. Run 'bash scripts/generate_n8n_workers.sh'."
    else
        TARGET_COUNT="$(grep -o 'n8n-worker-[0-9]*:5678' "$N8N_TARGETS_FILE" | wc -l | tr -d ' ')"
        if [ "$TARGET_COUNT" -ne "$WORKER_COUNT" ]; then
            count_warning "Prometheus n8n targets file lists $TARGET_COUNT worker(s) but N8N_WORKER_COUNT=$WORKER_COUNT. Run 'bash scripts/generate_n8n_workers.sh'."
        else
            count_ok "Prometheus n8n targets match N8N_WORKER_COUNT=$WORKER_COUNT"
        fi
    fi
fi

# A recording rule that fails to load stops Prometheus (visible); one that evaluates
# with errors only shows in its /rules page while the dependent alerts stay silent.
if is_profile_active "monitoring" && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^prometheus$"; then
    RULES_JSON="$(docker exec prometheus wget -qO- http://localhost:9090/api/v1/rules 2>/dev/null || true)"
    if ! echo "$RULES_JSON" | grep -q '"name":"n8n-workflows"'; then
        count_error "Prometheus did not load the n8n-workflows rule group from prometheus/rules/. Check 'make logs s=prometheus'."
    elif echo "$RULES_JSON" | grep -q '"health":"err"'; then
        count_error "A Prometheus recording rule is failing - the n8n stalled alerts cannot work. See Status > Rules in Prometheus."
    else
        count_ok "Prometheus n8n-workflows recording rules are healthy"
    fi
fi

# Summary
log_box "Summary"
echo ""
echo -e "  ${GREEN}OK:${NC}       ${BOLD}$OK${NC}"
echo -e "  ${YELLOW}Warnings:${NC} ${BOLD}$WARNINGS${NC}"
echo -e "  ${RED}Errors:${NC}   ${BOLD}$ERRORS${NC}"
echo ""

if [ $ERRORS -gt 0 ]; then
    echo -e "  ${BG_RED}${WHITE} ISSUES FOUND ${NC}"
    echo -e "  ${RED}Please review the errors above and take action.${NC}"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo -e "  ${BG_YELLOW}${WHITE} MOSTLY HEALTHY ${NC}"
    echo -e "  ${YELLOW}System is functional with some warnings.${NC}"
    exit 0
else
    echo -e "  ${BG_GREEN}${WHITE} HEALTHY ${NC}"
    echo -e "  ${GREEN}All checks passed successfully!${NC}"
    exit 0
fi
