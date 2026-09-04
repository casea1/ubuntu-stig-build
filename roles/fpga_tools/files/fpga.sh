#!/usr/bin/env bash
# it-fpga -- the FPGA toolchains on this workstation: what is installed, where
# the licence comes from, and whether the programmer cables can actually talk.
#
# The toolchains themselves are NOT installed by the baseline -- they are
# interactive, authenticated and ~150 GB, so they are baked into the image or
# run by hand. This owns everything around them.
#
#   it-fpga                    what is installed, licence, cables  (the default)
#   it-fpga status             the same
#   it-fpga license            show the current licence configuration
#   it-fpga license --server 1702@licsrv [--xilinx 2100@licsrv]
#                              point at a licence server on another machine
#   it-fpga license --file /path/License.dat
#                              node-locked licence served by a local daemon
#   it-fpga license --none     unset it
#   it-fpga check              run the vendors' own checkers and translate
#   it-fpga fixup              post-install fixes on an INSTALLED tree: make it
#                              readable by every user, drop Libero's bundled libstdc++
#   it-fpga install xilinx     run the Xilinx installer unattended from a staged
#                              .bin + saved config, under systemd so it survives
#                              a dropped session. Then fixes permissions itself.
#   it-fpga compat build       build the old RHEL-era libraries Libero needs
#                              (libpng15) into a private directory only it sees
#   it-fpga compat status      what is in there
#   it-fpga install --save-config
#                              capture this box's install config so every other
#                              box installs identically
#   it-fpga desktop            import the VENDOR's own app tiles system-wide, so
                             every user gets Libero SoC / FPExpress / SmartHLS
                             / PFSoC MSS and not just whoever installed them
  it-fpga cables             what is plugged in, and is it authorised
#   it-fpga env                the environment a user gets, and how to load it
#
# A licence change is written to BOTH the live /etc/profile.d scripts (so a new
# shell has it at once) AND /opt/it/site.yml (so the next ansible-pull renders
# the same thing). Changing only one is the trap this avoids.
set -uo pipefail

SITE_YML="${SITE_YML:-/opt/it/site.yml}"
CONF=/etc/stig-build/fpga.conf
XILINX_ENV=/etc/profile.d/xilinx.sh
MICROCHIP_ENV=/etc/profile.d/microchip.sh
LIC_DIR=/etc/stig-build/fpga
LIC_FILE="$LIC_DIR/License.dat"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# Read what the role rendered, so this and the pull agree on where things are.
env_var() {   # $1 = file, $2 = variable -> its value
  [ -r "$1" ] || return 0
  sed -nE "s/^export $2=//p" "$1" | tail -1 | tr -d '"'"'"
}
XROOT="$(env_var "$XILINX_ENV" XILINX_ROOT)";        XROOT="${XROOT:-/tools/Xilinx}"
XVER="$(env_var "$XILINX_ENV" XILINX_VERSION)";      XVER="${XVER:-2024.2}"
LIBDIR="$(env_var "$MICROCHIP_ENV" LIBERO_INSTALL_DIR)"
LIBDIR="${LIBDIR:-/opt/microchip/Libero_SoC_2025.1}"
# The parent, which the installer writes into as well (the "common" directory).
MCHP_ROOT="$(dirname "$LIBDIR")"
LIC_MCHP="$(env_var "$MICROCHIP_ENV" LM_LICENSE_FILE)"
LIC_XLNX="$(env_var "$XILINX_ENV" XILINXD_LICENSE_FILE)"

# Who may use the toolchains. Read from the conf the role renders, so this and
# the pull cannot disagree about the policy.
conf_get() {   # $1 = key, $2 = default
  local v=""
  [ -r "$CONF" ] && v=$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | tail -1)
  printf '%s' "${v:-$2}"
}
ACCESS_GROUP="$(conf_get ACCESS_GROUP sentry)"

# ---------------------------------------------------------------------------
# site.yml, with the same guard the pull applies on the way in: a file that
# does not parse stops the NEXT pull at task 2, long after whoever broke it has
# gone home.
# ---------------------------------------------------------------------------
yaml_ok() {
  [ -s "$1" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1]))
except Exception as e:
    print(str(e).splitlines()[0]); sys.exit(1)' "$1" 2>&1
}

# The live environment always takes; site.yml can be refused when the file is
# already broken. Half-landing is a real outcome, so say which happened rather
# than a flat OK -- otherwise the next pull silently reverts the licence and
# nobody knows why the tools stopped building.
not_persisted() {
  bad "NOT persisted: the next ansible-pull will revert this"
  say "  ${DIM}The live environment IS set, so a new shell works until then.${R}"
  say "  ${DIM}Fix the file named above, then re-run this command.${R}"
}

persist() {   # $1 = key, $2 = value (YAML-quoted by the caller if needed)
  local key="$1" val="$2" bak why
  install -d -o root -g "$(stat -c %G /opt/it 2>/dev/null || echo sudo)" -m 2770 /opt/it 2>/dev/null || true
  [ -f "$SITE_YML" ] || printf -- '---\n# Per-node overrides. Loaded above group_vars by local.yml.\n' > "$SITE_YML"
  bak="$SITE_YML.bak-$$"; cp -a "$SITE_YML" "$bak"
  if grep -qE "^${key}[[:space:]]*:" "$SITE_YML"; then
    sed -i -E "s|^${key}[[:space:]]*:.*|${key}: ${val}|" "$SITE_YML"
  else
    printf '%s: %s\n' "$key" "$val" >> "$SITE_YML"
  fi
  if why=$(yaml_ok "$SITE_YML"); then rm -f "$bak"; return 0; fi
  cp -a "$bak" "$SITE_YML"; rm -f "$bak"
  bad "refused to write $SITE_YML -- the result would not parse: $why"
  return 1
}

# Change the live /etc/profile.d script too, so a new shell has it without
# waiting for a pull. The role re-renders both files from site.yml, so the two
# stay in step.
env_set() {   # $1 = file, $2 = variable, $3 = value ("" removes it)
  local f="$1" var="$2" val="$3"
  [ -f "$f" ] || return 0
  sed -i -E "/^export ${var}=/d" "$f"
  [ -n "$val" ] || return 0
  # After the last export of the block, before the first shell function.
  if grep -qE '^[a-z-]+-env\(\)' "$f"; then
    sed -i -E "0,/^[a-z-]+-env\(\)/s||export ${var}=${val}\n\n&|" "$f"
  else
    printf 'export %s=%s\n' "$var" "$val" >> "$f"
  fi
}

# ---------------------------------------------------------------------------
have_tree() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

