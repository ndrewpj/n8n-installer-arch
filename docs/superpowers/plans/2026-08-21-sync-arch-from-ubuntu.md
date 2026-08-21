# sync-arch-from-ubuntu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a DeepSeek Harness project skill that keeps this Arch/CachyOS fork in sync with the Ubuntu-oriented upstream `kossakovsky/selfhost-ai`, deterministically translating Ubuntu idioms to CachyOS equivalents, staging a reviewable branch, and preserving fork-specific files.

**Architecture:** A skill bundle at `<fork>/.dsh/skills/sync-arch-from-ubuntu/` containing `SKILL.md` (loaded by the harness) plus a deterministic translation engine: `scripts/sync.sh` orchestrates fetch→diff→classify→stage, `scripts/translate.sh` applies declarative rules in `rules/`, and a `SYNC_REPORT.md` is generated for human review. Files get exactly one action from `translate | copy | preserve | ignore | review | merge`; the baseline only advances on `--finalize`.

**Tech Stack:** Bash (all fork scripts are bash), git CLI, declarative `rules/*.map` files (pattern<TAB>action syntax), `SKILL.md` with YAML frontmatter.

**Spec:** `docs/superpowers/specs/2026-08-21-sync-arch-from-ubuntu-design.md`

---
## File Structure

Files created/modified under the fork repo:

```
.dsh/skills/sync-arch-from-ubuntu/
  SKILL.md                       # frontmatter + run procedure (loaded by harness)
  scripts/
    sync.sh                      # orchestrator: fetch, diff, classify, stage, report, --finalize
    translate.sh                 # deterministic Ubuntu->CachyOS rule engine
    lib/
      parse_rules.sh             # read targets.map / packages.map / idioms.map into arrays
    tests/
      test_translate.sh          # asserts translate.sh output for fixtures
      test_sync_dryrun.sh        # asserts sync.sh --dry-run produces expected plan
      fixtures/                   # sample Ubuntu scripts for translate tests
        system_prep_ubuntu.sh
        install_docker_ubuntu.sh
  rules/
    packages.map                 # Ubuntu pkg -> Arch pkg
    idioms.map                   # Ubuntu idiom -> replacement (awk substitutions)
    targets.map                  # path<TAB>action for every upstream path
    fork-exclude                 # never-overwrite paths
    ignore.map                   # drop-silently paths
  templates/
    SYNC_REPORT.md               # report skeleton (filled by sync.sh)
  .last-sync                     # baseline (written only by --finalize; NOT committed content)
```

Existing files modified: the fork's own `scripts/` and root files are only touched by a real sync run, never by building the skill. The lone exception is the fork's root `CLAUDE.md`, which gains a short "Sync with upstream" note in Task 6.

---
## Task 1: Skill scaffold + SKILL.md

**Files:**
- Create: `.dsh/skills/sync-arch-from-ubuntu/SKILL.md`
- Create: `.dsh/skills/sync-arch-from-ubuntu/rules/packages.map`
- Create: `.dsh/skills/sync-arch-from-ubuntu/rules/idioms.map`
- Create: `.dsh/skills/sync-arch-from-ubuntu/rules/fork-exclude`
- Create: `.dsh/skills/sync-arch-from-ubuntu/rules/ignore.map`
- Create: `.dsh/skills/sync-arch-from-ubuntu/templates/SYNC_REPORT.md`

- [ ] **Step 1: Write SKILL.md**

Frontmatter must be kebab-case name + description (required by harness discovery). Content: the full run procedure, safety rules, and the action vocabulary. Model:

