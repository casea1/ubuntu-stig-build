#!/usr/bin/env bash
# it-offload -- set up and check the weekly audit/log offload.
#
# The job itself is /etc/cron.weekly/audit-offload, written by the
# usg_remediate role. This configures it: what gets collected, where it is
# pushed, and the credentials -- and proves it works without waiting a week.
#
# Settings are written to /opt/it/site.yml so they SURVIVE ansible-pull. Edit
# that file by hand and this reads it back; there is no state anywhere else.
#
# Usage:
#   it-offload                 what is collected, where it goes, when it last ran
#   it-offload setup           walk through the whole configuration
#   it-offload creds           set the share credentials (masked, root-only)
#   it-offload containers on|off
#   it-offload push on|off     enable/disable the remote-share copy
#   it-offload test            run the job NOW and report what happened
#   it-offload log [N]         last N lines of the run log (default 30)
#   it-offload apply           re-render the job from the current settings
set -uo pipefail

SITE_YML=/opt/it/site.yml
JOB=/etc/cron.weekly/audit-offload
RUN_LOG=/var/log/audit-offload.log
DEFAULT_CRED=/etc/stig-build/audit-offload.cred

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn() { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

# Same precedence the playbook uses: site.d after site.yml, later wins.
site_var() {
  local key="$1" f v d=""
  for f in /opt/it/site.yml /opt/it/site.d/*.yml; do
    [ -r "$f" ] || continue
    v=$(sed -nE "s/^${key}[[:space:]]*:[[:space:]]*//p" "$f" | tail -1)
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "$v" ] && d="$v"
  done
  printf '%s\n' "$d"
}

persist() {  # key value  -- replace in place or append, never duplicate
  local key="$1" val="$2"
  install -d -o root -g "$(stat -c %G /opt/it 2>/dev/null || echo sudo)" -m 2770 /opt/it 2>/dev/null || true
  touch "$SITE_YML"
  if grep -qE "^${key}[[:space:]]*:" "$SITE_YML"; then
    sed -i -E "s|^${key}[[:space:]]*:.*|${key}: ${val}|" "$SITE_YML"
  else
    printf '%s: %s\n' "$key" "$val" >> "$SITE_YML"
  fi
}

cred_file() { local c; c=$(site_var usg_audit_offload_smb_credentials); printf '%s\n' "${c:-$DEFAULT_CRED}"; }

