#!/usr/bin/env bash
# powerstrux-offload -- collect the week's PowerStrux report and logs into one
# dated folder and copy that folder to a Windows file share.
#
# Reached as `it-powerstrux offload <command>`; this file is not run directly.
#
#   it-powerstrux offload                 what is collected, where it goes, last run
#   it-powerstrux offload setup           walk through the whole configuration
#   it-powerstrux offload creds           set the share account (service account)
#   it-powerstrux offload test            prove the share works, without waiting a week
#   it-powerstrux offload run             build and push this week's folder NOW
#   it-powerstrux offload run --local     build the folder, do not push
#   it-powerstrux offload extra           list / add / remove other logs to include
#   it-powerstrux offload list            the week folders staged on this box
#   it-powerstrux offload log [N]         last N lines of the run log
#   it-powerstrux offload on | off        enable/disable the whole offload
#   it-powerstrux offload push on | off   enable/disable the copy to the share
#   it-powerstrux offload audit on|off    also include the auditd archive
#   it-powerstrux offload containers on|off   also include `docker logs`
#   it-powerstrux offload opts <cifs,opts>    mount options (vers=2.1 for old servers)
#   it-powerstrux offload where           the four paths this uses
#
# WHAT A WEEK LOOKS LIKE. One folder per ISO week, named <YYYY>-W<nn>, the same
# name locally and on the share:
#
#   <share>/<subdir>/2026-W36/
#       MANIFEST.txt              what is in here, with sha256 for each file
#       powerstrux/               the report(s) this week produced
#       powerstrux/logs/          the run logs behind them
#       powerstrux/PowerStruxLAConfig.txt
#       audit/                    the auditd archive, if INCLUDE_AUDIT=true
#       containers/               `docker logs` per container, if enabled
#       logs/                     anything else listed under EXTRA
#
# THE LOCAL COPY IS ALWAYS KEPT, even when the push succeeds. A share that is
# unreachable, full or misconfigured must never be the reason a week's evidence
# went missing, so the push is a copy and its failure is loud but not
# destructive. KEEP week folders are held locally and then pruned.
#
# CONFIGURATION lives in TWO places on purpose:
#   /etc/stig-build/powerstrux-offload.conf   what this script reads. Changing
#                                             it takes effect immediately.
#   /opt/it/site.yml                          what ansible-pull renders that
#                                             conf from. Without this the next
#                                             pull would quietly revert you.
# Every command here writes BOTH. Edit the conf by hand and a pull puts it back;
# that is the trap this avoids.
#
# THE ACCOUNT. Windows file shares take either a domain account or a local
# account on the file server; `it-powerstrux offload creds` asks which and
# writes the right thing into the credentials file:
#   domain     -> domain=CORP (or corp.example.com), username=svc_audit
#   workgroup  -> domain=<the server's own name>, username=<local account>
#   guest      -> no credentials at all; only works if the share allows it
# The password is written to a root-only 0600 file and never to site.yml, the
# repo, or this box's logs.
set -uo pipefail

CONF=/etc/stig-build/powerstrux-offload.conf
SITE_YML="${SITE_YML:-/opt/it/site.yml}"
RUN_LOG=/var/log/powerstrux-offload.log
MNT=/run/powerstrux-offload.mnt
DEFAULT_CRED=/etc/stig-build/powerstrux-offload.cred

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

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$RUN_LOG"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
# Read as data, never sourced: this file is root-owned but sourcing a config is
# still executing it, and nothing here needs shell syntax.
conf_get() {   # $1 = key, $2 = default
  local v=""
  if [ -r "$CONF" ]; then
    v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -1)
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  fi
  printf '%s' "${v:-${2:-}}"
}
conf_all() {   # every value of a repeatable key, one per line
  [ -r "$CONF" ] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" \
    | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}
conf_set() {   # $1 = key, $2 = value -- replace in place or append, never duplicate
  local key="$1" val="$2"
  # 0700, and only when it is not already there: /etc/stig-build holds generated
  # secrets and it_scripts creates it 0700 root:root. `install -d` on an
  # EXISTING directory rewrites its mode, so this must not run unconditionally.
  [ -d "$(dirname "$CONF")" ] || install -d -m 0700 -o root -g root "$(dirname "$CONF")" 2>/dev/null || true
  [ -f "$CONF" ] || { printf '# Written by it-powerstrux offload. Rendered by the powerstrux role.\n' > "$CONF"; chmod 0640 "$CONF"; }
  if grep -qE "^[[:space:]]*$key[[:space:]]*=" "$CONF"; then
    sed -i -E "s|^[[:space:]]*$key[[:space:]]*=.*|$key=$val|" "$CONF"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONF"
  fi
  chmod 0640 "$CONF"; chown root:root "$CONF" 2>/dev/null || true
}
conf_set_list() {   # $1 = key, rest = values (repeatable key rewritten wholesale)
  local key="$1"; shift
  [ -f "$CONF" ] && { grep -vE "^[[:space:]]*$key[[:space:]]*=" "$CONF" > "$CONF.new" && mv "$CONF.new" "$CONF"; }
  local v; for v in "$@"; do printf '%s=%s\n' "$key" "$v" >> "$CONF"; done
  chmod 0640 "$CONF" 2>/dev/null || true
}

# The Ansible variable each conf key is rendered from. A setting written only to
# the conf is reverted by the next pull, so every write goes to both.
ansible_var() {
  case "$1" in
    ENABLED)            echo powerstrux_offload_enabled ;;
    KEEP)               echo powerstrux_offload_keep ;;
    WINDOW_DAYS)        echo powerstrux_offload_window_days ;;
    INCLUDE_AUDIT)      echo powerstrux_offload_include_audit ;;
    INCLUDE_CONTAINERS) echo powerstrux_offload_containers ;;
    SMB_ENABLED)        echo powerstrux_offload_smb_enabled ;;
    SMB_SHARE)          echo powerstrux_offload_smb_share ;;
    SMB_SUBDIR)         echo powerstrux_offload_smb_subdir ;;
    SMB_AUTH)           echo powerstrux_offload_smb_auth ;;
    SMB_OPTS)           echo powerstrux_offload_smb_options ;;
  esac
}

