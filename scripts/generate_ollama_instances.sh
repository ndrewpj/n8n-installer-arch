#!/bin/bash
# Generates docker-compose.ollama-instances.yml with extra Ollama instances
# (ollama2 .. ollamaN) for multi-GPU hosts.
# Usage: OLLAMA_INSTANCE_COUNT=3 bash scripts/generate_ollama_instances.sh
#
# Instance 1 is the stock "ollama" container defined in docker-compose.yml and
# is never touched here, so a default install (count 1) behaves exactly as
# before.
#
# Idempotent: each run either rewrites the output file from scratch or, when a
# single instance is configured, REMOVES it. Removal rather than an empty file
# is deliberate - Compose rejects a bare 'services:' key, and a stale file would
# resurrect the old instance set after a downscale or point instances at the
# wrong hardware profile after a switch.

set -euo pipefail

# Source the utilities file and initialize paths
source "$(dirname "$0")/utils.sh"
init_paths

OUTPUT_FILE="$PROJECT_ROOT/docker-compose.ollama-instances.yml"

# Load values from .env if not already set in the environment
if [[ -f "$ENV_FILE" ]]; then
    [[ -z "${OLLAMA_INSTANCE_COUNT:-}" ]] && OLLAMA_INSTANCE_COUNT=$(read_env_var "OLLAMA_INSTANCE_COUNT")
    [[ -z "${COMPOSE_PROFILES:-}" ]] && COMPOSE_PROFILES=$(read_env_var "COMPOSE_PROFILES")
fi
OLLAMA_INSTANCE_COUNT="${OLLAMA_INSTANCE_COUNT:-1}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"

# Match the active Ollama hardware profile (mutually exclusive, set by the wizard)
TEMPLATE="ollama-instance-template"
if is_profile_active "gpu-nvidia"; then
    HW_PROFILE="gpu-nvidia"
elif is_profile_active "gpu-amd"; then
    HW_PROFILE="gpu-amd"
    TEMPLATE="ollama-instance-template-amd"
elif is_profile_active "cpu"; then
    HW_PROFILE="cpu"
else
    HW_PROFILE=""
fi

remove_output_and_exit() {
    if [[ -f "$OUTPUT_FILE" ]]; then
        log_info "Removing $OUTPUT_FILE ($1)"
        rm -f "$OUTPUT_FILE"
    fi
    cleanup_stale_ollama_instances 1 "$OLLAMA_MAX_INSTANCES"
    exit 0
}

# Ollama is not deployed at all. Check this BEFORE validating the count:
# 05_configure_services.sh calls this script unconditionally under 'set -e', so
# rejecting a leftover OLLAMA_INSTANCE_COUNT here would abort an entire
# 'make update' over a value that has no effect on the stack being built.
[[ -z "$HW_PROFILE" ]] && remove_output_and_exit "no Ollama profile active"

# Validate the count. Warn and fall back rather than exit: aborting here kills
# 'make update' after the wizard has already rewritten COMPOSE_PROFILES.
if ! [[ "$OLLAMA_INSTANCE_COUNT" =~ ^0*[1-9][0-9]*$ ]]; then
    log_warning "OLLAMA_INSTANCE_COUNT must be an integer between 1 and $OLLAMA_MAX_INSTANCES, got: '$OLLAMA_INSTANCE_COUNT'. Falling back to 1."
    OLLAMA_INSTANCE_COUNT=1