```markdown
---
name: sync-arch-from-ubuntu
description: Sync this Arch/CachyOS fork with the Ubuntu-oriented upstream selfhost-ai repo: fetch upstream, translate Ubuntu idioms to CachyOS, stage a reviewable branch, preserve fork-specific files. Trigger with "sync with upstream", "pull upstream changes", "sync from selfhost-ai", "update fork from upstream".
argument-hint: ""
---

# /sync-arch-from-ubuntu

Sync this fork with upstream `kossakovsky/selfhost-ai`, translating Ubuntu idioms to CachyOS.

## When to use
Run when you want to pull upstream changes into this fork, adapting them for Arch/CachyOS.

## Procedure
1. Run `bash .dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh` from the fork root.
2. It adds `upstream` remote if missing, fetches, diffs vs `.last-sync`, classifies each path, stages a `sync/from-upstream-<date>` branch, and writes `SYNC_REPORT.md`.
3. Present the diff + `SYNC_REPORT.md` to the user. Do NOT merge or commit to `main` yourself.
4. After the user reviews and merges the branch into `main`, run `bash .dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh --finalize` to advance the baseline.

## Safety rules (never violate)
- Never touch `main` during a sync. Only stage a `sync/from-upstream-*` branch.
- Never overwrite paths in `rules/fork-exclude` (`old_02_install_docker.sh`, `n8n_pipe.py`, `old_start_services copy.py`, `certs/`).
- Bare `pacman -Sy` is forbidden; always use `pacman -S --needed --noconfirm` or `pacman -Syu --needed --noconfirm`.
- Files classified `merge` (docker-compose.yml, README.md, .env.example, Caddyfile, GPU compose) require model-guided human review — never blind-overwrite.
- After any sync, report what was translated vs copied vs preserved vs skipped vs needs-review.

## Action vocabulary
Each path gets exactly one: translate | copy | preserve | ignore | review | merge.
- translate: run translate.sh
- copy: copy verbatim
- preserve / fork-exclude: leave untouched
- ignore: drop silently
- review: copy verbatim + flag needs-human-review
- merge: model-guided merge, stop for user
```

- [ ] **Step 2: Write `rules/packages.map`** (Ubuntu pkg<TAB>Arch pkg; `-` = drop)

```
python3	python
python3-pip	python-pip
python3-dotenv	python-dotenv
python3-yaml	python-yaml
build-essential	base-devel
whiptail	libnewt
software-properties-common	-
unattended-upgrades	-
apt-transport-https	-
lsb-release	-
ca-certificates	ca-certificates
gnupg	gnupg
openssl	openssl
psmisc	psmisc
make	make
unzip	unzip
ufw	ufw
fail2ban	fail2ban
git	git
curl	curl
htop	htop
docker-ce	docker
docker-ce-cli	docker
containerd.io	containerd
docker-buildx-plugin	docker
docker-compose-plugin	docker-compose
```

- [ ] **Step 3: Write `rules/idioms.map`** (awk substitution pairs, applied in order). Each line: `pattern<TAB>replacement`. Use regex tokens.

```
DEBIAN_FRONTEND=noninteractive	
export DEBIAN_FRONTEND=dialog	
add-apt-repository universe -y	
echo "y" | dpkg-reconfigure --priority=low unattended-upgrades	
apt-key	
install -m 0755 -d /etc/apt/keyrings	
deb [arch=
```

(NOTE: idioms.map holds ONLY simple textual drop/rewrite substitutions. apt install/update/remove
command lines are handled EXCLUSIVELY by translate.sh's dedicated command parser in Task 2 — they must
NOT also appear in idioms.map (remove the `apt install -y unattended-upgrades` line above; it belongs to
the parser, which drops unattended-upgrades per packages.map `unattended-upgrades\t-`). No idiom line may
use a third column; every line is strictly `pattern<TAB>replacement`.)

- [ ] **Step 4: Write `rules/fork-exclude`**

```
scripts/old_02_install_docker.sh
n8n_pipe.py
old_start_services copy.py
certs/
```

- [ ] **Step 5: Write `rules/ignore.map`**

```
scripts/telemetry.sh
scripts/update_preview.sh
```

- [ ] **Step 6: Write `templates/SYNC_REPORT.md`**

```markdown
# Sync Report — from upstream <commit> on <date>
Baseline: <old hash> -> <new hash>
## Translated
<per-file: action taken>
## Copied
## Preserved (fork-excluded)
## Skipped (ignored)
## Needs human review
## Deleted from upstream
```

- [ ] **Step 7: Commit**

```bash
git add .dsh/skills/sync-arch-from-ubuntu/
git commit -m "feat: scaffold sync-arch-from-ubuntu skill (SKILL.md, rules, template)"
```

---
## Task 2: translate.sh — deterministic rule engine

**Files:**
- Create: `.dsh/skills/sync-arch-from-ubuntu/scripts/translate.sh`
- Test: `.dsh/skills/sync-arch-from-ubuntu/scripts/tests/test_translate.sh`
- Create fixtures

- [ ] **Step 1: Write failing tests**

`tests/test_translate.sh` — asserts:
- `apt update -y && apt upgrade -y` block → `pacman -Syu --noconfirm`
- `apt install -y <pkgs>` → `pacman -S --needed --noconfirm <mapped>`
- `build-essential` → `base-devel`, `python3-pip` → `python-pip`, `whiptail` → `libnewt`
- `DEBIAN_FRONTEND=noninteractive` line removed
- Docker repo/key block (`curl ... gpg`, `tee /etc/apt/sources.list.d/docker.list`, `dpkg --print-architecture`) removed
- `apt remove -y caddy` → `pacman -R caddy` (and the caddy install block → pacman install)
- no bare `pacman -Sy` anywhere in output