cmd_status() {
  local push share sub cred dir containers extra last
  push=$(site_var usg_audit_offload_smb_enabled); push="${push:-false}"
  share=$(site_var usg_audit_offload_smb_share)
  sub=$(site_var usg_audit_offload_smb_subdir)
  cred=$(cred_file)
  dir=$(site_var usg_audit_offload_dir); dir="${dir:-/opt/ia/audit-offload}"
  containers=$(site_var usg_audit_offload_containers); containers="${containers:-false}"

  head2 "Audit / log offload"
  if [ -x "$JOB" ]; then ok "job installed: $JOB (runs weekly via cron.weekly)"
  else bad "job NOT installed at $JOB -- run an ansible-pull"; fi

  head2 "What gets collected"
  printf '  %-22s %s\n' "audit trail" "always -- rotated /var/log/audit -> audit-<host>-<date>.tar.gz"
  if [ "$containers" = true ]; then
    ok "container logs      ON  -> logs-<host>-<date>.tar.gz"
  else
    warn "container logs      OFF (container output is not in /var/log or journald,"
    say  "                      so nothing else collects it)"
  fi
  # Stop at the first line that is not a list item, so a later list in the
  # same file is not swept up as if it belonged to this key.
  extra=$(awk '
    /^usg_audit_offload_extra[[:space:]]*:/ { inlist = 1; next }
    inlist && /^[[:space:]]+-[[:space:]]*/  { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
    inlist { exit }
  ' "$SITE_YML" 2>/dev/null)
  if [ -n "$extra" ]; then
    printf '  %-22s\n' "extra files"
    printf '%s\n' "$extra" | sed 's/^/      /'
  else
    printf '  %-22s %s(none)%s\n' "extra files" "$DIM" "$R"
  fi

  head2 "Where it goes"
  printf '  %-22s %s\n' "staged locally" "$dir"
  if [ "$push" = true ]; then
    ok "remote push         ON  -> $share/${sub:-<host>}"
    if [ -r "$cred" ]; then
      ok "credentials         $cred ($(stat -c %a "$cred"))"
      [ "$(stat -c %a "$cred")" = 600 ] || warn "credentials should be 0600"
    else
      bad "credentials         MISSING at $cred -- the push will SKIP"
      say "                      fix: it-offload creds"
    fi
    command -v mount.cifs >/dev/null 2>&1 && ok "cifs-utils          installed" \
      || bad "cifs-utils          NOT installed -- the push will SKIP"
  else
    warn "remote push         OFF (local staging only)"
  fi

  # The PowerStrux report is NOT collected here and never has been. Say so:
  # "the offload is configured" has been read as "the reports are going out".
  head2 "PowerStrux reports"
  if [ -x /opt/_AuditFiles/powerstrux-offload.sh ]; then
    say "  ${DIM}Not this job's -- it-powerstrux offload owns the weekly report folder.${R}"
    say "  ${DIM}Check it with: it-powerstrux offload${R}"
  else
    warn "not collected by anything on this box (this job only takes the audit trail)"
    say  "  ${DIM}The powerstrux role installs the report offload; run an ansible-pull.${R}"
  fi

  head2 "Last run"
  if [ -r "$RUN_LOG" ]; then
    last=$(tail -5 "$RUN_LOG")
    printf '%s\n' "$last" | sed 's/^/  /'
  else
    say "  ${DIM}never run, or no log yet at $RUN_LOG${R}"
  fi
  head2 "Archives on disk"
  ls -1t "$dir" 2>/dev/null | head -6 | sed 's/^/  /' || say "  ${DIM}(none)${R}"
  say ""
  say "  ${DIM}Configure: it-offload setup     Prove it: it-offload test${R}"
  say ""
}

cmd_creds() {
  local cred u p p2 dom
  cred=$(cred_file)
  head2 "Share credentials -> $cred"
  say "  Never stored in the repo. Root-only on this box."
  say ""
  printf '  username: '; read -r u
  [ -n "$u" ] || die "username cannot be empty"
  printf '  domain (blank for none): '; read -r dom
  printf '  password: '; stty -echo 2>/dev/null; read -r p; stty echo 2>/dev/null; echo
  printf '  again:    '; stty -echo 2>/dev/null; read -r p2; stty echo 2>/dev/null; echo
  [ "$p" = "$p2" ] || die "passwords do not match"
  [ -n "$p" ] || die "password cannot be empty"

  install -d -m 0700 -o root -g root "$(dirname "$cred")"
  umask 077
  { printf 'username=%s\n' "$u"
    printf 'password=%s\n' "$p"
    [ -n "$dom" ] && printf 'domain=%s\n' "$dom"; } > "$cred"
  chmod 0600 "$cred"; chown root:root "$cred"
  ok "written, 0600 root:root"
  say "  ${DIM}Prove it works: it-offload test${R}"
}

cmd_setup() {
  local share sub containers extra ans cred
  head2 "Offload setup"
  say "  Settings go to $SITE_YML and survive ansible-pull."
  say ""

  printf '  Collect CONTAINER logs as well as the audit trail? [Y/n] '; read -r ans
  case "$ans" in [Nn]*) containers=false ;; *) containers=true ;; esac
  persist usg_audit_offload_containers "$containers"

  say ""
  say "  Extra files to collect (application audit trails living in volumes)."
  say "  ${DIM}Common one: /var/lib/docker/volumes/open-webui/_data/audit.log${R}"
  printf '  Add the Open WebUI audit trail? [Y/n] '; read -r ans
  case "$ans" in
    [Nn]*) ;;
    *)
      if ! grep -q 'open-webui/_data/audit.log' "$SITE_YML" 2>/dev/null; then
        {
          printf '\n# Set by it-offload -- extra log sources for the weekly offload.\n'
          printf 'usg_audit_offload_extra:\n'
          printf '  - /var/lib/docker/volumes/open-webui/_data/audit.log\n'
          printf '  - /var/log/clamav-scan.log\n'
        } >> "$SITE_YML"
      fi
      ;;
  esac

  say ""
  printf '  Push to a remote share? [y/N] '; read -r ans
  case "$ans" in
    [Yy]*) ;;
    *) persist usg_audit_offload_smb_enabled false
       ok "local staging only. Settings written."
       say "  ${DIM}Apply now: it-offload apply${R}"; return 0 ;;
  esac

  printf '  share (e.g. //logsrv/audit$): '; read -r share
  [ -n "$share" ] || die "share cannot be empty"
  printf '  subdirectory on the share [%s]: ' "$(hostname -s)"; read -r sub
  sub="${sub:-$(hostname -s)}"

  persist usg_audit_offload_smb_enabled true
  persist usg_audit_offload_smb_share "\"$share\""
  persist usg_audit_offload_smb_subdir "\"$sub\""

  cred=$(cred_file)
  if [ -r "$cred" ]; then
    ok "credentials already present at $cred"
  else
    say ""
    printf '  Set the credentials now? [Y/n] '; read -r ans
    case "$ans" in [Nn]*) warn "no credentials -- the push will SKIP until you run: it-offload creds" ;;
                   *) cmd_creds ;; esac
  fi

  say ""
  ok "Settings written to $SITE_YML"
  say "  ${DIM}Apply now:  it-offload apply${R}"
  say "  ${DIM}Then prove: it-offload test${R}"
}

