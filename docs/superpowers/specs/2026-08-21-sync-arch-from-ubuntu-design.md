# Design: `sync-arch-from-ubuntu` — DeepSeek Harness skill

Date: 2026-08-21
Status: Approved (option B)

## Summary

A DeepSeek Harness project skill that keeps this fork (`n8n-installer-arch`, Arch/CachyOS-oriented)
in sync with upstream `kossakovsky/selfhost-ai` (Ubuntu/Debian-oriented). The skill fetches
upstream changes, deterministically translates Ubuntu idioms to CachyOS equivalents, preserves
fork-specific files, stages a branch, and presents a reviewable diff + report. First run performs
a full reconciliation to establish a baseline; later runs sync only new upstream changes.

## User-selected decisions

- Deliverable form: **DeepSeek Harness skill**, project-scoped.
- Sync mode: **semi-automatic** — auto-translate and stage a branch, then present for review before merge.
- First sync: **full reconciliation then ongoing**.
- Skill location: **inside the fork repo** at `<fork>/.dsh/skills/`.
- Approach: **B — deterministic translation engine + model supervision** (chosen over pure in-head
  translation (A) and full auto-merge (C)).

## Architecture

The skill is a directory bundle discovered by the harness at the project root (`<projectRoot>/.dsh/skills`):

```
<fork>/.dsh/skills/sync-arch-from-ubuntu/
  SKILL.md            # skill frontmatter + full instructions (the "how to run a sync")
  scripts/
    sync.sh           # orchestrator: fetch upstream, diff, translate, stage branch, report
    translate.sh      # deterministic Ubuntu -> CachyOS rule engine over a file/stdin
    rules/            # declarative rules
      packages.map    # Ubuntu package name -> Arch package name
      idioms.map      # shell idiom / command -> replacement (line/substitution rules)
      fork-exclude    # fork-specific paths never overwritten
      ignore.map      # paths to skip entirely from upstream
  templates/
    SYNC_REPORT.md    # report skeleton
```

### Component responsibilities

