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

## First sync — confirm these with the user
On the first (full-reconciliation) sync, confirm before acting:
- docker-compose.yml merge strategy (port new upstream services selectively, never blind-overwrite).
- dropping `telemetry.sh` / `update_preview.sh` (ignore rows) is acceptable.
- appending `08_fix_permissions.sh` step 8 into the fork's `install.sh` is wanted.
- the `review` rows (e.g. import_workflows / generate_welcome_page tooling) are acceptable.
