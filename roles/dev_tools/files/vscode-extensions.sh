#!/usr/bin/env bash
# it-vscode -- one copy of the VS Code extension set for the whole box.
#
# The set is installed once into /opt/vscode-extensions. Each user's
# ~/.vscode/extensions holds SYMLINKS into it, so an account costs bytes rather
# than the 3.0 GB / 27,395 files a real copy costs -- which is what made a
# single `useradd` take 65 seconds when the set was seeded into /etc/skel.
#
#   it-vscode                  what is shared, and who is linked   (the default)
#   it-vscode status
#   it-vscode link <user>      link one account to the shared set
#   it-vscode link --all       every human account (uid >= 1000)
#   it-vscode unlink <user>    remove the links (keeps anything they installed)
#   it-vscode copy <user>      a REAL private copy instead of links, for someone
#                              who needs to modify the shared extensions
#   it-vscode verify [user]    ask VS Code itself what it can see
#
# Users can still install their own extensions: the directory is theirs and
# writable, and only the shared entries are links. `code --uninstall-extension`
# on a shared one removes the LINK, not the store.
set -uo pipefail

SHARED="${VSCODE_SHARED_DIR:-/opt/vscode-extensions}"
QUIET=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
head2() { [ "$QUIET" = 1 ] || printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { [ "$QUIET" = 1 ] || printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { [ "$QUIET" = 1 ] || printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R" >&2; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# Human accounts, the same range the org checklist counts.
humans() { awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | sort; }
home_of() { getent passwd "$1" | cut -d: -f6; }

shared_exts() {
  [ -d "$SHARED" ] || return 0
  find "$SHARED" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

# Both editors keep their own extensions directory, and they are NOT the same
# place -- linking one and not the other is the mistake to avoid.
ext_dirs_for() {   # $1 = user -> the dirs to populate, one per line
  local h; h="$(home_of "$1")"
  [ -n "$h" ] && [ -d "$h" ] || return 1
  printf '%s/.vscode/extensions\n' "$h"
  printf '%s/.local/share/code-server/extensions\n' "$h"
}

link_user() {   # $1 = user
  local u="$1" d e n=0 h
  h="$(home_of "$u")"
  [ -n "$h" ] && [ -d "$h" ] || { warn "$u: no home directory, skipped"; return 0; }
  [ -d "$SHARED" ] || die "no shared store at $SHARED -- run an ansible-pull"

  while IFS= read -r d; do
    install -d -m 0700 -o "$u" -g "$(id -gn "$u")" "$d" 2>/dev/null || continue
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      # A REAL directory here is the user's own copy of that extension --
      # never clobber it with a link to the shared one.
      if [ -d "$d/$e" ] && [ ! -L "$d/$e" ]; then continue; fi
      ln -sfn "$SHARED/$e" "$d/$e" && n=$((n + 1))
    done < <(shared_exts)
    # VS Code reads this manifest rather than scanning the directory, so the
    # links are inert without it.
    if [ -r "$SHARED/extensions.json" ] && [ ! -e "$d/extensions.json" ]; then
      install -m 0644 -o "$u" -g "$(id -gn "$u")" "$SHARED/extensions.json" "$d/extensions.json"
    fi
    chown -h "$u:$(id -gn "$u")" "$d"/* 2>/dev/null || true
  done < <(ext_dirs_for "$u")
  ok "$u: $n link(s)"
}

unlink_user() {
  local u="$1" d e n=0
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      [ -L "$d/$e" ] && { rm -f "$d/$e"; n=$((n + 1)); }
    done < <(shared_exts)
  done < <(ext_dirs_for "$u")
  ok "$u: removed $n link(s) (anything they installed themselves is untouched)"
}

copy_user() {
  local u="$1" d sz
  sz=$(du -sh "$SHARED" 2>/dev/null | cut -f1)
  warn "this makes a PRIVATE copy of $sz for $u -- links cost bytes and this does not"
  while IFS= read -r d; do
    install -d -m 0700 -o "$u" -g "$(id -gn "$u")" "$d" 2>/dev/null || continue
    # Dereference the links this user already has, so the copy is real.
    cp -rL "$SHARED"/. "$d/" 2>/dev/null || true
    chown -R "$u:$(id -gn "$u")" "$d"
  done < <(ext_dirs_for "$u")
  ok "$u: private copy in place"
}

# The honest check: ask the editor, not the filesystem.
verify_user() {
  local u="${1:-}" h d out
  [ -n "$u" ] || u="$(humans | head -1)"
  h="$(home_of "$u")"; d="$h/.vscode/extensions"
  head2 "What VS Code reports for $u"
  if ! command -v code >/dev/null 2>&1; then bad "the 'code' command is not installed"; return 1; fi
  out=$(sudo -u "$u" env HOME="$h" code --list-extensions --extensions-dir "$d" 2>&1)
  if [ -z "$out" ]; then
    bad "VS Code lists NOTHING from $d"
    say "  ${DIM}The symlinks are there but the editor is not loading them. Its manifest${R}"
    say "  ${DIM}(extensions.json) is how it finds extensions, and a version that does${R}"
    say "  ${DIM}not accept the shared manifest needs a real copy instead:${R}"
    say "  ${DIM}  sudo it-vscode copy $u${R}"
    return 1
  fi
  printf '%s\n' "$out" | sed 's/^/      /'
  ok "$(printf '%s\n' "$out" | grep -c .) extension(s) visible"
}

cmd_status() {
  local n sz u d linked
  head2 "Shared VS Code extensions"
  if [ -d "$SHARED" ]; then
    n=$(shared_exts | grep -c . || true); sz=$(du -sh "$SHARED" 2>/dev/null | cut -f1)
    ok "store             $SHARED  -- ${n:-0} extension(s), $sz"
    [ -r "$SHARED/extensions.json" ] && ok "manifest          present" \
      || warn "manifest          MISSING -- VS Code will not load the links without it"
  else
    bad "no store at $SHARED -- run an ansible-pull"
    return 1
  fi

  head2 "Accounts"
  printf '  %-24s %-10s %s\n' USER LINKED WHERE
  printf '  %s\n' "$(printf '%.0s-' $(seq 1 66))"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    linked=0
    while IFS= read -r d; do
      [ -d "$d" ] || continue
      linked=$((linked + $(find "$d" -maxdepth 1 -type l 2>/dev/null | wc -l)))
    done < <(ext_dirs_for "$u")
    if [ "$linked" -gt 0 ]; then
      printf '  %-24s %s%-10s%s %s\n' "$u" "$GRN" "$linked" "$R" "~/.vscode + code-server"
    else
      printf '  %-24s %s%-10s%s %s\n' "$u" "$YEL" "no" "$R" "sudo it-vscode link $u"
    fi
  done < <(humans)
  say ""
  say "  ${DIM}New accounts inherit the links from /etc/skel automatically.${R}"
  say "  ${DIM}Prove the editor actually sees them:  sudo it-vscode verify${R}"
  say ""
}

CMD="${1:-status}"; shift 2>/dev/null || true
for a in "$@"; do [ "$a" = --quiet ] && QUIET=1; done

case "$CMD" in
  ""|status) cmd_status ;;
  link)
    case "${1:-}" in
      --all) while IFS= read -r u; do [ -n "$u" ] && link_user "$u"; done < <(humans) ;;
      "")    die "usage: it-vscode link <user> | --all" ;;
      *)     id "$1" >/dev/null 2>&1 || die "no such user: $1"; link_user "$1" ;;
    esac ;;
  unlink)
    [ -n "${1:-}" ] || die "usage: it-vscode unlink <user>"
    id "$1" >/dev/null 2>&1 || die "no such user: $1"; unlink_user "$1" ;;
  copy)
    [ -n "${1:-}" ] || die "usage: it-vscode copy <user>"
    id "$1" >/dev/null 2>&1 || die "no such user: $1"; copy_user "$1" ;;
  verify) verify_user "${1:-}" ;;
  *) die "unknown command: $CMD  (try: it-vscode --help)" ;;
esac
