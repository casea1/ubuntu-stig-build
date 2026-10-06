#!/usr/bin/env bash
# it-ai-backup -- back up the AI stack's databases and data volumes, and send
# them to another machine (a Windows host over SFTP). Run by hand; nothing
# schedules it.
#
# Usage:
#   it-ai-backup                    what this node backs up, sizes, free space,
#                                   the backups on disk, where they go
#   it-ai-backup run [--send] [--db-only]
#                                   take a backup now; --send also sends it
#   it-ai-backup send [<folder>]    send the newest backup (or the one named)
#   it-ai-backup verify [<folder>]  restore its databases into a THROWAWAY
#                                   container and count what came back
#   it-ai-backup dest <user@host:/path> [--port N]
#                                   where `send` puts them; makes this box's key
#                                   and pins the host key. Windows path:
#                                   svc@winhost:/D:/Backups/AI  (leading slash)
#   it-ai-backup test               check the destination without sending
#   it-ai-backup list               the backups on disk
#
# WHAT IS BACKED UP, found on the box, not configured per node:
#   * every database in every RUNNING Postgres container (image name contains
#     postgres or pgvector) -- pgvector (Open WebUI: users, chats, knowledge AND
#     the embeddings) on System 1, mlflow-db on System 2. Plus each container's
#     roles (pg_dumpall --globals-only), so a restore keeps the same password.
#   * the data volumes in VOLUMES that exist here: open-webui (uploads, audit
#     log; its cache is skipped), mlflow-artifacts, magpie_state.
#   NOT: model weights (re-downloadable, huge), redis (a cache), .env files or
#   /etc/stig-build/*.pw (they stay on the box).
#
# WHY IT CANNOT BREAK A LIVE SERVICE:
#   * Nothing is stopped, restarted, recreated or reconfigured. No compose file
#     is read or written.
#   * pg_dump reads one consistent snapshot over the container's local socket
#     (not through pgbouncer, so it takes none of the app's pool) and holds only
#     ACCESS SHARE locks: reads and writes carry on. The one thing it delays is
#     DDL -- an Open WebUI upgrade's migration waits for the dump to finish.
#   * Everything runs at nice 19 / idle I/O priority.
#   * It refuses to start if the backup could leave the disk below MIN_FREE_GB
#     (default 20) -- /var/lib/docker usually shares that disk, and a full disk
#     DOES take the stack down.
#   * A failed run deletes its own partial folder; old backups are pruned only
#     after a new one succeeded.
#   * `verify` uses a separate container: same image (never pulled), no
#     network, 2 GB / 2 CPU cap, deleted afterwards with its storage.
#
# Settings: /etc/stig-build/ai-backup.conf (KEY=value; nothing else writes it).
#   BACKUP_DIR=/var/backups/ai-stack  KEEP=3  MIN_FREE_GB=20
#   VOLUMES="open-webui:cache mlflow-artifacts magpie_state"   name[:skip,skip]
#   DEST=svc@winhost:/D:/Backups/AI  PORT=22  LIMIT_KBIT=0 (sftp -l; 0 = none)
set -uo pipefail

