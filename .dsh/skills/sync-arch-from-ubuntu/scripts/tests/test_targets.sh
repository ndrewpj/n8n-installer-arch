#!/bin/bash
# test_targets.sh — read rules/targets.map and assert every upstream path
# resolves to the action pinned in the reconciliation table (full 43-row map).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGETS="$SCRIPT_DIR/../../rules/targets.map"

pass=0
fail=0

check() { # check <label> <cmd...>
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass+1))
    echo "ok  - $label"
  else
    fail=$((fail+1))
    echo "FAIL - $label"
  fi
}

# Full reconciliation table as (path, expected action) pairs — all 43 rows.
expected=(
  "scripts/01_system_preparation.sh|translate"
  "scripts/02_install_docker.sh|translate"
  "scripts/03_generate_secrets.sh|translate"
  "scripts/04_wizard.sh|translate"
  "scripts/05_configure_services.sh|translate"
  "scripts/06_run_services.sh|translate"
  "scripts/07_final_report.sh|translate"
  "scripts/08_fix_permissions.sh|translate"
  "scripts/install.sh|translate"
  "scripts/utils.sh|translate"
  "scripts/git.sh|translate"
  "scripts/databases.sh|translate"
  "scripts/apply_update.sh|translate"
  "scripts/docker_cleanup.sh|translate"
  "scripts/update.sh|translate"
  "scripts/restart.sh|review"
  "scripts/setup_custom_tls.sh|review"
  "scripts/doctor.sh|review"
  "scripts/import_workflows.sh|review"
  "scripts/download_top_workflows.sh|review"
  "scripts/generate_n8n_workers.sh|review"
  "scripts/generate_welcome_page.sh|review"
  "docker-compose.yml|merge"
  "docker-compose.ollama-gpu-devices.yml|merge"
  "docker-compose.invokeai-gpu-devices.yml|merge"
  "Caddyfile|merge"
  "README.md|merge"
  ".env.example|merge"
  "CHANGELOG.md|copy"
  "VERSION|copy"
  "Makefile|copy"
  "cloudflare-instructions.md|copy"
  "LICENSE|copy"
  ".gitignore|copy"
  "grafana/|copy"
  "prometheus/|copy"
  "searxng/|copy"
  "n8n/|copy"
  "caddy-addon/|copy"
  "paddlex/|copy"
  "python-runner/|copy"
  "welcome/|copy"
  "start_services.py|review"
)

# 1. targets.map must exist and be readable
check "targets.map exists and is readable" bash -c "[ -f \"$TARGETS\" ] && [ -r \"$TARGETS\" ]"

# 2. Structural invariants
check "targets.map has exactly ${#expected[@]} rows" \
  bash -c "test \$(grep -c . \"\$1\") -eq ${#expected[@]}" _ "$TARGETS"
check "translate count == 15" \
  bash -c "test \$(grep -c \$'\ttranslate' \"\$1\") -eq 15" _ "$TARGETS"
check "review count == 8" \
  bash -c "test \$(grep -c \$'\treview' \"\$1\") -eq 8" _ "$TARGETS"
check "merge count == 6" \
  bash -c "test \$(grep -c \$'\tmerge' \"\$1\") -eq 6" _ "$TARGETS"
check "copy count == 14" \
  bash -c "test \$(grep -c \$'\tcopy' \"\$1\") -eq 14" _ "$TARGETS"

# 3. Reject-list: no ignore/fork-exclude/preserve actions and no banned paths.
check "no forbidden actions or paths in targets.map" \
  bash -c "! grep -qE '\t(ignore|preserve|fork-exclude)\$|telemetry\.sh|update_preview\.sh|certs/|n8n_pipe\.py|old_start_services|old_02_install_docker|copy\.py' \"\$1\"" _ "$TARGETS"

# 4. Each expected (path, action) pair must appear as exactly "path<TAB>action",
#    with regex metacharacters escaped so matching is literal.
for pair in "${expected[@]}"; do
  path="${pair%%|*}"
  action="${pair#*|}"
  esc="${path//./\\.}"   # escape regex dots for literal match
  check "targets.map pins ${path} -> ${action}" \
    bash -c "grep -qP '^${esc}\t${action}\$' \"\$1\"" _ "$TARGETS"
done

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
