# sync-arch-from-ubuntu

Keep this Arch/CachyOS fork in step with the Ubuntu-oriented upstream
`kossakovsky/selfhost-ai`. Run from the fork root:

```bash
bash .dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh          # fetch + classify + stage branch + report
bash .dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh --dry-run # preview the plan, touch nothing
bash .dsh/skills/sync-arch-from-ubuntu/scripts/sync.sh --finalize # after the branch is merged into main
```

It translates Ubuntu idioms (apt, whiptail, DEBIAN_FRONTEND, Docker repo setup) to
CachyOS (pacman), preserves fork-excluded paths, and stages a reviewable
`sync/from-upstream-*` branch plus `SYNC_REPORT.md`. Semi-automatic: you review
and merge into `main` before `--finalize` advances the `.last-sync` baseline.