cmd_status() {
  head2 "FPGA toolchains -- $(hostname -s)"

  # ---- Xilinx
  if [ -r "$XILINX_ENV" ]; then
    local vbin="$XROOT/Vivado/$XVER/bin/vivado"
    if have_tree "$XROOT"; then
      ok "Xilinx $XVER      $XROOT  ($(du -sh "$XROOT" 2>/dev/null | cut -f1))"
      [ -x "$vbin" ] && ok "  vivado           present" || warn "  vivado           NOT found at $vbin"
      [ -x "$XROOT/Vitis/$XVER/bin/vitis" ] && ok "  vitis            present"
    else
      warn "Xilinx $XVER      NOT installed at $XROOT"
      say  "  ${DIM}The baseline does not install it -- bake it into the image, or run${R}"
      say  "  ${DIM}the SFD installer by hand. Scaffolding here is ready either way.${R}"
    fi
  else
    say "  ${DIM}Xilinx support is switched off (fpga_xilinx_enabled).${R}"
  fi

  # ---- Microchip
  if [ -r "$MICROCHIP_ENV" ]; then
    if have_tree "$LIBDIR"; then
      ok "Libero            $LIBDIR  ($(du -sh "$LIBDIR" 2>/dev/null | cut -f1))"
      [ -x "$LIBERO_BIN" ] && ok "  libero           $LIBERO_BIN" \
        || warn "  libero           NOT found under $LIBDIR"
      # The bundled RHEL libstdc++ is older than what Noble's libicuuc needs.
      local bundled
      bundled=$(find "$LIBDIR" -name 'libstdc++.so.6' -type f 2>/dev/null | head -3)
      if [ -n "$bundled" ]; then
        bad "  bundled libstdc++ still present -- libero_bin will die with GLIBCXX_3.4.30"
        printf '      %s\n' $bundled
        say  "      ${DIM}fix: sudo it-fpga fixup${R}"
      else
        ok "  libstdc++        using the system library (bundled copy removed)"
      fi
    else
      warn "Libero            NOT installed at $LIBDIR"
    fi
    # Shared IP vault. Wrong modes here do not stop Libero starting -- they
    # stop the SECOND engineer downloading a core, days later.
    if [ -d "$VAULT_DIR" ]; then
      local vm vg
      vm="$(stat -c '%a' "$VAULT_DIR" 2>/dev/null)"
      vg="$(stat -c '%G' "$VAULT_DIR" 2>/dev/null)"
      if [ "$vg" = "$ACCESS_GROUP" ] && [ "$(( 0$vm & 0020 ))" -ne 0 ]; then
        ok "  IP vault         $VAULT_DIR ($vm root:$vg, shared)"
      else
        bad "  IP vault         $VAULT_DIR is $vm $(stat -c '%U:%G' "$VAULT_DIR" 2>/dev/null)"
        say "                    ${DIM}$ACCESS_GROUP cannot write it, so only the person who${R}"
        say "                    ${DIM}installed can download IP cores. fix: sudo it-fpga fixup${R}"
      fi
    else
      warn "  IP vault         not at $VAULT_DIR -- each user has their own copy"
    fi
  else
    say "  ${DIM}Microchip support is switched off (fpga_microchip_enabled).${R}"
  fi

  # ---- permissions. The single most likely reason a correctly installed tool
  # is unusable: the installer ran under sudo with the STIG's umask 077.
  local st
  for st in "$XROOT/Vivado/$XVER/settings64.sh" "$LIBERO_BIN"; do
    [ -e "$st" ] || continue
    if perms_ok "$st"; then
      local grp members
      grp="$(stat -c '%G' "$st")"
      members="$(getent group "$grp" | cut -d: -f4 | tr ',' ' ')"
      ok "usable by         group $grp${members:+ -- $members}"
      check_parents "$st" || true
    else
      bad "NOT USABLE        $st"
      say "                    ${DIM}The STIG sets umask 077, so an installer run under sudo${R}"
      say "                    ${DIM}made the whole tree 0700/0600. Engineers get \"Permission${R}"
      say "                    ${DIM}denied\" on settings64.sh and it looks like a broken install.${R}"
      say "                    ${DIM}group is $(stat -c '%G' "$st" 2>/dev/null), should be $ACCESS_GROUP${R}"
      say "                    ${DIM}fix: sudo it-fpga fixup${R}"
    fi
  done

  # ---- compatibility
  head2 "24.04 compatibility"
  local n
  for n in tinfo ncurses; do
    if [ -e "/usr/lib/x86_64-linux-gnu/lib$n.so.5" ]; then
      ok "lib$n.so.5 $(printf '%*s' $(( 8 - ${#n} )) '')present"
    else
      warn "lib$n.so.5 missing -- Vivado hangs at \"Generating installed device list\""
    fi
  done
  if [ -d /usr/tmp ]; then
    local m; m=$(stat -c '%a %U:%G' /usr/tmp)
    case "$m" in
      "1777 root:root") ok "/usr/tmp          $m" ;;
      *) warn "/usr/tmp          $m -- should be 1777 root:root. Owned by one user"
         say  "                    locks out every other engineer's licence checkout." ;;
    esac
  else
    warn "/usr/tmp          missing -- FlexLM cannot create .flexlm"
  fi
  [ -L /etc/pki/tls/certs/ca-bundle.crt ] && ok "RHEL CA path      linked" \
    || warn "RHEL CA path      missing -- Libero cannot verify TLS"
  dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386 \
    && ok "i386 multiarch    enabled" \
    || bad "i386 multiarch    NOT enabled -- the 32-bit vendor components will not load"

  # ---- licence
  head2 "Licence"
  lic_show

  # ---- cables
  head2 "Programmer cables"
  cables_show
  say ""
  say "  ${DIM}Load the tools in a shell:  vivado_env    libero_env${R}"
  say "  ${DIM}Set the licence server:     sudo it-fpga license --server 1702@licsrv${R}"
  say ""
}

lic_show() {
  if [ -n "$LIC_MCHP" ] || [ -n "$LIC_XLNX" ]; then
    [ -n "$LIC_MCHP" ] && ok "Microchip         $LIC_MCHP  (LM_LICENSE_FILE, SNPSLMD_LICENSE_FILE)"
    [ -n "$LIC_XLNX" ] && ok "Xilinx            $LIC_XLNX  (XILINXD_LICENSE_FILE)"
  elif [ -r "$LIC_FILE" ]; then
    ok "node-locked       $LIC_FILE"
  else
    warn "none configured -- the tools start and then refuse to build"
    say  "  ${DIM}sudo it-fpga license --server 1702@licsrv${R}"
  fi

  # A local daemon, if there is one.
  if systemctl list-unit-files fpga-lmgrd.service >/dev/null 2>&1 \
     && [ -f /etc/systemd/system/fpga-lmgrd.service ]; then
    local st; st=$(systemctl is-active fpga-lmgrd.service 2>/dev/null)
    [ "$st" = active ] && ok "local lmgrd       running" || bad "local lmgrd       $st"
  fi

  # Can we actually reach the server? A licence variable that points at a host
  # nobody can talk to looks identical to a correct one until someone builds.
  local hp host port
  for hp in $(printf '%s,%s' "$LIC_MCHP" "$LIC_XLNX" | tr ',' ' '); do
    case "$hp" in
      *@*) port="${hp%%@*}"; host="${hp##*@}" ;;
      *) continue ;;
    esac
    case "$host" in localhost|127.0.0.1) continue ;; esac
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w3 "$host" "$port" 2>/dev/null; then ok "reachable         $host:$port"
      else bad "UNREACHABLE       $host:$port -- licence checkout will fail"
           say "                    ${DIM}FlexLM also needs the VENDOR daemon port, which is${R}"
           say "                    ${DIM}random unless pinned on the server. If this port is${R}"
           say "                    ${DIM}open and checkout still fails, that is why.${R}"
      fi
    fi
  done
}

