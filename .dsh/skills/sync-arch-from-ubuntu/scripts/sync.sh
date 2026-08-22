#!/bin/bash
# sync.sh [--dry-run] [--finalize]
# Orchestrate a fork sync with upstream kossakovsky/selfhost-ai:
#   --dry-run   classify changed paths and print the plan table, touch nothing.
#   --finalize  (post-review) write upstream/main hash + merged branch to
#               .last-sync and commit that marker on main.
# Default (no flags): fetch upstream, classify, stage a sync/from-upstream-*
# branch and write SYNC_REPORT.md. Never touches main or .last-sync.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # sync-arch-from-ubuntu/
LAST_SYNC="$SKILL_DIR/.last-sync"
RULES_DIR="$SKILL_DIR/rules"
TEMPLATES_DIR="$SKILL_DIR/templates"

FINALIZE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --finalize) FINALIZE=1 ;;
    *) echo "sync.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done
[ "$DRY_RUN" -eq 1 ] && [ "$FINALIZE" -eq 1 ] && { \
  echo "sync.sh: --dry-run and --finalize are mutually exclusive" >&2; exit 2; }

# 1. cd to the fork root (nearest .git ancestor of this script).
FORK_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$FORK_ROOT"

# 2. Ensure `upstream` remote -> upstream GitHub (add if missing); fetch.
if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/kossakovsky/selfhost-ai
fi
git fetch --quiet upstream

# 3. --finalize: write the new baseline on main after verifying the branch merged.
if [ "$FINALIZE" -eq 1 ]; then
  upstream_main="$(git rev-parse upstream/main)"
  # Most recently-committed sync/from-upstream-* branch that is merged into MAIN
  # (not HEAD: a sync branch is an ancestor of itself, so checking HEAD would let
  # a finalize run while still on the branch trivially pass).
  branch=""
  while IFS= read -r b; do
    if git merge-base --is-ancestor "$b" main 2>/dev/null; then branch="$b"; break; fi
  done < <(git for-each-ref --format='%(refname:short)' --sort=-committerdate \
           refs/heads/sync/from-upstream-\*)
  if [ -z "$branch" ]; then
    echo "sync.sh: --finalize: no sync/from-upstream-* branch merged into main" >&2
    exit 2
  fi
  # The marker commit must land on main, never on a sync branch or detached HEAD.
  git checkout --quiet main
  printf '%s\n%s\n' "$upstream_main" "$branch" > "$LAST_SYNC"
  git add "$LAST_SYNC"
  git commit -q -m "sync: advance baseline to upstream $(printf '%s' "$upstream_main" | cut -c1-12) via $branch"
  echo "sync.sh: finalized on main: baseline -> $upstream_main via $branch"
  exit 0
fi

# 4. baseline = .last-sync if present; else fork HEAD (first run). If present
#    but its commit is not reachable from upstream/main, warn and reset to fork
#    HEAD (full reconciliation); it is overwritten later on --finalize.
baseline="$(git rev-parse HEAD)"
if [ -f "$LAST_SYNC" ]; then
  last_sync_hash="$(head -n1 "$LAST_SYNC" | tr -d '[:space:]')"
  if [ -n "$last_sync_hash" ] && git merge-base --is-ancestor "$last_sync_hash" \
       upstream/main 2>/dev/null; then
    baseline="$last_sync_hash"
  else
    echo "sync.sh: warning: .last-sync baseline not reachable from upstream/main;" \
         "resetting baseline to fork HEAD (full reconciliation)" >&2
    baseline="$(git rev-parse HEAD)"
  fi
fi

# 5. changed = diff --name-status <baseline>..upstream/main (A/M/D).
changed="$(git diff --name-status "$baseline"..upstream/main)"
[ -n "$changed" ] || { echo "sync.sh: no changes between baseline and upstream/main"; exit 0; }

# Read classification tables into associative arrays.
declare -A target_action=()   # exact path or longest dir-prefix -> action
while IFS=$'\t' read -r path action; do
  [ -z "$path" ] && continue
  target_action["$path"]="$action"
done < "$RULES_DIR/targets.map"