| Unit | What it does | How you use it | Depends on |
|---|---|---|---|
| `SKILL.md` | Loaded by the harness; gives the model the exact run procedure, safety rules, and the package/idiom translation knowledge | invoked via `skill()` | scripts/ |
| `scripts/sync.sh` | Adds `upstream` remote if missing, fetches, computes the changed-file set vs the last sync point, classifies each path, calls `translate.sh` on translated files, stages a `sync/from-upstream-<date>` branch, writes `SYNC_REPORT.md` | `bash scripts/sync.sh [--dry-run]` | git, translate.sh |
| `scripts/translate.sh` | Applies rules to a file (or stdin) and emits the translated output | `bash translate.sh <file>` | rules/ |
| `rules/packages.map` | `python3-pip→python-pip`, `build-essential→base-devel`, `whiptail→libnewt`, `docker-ce*→docker/docker-compose`, `software-properties-common→(drop)`, etc. | read by translate.sh | — |
| `rules/idioms.map` | `apt update`→`pacman -Syu`, `DEBIAN_FRONTEND=noninteractive`→(drop), `add-apt-repository universe`→(drop), `dpkg-reconfigure`→(drop), `apt-key`→(drop), `unattended-upgrades`→(drop), `install .deb`→yay/pacman, etc. | read by translate.sh | — |
| `rules/targets.map` | **The single per-path classification source.** Lines of the form `<pattern>\t<action>` where action ∈ `translate | copy | preserve | ignore | review`. Longest-match wins; a missing pattern defaults to `copy` for known upstream files and `review` for anything the engine cannot classify confidently. This is what the data-flow §4 `-copy`/`-translate` terms refer to. | read by sync.sh to classify every changed path | — |
| `rules/fork-exclude` | Paths that are fork-owned and must **never** be overwritten (`old_02_install_docker.sh`, `n8n_pipe.py`, `old_start_services copy.py`, the fork's `README.md`/`docker-compose.yml` during reconciliation) | read by sync.sh (supersedes `targets.map` action) | — |
| `rules/ignore.map` | Paths upstream has no meaningful CachyOS equivalent for and should be dropped silently (e.g. `telemetry.sh`) | read by sync.sh | — |
| `templates/SYNC_REPORT.md` | per-file: translated / copied / preserved / skipped / needs-human-review / new | filled by sync.sh | — |
| `.dsh/skills/sync-arch-from-ubuntu/.last-sync` | Last-sync baseline (upstream commit hash + a `sync/from-upstream-*` branch name) — see Baseline lifecycle | written by `sync.sh --finalize` | — |

### Baseline lifecycle

`.last-sync` holds the upstream commit hash the fork was last synchronized to, plus the sync branch name that carried the merge. Because the flow is semi-automatic, the baseline **does not advance during staging** — it advances only when the user accepts the merge:

- `sync.sh` (no flag) — fetch, diff vs baseline, translate, stage branch, write `SYNC_REPORT.md`. **Does not** touch `.last-sync` or `main`.
- After the user reviews and merges the sync branch into `main`, the model (or the user) runs `bash scripts/sync.sh --finalize`, which:
  1. verifies the sync branch is merged into `main`,
  2. resolves `upstream/main` to a commit hash,
  3. writes the new hash + branch name to `.last-sync`,
  4. commits that single marker file on `main` (so the next run's baseline is durable).

If `.last-sync` is absent (first run) it means full reconciliation: baseline = fork HEAD, all upstream files are candidates. If `.last-sync` points to a commit not reachable from `upstream/main`, warn and reset to fork HEAD (full reconciliation).

### Data flow (one sync run)

1. `sync.sh` ensures `upstream` remote → `git fetch upstream`.
2. Reads last sync baseline from `.dsh/skills/sync-arch-from-ubuntu/.last-sync` (commit hash). On first run (no baseline), baseline = the fork's current HEAD, and full reconciliation is implied.
3. Computes changed files: `git diff --name-status <baseline>..upstream/main` → `added|modified|deleted`.
4. For each changed path, classify via `rules/targets.map` (longest-match) with `fork-exclude` taking precedence:
   - `ignore` → skip entirely.
   - `preserve` (or in `fork-exclude`) → do not overwrite; log `preserved`.
   - `translate` → run `translate.sh` and write the translated file.
   - `copy` → copy the file verbatim (no Ubuntu idioms to translate, e.g. JSON, plain YAML, `.gitignore`).
   - `review` → copy the file but log `needs-human-review` (a file the engine cannot classify confidently).
   - Deleted upstream files that are fork-owned → leave; log.
5. Stages everything on a fresh branch `sync/from-upstream-<YYYYMMDD-HHMM>` (does not touch `main` or `.last-sync`).
6. Writes `SYNC_REPORT.md` (untracked, not committed) summarizing the action per file and a list of files needing human eyes.
7. Prints a short summary and stops. The model then presents the diff + report to the user for approval before any merge; afterwards `--finalize` advances the baseline.

### Translation rules (core knowledge encoded)

Package name mappings (Ubuntu → Arch/CachyOS):
- `python3` → `python`, `python3-pip` → `python-pip`, `python3-dotenv` → `python-dotenv`, `python3-yaml` → `python-yaml`
- `build-essential` → `base-devel`
- `whiptail` → `libnewt`
- `apt-transport-https`, `lsb-release`, `ca-certificates`, `gnupg`, `openssl`, `psmisc`, `make`, `unzip`, `ufw`, `fail2ban`, `git`, `curl`, `htop` → kept, present in official repos
- `software-properties-common` → dropped
- `unattended-upgrades` → dropped (no direct Arch equivalent)
- `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` → `docker`, `docker-compose`, `containerd`, `runc` (+ optionally `docker-compose-bin` via yay)

Shell idiom mappings:
- `apt update -y`/`apt-get update` → `pacman -Syu --noconfirm` (single update+upgrade). Deliberate simplification: upstream's separate `apt update` then `apt upgrade` collapses to one `-Syu`. The translator must NOT "correct" this to `-Sy` (partial-upgrade footgun); `-Sy` alone is never emitted unless an upstream call is update-only with no follow-up upgrade.
- `apt install -y <pkgs>` / `apt-get install -y <pkgs>` → `pacman -Sy --noconfirm --needed <pkgs>` (mapped names)
- `apt upgrade -y` → part of `pacman -Syu`
- `DEBIAN_FRONTEND=noninteractive` / `dpkg-reconfigure` → dropped
- `add-apt-repository universe -y` → dropped
- Docker GPG key + `deb [arch=...] ...` repository block → dropped; replaced by official-repo install
- `apt remove -y caddy` → `pacman -R caddy` / `yay -R`
- whiptail package hint message → `sudo pacman -Sy libnewt`
- `docker compose` (plugin) invocation → preserved as-is

### Error handling

- `git fetch` failure → abort before any staging; report network/remote error.
- A file in `fork-exclude` that no longer exists upstream → no-op.
- Translation of a path produces zero output or a shell-syntax error → mark `needs-human-review`, do not delete the original.
- The `.last-sync` baseline points to a commit not on `upstream` → warn and re-baseline to fork HEAD (full reconciliation).
- Branch already exists for today → suffix `-2`, `-3`, ….
- Dry-run flag `--dry-run` prints the plan without staging.

### Testing

- Unit: run `translate.sh` against the current fork `01_system_preparation.sh` and `02_install_docker.sh`, assert the pacman equivalents match expected output.
- Fixture: a small synthetic Ubuntu script exercising every idiom in `idioms.map`; assert all mapped.
- Dry-run: `sync.sh --dry-run` with upstream cloned locally produces a correct plan without touching git state.
- Reconciliation smoke: dry-run full reconciliation against live upstream and inspect `SYNC_REPORT.md`.

### Scope guardrails (YAGNI)

- No auto-merge/auto-commit into `main` (semi-automatic by choice).
- No cron/schedule — syncs are run explicitly via the skill.
- No PR opening (branch is staged for manual review; user pushes if desired).
- No telemetry or network telemetry plumbing in the fork itself.

## Reconciliation target set (defaults for `rules/` on the first run)

These defaults are the concrete source for `targets.map` / `fork-exclude` / `ignore.map`
on full reconciliation. The model may adjust a handful after showing the user the plan,
but a planning baseline is pinned here.

### `scripts/` (upstream 24 files)

| Upstream path | Action | Rationale |
|---|---|---|
| `01_system_preparation.sh`, `02_install_docker.sh`, `03_generate_secrets.sh`, `04_wizard.sh`, `05_configure_services.sh`, `06_run_services.sh`, `07_final_report.sh`, `install.sh` | `translate` | Core install pipeline, already in fork; update + translate |
| `08_fix_permissions.sh` | `translate` | New upstream step; port (adds step 8 to install.sh) |
| `utils.sh` | `translate` | Upstream gained `init_paths`, profiles, doctor helpers; fork's simplified version must be replaced by the translated richer one |
| `git.sh` | `translate` | Git-pull-rebase helper upstream uses; port |
| `databases.sh` | `translate` | DB init before other services; port |
| `apply_update.sh`, `docker_cleanup.sh`, `update.sh` | `translate` | Already in fork; pull latest and translate |
| `restart.sh`, `setup_custom_tls.sh`, `doctor.sh`, `import_workflows.sh`, `download_top_workflows.sh`, `generate_n8n_workers.sh`, `generate_welcome_page.sh` | `review` | Functional scripts upstream added; port but flag for user confirmation (telemetry/import/welcome behavior is opinionated) |
| `telemetry.sh`, `update_preview.sh` | `ignore` | Telemetry/preview plumbing has no CachyOS value and upstream-specific services; drop silently |

### Root / other dirs

| Upstream path | Action | Rationale |
|---|---|---|
| `docker-compose.yml` | `review` | Fork's compose diverges (fewer services). Do a selective merge: port new upstream services into the fork compose rather than blind overwrite; flag for user. |
| `docker-compose.ollama-gpu-devices.yml`, `docker-compose.invokeai-gpu-devices.yml` | `review` | New GPU-pinning files; port after confirming fork's GPU profile |
| `Caddyfile`, `cloudflare-instructions.md`, `LICENSE`, `.gitignore`, `.env.example` | `copy` | No distro idioms, or present in fork; copy latest |
| `CHANGELOG.md`, `VERSION`, `Makefile`, `README.md` | `review` | README is fork-customized (Arch preamble); merge carefully; CHANGELOG/VERSION/Makefile optional |
| `grafana/`, `prometheus/`, `searxng/`, `n8n/`, `caddy-addon/`, `paddlex/`, `python-runner/`, `welcome/` | `copy` | Static config/data dirs; copy latest (fork dirs exist) |
| `certs/`, `start_services.py` | `review` | `certs/` is machine-generated (preserve); start_services.py diverged from fork's copy |
| Fork-only root files `n8n_pipe.py`, `old_start_services copy.py`, `old_02_install_docker.sh` | `preserve` (fork-exclude) | Fork-owned; never overwrite |

### What needs the user before the first reconciliation runs

- Confirm the `review` rows above (especially `docker-compose.yml` merge strategy and whether to import the 300-workflow / welcome-page tooling).
- Confirm `ignore` rows (telemetry, update_preview) are acceptable to drop.
- Confirm `08_fix_permissions.sh` step 8 should be appended to the fork's `install.sh`.