- [ ] **Step 2: Run tests, verify fail**

Run: `bash tests/test_translate.sh`
Expected: FAIL (translate.sh missing)

- [ ] **Step 3: Write minimal translate.sh**

```bash
#!/bin/bash
# translate.sh <file> — translate Ubuntu shell to CachyOS, print to stdout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="$(cd "$SCRIPT_DIR/../rules" && pwd)"
input="$1"

# 1. Collapse apt update+upgrade into pacman -Syu.
# 2. Rewrite apt install <pkgs> -> pacman -S --needed --noconfirm <mapped pkgs>,
#    mapping each package via packages.map (split on the first TAB).
# 3. apt remove <pkg> -> pacman -R <pkg>; apt remove -y -> pacman -R.
# 4. Drop: DEBIAN_FRONTEND lines, dpkg-reconfigure lines, add-apt-repository,
#    unattended-upgrades install, apt-key, docker apt repo/key blocks,
#    curl cloudsmith caddy repo lines, install -d /etc/apt/keyrings.
# 5. whiptail hint "sudo apt-get install -y whiptail" -> "sudo pacman -S libnewt".
# 6. Replace install-hint texts referencing apt.
# 7. Guard: if any line contains "pacman -Sy " (bare, not -Syu/-S), exit 1.

awk -F'\t' '
  NR==FNR { if (NF>=2) pkgmap[$1]=$2; next }
  { ... apply substitutions ... }
' "$RULES_DIR/packages.map" "$input"
```

Provide the complete awk body (full code in implementation — the plan specifies behavior, the implementer writes exact awk).

- [ ] **Step 4: Run tests, verify pass**

Run: `bash tests/test_translate.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add .dsh/skills/sync-arch-from-ubuntu/scripts/
git commit -m "feat: add deterministic translate.sh rule engine"
```

---
## Task 3: rules/targets.map — path classification

**Files:**
- Create: `.dsh/skills/sync-arch-from-ubuntu/rules/targets.map`
- Test: `.dsh/skills/sync-arch-from-ubuntu/scripts/tests/test_targets.sh`

- [ ] **Step 1: Write failing test** — reads targets.map, asserts every upstream path resolves to the action from the spec's reconciliation table (spot-check ~8 representative rows).

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Write targets.map** from the reconciliation table:

```
scripts/01_system_preparation.sh	translate
scripts/02_install_docker.sh	translate
scripts/03_generate_secrets.sh	translate
scripts/04_wizard.sh	translate
scripts/05_configure_services.sh	translate
scripts/06_run_services.sh	translate
scripts/07_final_report.sh	translate
scripts/08_fix_permissions.sh	translate
scripts/install.sh	translate
scripts/utils.sh	translate
scripts/git.sh	translate
scripts/databases.sh	translate
scripts/apply_update.sh	translate
scripts/docker_cleanup.sh	translate
scripts/update.sh	translate
scripts/restart.sh	review
scripts/setup_custom_tls.sh	review
scripts/doctor.sh	review
scripts/import_workflows.sh	review
scripts/download_top_workflows.sh	review
scripts/generate_n8n_workers.sh	review
scripts/generate_welcome_page.sh	review
docker-compose.yml	merge
docker-compose.ollama-gpu-devices.yml	merge
docker-compose.invokeai-gpu-devices.yml	merge
Caddyfile	merge
README.md	merge
.env.example	merge
CHANGELOG.md	copy
VERSION	copy
Makefile	copy
cloudflare-instructions.md	copy
LICENSE	copy
.gitignore	copy
grafana/	copy
prometheus/	copy
searxng/	copy
n8n/	copy
caddy-addon/	copy
paddlex/	copy
python-runner/	copy
welcome/	copy
start_services.py	review
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add .dsh/skills/sync-arch-from-ubuntu/
git commit -m "feat: add targets.map path classification"
```

---
## Task 4: sync.sh — orchestrator

**Files:**
- Create: `.dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh`
- Test: `.dsh/skills/sync-arch-from-ubuntu/scripts/tests/test_sync_dryrun.sh`

- [ ] **Step 1: Write failing test** — with a `--dry-run`, given a local fixture upstream git repo, asserts the plan lists expected translated/copy/merge/preserve/ignore actions without altering git state (no branch created, `.last-sync` untouched).

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Write minimal sync.sh** — behavior:

