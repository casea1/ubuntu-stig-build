#!/usr/bin/env bash
# Every it-* script's header block must be comments only, all the way to the
# first line of code. A line of prose that lost its "#" is SYNTACTICALLY VALID
# bash -- `every user gets Libero SoC` is a command invocation -- so `bash -n`
# passes and the damage only shows at run time, as "command not found" or, if
# the prose happens to contain the script's own name, as infinite recursion.
rc=0
for f in roles/*/files/*.sh; do
  head -1 "$f" | grep -q '^#!' || continue
  b=$(grep -nE '^(set |\[ "\$\(id -u\)")' "$f" | head -1 | cut -d: -f1)
  [ -n "$b" ] || { echo "SKIP $f (no recognisable first code line)"; continue; }
  bad=$(awk -v b="$b" 'NR>1 && NR<b && $0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/ {print NR": "$0}' "$f")
  if [ -n "$bad" ]; then
    echo "FAIL $f -- prose outside a comment in the header:"
    printf '%s\n' "$bad" | sed 's/^/       /'
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "OK   every script header is comments only"
exit "$rc"
