#!/bin/bash
# translate.sh <file> — translate Ubuntu shell to CachyOS, print to stdout.
# Deterministic rule engine: idioms.map drops/rewrites FIRST, then the apt
# command parser rewrites update/upgrade/install/remove invocations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="$(cd "$SCRIPT_DIR/../rules" && pwd)"
input="$1"

[ -f "$input" ] || { echo "translate.sh: no such file: $input" >&2; exit 2; }

# Pass A — idioms.map: case-sensitive LITERAL substring, first-match-wins in
# file order, empty replacement = drop line.
awk -F'\t' -v idr="$RULES_DIR/idioms.map" '
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
awk -F'\t' -v pkr="$RULES_DIR/packages.map" '
NR==FNR {
  split($0, a, "\t");
  if (a[2] != "") pkgmap[a[1]] = a[2];   # NF>=2 only
  next;
}
{
  line = $0;
  nf = split(line, w, " ");
  cmd = "";
  for (i = 1; i <= nf; i++) if (w[i] ~ /^(apt|apt-get)$/) { cmd = w[i]; break; }
  if (cmd == "") { print line; next; }

  op = ""; pkgstart = 0; is_sudo = 0;
  if (w[1] == "sudo") is_sudo = 1;
  if (w[is_sudo+1] != cmd) { print line; next; }   # not a bare apt command line
  for (i = is_sudo+2; i <= nf; i++) {
    if (w[i] ~ /^(update|upgrade|install|remove)$/) { op = w[i]; pkgstart = i+1; break; }
  }
  if (op == "") { print line; next; }

  if (op == "update") {
    pending_up = 1; updated = 1; next;
  }
  if (op == "upgrade") {
    if (pending_up) { pending_up = 0; updated = 1; print "pacman -Syu --noconfirm"; next; }
    pending_up = 0; updated = 1; print "pacman -Syu --noconfirm"; next;
  }
  if (op == "remove") {
    pkg = "";
    for (i = pkgstart; i <= nf; i++) if (w[i] != "-y") { pkg = w[i]; break; }
    print "pacman -R " pkg; next;
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
    if (mapped == "") next;                       # all pkgs dropped -> no dangling command
    if (updated) print "pacman -S --needed --noconfirm " mapped;
    else         print "pacman -Syu --needed --noconfirm " mapped;   # no-prior-update guard
    next;
  }
  print line;
}' "$RULES_DIR/packages.map" - |
# Guard: bare `pacman -Sy ` (next token not `u`) is forbidden.
awk 'index($0, "pacman -Sy ") && !(index($0, "pacman -Syu ")) { print "translate.sh: bare pacman -Sy forbidden" > "/dev/stderr"; exit 1 } { print }'