```bash
#!/bin/bash
set -euo pipefail
# sync.sh [--dry-run] [--finalize]
# 1. cd to fork root (nearest .git parent of this script).
# 2. Ensure `upstream` remote -> https://github.com/kossakovsky/selfhost-ai ; git fetch upstream.
# 3. If --finalize: resolve upstream/main hash, verify the sync branch is merged into
#    HEAD, write new hash+branch to .last-sync, commit that marker on main, exit.
# 4. baseline = read .last-sync if present; if absent -> first run, baseline = fork HEAD.
#    If .last-sync IS present but its commit is NOT reachable from upstream/main:
#    warn, reset baseline to fork HEAD (full reconciliation), overwrite .last-sync later on --finalize.
# 5. changed = git diff --name-status <baseline>..upstream/main.
# 6. For each changed path: classify (targets.map longest-match; fork-exclude supersedes;
#    ignore skips; absent pattern -> copy if file exists in baseline, else review).
#    - translate -> run translate.sh <file>; if output is empty or `bash -n` reports a
#      syntax error, do NOT write it: mark needs-human-review, leave the original in place,
#      and record it in the report (never delete the original on failure).
#    - copy -> git checkout upstream/main -- <path>
#    - review -> copy verbatim + note needs-human-review
#    - merge -> record placeholder for model; do not copy
#    - preserve/ignore -> nothing
#    - deleted non-fork-owned previously-copied path -> git rm (unless fork-excluded)
# 7. If --dry-run: print the plan table, exit 0 without staging.
# 8. Else: create branch sync/from-upstream-<YYYYMMDD-HHMM> (suffix -2,-3 if exists),
#    stage changed files, generate SYNC_REPORT.md from template, print summary, stop.
```

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add .dsh/skills/sync-arch-from-ubuntu/
git commit -m "feat: add sync.sh orchestrator with --dry-run and --finalize"
```

---
## Task 5: End-to-end dry-run against real upstream

**Files:**
- Modify: `.dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh` (only if a defect surfaces)

- [ ] **Step 1: Run a full dry-run reconciliation**

Run: `bash .dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh --dry-run`
Expected: prints a complete plan table covering all changed paths (full reconciliation since no baseline), lists translated/copy/merge/preserve/ignore/review, and does NOT create a branch or touch `.last-sync`/`main`. Inspect `git status` → clean, no new branch.

- [ ] **Step 2: Verify no fork files were modified**

Run: `git status --porcelain`
Expected: empty (dry run touched nothing).

- [ ] **Step 3: Commit** (only if a script fix was required)

```bash
git add .dsh/skills/sync-arch-from-ubuntu/
git commit -m "fix: resolve dry-run reconciliation defects"
```

---
## Task 6: Docs + final wiring

**Files:**
- Create: `.dsh/skills/sync-arch-from-ubuntu/README.md` (optional usage doc)
- Modify: fork `CLAUDE.md` (add a short note pointing at the skill)

- [ ] **Step 1: Write skill README.md** — 3-5 line usage summary mirroring SKILL.md.

- [ ] **Step 2: Add CLAUDE.md note**

Under a `## Sync with upstream` heading:
```
## Sync with upstream
This fork tracks upstream kossakovsky/selfhost-ai. To pull and translate Ubuntu changes for
Arch/CachyOS, use the sync-arch-from-ubuntu skill (see .dsh/skills/sync-arch-from-ubuntu/).
Semi-automatic: it stages a branch + SYNC_REPORT.md; review before merging, then --finalize.
```

- [ ] **Step 3: Final verification**

Run: `bash .dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh --dry-run` → succeeds.
Run: `bash .dsh/skills/sync-arch-from-ubuntu/scripts/tests/test_translate.sh` → passes.
Run: `bash .dsh/skills/sync-arch-from-ubuntu/scripts/tests/test_targets.sh` → passes.
Run: `bash .dsh/skills/sync-arch-from-ubuntu/scripts/tests/test_sync_dryrun.sh` → passes.

- [ ] **Step 4: Commit**

```bash
git add .dsh/skills/sync-arch-from-ubuntu/ CLAUDE.md
git commit -m "docs: skill usage README + CLAUDE.md sync note"
```

---
## Open items gated for the first real sync (not build blockers)
- docker-compose.yml merge strategy (model ports new upstream services into fork compose)
- confirm dropping telemetry.sh / update_preview.sh
- confirm appending 08_fix_permissions.sh step 8 to fork install.sh