# A broken site.yml stops the NEXT pull at task 2, long after whoever broke it
# has gone home. Check before keeping the edit -- this is the same guard it-pull
# applies on the way in.
yaml_ok() {
  [ -s "$1" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1]))
except Exception as e:
    print(str(e).splitlines()[0]); sys.exit(1)' "$1" 2>&1
}

site_prepare() {
  install -d -o root -g "$(stat -c %G /opt/it 2>/dev/null || echo sudo)" -m 2770 /opt/it 2>/dev/null || true
  [ -f "$SITE_YML" ] || printf -- '---\n# Per-node overrides. Loaded above group_vars by local.yml.\n' > "$SITE_YML"
}
site_commit() {   # $1 = backup path -- keep the edit only if the file still parses
  local bak="$1" why
  if why=$(yaml_ok "$SITE_YML"); then rm -f "$bak"; return 0; fi
  cp -a "$bak" "$SITE_YML"; rm -f "$bak"
  bad "refused to write $SITE_YML -- the result would not parse: $why"
  return 1
}
persist_site() {   # $1 = key, $2 = value (already YAML-quoted if it needs to be)
  local key="$1" val="$2" bak
  site_prepare
  bak="$SITE_YML.bak-$$"; cp -a "$SITE_YML" "$bak"
  if grep -qE "^${key}[[:space:]]*:" "$SITE_YML"; then
    sed -i -E "s|^${key}[[:space:]]*:.*|${key}: ${val}|" "$SITE_YML"
  else
    printf '%s: %s\n' "$key" "$val" >> "$SITE_YML"
  fi
  site_commit "$bak"
}
persist_site_list() {   # $1 = key, rest = items
  local key="$1"; shift
  local bak; site_prepare
  bak="$SITE_YML.bak-$$"; cp -a "$SITE_YML" "$bak"
  # Drop the old block: the key line, then its list items. A comment or a blank
  # line ends the block, so a later list in the same file is never swept up.
  awk -v k="$key" '
    $0 ~ "^" k "[[:space:]]*:"            { skip = 1; next }
    skip && /^[[:space:]]+-[[:space:]]*/  { next }
    { skip = 0; print }
  ' "$SITE_YML" > "$SITE_YML.new" && mv "$SITE_YML.new" "$SITE_YML"
  if [ "$#" -eq 0 ]; then
    printf '%s: []\n' "$key" >> "$SITE_YML"
  else
    printf '%s:\n' "$key" >> "$SITE_YML"
    # Quoted: a glob like *.log at the START of a scalar is a YAML ALIAS, and
    # an unquoted one turns the next pull's site.yml into a parse error.
    local i; for i in "$@"; do printf '  - "%s"\n' "$i" >> "$SITE_YML"; done
  fi
  site_commit "$bak"
}

set_opt() {   # $1 = conf key, $2 = value, $3 = 1 to quote it in YAML
  local ck="$1" val="$2" q="${3:-0}" av
  conf_set "$ck" "$val"
  av="$(ansible_var "$ck")"
  [ -n "$av" ] || return 0
  if [ "$q" = 1 ]; then persist_site "$av" "\"$val\""; else persist_site "$av" "$val"; fi
}

# Every setting has to land in TWO places, and half-landing is a real outcome:
# the conf always takes, site.yml can be refused when the file is already
# broken. Report which happened rather than a flat "OK".
apply_opt() {   # $1 = conf key, $2 = value, $3 = quote?, $4 = what to call it
  if set_opt "$1" "$2" "$3"; then
    ok "$4"
  else
    ok "$4 -- on this box"
    bad "NOT persisted: the next ansible-pull will revert it"
    say "  ${DIM}Fix the file named above, then re-run this command.${R}"
    return 1
  fi
}

# ---- current settings ------------------------------------------------------
ENABLED=$(conf_get ENABLED true)
REPORT_DIR=$(conf_get REPORT_DIR /opt/_AuditFiles)
DEST_ROOT=$(conf_get DIR /opt/ia/powerstrux-offload)
KEEP=$(conf_get KEEP 26)
WINDOW=$(conf_get WINDOW_DAYS 8)
INC_AUDIT=$(conf_get INCLUDE_AUDIT false)
INC_CONT=$(conf_get INCLUDE_CONTAINERS false)
CONT_NAMES=$(conf_get CONTAINER_NAMES "")
AUDIT_OFFLOAD_DIR=$(conf_get AUDIT_SOURCE_DIR /opt/ia/audit-offload)
SMB_ON=$(conf_get SMB_ENABLED false)
SMB_SHARE=$(conf_get SMB_SHARE "")
SMB_SUBDIR=$(conf_get SMB_SUBDIR "$(hostname -s)")
SMB_CRED=$(conf_get SMB_CRED "$DEFAULT_CRED")
SMB_AUTH=$(conf_get SMB_AUTH domain)
SMB_OPTS=$(conf_get SMB_OPTS "vers=3.1.1,sec=ntlmssp,uid=0,gid=0,file_mode=0640,dir_mode=0750")

case "$KEEP"   in ''|*[!0-9]*) KEEP=26 ;; esac
case "$WINDOW" in ''|*[!0-9]*) WINDOW=8 ;; esac

