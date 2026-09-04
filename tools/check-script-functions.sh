#!/usr/bin/env bash
# Every function an it-* script calls must be one it defines, or one it sources.
#
# WHY THIS EXISTS. `explain_mount_error` shipped and reached three boxes: bash
# resolves a function name only when the line RUNS, so `bash -n` was clean and
# the failure surfaced inside an error path -- the moment an operator most needs
# the tool to work. Running the script with --help does not reach it either.
# Only a static cross-check does.
#
# A "call" is a name at the START of a command. That deliberately ignores the
# same name inside a string (`echo "... nmap_container builds ..."`) or a grep
# pattern, which is where the first version's false positives came from.
rc=0
for f in roles/*/files/*.sh; do
  head -1 "$f" | grep -q '^#!' || continue

  # Definitions here, plus anything this script sources -- adduser.sh gets
  # pw_choose from pw-common.sh and that is not a bug.
  defined=$(grep -ohE '^[a-z_][a-z0-9_]*\(\)' "$f" | tr -d '()')
  for src in $(grep -oE '^\s*\.\s+"?\$\{?[A-Za-z_]+\}?/([a-z0-9_-]+\.sh)' "$f" \
               | grep -oE '[a-z0-9_-]+\.sh$'); do
    for cand in roles/*/files/"$src"; do
      [ -r "$cand" ] && defined="$defined
$(grep -ohE '^[a-z_][a-z0-9_]*\(\)' "$cand" | tr -d '()')"
    done
  done
  defined=$(printf '%s\n' "$defined" | sort -u)

  # Heredoc bodies are skipped. These scripts WRITE config files -- grub.cfg,
  # systemd units, .desktop entries -- and that content is full of lines that
  # look like a shell command (`password_pbkdf2 $SUPERUSER $hash` is GRUB
  # syntax, not a call). Without this the check cries wolf and gets ignored,
  # which is how a checker stops being run at all.
  called=$(awk '
    inhd { if ($0 ~ "^[[:space:]]*" delim "[[:space:]]*$") inhd = 0; next }
    match($0, /<<-?[[:space:]]*\047?"?[A-Za-z_][A-Za-z0-9_]*/) {
      d = substr($0, RSTART, RLENGTH)
      sub(/^<<-?[[:space:]]*\047?"?/, "", d)
      delim = d; inhd = 1; next
    }
    /^[[:space:]]*[a-z][a-z0-9]*_[a-z0-9_]+[[:space:]]/ { print $1 }
  ' "$f" | sort -u)
  for c in $called; do
    printf '%s\n' "$defined" | grep -qxF "$c" && continue
    command -v "$c" >/dev/null 2>&1 && continue
    echo "FAIL $f calls '$c', which it neither defines nor sources"
    rc=1
  done
done
[ "$rc" -eq 0 ] && echo "OK   every internal function call resolves"
exit "$rc"
