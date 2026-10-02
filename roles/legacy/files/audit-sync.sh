#!/usr/bin/env bash
# it-audit -- add the 24.04 fleet's audit rules to a 22.04 legacy box, add-only.
#
# For a box this baseline does not fully manage (the `legacy` profile): brings
# it up to the fleet's audit coverage without disturbing anything already there.
#
#   it-audit            status: rules on disk and loaded, lock state, and how
#                       many days of audit log the box actually keeps
#   it-audit check      what `apply` would add and drop. Changes nothing.
#   it-audit apply      validate, install, load -- and roll back if the load fails
#
# ADD-ONLY. No existing rules file is edited or removed, no auditd.conf setting
# is touched, and the lock (-e 2) is left exactly as the box has it. Every
# candidate rule is checked against THIS box before it is written:
#   - a syscall the box's own table does not know is dropped. Names differ per
#     architecture, and auditctl stops at the FIRST rule it cannot apply -- one
#     bad name once left a 24.04 box loading 1 rule of 68.
#   - a watch on a path that does not exist is dropped, for the same reason.
#   - a rule the box already has is skipped, even under a different key.
# The file sorts LAST (zz-), so where an existing rule and a new one overlap,
# the existing one matches first and the event keeps its existing key. Anything
# that searches the log by key -- PowerStrux, an auditor's ausearch -- sees what
# it saw before, plus the new coverage.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