cables_show() {
  local found=0 line
  if command -v lsusb >/dev/null 2>&1; then
    while read -r line; do
      case "$line" in
        *1514:*) printf '  %s  %s(Microchip FlashPro)%s\n' "$line" "$DIM" "$R"; found=1 ;;
        *0403:*) printf '  %s  %s(FTDI / FlashPro3 / generic JTAG)%s\n' "$line" "$DIM" "$R"; found=1 ;;
        *03fd:*) printf '  %s  %s(Xilinx Platform Cable)%s\n' "$line" "$DIM" "$R"; found=1 ;;
        *1443:*) printf '  %s  %s(Digilent JTAG)%s\n' "$line" "$DIM" "$R"; found=1 ;;
      esac
    done < <(lsusb 2>/dev/null)
  fi
  [ "$found" -eq 1 ] || say "  ${DIM}no programmer cable plugged in${R}"

  [ -f /etc/udev/rules.d/70-fpga-programmers.rules ] \
    && ok "udev rules        installed" || bad "udev rules        MISSING -- run an ansible-pull"

  # The one that catches people out. A udev rule sets permissions on a device
  # node USBGuard may never have let appear.
  if command -v usbguard >/dev/null 2>&1 && systemctl is-active --quiet usbguard 2>/dev/null; then
    # Read the class policy rather than assert one. Programmers present as
    # vendor-specific (ff), so where the class rule is in place they are
    # authorised on connect and telling people to enrol one sends them off to
    # fix something that is not broken.
    local cls
    cls=$(sed -nE 's/^allow with-interface none-of \{ (.*) \}.*/\1/p' \
            /etc/usbguard/rules.conf 2>/dev/null | tail -1)
    case "$cls" in
      *ff:*)
        warn "USBGuard          ACTIVE -- and vendor-specific is NOT auto-allowed here"
        say  "                    ${DIM}sudo it-usb enroll     (then re-plug)${R}" ;;
      "")
        warn "USBGuard          ACTIVE -- every device is enrolled by hand on this box"
        say  "                    ${DIM}sudo it-usb enroll     (then re-plug)${R}"
        say  "                    ${DIM}sudo it-usb blocked    what is being refused right now${R}" ;;
      *)
        ok   "USBGuard          ACTIVE -- programmers are authorised on connect"
        say  "                    ${DIM}Still enrolled by hand: $cls${R}"
        say  "                    ${DIM}sudo it-usb blocked    if a cable does not appear${R}" ;;
    esac
  fi
}

cmd_license() {
  local server="" xilinx="" file="" clear=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --server)  server="${2:?--server needs <port>@<host>}"; shift 2 ;;
      --xilinx)  xilinx="${2:?--xilinx needs <port>@<host>}"; shift 2 ;;
      --file)    file="${2:?--file needs a path}"; shift 2 ;;
      --none)    clear=1; shift ;;
      *) die "unknown option: $1  (try: it-fpga --help)" ;;
    esac
  done

  if [ -z "$server$xilinx$file" ] && [ "$clear" -eq 0 ]; then
    head2 "Licence"; lic_show; say ""
    say "  Point at a server on another machine:"
    say "    ${B}sudo it-fpga license --server 1702@licsrv${R}"
    say "    ${DIM}--xilinx 2100@licsrv   if Vivado uses a different port or host${R}"
    say "    ${DIM}redundant servers are comma-separated: 1702@a,1702@b,1702@c${R}"
    say ""
    say "  Or a node-locked file served locally:"
    say "    ${B}sudo it-fpga license --file /path/to/License.dat${R}"
    say ""
    return 0
  fi

  if [ "$clear" -eq 1 ]; then
    env_set "$MICROCHIP_ENV" LM_LICENSE_FILE ""
    env_set "$MICROCHIP_ENV" SNPSLMD_LICENSE_FILE ""
    env_set "$XILINX_ENV" XILINXD_LICENSE_FILE ""
    persist fpga_license_mode none
    persist fpga_license_microchip '""'
    persist fpga_license_xilinx '""'
    ok "licence configuration cleared"
    return 0
  fi

  # ---- node-locked, served locally
  if [ -n "$file" ]; then
    [ -r "$file" ] || die "cannot read $file"
    grep -qiE '^(SERVER|DAEMON|VENDOR|INCREMENT|FEATURE)' "$file" \
      || warn "that does not look like a FlexLM licence file -- continuing anyway"
    install -d -m 0700 -o root -g root "$LIC_DIR"
    install -m 0600 -o root -g root "$file" "$LIC_FILE"
    ok "installed $LIC_FILE (0600 root:root)"
    # The placeholder Microchip ships on line 1 stops lmgrd dead.
    if grep -q '<put.hostname.here>' "$LIC_FILE"; then
      sed -i 's/<put\.hostname\.here>/localhost/' "$LIC_FILE"
      ok "replaced the <put.hostname.here> placeholder with localhost"
    fi
    persist fpga_license_mode local || { not_persisted; return 1; }
    ok "licence mode: local (a systemd unit serves it -- NOT a login script)"
    say "  ${DIM}Run a pull to start the daemon:  sudo it-pull${R}"
    say "  ${DIM}Or now:  systemctl enable --now fpga-lmgrd${R}"
    return 0
  fi

  # ---- a server on another machine
  local hp host port
  for hp in $(printf '%s %s' "$server" "$xilinx"); do
    case "$hp" in
      *@*) port="${hp%%@*}"; host="${hp##*@}"
           case "$port" in ''|*[!0-9,]*) die "not a port: '$port' -- expected <port>@<host>" ;; esac ;;
      *) die "expected <port>@<host>, got '$hp'" ;;
    esac
  done

  [ -n "$server" ] && {
    env_set "$MICROCHIP_ENV" LM_LICENSE_FILE "$server"
    env_set "$MICROCHIP_ENV" SNPSLMD_LICENSE_FILE "$server"
    persist fpga_license_microchip "\"$server\"" || { ok "Microchip -> $server"; not_persisted; return 1; }
    ok "Microchip -> $server"
  }
  # Vivado falls back to the Microchip variable only if it is the same server;
  # set it explicitly so a mixed setup is not a surprise.
  local x="${xilinx:-$server}"
  env_set "$XILINX_ENV" XILINXD_LICENSE_FILE "$x"
  persist fpga_license_xilinx "\"$x\"" || { ok "Xilinx    -> $x"; not_persisted; return 1; }
  ok "Xilinx    -> $x"
  persist fpga_license_mode server || { not_persisted; return 1; }

  # Stop a stale local daemon: two licence sources is worse than none.
  if [ -f /etc/systemd/system/fpga-lmgrd.service ]; then
    systemctl disable --now fpga-lmgrd.service >/dev/null 2>&1
    warn "stopped the local lmgrd -- the server is authoritative now"
    say  "  ${DIM}The next pull removes its unit.${R}"
  fi

  say ""
  ok "Written to the live environment and $SITE_YML (survives the pull)."
  say "  ${DIM}A shell already open keeps the old value -- log out and back in.${R}"
  head2 "Reachability"
  LIC_MCHP="$server"; LIC_XLNX="$x"; lic_show
}