week_id() { date +%G-W%V; }

# ---------------------------------------------------------------------------
# building the week's folder
# ---------------------------------------------------------------------------
mkdir_evidence() {   # root:audit, group-readable, others nothing
  install -d -m 0750 -o root -g audit "$1" 2>/dev/null || mkdir -p "$1"
}

# cp that keeps the evidence permissions whatever the source had.
put() {   # $1 = src file, $2 = dest dir
  cp -p -- "$1" "$2/" 2>>"$RUN_LOG" || return 1
  chmod 0640 "$2/$(basename "$1")" 2>/dev/null || true
  chown root:audit "$2/$(basename "$1")" 2>/dev/null || true
}

collect_reports() {   # $1 = week dir -> count on stdout
  local wdir="$1" out="$1/powerstrux" n=0 f
  mkdir_evidence "$out"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    put "$f" "$out" && { n=$((n + 1)); log "report: $f"; }
  done < <(find "$REPORT_DIR" -maxdepth 2 -type f \
             \( -iname '*.html' -o -iname '*.htm' \) -mtime "-$WINDOW" 2>/dev/null | sort)

  mkdir_evidence "$out/logs"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    put "$f" "$out/logs" && log "run log: $f"
  done < <(find "$REPORT_DIR/logs" -maxdepth 1 -type f -name 'powerstrux-*.log' \
             -mtime "-$WINDOW" 2>/dev/null | sort)
  rmdir "$out/logs" 2>/dev/null || true

  # The config decides what the report contains, so the report is not
  # self-explaining without it. It is not managed by the repo and IS hand-tuned
  # per site, which is exactly why a copy belongs with the evidence.
  local cfg
  cfg="$(dirname "$(conf_get PS_SCRIPT /opt/microsoft/powershell/7/Modules/ReportHTML/Initiate-PowerstruxLA.ps1)")/PowerStruxLAConfig.txt"
  [ -r "$cfg" ] && put "$cfg" "$out"

  printf '%s' "$n"
}

collect_audit() {   # the auditd trail, if the site wants one folder for everything
  local wdir="$1" out="$1/audit" n=0 f
  [ "$INC_AUDIT" = true ] || return 0
  mkdir_evidence "$out"
  # Reuse what /etc/cron.weekly/audit-offload already staged rather than tarring
  # /var/log/audit a second time -- that job owns the AU-4 artifact.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    put "$f" "$out" && { n=$((n + 1)); log "audit archive: $f"; }
  done < <(find "$AUDIT_OFFLOAD_DIR" -maxdepth 1 -type f -name '*.tar.gz' \
             -mtime "-$WINDOW" 2>/dev/null | sort)
  [ "$n" -eq 0 ] && { rmdir "$out" 2>/dev/null; log "WARNING: INCLUDE_AUDIT=true but nothing recent in $AUDIT_OFFLOAD_DIR"; }
  return 0
}

collect_containers() {
  local out="$1/containers" c n=0
  [ "$INC_CONT" = true ] || return 0
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log "WARNING: docker not available -- container logs NOT collected"; return 0
  fi
  mkdir_evidence "$out"
  # `docker logs` rather than reaching into /var/lib/docker: it is the supported
  # interface, works whatever log driver is set, and names files by container
  # rather than by the 64-char id the on-disk files use.
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
    if [ -n "$CONT_NAMES" ]; then
      case " $CONT_NAMES " in *" $c "*) ;; *) continue ;; esac
    fi
    docker logs --timestamps "$c" > "$out/$c.log" 2>&1 || true
    chmod 0640 "$out/$c.log" 2>/dev/null || true
    n=$((n + 1))
  done
  log "container logs: $n container(s)"
  [ "$n" -eq 0 ] && rmdir "$out" 2>/dev/null
  return 0
}

