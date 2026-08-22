#!/bin/bash
# test_targets.sh — read rules/targets.map and assert every upstream path
# resolves to the action pinned in the reconciliation table (spot-check rows).
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

# The reconciliation table spot-checks, as (path, expected action) pairs.
# Representative rows across translate/review/merge/copy.
expected=(
  "scripts/01_system_preparation.sh|translate"
  "scripts/04_wizard.sh|translate"
  "scripts/08_fix_permissions.sh|translate"
  "scripts/utils.sh|translate"
  "scripts/apply_update.sh|translate"
  "scripts/restart.sh|review"
  "scripts/import_workflows.sh|review"
  "scripts/generate_welcome_page.sh|review"
  "docker-compose.yml|merge"
  "Caddyfile|merge"
  "docker-compose.ollama-gpu-devices.yml|merge"
  "CHANGELOG.md|copy"
  "LICENSE|copy"
  "grafana/|copy"
  "welcome/|copy"
  "start_services.py|review"
)

# 1. targets.map must exist and be readable
check "targets.map exists and is readable" bash -c "[ -f \"$TARGETS\" ] && [ -r \"$TARGETS\" ]"

# 2. Each expected (path, action) pair must appear as exactly "path<TAB>action".
#    Grep for a TAB-separated line matching ^path\t<action>$ (anchored, no extras).
for pair in "${expected[@]}"; do
  path="${pair%%|*}"
  action="${pair#*|}"
  check "targets.map pins ${path} -> ${action}" \
    bash -c "grep -qP '^${path}\t${action}\$' \"\$1\"" _ "$TARGETS"
done

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