# The post-install fixes that touch the VENDOR TREE. Deliberately a command and
# not a role task: the role never writes into a 150 GB install unattended, and
# these run once after an install, not on every pull.
# The STIG sets umask 077. A vendor installer run under sudo therefore creates
# its whole tree root-only -- 0700 directories, 0600 files -- and every engineer
# gets "Permission denied" on settings64.sh. Nothing in the vendor's output says
# so; it looks like a broken install.
#
# a+rX, not a+rx: capital X adds execute only to DIRECTORIES and to files that
# already have it for someone, so data files do not come out executable.
fix_perms() {   # $1 = tree, $2 = label
  local d="$1" lbl="$2"
  have_tree "$d" || return 0
  if ! getent group "$ACCESS_GROUP" >/dev/null 2>&1; then
    bad "no '$ACCESS_GROUP' group on this box -- run an ansible-pull first"; return 1
  fi
  say "  granting $ACCESS_GROUP read+execute on $lbl ($(du -sh "$d" 2>/dev/null | cut -f1)) -- takes a moment"
  # g+rX, o-rwx: the group may USE the toolchain, nobody may modify it, and it
  # is not readable by every account on the box. Capital X adds execute only to
  # directories and to files that already have it, so data files do not come
  # out executable.
  # chown, not just chgrp: an installer run unprivileged (which is how Libero
  # avoids needing an X cookie for root) leaves the tree owned by that person,
  # and "engineers cannot modify a shared toolchain" then is not true.
  chown -R "root:$ACCESS_GROUP" "$d" 2>/dev/null
  chmod -R g+rX,o-rwx "$d" 2>/dev/null
  ok "$lbl owned by root, usable by every member of $ACCESS_GROUP"
}

# Cheap check: one stat, no recursion. The settings script is what a user
# sources first, so if that is unreadable the tree is.
# Can the access group read this? -r as root says nothing about anyone else,
# so test the GROUP bit and the group owner, not our own access.
perms_ok() {   # $1 = a file every entitled user must be able to read
  [ -e "$1" ] || return 1
  [ "$(stat -c '%G' "$1" 2>/dev/null)" = "$ACCESS_GROUP" ] || return 1
  [ "$(( 0$(stat -c '%a' "$1" 2>/dev/null) & 0040 ))" -ne 0 ]
}

# A tree with perfect modes is still unreachable if any PARENT blocks traverse,
# and the symptom is identical -- "Permission denied" on settings64.sh. Worth
# one loop: this is not hypothetical, it is what an install into a directory
# someone created under the STIG umask looks like.
#
# "Traversable" is not the same as "other-executable": a member of the access
# group traverses a 0750 directory owned by that group perfectly well. Testing
# only the other bit reports directories that are in fact fine.
traversable() {   # $1 = directory
  local m g
  m="$(stat -c '%a' "$1" 2>/dev/null)" || return 0    # unreadable to us: not our call
  g="$(stat -c '%G' "$1" 2>/dev/null)"
  [ "$(( 0$m & 0001 ))" -ne 0 ] && return 0                       # world-traversable
  [ "$g" = "$ACCESS_GROUP" ] && [ "$(( 0$m & 0010 ))" -ne 0 ] && return 0  # group-traversable
  return 1
}

check_parents() {   # $1 = path -> 0 quiet, 1 after naming the blocker
  local d rc=0
  d="$(dirname "$1")"
  while [ "$d" != / ] && [ -n "$d" ] && [ "$d" != . ]; do
    if ! traversable "$d"; then
      bad "$d is $(stat -c '%a %U:%G' "$d" 2>/dev/null) -- $ACCESS_GROUP cannot traverse it,"
      say "      so nothing underneath is reachable however its own modes look."
      say "      ${DIM}fix: sudo chgrp $ACCESS_GROUP $d && sudo chmod g+x $d${R}"
      rc=1
    fi
    d="$(dirname "$d")"
  done
  return "$rc"
}

cmd_fixup() {
  local n=0
  head2 "Post-install fixes"

  # First, because it is the one that makes the tools unusable for everyone
  # except the person who installed them.
  fix_perms "$XROOT" "Xilinx"
  fix_perms "$LIBDIR" "Libero"
  have_tree "$XROOT"  && check_parents "$XROOT"
  have_tree "$LIBDIR" && check_parents "$LIBDIR"

  # `it-fpga install libero` handed the whole of $MCHP_ROOT to a person so a
  # GUI installer could write it without root. Take it back -- otherwise the
  # parent of a root-owned tree stays owned by whoever happened to install it.
  if [ -d "$MCHP_ROOT" ]; then
    chown root:root "$MCHP_ROOT" 2>/dev/null
    chmod 0755 "$MCHP_ROOT" 2>/dev/null
    ok "$MCHP_ROOT back to root:root 0755"
  fi

  # The IP vault is the one writable exception: Libero writes into it whenever
  # anyone downloads or imports a core, and it is shared so a core is fetched
  # once for the box. Left as the installer made it (0700, owned by the person
  # who ran it, because the STIG sets umask 077) the first colleague to fetch
  # an IP core fails -- and the error names Libero, not the permissions.
  if [ -d "$VAULT_DIR" ]; then
    chown -R "root:$ACCESS_GROUP" "$VAULT_DIR" 2>/dev/null
    chmod -R g+rwX,o-rwx "$VAULT_DIR" 2>/dev/null
    # setgid on every directory, so cores added later stay group-owned.
    find "$VAULT_DIR" -type d -exec chmod g+s {} + 2>/dev/null
    ok "IP vault $VAULT_DIR writable by $ACCESS_GROUP (setgid, shared)"
  else
    say "  ${DIM}no IP vault at $VAULT_DIR -- point Libero's common directory${R}"
    say "  ${DIM}there at install time so cores are fetched once, not per user.${R}"
  fi

  if have_tree "$LIBDIR"; then
    # Libero ships a RHEL libstdc++ OLDER than what Noble's libicuuc.so.74
    # needs, so libero_bin dies with GLIBCXX_3.4.30 not found. Removing the
    # bundled copy forces it onto the system library, which is newer.
    local f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      mv -f "$f" "$f.disabled" && { ok "disabled $f"; n=$((n + 1)); }
    done < <(find "$LIBDIR" -name 'libstdc++.so.6' -type f 2>/dev/null)
    [ "$n" -eq 0 ] && say "  ${DIM}no bundled libstdc++ left to remove${R}"
    say "  ${DIM}Renamed, not deleted -- put it back with .disabled -> .so.6 if this${R}"
    say "  ${DIM}turns out to be the wrong call for your version.${R}"
  else
    warn "Libero is not installed at $LIBDIR -- nothing to fix"
  fi

  # The vendor's own tiles, which otherwise belong to whoever ran the installer.
  cmd_desktop

  if have_tree "$XROOT"; then
    local drv="$XROOT/Vivado/$XVER/data/xicom/cable_drivers/lin64/install_script/install_drivers"
    if [ -x "$drv/install_drivers" ]; then
      say ""
      say "  JTAG cable drivers: run with NO cables plugged in --"
      say "    ${B}cd $drv && sudo ./install_drivers${R}"
      say "  ${DIM}Not run automatically: it wants a specific hardware state.${R}"
    fi
    say ""
    say "  ${DIM}Do NOT run Xilinx's installLibs.sh -- it uses 22.04 package names${R}"
    say "  ${DIM}(libasound2, compat-openssl10) and fails. The role already installed${R}"
    say "  ${DIM}what it was trying to install.${R}"
  fi
  say ""
}