collect_extra() {
  local out="$1/logs" p f n=0
  local -a globs=()
  while IFS= read -r p; do [ -n "$p" ] && globs+=("$p"); done < <(conf_all EXTRA)
  [ "${#globs[@]}" -gt 0 ] || return 0
  mkdir_evidence "$out"
  for p in "${globs[@]}"; do
    # Unquoted on purpose: these are globs, and a glob that matches nothing
    # comes back as itself, which the -e test below rejects.
    for f in $p; do
      if [ -d "$f" ]; then
        # A directory is copied whole, under its own name. The old audit-offload
        # took files only and logged a directory as "unreadable"; this does not.
        cp -a -- "$f" "$out/$(basename "$f")" 2>>"$RUN_LOG" \
          && { n=$((n + 1)); log "extra dir: $f"; } || log "ERROR: could not copy $f"
      elif [ -r "$f" ]; then
        # Flattened name: two different /…/audit.log in one folder would
        # otherwise silently overwrite each other.
        cp -p -- "$f" "$out/$(printf '%s' "${f#/}" | tr '/' '_')" 2>>"$RUN_LOG" \
          && { n=$((n + 1)); log "extra: $f"; } || log "ERROR: could not copy $f"
      else
        log "WARNING: unreadable or missing, not collected: $f"
      fi
    done
  done
  [ "$n" -eq 0 ] && rmdir "$out" 2>/dev/null
  chmod -R g-w,o-rwx "$out" 2>/dev/null || true
  return 0
}

# Which profile this box is, and which commit it was last built from. Both
# belong in the evidence: "the report is clean" means nothing without them.
prof_now() {
  local v
  v=$(sed -nE 's/^deployment_profile[[:space:]]*:[[:space:]]*//p' "$SITE_YML" 2>/dev/null | tail -1)
  v=$(printf '%s' "$v" | tr -d "\"'")
  [ -n "$v" ] || v=$(cat /etc/stig-build/profile 2>/dev/null)
  printf '%s' "${v:-unknown}"
}
baseline_now() {
  local co="/root/.ansible/pull/$(hostname -s 2>/dev/null || hostname)" v=""
  [ -d "$co/.git" ] && v=$(git -C "$co" rev-parse --short HEAD 2>/dev/null)
  printf '%s' "${v:-unknown}"
}

write_manifest() {   # $1 = week dir, $2 = report count
  local wdir="$1" reports="$2" m="$1/MANIFEST.txt"
  {
    printf 'PowerStrux weekly offload\n'
    printf '=========================\n\n'
    printf '  host        : %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf '  week        : %s   (ISO week, Monday-based)\n' "$(basename "$wdir")"
    printf '  generated   : %s\n' "$(date -Is)"
    printf '  profile     : %s\n' "$(prof_now)"
    printf '  baseline    : %s\n' "$(baseline_now)"
    printf '  window      : files modified in the last %s days\n' "$WINDOW"
    printf '  reports     : %s\n' "$reports"
    [ "$reports" -eq 0 ] && printf '                NOTE: no PowerStrux report was produced in this window.\n'
    printf '\nContents (sha256  bytes  modified  path)\n'
    printf -- '----------------------------------------------------------------------\n'
  } > "$m"
  # Relative paths: the manifest travels with the folder and must still make
  # sense on the Windows side, where /opt/ia does not exist.
  ( cd "$wdir" && find . -type f ! -name MANIFEST.txt -printf '%P\n' | sort | while IFS= read -r f; do
      printf '%s  %s  %s  %s\n' \
        "$(sha256sum -- "$f" | cut -d' ' -f1)" \
        "$(stat -c %s -- "$f")" \
        "$(date -d "@$(stat -c %Y -- "$f")" '+%Y-%m-%d %H:%M')" \
        "$f"
    done ) >> "$m"
  chmod 0640 "$m"; chown root:audit "$m" 2>/dev/null || true
}

prune_local() {
  local d
  ls -1d "$DEST_ROOT"/*-W* 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) | while IFS= read -r d; do
    [ -d "$d" ] && { rm -rf -- "$d"; log "pruned local: $d"; }
  done
}

# ---------------------------------------------------------------------------
# the share
# ---------------------------------------------------------------------------
mount_share() {   # 0 = mounted at $MNT
  [ -n "$SMB_SHARE" ] || { log "ERROR: no share configured"; return 1; }
  command -v mount.cifs >/dev/null 2>&1 || { log "ERROR: cifs-utils not installed"; return 1; }
  local opts="$SMB_OPTS"
  if [ "$SMB_AUTH" = guest ]; then
    # sec=none, overriding whatever SMB_OPTS carries. `guest` only means "send
    # no username or password" -- the client still performs the session setup
    # sec= asks for, and the default here is sec=ntlmssp. On a FIPS box that
    # cannot work at all: NTLMv2 needs HMAC-MD5, FIPS removes MD5 from the
    # kernel crypto API, and the mount fails with "Could not allocate shash TFM
    # 'hmac(md5)'" and ENOENT -- the same errno a missing share returns, which
    # is how this hides (dev-14, 2026-09-04). sec=none is an anonymous session
    # setup with no NTLM response to compute.
    opts="guest,sec=none,$(printf '%s' "$opts" | sed -E 's/(^|,)sec=[^,]*//g; s/^,//')"
  else
    [ -r "$SMB_CRED" ] || { log "ERROR: no credentials file at $SMB_CRED"; return 1; }
    opts="credentials=$SMB_CRED,$opts"
  fi
  mkdir -p "$MNT"
  mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null
  mount -t cifs "$SMB_SHARE" "$MNT" -o "$opts" 2>>"$RUN_LOG"
}
umount_share() { mountpoint -q "$MNT" && { umount "$MNT" 2>>"$RUN_LOG" || log "WARNING: umount $MNT failed"; }; return 0; }

push_week() {   # $1 = local week dir
  local wdir="$1" week dst
  week="$(basename "$wdir")"
  mount_share || { log "ERROR: could not mount $SMB_SHARE -- push SKIPPED, local copy kept"; return 1; }
  dst="$MNT/$SMB_SUBDIR/$week"
  if ! mkdir -p "$dst" 2>>"$RUN_LOG"; then
    log "ERROR: cannot create $SMB_SUBDIR/$week on the share (does the account have Change/Modify?)"
    umount_share; return 1
  fi
  # -r not -a: a CIFS mount will not take ownership or POSIX modes, and cp -a
  # reports that as an error on a folder that copied perfectly well.
  if cp -r -- "$wdir/." "$dst/" 2>>"$RUN_LOG"; then
    log "pushed: $week -> $SMB_SHARE/$SMB_SUBDIR/$week ($(find "$wdir" -type f | wc -l) file(s))"
    umount_share; return 0
  fi
  log "ERROR: copy to $SMB_SHARE/$SMB_SUBDIR/$week failed -- local copy kept"
  umount_share; return 1
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
cmd_run() {
  local push=1 rc=0 week wdir reports
  for a in "$@"; do
    case "$a" in
      --local|--no-push) push=0 ;;
      --quiet) QUIET=1 ;;
      *) die "unknown option: $a" ;;
    esac
  done

  if [ "$ENABLED" != true ]; then
    say "PowerStrux offload is disabled (ENABLED=false). Turn it on: it-powerstrux offload on"
    log "skipped: disabled"
    return 0
  fi

  week="$(week_id)"; wdir="$DEST_ROOT/$week"
  mkdir_evidence "$DEST_ROOT"; mkdir_evidence "$wdir"
  log "=== run $week ==="
  head2 "Building $wdir"

  reports=$(collect_reports "$wdir")
  collect_audit "$wdir"
  collect_containers "$wdir"
  collect_extra "$wdir"
  write_manifest "$wdir" "$reports"

  if [ "$reports" -eq 0 ]; then
    warn "no PowerStrux report in the last $WINDOW days -- the folder is built anyway"
    say  "  ${DIM}Check the audit ran: it-powerstrux status${R}"
    log "WARNING: no report within ${WINDOW}d"
  else
    ok "$reports report(s), $(find "$wdir" -type f | wc -l) file(s) total"
  fi

  prune_local

  if [ "$push" -eq 1 ] && [ "$SMB_ON" = true ] && [ -z "$SMB_SHARE" ]; then
    bad "push is ON but no share is set -- it-powerstrux offload setup"
    log "ERROR: SMB_ENABLED=true with an empty SMB_SHARE"
    rc=1
  elif [ "$push" -eq 1 ] && [ "$SMB_ON" = true ]; then
    head2 "Pushing to $SMB_SHARE/$SMB_SUBDIR/$week"
    if push_week "$wdir"; then ok "pushed"
    else bad "push FAILED -- the local copy is kept at $wdir"; rc=1; fi
  elif [ "$push" -eq 1 ]; then
    warn "remote push is OFF -- staged locally only"
    say  "  ${DIM}$wdir  (carry it off on media, or: it-powerstrux offload setup)${R}"
  fi

  chmod 0640 "$RUN_LOG" 2>/dev/null || true
  log "=== end $week rc=$rc ==="
  return "$rc"
}

