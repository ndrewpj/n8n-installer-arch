#!/bin/bash
# translate.sh <file> — translate Ubuntu shell to CachyOS, print to stdout.
# Deterministic rule engine: idioms.map drops/rewrites FIRST, then the apt
# command parser rewrites update/upgrade/install/remove invocations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="$(cd "$SCRIPT_DIR/../rules" && pwd)"

if [ $# -lt 1 ]; then
  echo "usage: translate.sh <file>" >&2
  exit 2
fi
input="$1"

# Input may be a regular file, `-`/stdin, or a process-substitution fd
# (/dev/fd/N — a pipe, which -f does not accept). Any readable source works.
if [ "$input" != "-" ] && [[ "$input" != /dev/fd/* ]] && [ ! -f "$input" ]; then
  echo "translate.sh: no such input: $input" >&2
  exit 2
fi
for rf in idioms.map packages.map; do
  if [ ! -f "$RULES_DIR/$rf" ]; then
    echo "translate.sh: missing rules file $RULES_DIR/$rf" >&2
    exit 2
  fi
done

# Pass A — idioms.map: case-sensitive LITERAL substring, first-match-wins in
# file order, empty replacement = drop line. Patterns are literal (index()),
# so `[`/`]` in patterns are safe.
awk -F'\t' '
NR==FNR {
  split($0, a, "\t");
  n++;
  pat[n] = a[1];
  rep[n] = a[2];
  next;
}
{
  line = $0;
  for (i = 1; i <= n; i++) {
    if (index(line, pat[i])) {
      if (rep[i] == "") {
        line = "";
      } else {
        p = index(line, pat[i]);
        line = substr(line, 1, p - 1) rep[i] substr(line, p + length(pat[i]));
      }
      break;                       # first-match-wins, file order
    }
  }
  if (line != "") print line;
}' "$RULES_DIR/idioms.map" "$input" |

# Pass B — packages.map + apt command parser.
#
# Ordering rule: the no-prior-update guard must never let an install land ahead
# of the upgrade it implies, nor emit a redundant duplicate upgrade. The parser
# buffers apt-translated lines in `buf[]` and flushes them in source order when
# a NON-apt line appears or at END. `pending_up`/`updated`/`upgraded_once` are
# per-file heuristics (single awk state machine): an install after ANY prior
# update gets `-S --needed`, even if the update covered a different repo block.
# This is accepted because idiom rows drop repo-add lines and Arch pulls from
# official repos.
awk -F'\t' '
NR==FNR {
  split($0, a, "\t");
  if (a[2] != "") pkgmap[a[1]] = a[2];   # NF>=2 only
  next;
}
function emit(s)  { buf[nbuf++] = s; }
function flush()  { for (i = 0; i < nbuf; i++) print buf[i]; nbuf = 0; }
{
  line = $0;
  nf = split(line, w, " ");
  cmd = "";
  for (i = 1; i <= nf; i++) if (w[i] ~ /^(apt|apt-get)$/) { cmd = w[i]; break; }
  if (cmd == "") { flush(); print line; next; }

  op = ""; pkgstart = 0; is_sudo = 0;
  if (w[1] == "sudo") is_sudo = 1;
  if (w[is_sudo+1] != cmd) { flush(); print line; next; }   # not a bare apt command
  for (i = is_sudo+2; i <= nf; i++) {
    if (w[i] ~ /^(update|upgrade|install|remove)$/) { op = w[i]; pkgstart = i+1; break; }
  }
  if (op == "") { flush(); print line; next; }

  if (op == "update") {
    pending_up = 1; updated = 1; pending_up_seen = 1;
    next;                          # -Syu folds into the next upgrade/install
  }
  if (op == "upgrade") {
    pending_up = 0; updated = 1;
    # A standalone upgrade right after a guard install (which already emitted a
    # full `-Syu --needed`) is redundant unless a fresh apt update preceded it
    # (covering a repo added after the guard). Suppress the redundant one.
    # NOTE: `upgraded_once` is never reset; a legitimate later upgrade is only
    # re-armed by `pending_up_seen` on a fresh `apt update`. This coupling relies
    # on idioms.map dropping every repo-add line — if a future idiom regression
    # lets a repo line through, a post-guard upgrade would be silently suppressed.
    if (upgraded_once && !pending_up_seen) { next; }
    emit("pacman -Syu --noconfirm");
    next;
  }
  if (op == "remove") {
    pending_up = 0; updated = 1;
    pkgs = ""; any = 0;
    for (i = pkgstart; i <= nf; i++) {
      if (w[i] == "-y" || w[i] == "--purge") continue;
      if (any) pkgs = pkgs " ";
      pkgs = pkgs w[i]; any = 1;
    }
    if (pkgs != "") emit("pacman -R " pkgs);
    next;
  }
  if (op == "install") {
    mapped = ""; any = 0;
    for (i = pkgstart; i <= nf; i++) {
      if (w[i] == "-y") continue;
      m = pkgmap[w[i]];
      if (m == "") m = w[i];            # unmapped pkg passes through
      if (m == "-") continue;           # drop mapped-to-`-` packages
      if (any) mapped = mapped " ";
      mapped = mapped m; any = 1;
    }
    if (mapped == "") { pending_up = 0; updated = 1; next; }   # all dropped
    if (updated) {
      pending_up = 0;
      emit("pacman -S --needed --noconfirm " mapped);
    } else {
      # No-prior-update guard: this install needs a full upgrade first.
      # NOTE: the `pending_up_seen = 0` reset is a no-op here — this branch only
      # runs when `updated==0`, which guarantees no `apt update` ever fired, so
      # `pending_up_seen` was already 0. Kept for explicitness.
      pending_up = 0; updated = 1; upgraded_once = 1; pending_up_seen = 0;
      emit("pacman -Syu --needed --noconfirm " mapped);
    }
    next;
  }
  print line;
}
END {
  if (pending_up) emit("pacman -Syu --noconfirm");
  flush();
}' "$RULES_DIR/packages.map" - |
# Guard: bare `pacman -Sy ` (next token not `u`) is forbidden.
awk 'index($0, "pacman -Sy ") && !(index($0, "pacman -Syu ")) { print "translate.sh: bare pacman -Sy forbidden" > "/dev/stderr"; exit 1 } { print }'