# ---------------------------------------------------------------------------
# Unattended Xilinx install.
#
# The pull does NOT do this and should not: it is ~150 GB and an hour or more.
# But there is nothing interactive left once a config exists, so it does not
# have to be done by hand on every box either.
#
# systemd-run rather than tmux: it survives a dropped SSH session, a closed
# terminal and a logout, it records an exit code, and everything lands in the
# journal. A tmux session that vanished is exactly how the first attempt on
# this fleet ended with nobody able to say whether it had finished.
# ---------------------------------------------------------------------------
INSTALLER_DIR="${FPGA_INSTALLER_DIR:-/opt/it/installers}"
XCONFIG=/etc/stig-build/fpga/xilinx-install_config.txt

find_installer() {   # -> path of the newest Xilinx .bin we can see
  local d f
  for d in "$INSTALLER_DIR" /media/*/* /media/* /run/media/*/* /mnt/*; do
    [ -d "$d" ] || continue
    f=$(find "$d" -maxdepth 2 -type f -name '*AdaptiveSoCs*Lin64.bin' 2>/dev/null | sort | tail -1)
    [ -n "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

cmd_install() {
  local what="${1:-}" bin="" cfg="$XCONFIG" save=0
  shift 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --bin)    bin="${2:?--bin needs a path}"; shift 2 ;;
      --config) cfg="${2:?--config needs a path}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$what" in
    --save-config) save=1 ;;
    xilinx|"") ;;
    libero) cmd_install_libero; return $? ;;
    *) die "usage: it-fpga install xilinx|libero [--bin PATH] [--config PATH]" ;;
  esac

  if [ "$save" -eq 1 ]; then
    local src=/root/.Xilinx/install_config.txt
    [ -r "$src" ] || die "no $src -- run the installer once (or ./xsetup -b ConfigGen) first"
    install -d -m 0755 "$(dirname "$XCONFIG")"
    install -m 0644 "$src" "$XCONFIG"
    ok "saved $XCONFIG"
    say "  ${DIM}Commit it to the repo as roles/fpga_tools/files/xilinx-install_config.txt${R}"
    say "  ${DIM}and every box installs the same modules and devices.${R}"
    return 0
  fi

  head2 "Unattended Xilinx install"
  if [ -z "$bin" ]; then
    bin="$(find_installer)" || die \
"no Xilinx installer found.
Looked in $INSTALLER_DIR and on attached media for *AdaptiveSoCs*Lin64.bin
Point at one:  sudo it-fpga install xilinx --bin /path/to/installer.bin"
  fi
  [ -r "$bin" ] || die "cannot read $bin"

  if [ ! -r "$cfg" ]; then
    bad "no install config at $cfg"
    say "  The config decides which modules and device families are installed --"
    say "  it is the difference between 40 GB and 150 GB, so it is not guessed."
    say ""
    say "  Make one on this box:"
    say "    ${B}cd $(dirname "$bin") && ./xsetup -b ConfigGen${R}"
    say "    ${DIM}then: sudo it-fpga install --save-config${R}"
    say "  Or point at one you already have:  --config /path/to/install_config.txt"
    return 1
  fi

  local dest
  dest="$(sed -nE 's/^Destination=//p' "$cfg" | tail -1)"
  printf '  %-12s %s\n' "installer" "$bin"
  printf '  %-12s %s\n' "config" "$cfg"
  printf '  %-12s %s\n' "destination" "${dest:-<not set in the config>}"
  # df on a destination that does not exist yet answers nothing -- ask about the
  # nearest parent that does, which is the filesystem it will land on.
  local dfp="${dest:-/}"
  while [ -n "$dfp" ] && [ ! -d "$dfp" ]; do dfp="$(dirname "$dfp")"; done
  printf '  %-12s %s\n' "free space" "$(df -h "${dfp:-/}" 2>/dev/null | awk 'NR==2{print $4" on "$6}')"
  say ""

  if have_tree "$XROOT"; then
    warn "$XROOT already has something in it ($(du -sh "$XROOT" 2>/dev/null | cut -f1))"
    say  "  The installer may refuse, or resume. Remove it first for a clean run."
  fi

  if [ -t 0 ]; then
    printf '  This runs for an hour or more and writes ~150 GB. Type YES to start: '
    local a; read -r a; [ "$a" = YES ] || die "not confirmed -- nothing was started"
  fi

  # Extract once, next to the .bin, so a re-run does not unpack it again.
  local xdir="$INSTALLER_DIR/xsetup"
  if [ ! -x "$xdir/xsetup" ]; then
    say "  extracting the installer..."
    install -d -m 0755 "$INSTALLER_DIR"
    "$bin" --noexec --keep --target "$xdir" >/dev/null 2>&1 \
      || die "could not extract $bin"
  fi
  ok "installer ready at $xdir"

  systemctl reset-failed xilinx-install.service 2>/dev/null || true
  if systemd-run --unit=xilinx-install --collect \
       --working-directory="$xdir" \
       --property=TimeoutStartSec=infinity \
       "$xdir/xsetup" --agree XilinxEULA,3rdPartyEULA \
       --batch Install --config "$cfg" >/dev/null 2>&1; then
    ok "started as xilinx-install.service"
    say ""
    say "  ${B}journalctl -u xilinx-install -f${R}      watch it; detach any time"
    say "  ${B}systemctl status xilinx-install${R}      did it finish, and how"
    say ""
    say "  ${DIM}It survives a dropped session, a closed terminal and a logout.${R}"
    say "  ${DIM}When it finishes:  sudo it-fpga fixup   (permissions + the rest)${R}"
  else
    die "systemd-run failed to start the installer"
  fi
}

# ---------------------------------------------------------------------------
# Libero's old-library problem.
#
# Its installer and tools are built against RHEL library versions Ubuntu 24.04
# does not ship and does not package. libpng15 is the one that stops the
# installer at load. There is no apt answer, and this is NOT the ncurses
# situation: libpng 1.5 -> 1.6 was an ABI break (the structs became opaque), so
# a symlink onto libpng16 links and then misbehaves, which is worse than
# failing cleanly.
#
# Built from upstream source into a directory only Libero sees, via
# LD_LIBRARY_PATH. Never a symlink or a foreign .deb in /usr/lib -- that would
# put an unmaintained libpng in front of every program on the box.
# ---------------------------------------------------------------------------
COMPAT_DIR="$(conf_get COMPAT_DIR /opt/microchip/compat/lib)"
VAULT_DIR="$(conf_get VAULT_DIR "$MCHP_ROOT/common")"
# Microchip moved Designer under Libero_SoC/ in 2025.1; the conf carries
# whichever the role was told, and the fallback finds it either way.
LIBERO_BIN="$(conf_get LIBERO_BIN "$LIBDIR/Libero_SoC/Designer/bin64/libero")"
if [ ! -x "$LIBERO_BIN" ] && [ -d "$LIBDIR" ]; then
  _lb="$(find "$LIBDIR" -maxdepth 5 -type f -name libero -perm -u+x 2>/dev/null \
          | grep -E '/bin64/libero$' | head -1)"
  [ -n "$_lb" ] && LIBERO_BIN="$_lb"
fi
LIBPNG15_URL="https://downloads.sourceforge.net/project/libpng/libpng15/1.5.30/libpng-1.5.30.tar.gz"

compat_status() {
  head2 "Libero compatibility libraries"
  printf '  %-14s %s\n' "directory" "$COMPAT_DIR"
  if [ -d "$COMPAT_DIR" ] && [ -n "$(ls -A "$COMPAT_DIR" 2>/dev/null)" ]; then
    ls -1 "$COMPAT_DIR" | sed 's/^/      /'
  else
    warn "empty -- Libero and its installer will fail on the first old library"
    say  "  ${DIM}build them: sudo it-fpga compat build${R}"
  fi
  # What is actually still missing, asked of the binaries themselves.
  local b
  for b in "$LIBERO_BIN" "$(dirname "$LIBERO_BIN")/libero_bin"; do
    [ -x "$b" ] || continue
    if LD_LIBRARY_PATH="$COMPAT_DIR:/usr/lib/i386-linux-gnu" ldd "$b" 2>/dev/null | grep -q 'not found'; then
      bad "still missing for $(basename "$b"):"
      LD_LIBRARY_PATH="$COMPAT_DIR:/usr/lib/i386-linux-gnu" ldd "$b" 2>/dev/null \
        | awk '/not found/{print "      " $1}'
    else
      ok "$(basename "$b") resolves every library"
    fi
  done
  say ""
}

compat_build() {
  head2 "Building Libero's compatibility libraries"
  say "  Into $COMPAT_DIR, which only Libero sees. Nothing is installed into"
  say "  /usr/lib -- an unmaintained libpng in front of every program on the"
  say "  box is a worse problem than the one it solves."
  say ""

  local missing=""
  command -v gcc  >/dev/null 2>&1 || missing="$missing build-essential"
  command -v make >/dev/null 2>&1 || missing="$missing make"
  [ -n "$missing" ] && die "install these first: apt install$missing"

  install -d -m 0755 "$COMPAT_DIR"
  if [ -e "$COMPAT_DIR/libpng15.so.15" ]; then
    ok "libpng15 already built"
  else
    local tmp; tmp="$(mktemp -d /tmp/fpga-compat.XXXXXX)" || die "mktemp failed"
    say "  fetching libpng 1.5.30..."
    if ! curl -fsSL -o "$tmp/libpng.tar.gz" "$LIBPNG15_URL"; then
      rm -rf "$tmp"
      bad "could not download libpng 1.5.30"
      say "  ${DIM}Air-gapped? Carry the tarball in and:${R}"
      say "  ${DIM}  sudo it-fpga compat build --source /path/to/libpng-1.5.30.tar.gz${R}"
      return 1
    fi
    say "  building (a minute or so)..."
    # Output to a log, not the terminal: libpng's install step runs with set -x
    # and buries the result in link commands. Kept on failure so the reason
    # survives, removed on success.
    local blog=/var/log/fpga-compat-build.log
    if ! ( set -e
           cd "$tmp"
           tar xzf libpng.tar.gz
           cd libpng-1.5.30
           ./configure --prefix="$tmp/out" --disable-static
           make -j"$(nproc)"
           make install ) > "$blog" 2>&1; then
      rm -rf "$tmp"
      bad "libpng 1.5.30 failed to build -- see $blog"
      tail -15 "$blog" | sed 's/^/      /'
      return 1
    fi
    rm -f "$blog"
    install -m 0644 "$tmp/out/lib/"libpng15.so.15* "$COMPAT_DIR/" 2>/dev/null
    ( cd "$COMPAT_DIR" && ln -sfn libpng15.so.15.*.* libpng15.so.15 2>/dev/null ) || true
    rm -rf "$tmp"
    ok "libpng15 built into $COMPAT_DIR"
  fi

  chgrp -R "$ACCESS_GROUP" "$COMPAT_DIR" 2>/dev/null || true
  chmod -R g+rX,o-rwx "$COMPAT_DIR" 2>/dev/null || true
  say ""
  compat_status
}

cmd_compat() {
  case "${1:-status}" in
    ""|status) compat_status ;;
    build)
      shift
      if [ "${1:-}" = --source ]; then
        [ -r "${2:-}" ] || die "cannot read ${2:-<nothing>}"
        die "carrying a tarball in is not wired up yet -- extract it and run configure/make by hand into $COMPAT_DIR, then: sudo it-fpga compat status"
      fi
      compat_build ;;
    *) die "usage: it-fpga compat [status|build]" ;;
  esac
}

# Libero's installer is a GUI and there is no batch response file for it, so it
# cannot be run unattended the way Xilinx can. What CAN be removed is the reason
# people run it as root.
#
# It needs to write /opt/microchip, so the obvious move is sudo -- and then the
# Qt GUI cannot open the display, because sudo drops DISPLAY and XAUTHORITY and
# root has no X cookie for the user's session. The usual workaround, `xhost
# +SI:localuser:root`, opens the display to root for everything else too.
#
# Instead: hand the directory to the person doing the install, let them run the
# installer as themselves with a working display, and take ownership back
# afterwards. `it-fpga fixup` is what takes it back -- it chowns to root and
# grants the access group, so nothing is left owned by whoever happened to
# install it.
cmd_install_libero() {
  local who="${SUDO_USER:-}"
  [ -n "$who" ] || die "run this with sudo from your own account -- it needs to know who to hand the directory to"

  head2 "Preparing a Libero install for $who"
  say "  Libero has no batch response file, so the GUI has to run -- and it must"
  say "  NOT run as root: sudo drops DISPLAY and XAUTHORITY, and root has no X"
  say "  cookie for your session. That is the \"could not connect to display\""
  say "  you get from sudo, and xhost +SI:localuser:root is not the answer."
  say ""

  install -d -m 0755 "$MCHP_ROOT" 2>/dev/null || true
  chown -R "$who" "$MCHP_ROOT" 2>/dev/null \
    || die "could not hand $MCHP_ROOT to $who"
  ok "$MCHP_ROOT is writable by $who (temporarily)"

  local bin
  bin=$(find "$INSTALLER_DIR" /media/*/* /mnt/* -maxdepth 2 -type f \
          -name 'Libero_SoC_*_lin.bin' 2>/dev/null | sort | tail -1)

  say ""
  say "  Now run it ${B}as yourself, no sudo${R}, in your desktop session:"
  say ""
  say "    ${B}env LD_LIBRARY_PATH=$COMPAT_DIR ${bin:-/path/to/Libero_SoC_*_lin.bin}${R}"
  say ""
  say "  Install directory : ${B}$LIBDIR${R}"
  say "  Common IP vault   : ${B}$VAULT_DIR${R}   -- shared; not your home directory"
  say "  Installation type : ${B}Full${R}   -- and DECLINE its post-install script"
  say ""
  say "  When it finishes, take the tree back:"
  say ""
  say "    ${B}sudo it-fpga fixup${R}"
  say ""
  warn "until you run fixup, $MCHP_ROOT is writable by $who -- that is the point,"
  say  "  and it is also why fixup is not optional."
  say ""
  say "  ${DIM}The handover does not survive a pull: the role re-asserts root:root on${R}"
  say "  ${DIM}$MCHP_ROOT every run. If the installer says \"No write permission for${R}"
  say "  ${DIM}the selected directory\", a pull has been past -- run this again.${R}"
}

# ---------------------------------------------------------------------------
# VENDOR APP TILES.
#
# Both installers write .desktop files into the INSTALLING USER'S HOME
# (~/.local/share/applications). Libero has to be installed as a person rather
# than root -- root has no X cookie for the session -- so the branded tiles for
# Libero SoC, FPExpress, SmartHLS, PFSoC MSS Configurator and Program Debug end
# up belonging to one account. Everybody else gets the single generic tile the
# pull creates, and none of the sub-tools at all.
#
# So: import them system-wide. NOT as a straight copy -- the vendor's Exec line
# launches the binary with no environment, and Libero's 32-bit components need
# the compat libraries and the i386 path or they abort at load. Each import gets
# a wrapper that sets the environment and then runs the vendor's own command, so
# what everyone gets is the vendor's name and icon on a launcher that works.
#
# A command rather than a pull task, for the same reason `fixup` is: it reads a
# 150 GB tree that Ansible has no business walking on every run, and it is a
# once-after-install step.
# ---------------------------------------------------------------------------
IMPORT_PREFIX=/usr/share/applications/fpga-vendor-
WRAP_PREFIX=/usr/local/bin/fpga-vendor-

# Where an installer might have left them: the vendor trees themselves, and the
# per-user directories of anyone who has run one.
vendor_desktops() {
  local d
  for d in "$XROOT" "$MCHP_ROOT"; do
    [ -d "$d" ] && find "$d" -maxdepth 6 -type f -name '*.desktop' 2>/dev/null
  done
  for d in /root/.local/share/applications /home/*/.local/share/applications; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null
  done
}

