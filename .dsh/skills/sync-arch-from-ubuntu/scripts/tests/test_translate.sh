#!/bin/bash
# test_translate.sh — run translate.sh against fixture inputs and grep-assert the output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSLATE="$SCRIPT_DIR/../translate.sh"
FIX="$SCRIPT_DIR/fixtures"

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

out_prep="$("$TRANSLATE" "$FIX/system_prep_ubuntu.sh")"
out_dock="$("$TRANSLATE" "$FIX/install_docker_ubuntu.sh")"

# 1. apt update + apt upgrade collapse -> single pacman -Syu --noconfirm
check "update+upgrade collapse into one pacman -Syu --noconfirm" \
  bash -c "printf '%s' \"\$0\" | grep -c '^pacman -Syu --noconfirm$' | grep -q '^1$'" "$out_prep"
check "no apt update/upgrade lines remain in prep" \
  bash -c "! printf '%s' \"\$0\" | grep -qE 'apt (update|upgrade)'" "$out_prep"

# 2 + 3. apt install package remap (build-essential, python3-pip, whiptail)
check "build-essential -> base-devel" \
  bash -c "printf '%s' \"\$0\" | grep -q 'base-devel'" "$out_prep"
check "no build-essential remains" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'build-essential'" "$out_prep"
check "python3-pip -> python-pip" \
  bash -c "printf '%s' \"\$0\" | grep -q 'python-pip'" "$out_dock"
check "no python3-pip remains" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'python3-pip'" "$out_dock"
check "whiptail -> libnewt (in list)" \
  bash -c "printf '%s' \"\$0\" | grep -q 'libnewt'" "$out_prep"
check "no bare whiptail remains" \
  bash -c "! printf '%s' \"\$0\" | grep -qE 'whiptail'" "$out_prep"

# 4. DEBIAN_FRONTEND removed
check "DEBIAN_FRONTEND=noninteractive line removed" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'DEBIAN_FRONTEND'" "$out_prep"

# 5. Docker repo/key block removed
check "download.docker.com gone" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'download.docker.com'" "$out_dock"
check "sources.list.d/docker.list gone" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'sources.list.d/docker.list'" "$out_dock"
check "dpkg --print-architecture gone" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'dpkg --print-architecture'" "$out_dock"
check "apt-get install of docker pkgs -> pacman" \
  bash -c "printf '%s' \"\$0\" | grep -q 'pacman -S --needed --noconfirm docker docker containerd docker docker-compose'" "$out_dock"

# 6. caddy remove + install
check "apt remove -y caddy -> pacman -R caddy" \
  bash -c "printf '%s' \"\$0\" | grep -q 'pacman -R caddy'" "$out_dock"
check "no 'apt remove -y caddy' remains" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'apt remove -y caddy'" "$out_dock"
check "caddy install -> pacman install" \
  bash -c "printf '%s' \"\$0\" | grep -q 'pacman -S --needed --noconfirm caddy'" "$out_dock"

# 7. no bare pacman -Sy (next token not u)
check "no bare pacman -Sy anywhere" \
  bash -c "! printf '%s' \"\$0\" | grep -E 'pacman -Sy ' | grep -vE 'pacman -Syu '" "$out_prep"
check "no bare pacman -Sy anywhere (docker)" \
  bash -c "! printf '%s' \"\$0\" | grep -E 'pacman -Sy ' | grep -vE 'pacman -Syu '" "$out_dock"

# 8. no-prior-update guard: install with NO preceding update -> pacman -Syu --needed
check "install w/o prior update -> pacman -Syu --needed --noconfirm" \
  bash -c "printf '%s' \"\$0\" | grep -q 'pacman -Syu --needed --noconfirm'" "$out_dock"

# 9. whiptail hint line -> pacman with --needed --noconfirm (no bare pacman -S)
tmp_hint="$FIX/_tmp_hint.sh"; printf 'sudo apt-get install -y whiptail\n' > "$tmp_hint"
out_hint="$("$TRANSLATE" "$tmp_hint")"
check "whiptail hint -> pacman -Syu --needed --noconfirm libnewt" \
  bash -c "printf '%s' \"\$0\" | grep -q 'pacman -Syu --needed --noconfirm libnewt'" "$out_hint"
check "no bare pacman -S libnewt (no --needed)" \
  bash -c "! printf '%s' \"\$0\" | grep -q 'pacman -S libnewt'" "$out_hint"

# 10. multi-package remove -> pacman -R pkg1 pkg2 ...
tmp_rm="$FIX/_tmp_rm.sh"; printf 'apt remove -y caddy nginx\n' > "$tmp_rm"
out_rm="$("$TRANSLATE" "$tmp_rm")"
check "apt remove -y caddy nginx -> pacman -R caddy nginx" \
  bash -c "printf '%s' \"\$0\" | grep -q 'pacman -R caddy nginx'" "$out_rm"

# 11. standalone apt update (no following upgrade/install) still emits -Syu
tmp_up="$FIX/_tmp_up.sh"; printf 'apt update\n' > "$tmp_up"
out_up="$("$TRANSLATE" "$tmp_up")"
check "standalone apt update -> pacman -Syu --noconfirm" \
  bash -c "printf '%s' \"\$0\" | grep -q 'pacman -Syu --noconfirm'" "$out_up"

# 12. ordering: install(guard) then upgrade with no update between -> redundant
#     upgrade suppressed (no duplicate -Syu after a guard install already -Syu'd)
tmp_ord="$FIX/_tmp_ord.sh"; printf 'apt install -y foo\napt upgrade\n' > "$tmp_ord"
out_ord="$("$TRANSLATE" "$tmp_ord")"
check "no redundant -Syu --noconfirm after guard install (no update between)" \
  bash -c "! printf '%s' \"\$0\" | grep -qE 'pacman -Syu --noconfirm'" "$out_ord"
rm -f "$tmp_hint" "$tmp_rm" "$tmp_up" "$tmp_ord"

# 13. translate.sh must accept a process-substitution fd (/dev/fd/N) and stdin
#     (`-`), not only a regular file — this is how sync.sh feeds upstream blobs.
out_fd="$("$TRANSLATE" <(printf 'sudo apt-get install -y whiptail\n'))"
check "translate accepts process-substitution fd" \
  bash -c "printf '%s' \"\$0\" | grep -q 'libnewt'" "$out_fd"
out_stdin="$(printf 'apt install -y python3-pip\n' | "$TRANSLATE" -)"
check "translate accepts stdin via '-'" \
  bash -c "printf '%s' \"\$0\" | grep -q 'python-pip'" "$out_stdin"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
