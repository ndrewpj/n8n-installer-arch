#!/bin/bash
# test_sync_dryrun.sh — run sync.sh --dry-run against a local fixture "upstream"
# repo and assert: the plan lists the expected actions (translate/copy/merge/
# ignore/preserve), NO sync/from-upstream-* branch is created, and .last-sync is
# never written. Leaves the fork's git remotes and branches exactly as found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/../sync.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # sync-arch-from-ubuntu/
LAST_SYNC="$SKILL_DIR/.last-sync"
FORK_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)" # nearest .git ancestor

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

# --- fixture: a local git repo that plays the role of upstream/main ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The fixture repo must already be on branch `main` (sync.sh diffs upstream/main).
git -C "$TMP" init -q
git -C "$TMP" config user.email test@example.com
git -C "$TMP" config user.name "sync test"
git -C "$TMP" branch -M main

# A few files matching rules/targets.map patterns: translate / merge / copy
# (via the grafana/ directory prefix, the longest-match case) / ignore /
# preserve (fork-exclude supersedes). Content is arbitrary: --dry-run never
# stages or runs translate.sh.
mkdir -p "$TMP/scripts" "$TMP/grafana" "$TMP/certs"
printf 'sudo apt-get install -y nginx\n' > "$TMP/scripts/01_system_preparation.sh"
printf '# upstream readme\n'             > "$TMP/README.md"
printf '{"dashboard": 1}\n'              > "$TMP/grafana/dash.json"
# ignore.map pins `scripts/telemetry.sh` — a top-level telemetry.sh would NOT be
# ignored, so write it under scripts/ to genuinely exercise the ignore action.
printf 'echo telemetry\n'                > "$TMP/scripts/telemetry.sh"
printf 'fixture secret\n'                > "$TMP/certs/fixture.pem"
git -C "$TMP" add -A
git -C "$TMP" commit -qm "upstream fixture"

# --- point the fork's `upstream` remote at the fixture ---
# sync.sh only ADDS upstream when missing, so an existing remote is used as-is.
git -C "$FORK_ROOT" remote add upstream "$TMP" 2>/dev/null || \
  git -C "$FORK_ROOT" remote set-url upstream "$TMP"
# Restore remotes/branches on exit regardless of assertions.
trap 'git -C "$FORK_ROOT" remote remove upstream 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Baseline for a first run: .last-sync absent -> fork HEAD. If a stale
# .last-sync already exists, snapshot it so we can assert dry-run left it alone.
if [ -f "$LAST_SYNC" ]; then
  before_last_sync="$(cat "$LAST_SYNC")"
else
  before_last_sync="<absent>"
fi
# Compare only LOCAL branch refs: `git fetch` legitimately updates the
# upstream/main remote-tracking ref, so the no-mutation invariant is that no
# local branch appears/disappears (refs/heads/*).
before_branches="$(git -C "$FORK_ROOT" for-each-ref --format='%(refname)' refs/heads/ | sort)"

plan="$("$SYNC" --dry-run)"
sync_status=$?

# --- plan table lists every expected action ---
check "dry-run prints a translate action" \
  bash -c "printf '%s' \"\$0\" | grep -qi 'translate'" "$plan"
check "dry-run prints a copy action (grafana/ longest-match)" \
  bash -c "printf '%s' \"\$0\" | grep -qi 'copy'" "$plan"
check "dry-run prints a merge action" \
  bash -c "printf '%s' \"\$0\" | grep -qi 'merge'" "$plan"
check "dry-run prints an ignore action (scripts/telemetry.sh)" \
  bash -c "printf '%s' \"\$0\" | grep -q -- '-> ignore'" "$plan"
check "dry-run prints a preserve action (fork-exclude supersedes)" \
  bash -c "printf '%s' \"\$0\" | grep -qi 'preserve'" "$plan"

# --- dry-run must not alter git state ---
check "sync.sh exited 0 on --dry-run" test "$sync_status" -eq 0
check "no sync/from-upstream-* branch created" \
  bash -c "! git -C \"\$1\" for-each-ref --format='%(refname)' refs/heads/ | grep -q 'sync/from-upstream-'" _ "$FORK_ROOT"
check "no local branch changed by --dry-run" \
  bash -c "test \"\$1\" = \"\$2\"" _ "$(git -C "$FORK_ROOT" for-each-ref --format='%(refname)' refs/heads/ | sort)" "$before_branches"

# --- dry-run must not write .last-sync ---
if [ "$before_last_sync" = "<absent>" ]; then
  check ".last-sync still absent after --dry-run" test ! -e "$LAST_SYNC"
else
  check ".last-sync unchanged after --dry-run" \
    bash -c "test \"\$(cat \"\$1\")\" = \"\$2\"" _ "$LAST_SYNC" "$before_last_sync"
fi

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