# First value of a key, ignoring the localised variants (Name[de] and friends).
dget() { sed -nE "s/^$2=(.*)$/\1/p" "$1" 2>/dev/null | head -1; }

import_one() {   # $1 = a vendor .desktop -> 0 if imported
  local f="$1" name exec_line bin icon comment slug wrap

  name="$(dget "$f" Name)"
  exec_line="$(dget "$f" Exec)"
  [ -n "$name" ] && [ -n "$exec_line" ] || return 1

  # Field codes are for file managers passing arguments; a launcher has none.
  exec_line="$(printf '%s' "$exec_line" | sed -E 's/%[fFuUickvm]//g; s/[[:space:]]+$//')"

  # The binary must live inside a vendor tree. That is the whole filter: it
  # keeps this from importing Firefox because someone's home happened to have a
  # .desktop file in it.
  bin="$(printf '%s' "$exec_line" | sed -E 's/^"([^"]*)".*/\1/; t; s/^([^[:space:]]+).*/\1/')"
  case "$bin" in
    "$XROOT"/*|"$MCHP_ROOT"/*) ;;
    *) return 1 ;;
  esac
  [ -e "$bin" ] || return 1

  icon="$(dget "$f" Icon)"
  comment="$(dget "$f" Comment)"
  slug="$(basename "$f" .desktop | tr -cs '[:alnum:]._-' '-' | tr '[:upper:]' '[:lower:]')"
  slug="${slug%-}"
  wrap="$WRAP_PREFIX$slug"

  # An absolute Icon that no longer exists gives a blank tile, which looks like
  # a broken install. Fall back to a themed name in that case only -- a bare
  # name is a theme lookup and is left alone.
  case "$icon" in
    /*) [ -e "$icon" ] || icon="applications-engineering" ;;
    "") icon="applications-engineering" ;;
  esac

  cat > "$wrap" <<WRAP
#!/usr/bin/env bash
# Managed by it-fpga -- do not edit by hand. Regenerate with: it-fpga desktop
#
# $name, imported from
#   $f
# The vendor's launcher runs the binary with no environment. Libero's 32-bit
# components need the compat libraries and the i386 path, or they abort at
# load with a missing library rather than saying what is wrong.
export LD_LIBRARY_PATH="$COMPAT_DIR:/usr/lib/i386-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec $exec_line "\$@"
WRAP
  chmod 0755 "$wrap"; chown root:root "$wrap"

  cat > "$IMPORT_PREFIX$slug.desktop" <<DESK
[Desktop Entry]
Type=Application
Version=1.0
Name=$name
${comment:+Comment=$comment}
Exec=$wrap
Icon=$icon
Terminal=false
Categories=Development;Electronics;
DESK
  chmod 0644 "$IMPORT_PREFIX$slug.desktop"; chown root:root "$IMPORT_PREFIX$slug.desktop"
  ok "$name"
  return 0
}

# An import whose wrapper points at a binary that is gone -- an uninstalled or
# renamed toolchain -- must go too, or the app grid keeps offering something
# that is not there (trap 3: copy only ever creates).
prune_imports() {
  local d slug wrap bin
  for d in "$IMPORT_PREFIX"*.desktop; do
    [ -e "$d" ] || continue
    slug="$(basename "$d" .desktop)"; slug="${slug#fpga-vendor-}"
    wrap="$WRAP_PREFIX$slug"
    bin="$(sed -nE 's/^exec ("?)([^" ]+).*/\2/p' "$wrap" 2>/dev/null | head -1)"
    if [ -z "$bin" ] || [ ! -e "$bin" ]; then
      rm -f "$d" "$wrap"
      warn "removed $slug -- its program is gone"
    fi
  done
}

cmd_desktop() {
  head2 "Vendor app tiles, system-wide"
  say "  The installers write these into the installing user's home, so only"
  say "  that account sees them. Imported here for every member of $ACCESS_GROUP."
  say ""
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    import_one "$f" && n=$((n + 1))
  done < <(vendor_desktops | sort -u)
  [ "$n" -eq 0 ] && warn "no vendor .desktop files found under $XROOT, $MCHP_ROOT or any home"
  prune_imports
  # GNOME reads the desktop DATABASE, not the directory.
  update-desktop-database /usr/share/applications 2>/dev/null || true
  say ""
  [ "$n" -gt 0 ] && say "  ${DIM}$n tile(s). They appear for every user -- no re-login needed.${R}"
  say ""
}

cmd_check() {
  head2 "Vendor checkers"
  # Microchip moves this between releases -- 2025.1 buries it at
  # Libero_SoC/Designer/bin/check_linux_req/check_linux_req.sh -- so find it
  # rather than hardcode a path that silently reports "not found" on the next
  # version and looks like a missing install.
  local c=""
  if [ -d "$LIBDIR" ]; then
    c="$(find "$LIBDIR" -maxdepth 6 -type f -name 'check_linux_req*' \
           -perm -u+x 2>/dev/null | sort | head -1)"
  fi
  if [ -n "$c" ] && [ -x "$c" ]; then
    say "  ${DIM}$c${R}"
    say "  ${DIM}Microchip's checker reports in RPM names -- translate before believing it.${R}"
    say ""
    "$c" 2>&1 | sed 's/^/  /'
  else
    warn "Microchip's check_linux_req not found under $LIBDIR"
  fi

  local v="$XROOT/Vivado/$XVER/bin/unwrapped/lnx64.o/vivado"
  if [ -x "$v" ]; then
    head2 "Vivado shared libraries"
    if ldd "$v" 2>/dev/null | grep -q 'not found'; then
      bad "missing libraries -- this is why the splash screen hangs:"
      ldd "$v" 2>/dev/null | grep 'not found' | sed 's/^/    /'
    else
      ok "every library resolves"
    fi
  fi

  # The i386 half. Ubuntu 24.04 publishes only a curated subset for i386, so
  # some vendor dependencies cannot be installed at all -- the pull says so
  # once, and this says so whenever anyone asks.
  head2 "32-bit dependencies"
  if ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
    bad "i386 multiarch is not enabled -- run: sudo it-pull full"
  else
    local want missing=0 p c
    want="libc6 zlib1g libx11-6 libx11-xcb1 libxext6 libxrender1 libfontconfig1
          libfreetype6 libsm6 libice6 libgtk2.0-0t64 libcanberra-gtk-module
          libxft2 libdrm2 libexpat1 libglapi-mesa libglib2.0-0t64 libgl1
          libuuid1 libxau6 libxcb-dri2-0 libxcb-glx0 libxcb1 libxdamage1
          libxfixes3 libxxf86vm1"
    for p in $want; do
      dpkg -l "$p:i386" 2>/dev/null | grep -q '^ii' && continue
      c=$(apt-cache policy "$p:i386" 2>/dev/null | awk '/Candidate:/{print $2}')
      [ "$missing" -eq 0 ] && warn "not installed:"
      missing=$((missing + 1))
      if [ -z "$c" ] || [ "$c" = "(none)" ]; then
        printf '      %-32s %s\n' "$p:i386" "not published for i386"
      # A candidate is NOT proof it can be installed: apt must resolve the
      # whole dependency closure, and libgtk2.0-0t64:i386 reaches
      # libgnutls30t64:i386 / libgcrypt20:i386, which noble does not satisfy.
      # Simulate answers the real question and does no dpkg work.
      elif apt-get -s -q install -y "$p:i386" >/dev/null 2>&1; then
        printf '      %-32s %s\n' "$p:i386" "available ($c) -- run: sudo it-pull full"
      else
        printf '      %-32s %s\n' "$p:i386" "published ($c) but its dependencies are not"
      fi
    done
    if [ "$missing" -eq 0 ]; then
      ok "every 32-bit dependency is installed"
    else
      say "  ${DIM}Ubuntu has shipped only a curated i386 subset since 19.10. A${R}"
      say "  ${DIM}component needing one of these will not start -- that is the${R}"
      say "  ${DIM}32-bit GUI half of Libero/Synplify and Vivado's cable drivers.${R}"
      say "  ${DIM}Do not pin a version or pull a foreign .deb to force it.${R}"
    fi
  fi

  # FIPS. Both toolchains bundle their own crypto, and this fleet has been
  # bitten twice by a FIPS kernel refusing a bundled algorithm silently.
  if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)" = 1 ]; then
    head2 "FIPS"
    warn "this box runs a FIPS kernel and both toolchains bundle their own crypto"
    say  "  ${DIM}If something behaves strangely rather than failing loudly, check this${R}"
    say  "  ${DIM}first: ClamAV on this fleet reported every file clean while scanning${R}"
    say  "  ${DIM}zero bytes, because FIPS refuses MD5. Prove a full flow -- synthesis,${R}"
    say  "  ${DIM}licence checkout, programming a real device -- before trusting it.${R}"
  fi
  say ""
}

cmd_env() {
  head2 "What a user gets"
  local f
  for f in "$XILINX_ENV" "$MICROCHIP_ENV"; do
    [ -r "$f" ] || continue
    printf '\n  %s%s%s\n' "$B" "$f" "$R"
    grep -E '^export ' "$f" | sed 's/^/      /'
  done
  say ""
  say "  These are in /etc/profile.d, so EVERY user gets them at login -- there"
  say "  is nothing per-user to source and nothing in anyone's home directory."
  say ""
  say "  The heavy PATH is opt-in, per shell:"
  say "    ${B}vivado_env${R}   then  ${B}vivado${R}"
  say "    ${B}libero_env${R}   then  ${B}libero${R}"
  say "  ${DIM}settings64.sh is not sourced for every login shell on the box: it${R}"
  say "  ${DIM}prepends a large PATH and LD_LIBRARY_PATH for users who never touch${R}"
  say "  ${DIM}Vivado, and has been known to break unrelated system tools.${R}"
  say ""
}

case "${1:-status}" in
  ""|status) cmd_status ;;
  license|licence) shift; cmd_license "$@" ;;
  fixup)     cmd_fixup ;;
  desktop)   cmd_desktop ;;
  install)   shift; cmd_install "$@" ;;
  compat)    shift; cmd_compat "$@" ;;
  check)     cmd_check ;;
  cables)    head2 "Programmer cables"; cables_show; say "" ;;
  env)       cmd_env ;;
  *) die "unknown command: $1  (try: it-fpga --help)" ;;
esac