fi
OLLAMA_INSTANCE_COUNT=$((10#$OLLAMA_INSTANCE_COUNT))
if (( OLLAMA_INSTANCE_COUNT > OLLAMA_MAX_INSTANCES )); then
    log_warning "OLLAMA_INSTANCE_COUNT=$OLLAMA_INSTANCE_COUNT exceeds the supported maximum of $OLLAMA_MAX_INSTANCES; capping to $OLLAMA_MAX_INSTANCES."
    OLLAMA_INSTANCE_COUNT=$OLLAMA_MAX_INSTANCES
fi

# A single instance is the default: the stock "ollama" container is enough.
# The 'cpu' profile is supported here as well as the GPU ones - the wizard only
# offers the prompt for GPU hosts, but a hand-set count still works on CPU.
(( OLLAMA_INSTANCE_COUNT <= 1 )) && remove_output_and_exit "single Ollama instance"

log_info "Generating extra Ollama instances configuration..."
log_info "OLLAMA_INSTANCE_COUNT=$OLLAMA_INSTANCE_COUNT (hardware profile: $HW_PROFILE)"

cat > "$OUTPUT_FILE" << 'EOF'
# Auto-generated file for extra Ollama instances (ollama2, ollama3, ...)
# Regenerate with: bash scripts/generate_ollama_instances.sh
# DO NOT EDIT MANUALLY - this file is overwritten on each run
#
# Instance 1 is the stock "ollama" container defined in docker-compose.yml.
# All instances share the ollama_storage volume, so models are downloaded once.
# Extra instances are internal only (http://ollama2:11434) - no published ports.
#
# Tune an instance WITHOUT regenerating by setting OLLAMA<N>_* in .env, e.g.
#   OLLAMA2_GPU_DEVICES=2
#   OLLAMA2_KEEP_ALIVE=-1
#   OLLAMA2_MAX_LOADED_MODELS=1
# The runtime knobs fall back to the global OLLAMA_* value, then to the stack
# default. OLLAMA<N>_GPU_DEVICES is the exception: it defaults to GPU N-1 and
# does not read the global OLLAMA_GPU_DEVICES.
# Anything else (e.g. LLAMA_ARG_FIT_TARGET=128) goes into ollama<N>.env next
# to .env; ollama.env applies to every instance and ollama<N>.env overrides it.

services:
EOF

for (( i = 2; i <= OLLAMA_INSTANCE_COUNT; i++ )); do
cat >> "$OUTPUT_FILE" << EOF
  ollama${i}:
    extends:
      file: docker-compose.yml
      service: ${TEMPLATE}
    container_name: ollama${i}
    profiles: ["${HW_PROFILE}"]
    restart: unless-stopped
    environment:
      OLLAMA_CONTEXT_LENGTH: "\${OLLAMA${i}_CONTEXT_LENGTH:-\${OLLAMA_CONTEXT_LENGTH:-8192}}"
      OLLAMA_FLASH_ATTENTION: 1
      OLLAMA_GPU_OVERHEAD: "\${OLLAMA${i}_GPU_OVERHEAD:-\${OLLAMA_GPU_OVERHEAD:-0}}"
      OLLAMA_KEEP_ALIVE: "\${OLLAMA${i}_KEEP_ALIVE:-\${OLLAMA_KEEP_ALIVE:-}}"
      OLLAMA_KV_CACHE_TYPE: "\${OLLAMA${i}_KV_CACHE_TYPE:-\${OLLAMA_KV_CACHE_TYPE:-q8_0}}"
      OLLAMA_MAX_LOADED_MODELS: "\${OLLAMA${i}_MAX_LOADED_MODELS:-\${OLLAMA_MAX_LOADED_MODELS:-2}}"
      OLLAMA_NUM_PARALLEL: "\${OLLAMA${i}_NUM_PARALLEL:-\${OLLAMA_NUM_PARALLEL:-}}"
      OLLAMA_SCHED_SPREAD: "\${OLLAMA${i}_SCHED_SPREAD:-\${OLLAMA_SCHED_SPREAD:-}}"
EOF

    case "$HW_PROFILE" in
        gpu-nvidia)
cat >> "$OUTPUT_FILE" << EOF
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["\${OLLAMA${i}_GPU_DEVICES:-$((i - 1))}"]
              capabilities: [gpu]
EOF
            ;;
        gpu-amd)
            # ROCm passes all of /dev/kfd and /dev/dri to every container, so
            # pinning is done with HIP_VISIBLE_DEVICES, not deploy.resources.
cat >> "$OUTPUT_FILE" << EOF
      HIP_VISIBLE_DEVICES: "\${OLLAMA${i}_GPU_DEVICES:-$((i - 1))}"
      ROCR_VISIBLE_DEVICES: "\${OLLAMA${i}_GPU_DEVICES:-$((i - 1))}"
EOF
            ;;
    esac

    # Appended after the hardware block on purpose: the gpu-amd branch above
    # continues the 'environment:' mapping, so env_file must come last.
cat >> "$OUTPUT_FILE" << EOF
    env_file:
      - path: ./ollama${i}.env
        required: false

EOF
done

log_success "Generated $OUTPUT_FILE with $((OLLAMA_INSTANCE_COUNT - 1)) extra Ollama instance(s)"

# Drop containers above the new count - a plain 'docker compose down' leaves
# them behind as orphans, still holding a GPU.
cleanup_stale_ollama_instances "$OLLAMA_INSTANCE_COUNT" "$OLLAMA_MAX_INSTANCES"