cmd_toggle() {  # key, on|off, label
  local key="$1" val="$2" label="$3"
  case "$val" in
    on|true|yes)  persist "$key" true;  ok "$label ON" ;;
    off|false|no) persist "$key" false; ok "$label OFF" ;;
    *) die "usage: it-offload ${label// /-} on|off" ;;
  esac
  say "  ${DIM}Apply: it-offload apply${R}"
}

# The job is a TEMPLATE rendered by the role, so the only honest way to
# regenerate it from new settings is to re-run the pull. Say that rather than
# writing a second copy of the job here that could drift from the role's.
cmd_apply() {
  head2 "Applying"
  say "  The job is rendered by the usg_remediate role, so the settings you just"
  say "  wrote take effect on the next configuration-management run:"
  say ""
  say "    sudo ansible-pull -U <repo-url> -e deployment_profile=<profile>${DIM} \\${R}"
  say "      ${DIM}--skip-tags ai-runtime,ai-gpu${R}   ${DIM}(on an AI node)${R}"
  say ""
  say "  ${DIM}Then: it-offload test${R}"
}

cmd_test() {
  [ -x "$JOB" ] || die "no job at $JOB -- run an ansible-pull first"
  head2 "Running $JOB now"
  local before rc
  before=$(wc -l < "$RUN_LOG" 2>/dev/null || echo 0)
  "$JOB"; rc=$?
  say ""
  if [ "$rc" -eq 0 ]; then ok "job exited 0"
  else bad "job exited $rc -- the offload did NOT complete (the local copy is still staged)"; fi
  head2 "What it did"
  if [ -r "$RUN_LOG" ]; then
    tail -n +$((before + 1)) "$RUN_LOG" | sed 's/^/  /'
  else
    warn "no run log at $RUN_LOG"
  fi
  say ""
  return "$rc"
}

cmd_log() { local n="${1:-30}"; [ -r "$RUN_LOG" ] || die "no log at $RUN_LOG"; tail -n "$n" "$RUN_LOG"; }

case "${1:-status}" in
  ""|status)  cmd_status ;;
  setup)      cmd_setup ;;
  creds)      cmd_creds ;;
  containers) cmd_toggle usg_audit_offload_containers "${2:-}" "container logs" ;;
  push)       cmd_toggle usg_audit_offload_smb_enabled "${2:-}" "remote push" ;;
  apply)      cmd_apply ;;
  test)       cmd_test ;;
  log)        cmd_log "${2:-30}" ;;
  -h|--help)  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0" ;;
  *)          die "unknown command: $1  (try --help)" ;;
esac