SRC="${IT_AUDIT_SRC:-/opt/it/legacy/stig-audit.rules}"
RULESD="${IT_AUDIT_RULESD:-/etc/audit/rules.d}"
OURS="$RULESD/zz-stig-build-legacy.rules"
LOG=/var/log/it-audit.log
# PowerStrux reports on this many days of audit log; fewer kept = a thin report.
WINDOW_DAYS="${POWERSTRUX_DAYS:-8}"
QUIET=0

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[0m'; G=$'\e[32m'; Y=$'\e[33m'; RED=$'\e[31m'; DIM=$'\e[2m'
else B=""; R=""; G=""; Y=""; RED=""; DIM=""; fi
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
ok()   { [ "$QUIET" = 1 ] || printf '  %s%s%s\n' "$G" "$*" "$R"; }
warn() { printf '  %s%s%s\n' "$Y" "$*" "$R"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

command -v auditctl >/dev/null 2>&1 || die "auditd is not installed (apt install auditd)"

audit_state() { auditctl -s 2>/dev/null | awk '$1=="enabled"{print $2}'; }
loaded_count() { auditctl -l 2>/dev/null | grep -vc '^No rules'; }

# The reboot/shutdown rule the 24.04 fleet adds itself, resolved per arch.
reboot_rules() {
  local a s cand names
  for a in b64 b32; do
    names=""
    for s in reboot kexec_load; do
      for cand in "$s" "sys_$s"; do
        if ausyscall "$a" --dump 2>/dev/null | awk -v n="$cand" '$2==n{f=1} END{exit !f}'; then
          names="$names -S $cand"; break
        fi
      done
    done
    [ -n "$names" ] && printf -- '-a always,exit -F arch=%s%s -k reboot\n' "$a" "$names"
  done
}

# Validate the candidates against this box and what it already loads.
# Prints "KEEP <rule>" / "DROP <reason>\t<rule>" / "HAVE <rule>".
# The program is read into a variable first: `python3 - <<EOF` would take its
# stdin from the heredoc and silently drop the piped rule list (it did: "add 0").
read -r -d '' PLAN_PY <<'PY' || true
import glob, os, re, subprocess, sys
rulesd, ours = sys.argv[1], sys.argv[2]

tables = {}
def syscalls(arch):
    if arch not in tables:
        out = subprocess.run(['ausyscall', arch, '--dump'], capture_output=True, text=True).stdout
        tables[arch] = {l.split()[1] for l in out.splitlines()[1:] if len(l.split()) > 1}
    return tables[arch]

def norm(line, with_key=False):
    """A rule's identity: list/action, fields and syscalls in sorted order, the
    key only if asked. `auid!=unset` / -1 / 4294967295 are one value."""
    t = line.split()
    if not t: return None
    if t[0] == '-w':
        path = perms = key = ''
        for i, x in enumerate(t):
            if x == '-w': path = t[i+1].rstrip('/')
            if x == '-p': perms = ''.join(sorted(t[i+1]))
            if x == '-k': key = t[i+1]
        return ('w', path, perms, key if with_key else '')
    act, fields, scs, key = '', [], set(), ''
    i = 0
    while i < len(t):
        x = t[i]
        if x == '-a': act = t[i+1]; i += 2; continue
        if x == '-S': scs.update(t[i+1].split(',')); i += 2; continue
        if x in ('-F', '-C'):
            f = re.sub(r'(auid!=)(unset|4294967295)$', r'\1-1', t[i+1])
            if f.startswith('key='): key = f[4:]
            else: fields.append(x + f)
            i += 2; continue
        if x == '-k': key = t[i+1]; i += 2; continue
        i += 1
    return ('a', act, tuple(sorted(fields)), tuple(sorted(scs)), key if with_key else '')

existing = set()
for f in sorted(glob.glob(os.path.join(rulesd, '*.rules'))):
    if os.path.abspath(f) == os.path.abspath(ours): continue
    for l in open(f, errors='replace'):
        l = l.strip()
        if l and not l.startswith('#'): existing.add(norm(l))

seen = set()
for line in sys.stdin:
    line = line.strip()
    t = line.split()
    if not t: continue
    if t[0] in ('-e', '-D', '-b', '-f', '-r') or t[0].startswith('--'):
        print('DROP control line: the box keeps its own\t' + line); continue
    n = norm(line)
    if n in existing: print('HAVE ' + line); continue
    if n in seen: continue
    seen.add(n)
    if t[0] == '-w':
        p = n[1] or '/'
        if not os.path.exists(p): print(f'DROP no such path on this box: {p}\t' + line); continue
        print('KEEP ' + line); continue
    m = re.search(r'-F arch=(b32|b64)', line)
    path = re.search(r'-F path=(\S+)', line)
    if path and not os.path.exists(path.group(1)):
        print(f'DROP no such path on this box: {path.group(1)}\t' + line); continue
    if m and n[3]:
        known = syscalls(m.group(1))
        bad = [s for s in n[3] if s not in known]
        if bad:
            good = [s for s in n[3] if s in known]
            if not good:
                print(f'DROP {m.group(1)} has none of: {",".join(bad)}\t' + line); continue
            # Keep the rule with only the syscalls this kernel has.
            line = re.sub(r'\s-S\s\S+', '', line)
            line = line.replace(f'-F arch={m.group(1)}', f'-F arch={m.group(1)} ' + ' '.join('-S ' + s for s in good), 1)
            print(f'TRIM {m.group(1)} has no {",".join(bad)}\t' + line)
        else:
            print('KEEP ' + line)
        continue
    print('KEEP ' + line)
PY

plan() {
  { grep -vE '^[[:space:]]*(#|$)' "$SRC"; reboot_rules; } |
  python3 -c "$PLAN_PY" "$RULESD" "$OURS"
}

render() {   # the file `apply` would write
  printf '%s\n' "# Managed by it-audit (legacy profile) -- do not edit by hand."
  printf '%s\n' "# Added to this box's existing rules; never replaces them. Source:"
  printf '%s\n' "# $(sed -n 's/^# source: //p' "$SRC" | head -1)"
  plan | awk -F'\t' '/^KEEP /{sub(/^KEEP /,""); print} /^TRIM /{print $2}'
}

cmd_check() {
  [ -r "$SRC" ] || die "no rule set at $SRC -- run a pull first"
  local p; p="$(plan)"
  printf '%sAudit rules: what apply would do%s\n' "$B" "$R"
  printf '  add      : %s\n' "$(grep -cE '^(KEEP|TRIM) ' <<<"$p")"
  printf '  have     : %s already audited here (kept as they are)\n' "$(grep -c '^HAVE ' <<<"$p")"
  printf '  dropped  : %s\n' "$(grep -c '^DROP ' <<<"$p")"
  grep -E '^(DROP|TRIM) ' <<<"$p" | cut -f1 | sed 's/^/    /' | sort | uniq -c
}

cmd_apply() {
  [ -r "$SRC" ] || die "no rule set at $SRC -- run a pull first"
  [ -d "$RULESD" ] || die "no $RULESD -- is auditd installed?"
  local tmp state before after out
  tmp="$(mktemp)"; render > "$tmp"
  if [ -f "$OURS" ] && cmp -s "$tmp" "$OURS"; then
    rm -f "$tmp"; ok "audit rules already current ($(grep -cvE '^(#|$)' "$OURS") added rules)"
    return 0
  fi
  state="$(audit_state)"; before="$(loaded_count)"
  [ -f "$OURS" ] && cp -p "$OURS" "$OURS.prev"
  install -m 0600 -o root -g root "$tmp" "$OURS"; rm -f "$tmp"
  printf '%s %s rules written, state=%s, loaded before=%s\n' "$(date -Is)" \
    "$(grep -cvE '^(#|$)' "$OURS")" "$state" "$before" >> "$LOG"

  if [ "$state" = 2 ]; then
    warn "the audit rules are LOCKED (-e 2) until reboot: $(grep -cvE '^(#|$)' "$OURS") rules staged, they load at the next boot"
    say  "  ${DIM}after the reboot: sudo it-audit   (checks they loaded)${R}"
    return 0
  fi
  out="$(augenrules --load 2>&1)"
  after="$(loaded_count)"
  # A load that stopped part-way prints an error and leaves FEWER rules than
  # before. Put the box back exactly as it was rather than leave it auditing less.
  if grep -qiE 'error|unknown|invalid' <<<"$out" || [ "${after:-0}" -lt "${before:-0}" ]; then
    bad "the load failed -- restoring the previous rules:"
    printf '%s\n' "$out" | sed 's/^/    /' | head -10
    if [ -f "$OURS.prev" ]; then mv -f "$OURS.prev" "$OURS"; else rm -f "$OURS"; fi
    augenrules --load >/dev/null 2>&1
    printf '%s ROLLED BACK: %s\n' "$(date -Is)" "$(head -1 <<<"$out")" >> "$LOG"
    bad "restored: $(loaded_count) rules loaded (was $before)"
    return 1
  fi
  rm -f "$OURS.prev"
  ok "loaded: $after rules (was $before)"
  printf '%s loaded after=%s\n' "$(date -Is)" "$after" >> "$LOG"
}

# How many days of log this box actually keeps -- measured, and projected from
# auditd.conf's size limits at the CURRENT rate. More rules means more log per
# day, so the projection is what says whether PowerStrux's window still fits.
retention() {
  local oldest newest f ts span bytes mb n
  f=$(ls -1 /var/log/audit/audit.log* 2>/dev/null | sort -V | tail -1)
  [ -n "$f" ] || { echo "  no audit log yet"; return; }
  ts=$(grep -m1 -oE 'msg=audit\([0-9]+' "$f" | grep -oE '[0-9]+$')
  newest=$(date +%s)
  [ -n "$ts" ] || { echo "  cannot read the oldest record"; return; }
  span=$(( (newest - ts) / 86400 ))
  printf '  %-16s %s day(s)  (%s)\n' "oldest record" "$span" "$(date -d "@$ts" '+%Y-%m-%d')"
  mb=$(awk -F= '/^[[:space:]]*max_log_file[[:space:]]*=/{gsub(/ /,"",$2); print $2}' /etc/audit/auditd.conf)
  n=$(awk -F= '/^[[:space:]]*num_logs[[:space:]]*=/{gsub(/ /,"",$2); print $2}' /etc/audit/auditd.conf)
  bytes=$(cat /var/log/audit/audit.log* 2>/dev/null | wc -c)
  if [ -n "$mb" ] && [ -n "$n" ] && [ "$newest" -gt "$ts" ] && [ "$bytes" -gt 0 ]; then
    local perday cap days
    perday=$(( bytes * 86400 / (newest - ts + 1) ))
    cap=$(( mb * 1024 * 1024 * n ))
    days=$(( cap / (perday + 1) ))
    printf '  %-16s ~%s KB/day; auditd keeps %s x %s MB = ~%s day(s)\n' "rate" "$((perday/1024))" "$n" "$mb" "$days"
    if [ "$days" -lt "$WINDOW_DAYS" ]; then
      warn "that is LESS than PowerStrux's ${WINDOW_DAYS}-day window -- its report would lose days."
      warn "raise max_log_file or num_logs in /etc/audit/auditd.conf (it-audit does not change it)"
    fi
  fi
}

cmd_status() {
  local state ours
  state="$(audit_state)"
  ours=$( [ -f "$OURS" ] && grep -cvE '^(#|$)' "$OURS" || echo 0 )
  printf '%sAudit%s  %s\n\n' "$B" "$R" "$(hostname -s)"
  printf '  %-16s %s\n' "auditd" "$(systemctl is-active auditd 2>/dev/null)"
  printf '  %-16s %s\n' "state" "$(case "$state" in 2) echo "locked (-e 2): changes load at reboot";; 1) echo "enabled";; 0) echo "${RED}DISABLED${R}";; *) echo unknown;; esac)"
  printf '  %-16s %s\n' "loaded rules" "$(loaded_count)"
  printf '  %-16s %s\n' "added by us" "$ours  ($OURS)"
  printf '  %-16s %s\n' "rule files" "$(ls "$RULESD"/*.rules 2>/dev/null | wc -l) in $RULESD"
  [ -r "$LOG" ] && printf '  %-16s %s\n' "last apply" "$(tail -1 "$LOG")"
  say ""
  say "${B}Log retention${R} (PowerStrux reports on ${WINDOW_DAYS} days)"
  retention
  say ""
}

case "${1:-status}" in
  status) cmd_status ;;
  check)  cmd_check ;;
  apply)  [ "${2:-}" = --quiet ] && QUIET=1; cmd_apply ;;
  -h|--help|help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0" ;;
  *) die "unknown: $1  (try: it-audit --help)" ;;
esac