cmd_status() {
  local last n
  head2 "PowerStrux offload -- $(hostname -s)"
  if [ -r "$CONF" ]; then ok "config      $CONF"
  else bad "config      MISSING at $CONF -- run an ansible-pull"; fi
  if [ "$ENABLED" = true ]; then ok "offload     ON"; else warn "offload     OFF (it-powerstrux offload on)"; fi

  head2 "When it runs"
  if [ -f /etc/systemd/system/powerstrux-offload.service ]; then
    printf '  %-14s %s\n' "trigger" "straight after each scheduled PowerStrux audit"
    printf '  %-14s %s\n' "audit at" "$(sed -n 's/^OnCalendar=//p' /etc/systemd/system/powerstrux-audit.timer 2>/dev/null | head -1)"
    printf '  %-14s %s\n' "last run" "$(systemctl show powerstrux-offload.service -p ExecMainStartTimestamp --value 2>/dev/null || echo never)"
    printf '  %-14s %s\n' "last result" "$(systemctl show powerstrux-offload.service -p Result --value 2>/dev/null || echo -)"
    if [ -f /etc/systemd/system/powerstrux-offload.timer ]; then
      printf '  %-14s %s\n' "own timer" "$(sed -n 's/^OnCalendar=//p' /etc/systemd/system/powerstrux-offload.timer | head -1)"
    fi
  elif [ -f /etc/cron.d/powerstrux-audit ] && grep -q powerstrux-offload /etc/cron.d/powerstrux-audit 2>/dev/null; then
    printf '  %-14s %s\n' "trigger" "after the PowerStrux audit (cron.d)"
  else
    bad "NOT SCHEDULED -- run an ansible-pull, or run it by hand: it-powerstrux offload run"
  fi

  head2 "What goes in the week folder"
  printf '  %-20s %s\n' "PowerStrux reports" "always -- anything from the last $WINDOW days, plus its run logs and config"
  [ "$INC_AUDIT" = true ] && ok "auditd archive       ON (reuses /etc/cron.weekly/audit-offload output)" \
                          || printf '  %-20s %s%s%s\n' "auditd archive" "$DIM" "off -- it-offload handles AU-4 separately" "$R"
  [ "$INC_CONT" = true ]  && ok "container logs       ON${CONT_NAMES:+ (${CONT_NAMES})}" \
                          || printf '  %-20s %s%s%s\n' "container logs" "$DIM" "off" "$R"
  n=$(conf_all EXTRA | grep -c . || true)
  if [ "${n:-0}" -gt 0 ]; then
    printf '  %-20s\n' "other logs"
    conf_all EXTRA | sed 's/^/      /'
  else
    printf '  %-20s %s%s%s\n' "other logs" "$DIM" "none -- add with: it-powerstrux offload extra add <path>" "$R"
  fi

  head2 "Where it goes"
  printf '  %-20s %s (keeps %s weeks)\n' "staged locally" "$DEST_ROOT" "$KEEP"
  if [ "$SMB_ON" = true ]; then
    ok "share                $SMB_SHARE/$SMB_SUBDIR/<week>"
    printf '  %-20s %s\n' "auth" "$SMB_AUTH"
    if [ "$SMB_AUTH" = guest ]; then
      warn "credentials          none (guest) -- most Windows shares refuse this"
    elif [ -r "$SMB_CRED" ]; then
      ok "credentials          $SMB_CRED ($(stat -c %a "$SMB_CRED"))"
      [ "$(stat -c %a "$SMB_CRED")" = 600 ] || warn "credentials should be 0600"
      printf '  %-20s %s\n' "account" "$(sed -n 's/^username=//p' "$SMB_CRED" | head -1)"
      printf '  %-20s %s\n' "domain/workgroup" "$(sed -n 's/^domain=//p' "$SMB_CRED" | head -1)"
    else
      bad "credentials          MISSING at $SMB_CRED -- the push will FAIL"
      say "                       fix: it-powerstrux offload creds"
    fi
    command -v mount.cifs >/dev/null 2>&1 && ok "cifs-utils           installed" \
      || bad "cifs-utils           NOT installed -- the push will FAIL"
    printf '  %-20s %s\n' "mount options" "$SMB_OPTS"
    # Signing is not encryption. Without `seal` these reports cross the network
    # in the clear, whatever SMB version was negotiated.
    case "$SMB_OPTS" in
      *seal*) ok "in transit           SMB3 encrypted (seal)" ;;
      *)      warn "in transit           NOT encrypted -- signing only"
              say  "                       it-powerstrux offload opts 'vers=3.1.1,seal,${SMB_OPTS#vers=3.1.1,}'" ;;
    esac
  else
    warn "share                OFF -- staged locally only"
    say  "  ${DIM}Set one up: it-powerstrux offload setup${R}"
  fi

  head2 "Week folders on this box"
  if ls -1d "$DEST_ROOT"/*-W* >/dev/null 2>&1; then
    ls -1d "$DEST_ROOT"/*-W* | sort -r | head -6 | while IFS= read -r d; do
      printf '  %-16s %s file(s), %s\n' "$(basename "$d")" \
        "$(find "$d" -type f 2>/dev/null | wc -l)" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
  else
    say "  ${DIM}(none yet -- it-powerstrux offload run)${R}"
  fi

  head2 "Last run"
  if [ -r "$RUN_LOG" ]; then tail -6 "$RUN_LOG" | sed 's/^/  /'
  else say "  ${DIM}never run, or no log yet at $RUN_LOG${R}"; fi
  say ""
  say "  ${DIM}Prove the share works:  it-powerstrux offload test${R}"
  say ""
}

cmd_creds() {
  local u p p2 dom mode ans
  head2 "Share account -> $SMB_CRED"
  say "  This is normally a dedicated SERVICE ACCOUNT that can write to the share"
  say "  and nothing else. On the Windows side it needs Share = Change and NTFS ="
  say "  Modify on the target folder; Read alone makes the push fail at mkdir."
  say ""
  say "  1) Domain account      e.g. CORP\\svc_audit   (the box does NOT have to be joined)"
  say "  2) Local account on the file server (workgroup)"
  say "  3) Guest / no credentials"
  say ""
  while :; do
    printf '  Choose [1-3]: '; read -r ans
    case "$ans" in 1) mode=domain; break ;; 2) mode=workgroup; break ;; 3) mode=guest; break ;;
                   *) bad "pick 1, 2 or 3" ;; esac
  done

  if [ "$mode" = guest ]; then
    set_opt SMB_AUTH guest
    # Moved aside, not deleted. Picking 3 by mistake must not destroy a working
    # service-account password that nothing else has a copy of.
    [ -f "$SMB_CRED" ] && { mv -f "$SMB_CRED" "$SMB_CRED.disabled"; warn "existing credentials moved to $SMB_CRED.disabled"; }
    warn "guest access set. No credentials will be sent."
    say  "  ${DIM}Most Windows shares refuse guest by default (SMB2+ signing/guest-auth policy).${R}"
    if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)" = 1 ]; then
      say  "  ${DIM}On this FIPS box guest is the ONLY option that can work until the${R}"
      say  "  ${DIM}fleet is domain-joined: NTLM needs HMAC-MD5 and FIPS has no MD5.${R}"
      say  "  ${DIM}sec=none is forced for guest, so the mount never attempts NTLM.${R}"
    fi
    say  "  ${DIM}Prove it: it-powerstrux offload test${R}"
    return 0
  fi

  if [ "$mode" = domain ]; then
    printf '  AD domain (CORP, or corp.example.com): '; read -r dom
    [ -n "$dom" ] || die "a domain account needs a domain"
  else
    # For a LOCAL account, cifs wants the server's own name where a domain would
    # go. "WORKGROUP" works on many servers and silently fails on others, which
    # is why this defaults to the share's host rather than to WORKGROUP.
    local guess=""
    case "$SMB_SHARE" in //*) guess="${SMB_SHARE#//}"; guess="${guess%%/*}"; guess="${guess%%.*}" ;; esac
    printf '  Server or workgroup name [%s]: ' "${guess:-WORKGROUP}"; read -r dom
    dom="${dom:-${guess:-WORKGROUP}}"
  fi

  printf '  username (no domain prefix): '; read -r u
  [ -n "$u" ] || die "username cannot be empty"
  case "$u" in *\\*|*@*) warn "put the domain in the field above, not in the username" ;; esac
  printf '  password: '; stty -echo 2>/dev/null; read -r p; stty echo 2>/dev/null; echo
  printf '  again:    '; stty -echo 2>/dev/null; read -r p2; stty echo 2>/dev/null; echo
  [ "$p" = "$p2" ] || die "passwords do not match"
  [ -n "$p" ]      || die "password cannot be empty"

  [ -d "$(dirname "$SMB_CRED")" ] || install -d -m 0700 -o root -g root "$(dirname "$SMB_CRED")"
  umask 077
  { printf 'username=%s\n' "$u"
    printf 'password=%s\n' "$p"
    printf 'domain=%s\n' "$dom"; } > "$SMB_CRED"
  chmod 0600 "$SMB_CRED"; chown root:root "$SMB_CRED"
  unset p p2
  set_opt SMB_AUTH "$mode"
  ok "written, 0600 root:root -- never in the repo, never in site.yml"
  say "  ${DIM}Prove it: it-powerstrux offload test${R}"
}

cmd_setup() {
  local ans share sub
  head2 "PowerStrux offload setup"
  say "  Settings are written to $CONF (immediate) and"
  say "  $SITE_YML (so the next ansible-pull keeps them)."
  say ""

  printf '  Turn the weekly offload ON? [Y/n] '; read -r ans
  case "$ans" in [Nn]*) set_opt ENABLED false; warn "offload OFF"; return 0 ;; *) set_opt ENABLED true ;; esac

  say ""
  printf '  Also include the auditd archive in the week folder? [y/N] '; read -r ans
  case "$ans" in [Yy]*) set_opt INCLUDE_AUDIT true ;; *) set_opt INCLUDE_AUDIT false ;; esac
  printf '  Also include container logs? [y/N] '; read -r ans
  case "$ans" in [Yy]*) set_opt INCLUDE_CONTAINERS true ;; *) set_opt INCLUDE_CONTAINERS false ;; esac

  say ""
  printf '  Copy each week to a Windows file share? [Y/n] '; read -r ans
  case "$ans" in
    [Nn]*) set_opt SMB_ENABLED false
           ok "local staging only -- $DEST_ROOT/<week>"
           say "  ${DIM}Carry it off on media, or re-run this to add a share later.${R}"
           return 0 ;;
  esac

  printf '  Share (e.g. //fileserver/audit$ or //10.0.0.5/Reports): '; read -r share
  [ -n "$share" ] || die "share cannot be empty"
  case "$share" in //*) ;; \\\\*) share=$(printf '%s' "$share" | tr '\\' '/') ;;
                   *) die "a share looks like //server/share" ;; esac
  printf '  Folder on the share for THIS box [%s]: ' "$(hostname -s)"; read -r sub
  sub="${sub:-$(hostname -s)}"

  set_opt SMB_ENABLED true
  set_opt SMB_SHARE "$share" 1
  set_opt SMB_SUBDIR "$sub" 1
  SMB_SHARE="$share"; SMB_SUBDIR="$sub"; SMB_ON=true

  say ""
  if [ -r "$SMB_CRED" ] && [ "$SMB_AUTH" != guest ]; then
    ok "credentials already set for $(sed -n 's/^username=//p' "$SMB_CRED" | head -1)"
    printf '  Replace them? [y/N] '; read -r ans
    case "$ans" in [Yy]*) cmd_creds ;; esac
  else
    cmd_creds
  fi

  say ""
  ok "Setup done."
  say ""
  say "  These reports inventory the system, so encrypt them in transit. SMB3"
  say "  SIGNING is not encryption -- 'seal' is, and fails the mount if the"
  say "  server will not do it (which is the correct failure):"
  say "    ${B}it-powerstrux offload opts 'vers=3.1.1,seal,${SMB_OPTS#vers=3.1.1,}'${R}"
  say ""
  say "  ${DIM}Prove it now:  it-powerstrux offload test${R}"
  say "  ${DIM}Then the first real folder:  it-powerstrux offload run${R}"
}

cmd_test() {
  local rc=0 probe
  head2 "Checking the offload"
  [ "$ENABLED" = true ] && ok "offload enabled" || { warn "offload is OFF -- the schedule will do nothing"; }
  [ -r "$CONF" ] && ok "config present" || { bad "no config at $CONF"; rc=1; }
  [ -d "$REPORT_DIR" ] && ok "report dir   $REPORT_DIR" || { bad "no report dir at $REPORT_DIR"; rc=1; }
  local n
  n=$(find "$REPORT_DIR" -maxdepth 2 -type f \( -iname '*.html' -o -iname '*.htm' \) -mtime "-$WINDOW" 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && ok "reports      $n in the last $WINDOW days" \
                 || warn "reports      none in the last $WINDOW days (run one: it-powerstrux)"

  if [ "$SMB_ON" != true ]; then
    head2 "Share"
    warn "push is OFF -- nothing to test. Set one up: it-powerstrux offload setup"
    return "$rc"
  fi
  if [ -z "$SMB_SHARE" ]; then
    head2 "Share"
    bad "push is ON but no share is set -- it-powerstrux offload setup"
    return 1
  fi

  head2 "Share  $SMB_SHARE"
  command -v mount.cifs >/dev/null 2>&1 && ok "cifs-utils installed" \
    || { bad "cifs-utils NOT installed -- apt install cifs-utils"; return 1; }
  if [ "$SMB_AUTH" != guest ]; then
    [ -r "$SMB_CRED" ] && ok "credentials  $SMB_CRED" \
      || { bad "no credentials -- it-powerstrux offload creds"; return 1; }
  fi

  say "  mounting..."
  if ! mount_share; then
    bad "MOUNT FAILED"
    say ""
    say "  The reason is the last line of $RUN_LOG:"
    tail -3 "$RUN_LOG" 2>/dev/null | sed 's/^/    /'
    say ""
    say "  Most common causes, in the order they actually happen:"
    say "    * wrong password, or the account is locked out"
    say "    * domain/workgroup wrong -- a LOCAL account on the server needs the"
    say "      SERVER's name where a domain would go, not WORKGROUP"
    say "    * the server only speaks SMB 2.1 (older NAS / Server 2008 R2):"
    say "        it-powerstrux offload opts vers=2.1,sec=ntlmssp,uid=0,gid=0,file_mode=0640,dir_mode=0750"
    say "    * the share name is wrong -- check it with:"
    say "        smbclient -L //${SMB_SHARE#//} -U <user>"
    case "$SMB_OPTS" in *seal*)
      say "    * 'seal' is set and the server will not encrypt. That is a real"
      say "      finding, not a client problem -- fix the server, or accept an"
      say "      unencrypted transfer knowingly by removing seal." ;;
    esac
    return 1
  fi
  ok "mounted"

  probe="$MNT/$SMB_SUBDIR"
  if mkdir -p "$probe" 2>/dev/null; then ok "folder       $SMB_SUBDIR exists / created"
  else bad "cannot create $SMB_SUBDIR on the share -- the account needs Change + Modify"; rc=1; fi
  if [ "$rc" -eq 0 ]; then
    if : > "$probe/.write-test-$(hostname -s)" 2>/dev/null; then
      rm -f "$probe/.write-test-$(hostname -s)"
      ok "write        OK"
    else
      bad "cannot WRITE to $SMB_SHARE/$SMB_SUBDIR -- Read-only share or NTFS permissions"
      rc=1
    fi
  fi
  umount_share
  ok "unmounted"
  say ""
  [ "$rc" -eq 0 ] && ok "The share is usable. Build this week's folder: it-powerstrux offload run"
  return "$rc"
}

cmd_extra() {
  local sub="${1:-list}"; shift 2>/dev/null || true
  local -a cur=()
  while IFS= read -r p; do [ -n "$p" ] && cur+=("$p"); done < <(conf_all EXTRA)
  case "$sub" in
    list|"")
      head2 "Other logs collected with the report"
      if [ "${#cur[@]}" -eq 0 ]; then say "  ${DIM}(none)${R}"
      else printf '  %s\n' "${cur[@]}"; fi
      say ""
      say "  ${DIM}A path or a glob. A directory is copied whole.${R}"
      say "  ${DIM}it-powerstrux offload extra add /var/log/clamav-scan.log${R}"
      ;;
    add)
      [ $# -gt 0 ] || die "usage: it-powerstrux offload extra add <path-or-glob>"
      local p
      for p in "$@"; do
        # A double quote would break the quoting this writes into site.yml, and
        # no log path has ever needed one.
        case "$p" in *'"'*|*'\\'*) bad "not a usable path: $p"; continue ;; esac
        case " ${cur[*]+${cur[*]}} " in *" $p "*) warn "already listed: $p"; continue ;; esac
        cur+=("$p")
        # shellcheck disable=SC2086
        ls -d $p >/dev/null 2>&1 && ok "added: $p" \
          || warn "added: $p  (nothing matches it right now -- that is fine for a log not written yet)"
      done
      conf_set_list EXTRA "${cur[@]}"; persist_site_list powerstrux_offload_extra "${cur[@]}" ;;
    remove|rm|del)
      [ $# -gt 0 ] || die "usage: it-powerstrux offload extra remove <path>"
      local -a keep=(); local c hit=0
      for c in ${cur[@]+"${cur[@]}"}; do
        local drop=0 p
        for p in "$@"; do [ "$c" = "$p" ] && drop=1; done
        if [ "$drop" -eq 1 ]; then ok "removed: $c"; hit=1; else keep+=("$c"); fi
      done
      [ "$hit" -eq 1 ] || warn "nothing matched"
      conf_set_list EXTRA ${keep[@]+"${keep[@]}"}; persist_site_list powerstrux_offload_extra ${keep[@]+"${keep[@]}"} ;;
    *) die "usage: it-powerstrux offload extra [list|add <path>|remove <path>]" ;;
  esac
}

cmd_list() {
  head2 "Week folders in $DEST_ROOT"
  ls -1d "$DEST_ROOT"/*-W* 2>/dev/null | sort -r | while IFS= read -r d; do
    printf '  %s%s%s  %s file(s)  %s\n' "$B" "$(basename "$d")" "$R" \
      "$(find "$d" -type f | wc -l)" "$(du -sh "$d" | cut -f1)"
    sed -n '/^Contents/,$p' "$d/MANIFEST.txt" 2>/dev/null | tail -n +3 \
      | awk '{ $1=""; $2=""; $3=""; $4=""; sub(/^ +/,""); print "      " $0 }' | head -8
  done || say "  ${DIM}(none)${R}"
  say ""
  say "  ${DIM}Keeping the newest $KEEP weeks. Full listing: cat $DEST_ROOT/<week>/MANIFEST.txt${R}"
}

cmd_toggle() {   # $1 = conf key, $2 = on|off, $3 = label
  case "${2:-}" in
    on|true|yes)  apply_opt "$1" true  0 "$3 ON" ;;
    off|false|no) apply_opt "$1" false 0 "$3 OFF" ;;
    *) die "usage: it-powerstrux offload ${3%% *} on|off" ;;
  esac
}

case "${1:-status}" in
  ""|status)  cmd_status ;;
  setup)      cmd_setup ;;
  creds)      cmd_creds ;;
  test|check) cmd_test ;;
  run)        shift; cmd_run "$@" ;;
  extra)      shift; cmd_extra "$@" ;;
  list)       cmd_list ;;
  log)        [ -r "$RUN_LOG" ] || die "no log at $RUN_LOG"; tail -n "${2:-30}" "$RUN_LOG" ;;
  on)         apply_opt ENABLED true  0 "offload ON" ;;
  off)        apply_opt ENABLED false 0 "offload OFF" ;;
  push)       cmd_toggle SMB_ENABLED "${2:-}" "remote push" ;;
  audit)      cmd_toggle INCLUDE_AUDIT "${2:-}" "auditd archive" ;;
  containers) cmd_toggle INCLUDE_CONTAINERS "${2:-}" "container logs" ;;
  opts)       [ -n "${2:-}" ] || die "usage: it-powerstrux offload opts <cifs,mount,options>"
              apply_opt SMB_OPTS "$2" 1 "mount options set: $2" ;;
  where)      printf 'config : %s\ncreds  : %s\nstaged : %s\nlog    : %s\n' \
                "$CONF" "$SMB_CRED" "$DEST_ROOT" "$RUN_LOG" ;;
  *)          die "unknown command: $1  (try: it-powerstrux offload --help)" ;;
esac