CONF="${IT_AI_BACKUP_CONF:-/etc/stig-build/ai-backup.conf}"
LOG=/var/log/it-ai-backup.log
LOCK=/run/it-ai-backup.lock
VERIFY_LABEL=it-ai-backup=verify

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""
fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
note()  { printf '  %s%s%s\n' "$DIM" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
log()   { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

conf_get() {   # $1 = key, $2 = default
  local v=""
  [ -r "$CONF" ] && v=$(sed -nE "s/^[[:space:]]*$1=//p" "$CONF" | tail -1)
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "${v:-$2}"
}
conf_set() {   # $1 = key, $2 = value
  install -d -m 0700 "$(dirname "$CONF")"
  [ -e "$CONF" ] || { printf '# it-ai-backup settings. Nothing else writes this file.\n' > "$CONF"; chmod 0600 "$CONF"; }
  local tmp; tmp=$(mktemp "$CONF.XXXXXX")
  grep -vE "^[[:space:]]*$1=" "$CONF" > "$tmp"
  printf '%s="%s"\n' "$1" "$2" >> "$tmp"
  chmod 0600 "$tmp"; mv "$tmp" "$CONF"
}

BACKUP_DIR=$(conf_get BACKUP_DIR /var/backups/ai-stack)
KEEP=$(conf_get KEEP 3)
MIN_FREE_GB=$(conf_get MIN_FREE_GB 20)
VOLUMES=$(conf_get VOLUMES "open-webui:cache mlflow-artifacts magpie_state")
DEST=$(conf_get DEST "")
PORT=$(conf_get PORT 22)
LIMIT_KBIT=$(conf_get LIMIT_KBIT 0)
KEY=$(conf_get KEY /etc/stig-build/ssh/ai-backup)
KNOWN=$(conf_get KNOWN_HOSTS /etc/stig-build/ssh/known_hosts)
HOST=$(hostname -s)

# Low priority for anything this script runs on the host.
LOW=(nice -n 19)
command -v ionice >/dev/null 2>&1 && LOW=(ionice -c3 nice -n 19)

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
free_bytes() {   # $1 = path (its nearest existing parent)
  local p="$1"; while [ ! -e "$p" ]; do p=$(dirname "$p"); done
  df -PB1 "$p" | awk 'NR==2 { print $4 }'
}

command -v docker >/dev/null 2>&1 || die "docker is not installed -- this is for the AI nodes."
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon."

# ---------------------------------------------------------------------------
# what is on this box
# ---------------------------------------------------------------------------
# Running Postgres containers, by image name. Never our own verify container.
pg_containers() {
  docker ps --filter status=running --format '{{.Names}}\t{{.Image}}\t{{.Label "it-ai-backup"}}' 2>/dev/null |
    awk -F'\t' '$3 == "" && tolower($2) ~ /(postgres|pgvector)/ { print $1 }' | sort
}
ctr_env() {   # $1 = container, $2 = variable -- ONE variable, never the whole env
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null |
    sed -n "s/^$2=//p" | head -1
}
pg_user()  { local u; u=$(ctr_env "$1" POSTGRES_USER); printf '%s' "${u:-postgres}"; }
ctr_image(){ docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }
# psql inside the container over its local socket (trusted by the image).
cpsql() {   # $1 = container, $2 = user, $3 = db, $4 = sql
  docker exec "$1" psql -X -q -At -v ON_ERROR_STOP=1 -U "$2" -d "$3" -c "$4"
}
pg_dbs() {   # $1 = container, $2 = user
  cpsql "$1" "$2" postgres \
    "select datname from pg_database where datallowconn and not datistemplate and datname <> 'postgres' order by 1"
}
pg_size() {   # $1 container, $2 user, $3 db
  cpsql "$1" "$2" postgres "select pg_database_size('$3')" 2>/dev/null || echo 0
}

vol_name() { printf '%s' "${1%%:*}"; }
vol_skips() { case "$1" in *:*) printf '%s' "${1#*:}" | tr ',' ' ' ;; esac; }
vol_path() { docker volume inspect -f '{{.Mountpoint}}' "$1" 2>/dev/null; }
present_volumes() {   # the configured ones that exist here, spec form
  local spec
  for spec in $VOLUMES; do
    docker volume inspect "$(vol_name "$spec")" >/dev/null 2>&1 && printf '%s\n' "$spec"
  done
}
vol_size() {   # $1 = spec
  local p ex=() s
  p=$(vol_path "$(vol_name "$1")") || { echo 0; return; }
  for s in $(vol_skips "$1"); do ex+=(--exclude="$p/$s"); done
  "${LOW[@]}" du -sb "${ex[@]}" "$p" 2>/dev/null | awk '{ print $1 }'
}

backups() {   # complete backup folders, oldest first
  local d
  for d in "$BACKUP_DIR/$HOST"-*/; do
    [ -f "$d/MANIFEST.txt" ] && printf '%s\n' "${d%/}"
  done 2>/dev/null | sort
}
newest() { backups | tail -1; }
resolve_folder() {   # $1 = name or path or empty -> path
  if [ -z "${1:-}" ]; then newest
  elif [ -d "$1" ]; then printf '%s' "${1%/}"
  elif [ -d "$BACKUP_DIR/$1" ]; then printf '%s' "$BACKUP_DIR/$1"
  else return 1; fi
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
PARTIAL=""
cleanup_partial() { [ -n "$PARTIAL" ] && [ -d "$PARTIAL" ] && rm -rf "$PARTIAL"; }

dump_db() {   # $1 container, $2 user, $3 db, $4 folder -> 0/1
  local c="$1" u="$2" db="$3" out="$4/db-$1-$3.dump" rc toc
  # pg_dump sets its own statement/lock/idle timeouts to 0, so the server's
  # statement_timeout (pgvector: 5 min) does not cut a long dump short.
  # Streamed to the host: nothing is written inside the container.
  docker exec "$c" sh -c 'command -v ionice >/dev/null && exec ionice -c3 nice -n 19 "$@"; exec nice -n 19 "$@"' sh \
    pg_dump -U "$u" -d "$db" -Fc --lock-wait-timeout=120s > "$out.part" 2>>"$LOG"
  rc=$?
  [ "$rc" = 0 ] || { bad "pg_dump $c/$db failed (exit $rc) -- see $LOG"; rm -f "$out.part"; return 1; }
  # The archive's table of contents must read back.
  toc=$(docker exec -i "$c" pg_restore -l < "$out.part" 2>>"$LOG" | grep -c ';' || true)
  [ "${toc:-0}" -gt 0 ] || { bad "the dump of $c/$db does not read back"; rm -f "$out.part"; return 1; }
  mv "$out.part" "$out"
  ok "$c/$db  $(human "$(stat -c %s "$out")")  ($toc archive entries)"
  printf 'db        %s  %s  db=%s user=%s image=%s entries=%s\n' "$(basename "$out")" \
    "$(stat -c %s "$out")" "$db" "$u" "$(ctr_image "$c")" "$toc" >> "$4/MANIFEST.txt"
}

dump_globals() {   # $1 container, $2 user, $3 folder
  local out="$3/globals-$1.sql"
  if docker exec "$1" pg_dumpall -U "$2" --globals-only > "$out" 2>>"$LOG"; then
    printf 'globals   %s  %s  roles of %s\n' "$(basename "$out")" "$(stat -c %s "$out")" "$1" >> "$3/MANIFEST.txt"
  else
    rm -f "$out"; warn "$1: could not dump its roles (the databases are still backed up)"
  fi
}

tar_volume() {   # $1 spec, $2 folder -> 0/1
  local name p out s rc ex=()
  name=$(vol_name "$1"); p=$(vol_path "$name")
  [ -n "$p" ] && [ -d "$p" ] || { bad "volume $name: no path"; return 1; }
  out="$2/vol-$name.tar.gz"
  for s in $(vol_skips "$1"); do ex+=(--exclude="./$s"); done
  # Exit 1 = a file changed while it was read (the audit log grows): the
  # archive is still valid, that file is as of the moment it was read.
  "${LOW[@]}" tar -czf "$out.part" --warning=no-file-changed --numeric-owner \
    "${ex[@]}" -C "$p" . 2>>"$LOG"
  rc=$?
  [ "$rc" -le 1 ] || { bad "tar of volume $name failed (exit $rc) -- see $LOG"; rm -f "$out.part"; return 1; }
  mv "$out.part" "$out"
  ok "volume $name  $(human "$(stat -c %s "$out")")$( [ -n "$(vol_skips "$1")" ] && printf '  (skipped: %s)' "$(vol_skips "$1")")"
  printf 'volume    %s  %s  volume=%s skipped=%s\n' "$(basename "$out")" "$(stat -c %s "$out")" \
    "$name" "$(vol_skips "$1" | tr ' ' ',')" >> "$2/MANIFEST.txt"
}

cmd_run() {
  local send=0 dbonly=0 a c u db need=0 free reserve stamp dir fails=0 n=0
  for a in "$@"; do
    case "$a" in
      --send) send=1 ;;
      --db-only) dbonly=1 ;;
      *) die "unknown option: $a" ;;
    esac
  done
  exec 9>"$LOCK"; flock -n 9 || die "another it-ai-backup is already running."

  head2 "What will be backed up"
  local -a ctrs=() vols=()
  mapfile -t ctrs < <(pg_containers)
  [ "$dbonly" = 1 ] || mapfile -t vols < <(present_volumes)
  [ ${#ctrs[@]} -gt 0 ] || [ ${#vols[@]} -gt 0 ] || die "nothing to back up: no running Postgres container and none of: $VOLUMES"

  local -a dbs=(); local list s d
  for c in "${ctrs[@]}"; do
    u=$(pg_user "$c")
    list=$(pg_dbs "$c" "$u" 2>>"$LOG") || die "cannot list the databases in $c (as $u) -- nothing started. See $LOG."
    for db in $list; do
      dbs+=("$c|$u|$db")
      s=$(pg_size "$c" "$u" "$db"); need=$((need + s))
      say "  database  $c/$db  $(human "$s")"
    done
  done
  for a in "${vols[@]}"; do
    s=$(vol_size "$a"); need=$((need + ${s:-0}))
    say "  volume    $(vol_name "$a")  $(human "${s:-0}")"
  done

  # The estimate is the live size; dumps and gzip are usually smaller.
  free=$(free_bytes "$BACKUP_DIR")
  reserve=$((MIN_FREE_GB * 1024 * 1024 * 1024))
  say "  ${DIM}needs up to $(human "$need"); free on $(df -P "$(dirname "$BACKUP_DIR")" | awk 'NR==2{print $6}'): $(human "$free"); keeps $MIN_FREE_GB GB free${R}"
  if [ $((free - need)) -lt "$reserve" ]; then
    bad "NOT STARTED: this could leave less than $MIN_FREE_GB GB free, and a full disk stops Docker."
    say "  Free space, or point BACKUP_DIR at another disk in $CONF$( [ "$dbonly" = 1 ] || printf ', or use --db-only')."
    log "refused: need $need free $free reserve $reserve"
    exit 1
  fi

  install -d -m 0700 -o root -g root "$BACKUP_DIR"
  stamp=$(date +%Y%m%d-%H%M)
  dir="$BACKUP_DIR/$HOST-$stamp"
  [ -e "$dir" ] && die "$dir already exists -- wait a minute and run it again."
  PARTIAL="$BACKUP_DIR/.partial-$HOST-$stamp"
  trap cleanup_partial EXIT
  ( umask 077; mkdir "$PARTIAL" ) || die "cannot create $PARTIAL"
  {
    printf 'it-ai-backup  host=%s  started=%s\n' "$HOST" "$(date -Is)"
    printf 'baseline      %s\n' "$(sed -n 's/^baseline_revision=//p' /etc/stig-build/profile 2>/dev/null || true)"
    printf '\n'
  } > "$PARTIAL/MANIFEST.txt"
  log "run: start -> $dir"

  head2 "Backing up"
  for c in "${ctrs[@]}"; do dump_globals "$c" "$(pg_user "$c")" "$PARTIAL"; done
  for a in "${dbs[@]}"; do
    IFS='|' read -r c u db <<<"$a"
    n=$((n + 1)); dump_db "$c" "$u" "$db" "$PARTIAL" || fails=$((fails + 1))
  done
  for a in "${vols[@]}"; do
    n=$((n + 1)); tar_volume "$a" "$PARTIAL" || fails=$((fails + 1))
  done

  if [ "$fails" -gt 0 ]; then
    log "run: FAILED ($fails of $n) -- partial folder removed"
    die "$fails of $n item(s) failed -- nothing kept. The log is $LOG."
  fi

  { printf '\nfinished      %s\n\nsha256:\n' "$(date -Is)"
    ( cd "$PARTIAL" && shopt -s nullglob && sha256sum -- *.dump *.sql *.tar.gz )
  } >> "$PARTIAL/MANIFEST.txt"
  chmod 0600 "$PARTIAL"/*
  mv "$PARTIAL" "$dir"; PARTIAL=""; trap - EXIT
  log "run: OK $dir ($n item(s), $(du -sh "$dir" | cut -f1))"
  head2 "Done"
  ok "$dir  ($(du -sh "$dir" | cut -f1))"

  # Prune only now that a new one exists, and never the newest.
  local -a all=(); mapfile -t all < <(backups)
  if [ "${#all[@]}" -gt "$KEEP" ]; then
    for d in "${all[@]:0:$(( ${#all[@]} - KEEP ))}"; do
      rm -rf -- "$d" && note "removed old: $(basename "$d")" && log "pruned $d"
    done
  fi

  if [ "$send" = 1 ]; then cmd_send "$dir"
  else note "Send it: it-ai-backup send     Check it restores: it-ai-backup verify"; fi
}

# ---------------------------------------------------------------------------
# send
# ---------------------------------------------------------------------------
sftp_do() {   # stdin = batch, $1 = user@host
  local lim=()
  [ "${LIMIT_KBIT:-0}" -gt 0 ] && lim=(-l "$LIMIT_KBIT")
  sftp -q -b - "${lim[@]}" -o BatchMode=yes -o ConnectTimeout=20 \
       -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" \
       -o GlobalKnownHostsFile=/dev/null -i "$KEY" -P "$PORT" "$1"
}

cmd_send() {
  local dir uh path base
  dir=$(resolve_folder "${1:-}") && [ -n "$dir" ] || die "no backup ${1:+named $1 }to send -- run: it-ai-backup run"
  [ -f "$dir/MANIFEST.txt" ] || die "$dir is not a finished backup."
  [ -n "$DEST" ] || die "no destination -- it-ai-backup dest <user@host:/path>"
  [ -r "$KEY" ] || die "no key at $KEY -- it-ai-backup dest $DEST"
  uh="${DEST%%:*}"; path="${DEST#*:}"; base="$path/$HOST"
  case "$path" in *'"'*) die "the destination path contains a double quote" ;; esac
  exec 9>"$LOCK"; flock -n 9 || die "another it-ai-backup is already running."

  head2 "Sending $(basename "$dir")  ($(du -sh "$dir" | cut -f1))"
  say "  to $DEST/$HOST/"
  # Each path quoted: sftp splits its own commands on whitespace. -mkdir ignores
  # "already exists". put -r creates the folder from its own name.
  if printf -- '-mkdir "%s"\n-mkdir "%s"\ncd "%s"\nput -r "%s"\nquit\n' \
       "$path" "$base" "$base" "$dir" | sftp_do "$uh" >>"$LOG" 2>&1; then
    date -Is > "$dir/.sent"
    log "sent $dir -> $DEST/$HOST"
    ok "sent. On Windows, check a file against MANIFEST.txt:  Get-FileHash <file>"
  else
    log "send FAILED $dir -> $DEST"
    bad "send failed -- the local copy is kept. Last lines of $LOG:"
    tail -4 "$LOG" | sed 's/^/    /'
    say "  Check the destination: it-ai-backup test"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# destination
# ---------------------------------------------------------------------------
kh_name() { [ "$2" = 22 ] && printf '%s' "$1" || printf '[%s]:%s' "$1" "$2"; }

cmd_dest() {
  local d="" p="$PORT" host
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) p="${2:?--port needs a number}"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) d="$1"; shift ;;
    esac
  done
  [ -n "$d" ] || die "usage: it-ai-backup dest <user@host:/path>   e.g. svc@winhost:/D:/Backups/AI"
  case "$d" in *@*:/*) ;; *) die "expected user@host:/path -- a Windows path starts with a slash: /D:/Backups/AI" ;; esac
  conf_set DEST "$d"; conf_set PORT "$p"; DEST="$d"; PORT="$p"
  host="${d%%:*}"; host="${host#*@}"

  head2 "Destination  $d"
  install -d -m 0700 "$(dirname "$KEY")"
  if [ ! -r "$KEY" ]; then
    # ECDSA P-384, not ed25519: FIPS-mode OpenSSH refuses ed25519 keys.
    ssh-keygen -q -t ecdsa -b 384 -N '' -C "it-ai-backup $HOST" -f "$KEY" </dev/null || die "could not create $KEY"
    ok "made this box's key: $KEY"
  else
    ok "key: $KEY"
  fi

  if ssh-keygen -F "$(kh_name "$host" "$p")" -f "$KNOWN" >/dev/null 2>&1; then
    ok "host key already pinned for $host"
  else
    # ssh itself, not ssh-keyscan: keyscan aborts on sntrup761 under FIPS.
    touch "$KNOWN"; chmod 0600 "$KNOWN"
    ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN" -o GlobalKnownHostsFile=/dev/null -o HashKnownHosts=yes \
        -o PreferredAuthentications=none -o LogLevel=ERROR -p "$p" "it-ai-backup@$host" exit 2>&1 |
      grep -v 'Permission denied' | sed 's/^/    /'
    if ssh-keygen -F "$(kh_name "$host" "$p")" -f "$KNOWN" >/dev/null 2>&1; then
      ok "pinned $host's host key:"
      ssh-keygen -l -F "$(kh_name "$host" "$p")" -f "$KNOWN" 2>/dev/null | grep -v '^#' | sed 's/^/    /'
      note "Compare on the Windows host:  ssh-keygen -lf C:\\ProgramData\\ssh\\ssh_host_ecdsa_key.pub"
    else
      bad "could not reach an SSH server on $host:$p"
    fi
  fi

  head2 "On the Windows host, put this ONE line in the account's authorized_keys"
  note "a normal user: C:\\Users\\<account>\\.ssh\\authorized_keys"
  note "an administrator: C:\\ProgramData\\ssh\\administrators_authorized_keys"
  say ""
  cat "$KEY.pub"
  say ""
  note "Then: it-ai-backup test"
}

cmd_test() {
  local uh path rc=0
  [ -n "$DEST" ] || die "no destination -- it-ai-backup dest <user@host:/path>"
  uh="${DEST%%:*}"; path="${DEST#*:}"
  head2 "Destination  $DEST"
  [ -r "$KEY" ] && ok "key        $KEY" || { bad "key        missing -- it-ai-backup dest $DEST"; return 1; }
  if printf 'quit\n' | sftp_do "$uh" >>"$LOG" 2>&1; then ok "login      OK"
  else
    bad "login      FAILED"; tail -3 "$LOG" | sed 's/^/    /'
    say "  Usually: the public key is not in authorized_keys, or the account is an"
    say "  administrator (then it is administrators_authorized_keys), or the host"
    say "  key changed (it-ai-backup dest again)."
    return 1
  fi
  if printf -- '-mkdir "%s"\ncd "%s"\nquit\n' "$path" "$path" | sftp_do "$uh" >>"$LOG" 2>&1; then
    ok "folder     $path reachable"
  else
    bad "folder     cannot reach or create $path"; rc=1
    note "a Windows path needs the LEADING slash: /D:/Backups/AI"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# verify -- a restore into a throwaway container
# ---------------------------------------------------------------------------
VCTR=""
cleanup_verify() { [ -n "$VCTR" ] && docker rm -f -v "$VCTR" >/dev/null 2>&1; }

cmd_verify() {
  local dir f db c u img pw i s total=0 fails=0
  dir=$(resolve_folder "${1:-}") && [ -n "$dir" ] || die "no backup ${1:+named $1 }to verify -- run: it-ai-backup run"
  ls "$dir"/db-*.dump >/dev/null 2>&1 || die "$dir has no database dumps."
  exec 9>"$LOCK"; flock -n 9 || die "another it-ai-backup is already running."

  for f in "$dir"/db-*.dump; do total=$((total + $(stat -c %s "$f"))); done
  # A restore is several times the dump (indexes are rebuilt); Docker's disk.
  local dfree; dfree=$(free_bytes /var/lib/docker)
  if [ $((dfree - total * 6)) -lt $((MIN_FREE_GB * 1024 * 1024 * 1024)) ]; then
    die "NOT STARTED: restoring $(human "$total") of dumps could take Docker's disk below $MIN_FREE_GB GB free."
  fi

  head2 "Verifying $(basename "$dir") -- restored into a throwaway container"
  trap cleanup_verify EXIT
  for f in "$dir"/db-*.dump; do
    # db-<container>-<db>.dump; the MANIFEST line has the exact db, user, image.
    local line; line=$(grep -F " $(basename "$f") " "$dir/MANIFEST.txt" | head -1)
    db=$(sed -nE 's/.* db=([^ ]+).*/\1/p' <<<"$line")
    u=$(sed -nE 's/.* user=([^ ]+).*/\1/p' <<<"$line")
    img=$(sed -nE 's/.* image=([^ ]+).*/\1/p' <<<"$line")
    [ -n "$db" ] && [ -n "$u" ] && [ -n "$img" ] || { bad "$(basename "$f"): not in MANIFEST.txt"; fails=$((fails + 1)); continue; }
    docker image inspect "$img" >/dev/null 2>&1 || { bad "$(basename "$f"): image $img is not on this box (never pulled)"; fails=$((fails + 1)); continue; }

    pw=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    VCTR="it-ai-backup-verify-$$"
    docker run -d --rm --pull never --name "$VCTR" --label "$VERIFY_LABEL" \
      --network none --memory 2g --cpus 2 \
      -e POSTGRES_USER="$u" -e POSTGRES_PASSWORD="$pw" -e POSTGRES_DB="$db" \
      "$img" >/dev/null 2>>"$LOG" || { bad "could not start a throwaway $img"; fails=$((fails + 1)); VCTR=""; continue; }
    # The image runs a temporary server during init and then restarts it, so
    # wait for the init to finish, not just for a socket.
    for i in $(seq 1 90); do
      docker logs "$VCTR" 2>&1 | grep -q 'init process complete' &&
        docker exec "$VCTR" pg_isready -q -U "$u" -d "$db" 2>/dev/null && break
      sleep 2
    done
    if [ "$i" -ge 90 ]; then bad "the throwaway Postgres did not start"; fails=$((fails + 1)); cleanup_verify; VCTR=""; continue; fi

    if docker exec -i "$VCTR" pg_restore -U "$u" -d "$db" --no-owner --exit-on-error < "$f" >>"$LOG" 2>&1; then
      s=$(docker exec "$VCTR" psql -X -q -At -U "$u" -d "$db" -c \
        "ANALYZE; select count(*) || ' tables, ' || coalesce(sum(n_live_tup),0) || ' rows' from pg_stat_user_tables" 2>/dev/null | tail -1)
      ok "$(basename "$f")  restores: $s"
      docker exec "$VCTR" psql -X -q -At -F '  ' -U "$u" -d "$db" -c \
        "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 5" 2>/dev/null |
        sed 's/^/      /'
      log "verify OK $f: $s"
    else
      bad "$(basename "$f")  DID NOT RESTORE -- see $LOG"; fails=$((fails + 1))
      log "verify FAILED $f"
    fi
    cleanup_verify; VCTR=""
  done
  trap - EXIT

  for f in "$dir"/vol-*.tar.gz; do
    [ -e "$f" ] || continue
    if "${LOW[@]}" tar -tzf "$f" >/dev/null 2>>"$LOG"; then ok "$(basename "$f")  reads back ($(tar -tzf "$f" | wc -l) entries)"
    else bad "$(basename "$f")  is damaged"; fails=$((fails + 1)); fi
  done
  ( cd "$dir" && sed -n '/^sha256:/,$p' MANIFEST.txt | tail -n +2 | sha256sum -c --quiet - ) \
    && ok "checksums match MANIFEST.txt" || { bad "checksums do NOT match MANIFEST.txt"; fails=$((fails + 1)); }

  say ""
  [ "$fails" = 0 ] && ok "This backup restores." || { bad "$fails problem(s)."; return 1; }
}

# ---------------------------------------------------------------------------
cmd_list() {
  local d any=0
  head2 "Backups in $BACKUP_DIR (keeping $KEEP)"
  while read -r d; do
    [ -n "$d" ] || continue; any=1
    printf '  %-28s %6s  %s\n' "$(basename "$d")" "$(du -sh "$d" | cut -f1)" \
      "$( [ -f "$d/.sent" ] && echo "sent $(cut -c1-16 "$d/.sent")" || echo 'not sent')"
  done < <(backups)
  [ "$any" = 1 ] || note "none yet -- it-ai-backup run"
}

cmd_status() {
  local c u db a s
  head2 "This node ($HOST) backs up"
  local found=0
  for c in $(pg_containers); do
    found=1; u=$(pg_user "$c")
    for db in $(pg_dbs "$c" "$u"); do
      say "  database  $c/$db  $(human "$(pg_size "$c" "$u" "$db")")"
    done
  done
  while read -r a; do
    [ -n "$a" ] || continue; found=1
    say "  volume    $(vol_name "$a")  $(human "$(vol_size "$a")")$( [ -n "$(vol_skips "$a")" ] && printf '  (skips %s)' "$(vol_skips "$a")")"
  done < <(present_volumes)
  [ "$found" = 1 ] || warn "nothing: no running Postgres container and none of: $VOLUMES"
  note "free where backups go: $(human "$(free_bytes "$BACKUP_DIR")")  (keeps $MIN_FREE_GB GB free)"

  cmd_list

  head2 "Destination"
  if [ -n "$DEST" ]; then
    ok "$DEST/$HOST/"
    [ -r "$KEY" ] || bad "no key at $KEY -- it-ai-backup dest $DEST"
  else
    warn "not set -- it-ai-backup dest <user@host:/path>   (backups stay on this box)"
  fi
  say ""
}

case "${1:-status}" in
  status|"")      cmd_status ;;
  run)            shift; cmd_run "$@" ;;
  send)           shift; cmd_send "$@" ;;
  verify)         shift; cmd_verify "$@" ;;
  dest)           shift; cmd_dest "$@" ;;
  test)           cmd_test ;;
  list)           cmd_list ;;
  -h|--help|help) usage ;;
  *)              die "unknown command: $1  (try: it-ai-backup --help)" ;;
esac
