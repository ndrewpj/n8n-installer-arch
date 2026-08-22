#!/bin/bash
# test_sync_e2e.sh — end-to-end dry-run against a REAL upstream repo (local
# full clone of kossakovsky/selfhost-ai). Asserts the reconciliation plan
# classifies the key paths per targets.map / fork-exclude / ignore, and that
# --dry-run touches no branch and no .last-sync. SKIPS (exit 0) when the
# upstream dir is absent so the suite stays runnable offline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/../sync.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # sync-arch-from-ubuntu/
LAST_SYNC="$SKILL_DIR/.last-sync"
FORK_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)" # nearest .git ancestor

UPSTREAM_DIR="${UPSTREAM_DIR:-/home/andrey/ds_harness/selfhost-ai-upstream}"
if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  echo "skip - no upstream clone at $UPSTREAM_DIR"
  exit 0
fi

pass=0
fail=0
check() { # check <label> <cmd...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass+1)); echo "ok  - $label"
  else
    fail=$((fail+1)); echo "FAIL - $label"
  fi
}

# Use the real upstream clone as the `upstream` remote (add or re-point).
git -C "$FORK_ROOT" remote add upstream "$UPSTREAM_DIR" 2>/dev/null || \
  git -C "$FORK_ROOT" remote set-url upstream "$UPSTREAM_DIR"
trap 'git -C "$FORK_ROOT" remote remove upstream 2>/dev/null || true' EXIT

if [ -f "$LAST_SYNC" ]; then before_last_sync="$(cat "$LAST_SYNC")"; else before_last_sync="<absent>"; fi
before_branches="$(git -C "$FORK_ROOT" for-each-ref --format='%(refname)' refs/heads/ | sort)"

plan="$("$SYNC" --dry-run)"
sync_status=$?

# 1. The six merge files (docker-compose set + docs) must be listed -> merge.
for f in docker-compose.yml docker-compose.ollama-gpu-devices.yml \
         docker-compose.invokeai-gpu-devices.yml Caddyfile README.md .env.example; do
  check "e2e plan: $f -> merge" \
    bash -c "printf '%s' \"\$0\" | grep -q -- \"$f -> merge\"" "$plan"
done

# 2. fork-excluded paths must classify -> preserve.
check "e2e plan: n8n_pipe.py -> preserve" \
  bash -c "printf '%s' \"\$0\" | grep -q -- 'n8n_pipe.py -> preserve'" "$plan"
check "e2e plan: old_02_install_docker.sh -> preserve" \
  bash -c "printf '%s' \"\$0\" | grep -q -- 'old_02_install_docker.sh -> preserve'" "$plan"
check "e2e plan: certs/ subtree -> preserve" \
  bash -c "printf '%s' \"\$0\" | grep -qE -- 'certs/.*-> preserve'" "$plan"

# 3. ignored paths -> ignore.
check "e2e plan: scripts/telemetry.sh -> ignore" \
  bash -c "printf '%s' \"\$0\" | grep -q -- 'scripts/telemetry.sh -> ignore'" "$plan"
check "e2e plan: scripts/update_preview.sh -> ignore" \
  bash -c "printf '%s' \"\$0\" | grep -q -- 'scripts/update_preview.sh -> ignore'" "$plan"

# 4. core scripts -> translate (exactly the 15 targets.map translate rows).
check "e2e plan: scripts/01_system_preparation.sh -> translate" \
  bash -c "printf '%s' \"\$0\" | grep -q -- 'scripts/01_system_preparation.sh -> translate'" "$plan"
check "e2e plan: exactly 15 translate rows" \
  bash -c "printf '%s' \"\$0\" | grep -cE -- '-> translate$' | grep -qx 15" "$plan"

# 5. dry-run side-effect-freedom.
check "e2e sync.sh exited 0" test "$sync_status" -eq 0
check "e2e: no sync/from-upstream-* branch created" \
  bash -c "! git -C \"\$1\" for-each-ref --format='%(refname)' refs/heads/ | grep -q 'sync/from-upstream-'" _ "$FORK_ROOT"
check "e2e: no local branch changed" \
  bash -c "test \"\$1\" = \"\$2\"" _ \
  "$(git -C "$FORK_ROOT" for-each-ref --format='%(refname)' refs/heads/ | sort)" "$before_branches"
if [ "$before_last_sync" = "<absent>" ]; then
  check "e2e: .last-sync still absent" test ! -e "$LAST_SYNC"
else
  check "e2e: .last-sync unchanged" \
    bash -c "test \"\$(cat \"\$1\")\" = \"\$2\"" _ "$LAST_SYNC" "$before_last_sync"
fi

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
