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
| `scripts/sync.sh` | Adds `upstream` remote if missing, fetches, computes the changed-file set vs the last sync point, calls `translate.sh` on changed files, stages a `sync/from-upstream-<date>` branch, writes `SYNC_REPORT.md` | `bash scripts/sync.sh` | git, translate.sh |
| `scripts/translate.sh` | Applies rules to a file (or stdin) and emits the translated output | `bash translate.sh <file>` | rules/ |
| `rules/packages.map` | `python3-pip→python-pip`, `build-essential→base-devel`, `whiptail→libnewt`, `docker-ce*→docker/docker-compose`, `software-properties-common→(drop)`, etc. | read by translate.sh | — |
| `rules/idioms.map` | `apt update`→`pacman -Syu`, `DEBIAN_FRONTEND=noninteractive`→(drop), `add-apt-repository universe`→(drop), `dpkg-reconfigure`→(drop), `apt-key`→(drop), `unattended-upgrades`→(drop), `install .deb`→yay/pacman, etc. | read by translate.sh | — |
| `rules/fork-exclude` | `old_02_install_docker.sh`, fork `utils.sh`, `README.md` preamble, fork `docker-compose.yml` (user's compose may diverge) | read by sync.sh to skip overwrite | — |
| `rules/ignore.map` | files upstream has no CachyOS equivalent for (e.g. telemetry.sh? — decided at build time) | read by sync.sh | — |
| `templates/SYNC_REPORT.md` | per-file: translated / skipped / needs-human-review / new | filled by sync.sh | — |

### Data flow (one sync run)

1. `sync.sh` ensures `upstream` remote → `git fetch upstream`.
2. Reads last sync baseline from `.dsh/skills/sync-arch-from-ubuntu/.last-sync` (commit hash). On first run (no baseline), baseline = the fork's current HEAD, and full reconciliation is implied.
3. Computes changed files: `git diff --name-status <baseline>..upstream/main` → `added|modified|deleted`.
4. For each path:
   - If in `ignore.map` → skip.
   - If in `fork-exclude` → do not overwrite; log `preserved`.
   - Else if a `-copy` translation target → run `translate.sh` and write the translated file.
   - Deleted upstream files that are fork-owned → leave; log.
   - Any file where rules produce an uncertain result → mark `needs-human-review`.
5. Stages everything on a fresh branch `sync/from-upstream-<YYYYMMDD-HHMM>`.
6. Writes `SYNC_REPORT.md` (untracked, not committed) summarizing the action per file and a list of files needing human eyes.
7. Prints a short summary and stops. The model then presents the diff + report to the user for approval before any merge.

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
- `apt update -y`/`apt-get update` → `pacman -Syu --noconfirm` (or `pacman -Sy`)
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

## Open items resolved at build time

- Which upstream additions are worth porting vs dropping in full reconciliation (e.g. `doctor.sh`, `databases.sh`, `git.sh`, worker generators). Default: port `git.sh`, `utils.sh` helpers, `databases.sh`; mark `generate_n8n_workers.sh`, `generate_welcome_page.sh`, `telemetry.sh`, `update_preview.sh` as `needs-human-review` or `ignore` pending user preference.
- Whether `docker-compose.yml` is fork-excluded (fork compose is older) — likely yes for reconciliation, then re-port upstream service additions selectively.