declare -A fork_excluded=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  fork_excluded["$p"]=1
done < "$RULES_DIR/fork-exclude"

declare -A ignored=()
while IFS= read -r p; do
  [ -z "$p" ] && continue
  ignored["$p"]=1
done < "$RULES_DIR/ignore.map"

# prefix_matches <path> <key> — true when key is an ancestor dir-prefix of path:
# a key ending in `/` (e.g. `grafana/`, `certs/`) matches any child path; a key
# that is a literal filename (e.g. `n8n_pipe.py`) only matches when the path
# treats it as a directory (next char is `/`), never a filename lookalike.
prefix_matches() {
  local path="$1" key="$2"
  [ "$path" = "$key" ] && return 1               # exact match handled separately
  case "$path" in
    "$key"*) ;;                                  # key is a leading prefix
    *) return 1 ;;
  esac
  case "$key" in
    */) return 0 ;;                               # dir key: any child matches
  esac
  local rest="${path#"$key"}"
  case "$rest" in
    /*) return 0 ;;                               # file key used as a directory
    *) return 1 ;;
  esac
}

# classify <path> -> echoes one of: translate|copy|review|merge|preserve|ignore
classify() {
  local path="$1" best="" best_len=-1 k
  # fork-exclude supersedes everything (exact path OR any ancestor dir-prefix).
  for k in "${!fork_excluded[@]}"; do
    if [ "$path" = "$k" ] || prefix_matches "$path" "$k"; then
      echo "preserve"; return 0
    fi
  done
  # ignore skips (exact path OR dir-prefix).
  for k in "${!ignored[@]}"; do
    if [ "$path" = "$k" ] || prefix_matches "$path" "$k"; then
      echo "ignore"; return 0
    fi
  done
  # targets.map longest-match: exact row beats nothing; otherwise the longest
  # dir-prefix row (e.g. `grafana/` matches `grafana/dash.json`).
  for k in "${!target_action[@]}"; do
    if [ "$path" = "$k" ]; then
      echo "${target_action[$k]}"; return 0
    fi
    if prefix_matches "$path" "$k"; then
      local len="${#k}"
      if [ "$len" -gt "$best_len" ]; then best="$k"; best_len="$len"; fi
    fi
  done
  if [ "$best_len" -ge 0 ]; then
    echo "${target_action[$best]}"; return 0
  fi
  # absent pattern -> copy if file exists in baseline, else review.
  if git cat-file -e "$baseline:$path" 2>/dev/null; then echo "copy"; else echo "review"; fi
}

# Build the plan. For non-dry-run, perform each action here.
declare -a plan_rows=()
declare -a stage_paths=()
declare -a needs_review=()
declare -a translated_ok=()
declare -a copied_paths=()
declare -a preserved_paths=()
declare -a ignored_paths=()
declare -a merge_paths=()
declare -a deleted_paths=()

report=""

while IFS=$'\t' read -r status path; do
  [ -z "$path" ] && continue
  action="$(classify "$path")"
  plan_rows+=("$status $path -> $action")

  case "$action" in
    preserve) preserved_paths+=("$path") ;;                     # fork-excluded: nothing
    ignore) ignored_paths+=("$path") ;;                        # skipped: nothing
    merge) merge_paths+=("$path") ;;                           # model placeholder, no copy
    review)
      needs_review+=("$path")
      if [ "$DRY_RUN" -eq 0 ] && git cat-file -e "upstream/main:$path" 2>/dev/null; then
        git checkout --quiet upstream/main -- "$path"
      fi
      ;;
    translate)
      if [ "$DRY_RUN" -eq 1 ]; then continue; fi
      out="$(bash "$SCRIPT_DIR/translate.sh" <(git show "upstream/main:$path") 2>/dev/null)" \
        || out=""
      if [ -z "$out" ] || ! printf '%s\n' "$out" | bash -n 2>/dev/null; then
        needs_review+=("$path")                                # human review, original kept
        report+="translate-failed: ${path}"$'\n'
        continue
      fi
      printf '%s\n' "$out" > "$path"
      translated_ok+=("$path")
      stage_paths+=("$path")
      ;;
    copy)
      copied_paths+=("$path")
      if [ "$DRY_RUN" -eq 0 ] && git cat-file -e "upstream/main:$path" 2>/dev/null; then
        git checkout --quiet upstream/main -- "$path"
      fi
      if [ "$DRY_RUN" -eq 0 ]; then stage_paths+=("$path"); fi
      ;;
  esac

  # deleted non-fork-owned previously-copied path -> git rm (unless excluded).
  if [ "$status" = "D" ] && [ "$action" != "preserve" ] && [ "$DRY_RUN" -eq 0 ]; then
    if git cat-file -e "HEAD:$path" 2>/dev/null && \
       git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      git rm --quiet -- "$path"
      deleted_paths+=("$path")
    fi
  fi
done < <(printf '%s\n' "$changed")

# 7. --dry-run: print the plan table, exit 0 without staging.
if [ "$DRY_RUN" -eq 1 ]; then
  echo "SYNC PLAN (dry-run) — upstream/main vs baseline $(printf '%s' "$baseline" | cut -c1-12)"
  printf '%s\n' "${plan_rows[@]}"
  if [ "${#needs_review[@]}" -gt 0 ]; then
    echo "NEEDS-HUMAN-REVIEW: ${needs_review[*]}"
  fi
  exit 0
fi

# 8. Create branch sync/from-upstream-<YYYYMMDD-HHMM> (suffix -2,-3 if exists).
stamp="$(date +%Y%m%d-%H%M)"
branch="sync/from-upstream-$stamp"
i=2
while git rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; do
  branch="sync/from-upstream-$stamp-$((i))"
  i=$((i+1))
done
git checkout --quiet -b "$branch"

git add "${stage_paths[@]:-}" 2>/dev/null || true

# Generate SYNC_REPORT.md from the template (untracked). Placeholders are
# filled with the per-file action lists; any line starting with `## ` is kept.
new_hash="$(git rev-parse upstream/main)"
old_hash="$baseline"
report_file="$(mktemp)"
{
  printf '# Sync Report — from upstream %s on %s\n' \
    "$(printf '%s' "$new_hash" | cut -c1-12)" "$(date)"
  printf 'Baseline: %s -> %s\n' \
    "$(printf '%s' "$old_hash" | cut -c1-12)" "$(printf '%s' "$new_hash" | cut -c1-12)"
  printf '## Translated\n'
  [ "${#translated_ok[@]}" -gt 0 ] && printf '%s\n' "${translated_ok[@]}"
  printf '## Copied\n'
  [ "${#copied_paths[@]}" -gt 0 ] && printf '%s\n' "${copied_paths[@]}"
  printf '## Preserved (fork-excluded)\n'
  [ "${#preserved_paths[@]}" -gt 0 ] && printf '%s\n' "${preserved_paths[@]}"
  printf '## Skipped (ignored)\n'
  [ "${#ignored_paths[@]}" -gt 0 ] && printf '%s\n' "${ignored_paths[@]}"
  printf '## Merge (model-guided review required)\n'
  [ "${#merge_paths[@]}" -gt 0 ] && printf '%s\n' "${merge_paths[@]}"
  printf '## Needs human review\n'
  [ "${#needs_review[@]}" -gt 0 ] && printf '%s\n' "${needs_review[@]}"
  printf '## Deleted from upstream\n'
  [ "${#deleted_paths[@]}" -gt 0 ] && printf '%s\n' "${deleted_paths[@]}"
  [ -n "$report" ] && printf '%s' "$report"
} > "$report_file"
mv "$report_file" SYNC_REPORT.md
printf 'sync.sh: wrote SYNC_REPORT.md (%s translated, %s copied, %s merge, %s review)\n' \
  "${#translated_ok[@]}" "${#copied_paths[@]}" "${#merge_paths[@]}" "${#needs_review[@]}"

echo
echo "sync.sh: staged $branch — $(printf '%s\n' "${stage_paths[@]}" | wc -l) files translated/copied;"
echo "         needs-human-review: ${#needs_review[@]}; deleted: ${#deleted_paths[@]}"
echo "         review SYNC_REPORT.md, then git merge '$branch' and run sync.sh --finalize"
