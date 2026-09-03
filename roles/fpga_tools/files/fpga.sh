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
#   it-fpga fixup              apply the post-install fixes to an INSTALLED tree
#   it-fpga cables             what is plugged in, and is it authorised
#   it-fpga env                the environment a user gets, and how to load it
#
# A licence change is written to BOTH the live /etc/profile.d scripts (so a new
# shell has it at once) AND /opt/it/site.yml (so the next ansible-pull renders
# the same thing). Changing only one is the trap this avoids.
set -uo pipefail

SITE_YML="${SITE_YML:-/opt/it/site.yml}"
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
LIC_MCHP="$(env_var "$MICROCHIP_ENV" LM_LICENSE_FILE)"
LIC_XLNX="$(env_var "$XILINX_ENV" XILINXD_LICENSE_FILE)"

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
      [ -x "$LIBDIR/Libero/bin64/libero" ] && ok "  libero           present" \
        || warn "  libero           NOT found at $LIBDIR/Libero/bin64/libero"
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
  else
    say "  ${DIM}Microchip support is switched off (fpga_microchip_enabled).${R}"
  fi

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
    warn "USBGuard          ACTIVE -- a cable must be enrolled before udev ever sees it"
    say  "                    ${DIM}sudo it-usb enroll     (then re-plug)${R}"
    say  "                    ${DIM}sudo it-usb blocked    what is being refused right now${R}"
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
cmd_fixup() {
  local n=0
  head2 "Post-install fixes"

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

cmd_check() {
  head2 "Vendor checkers"
  local c="$LIBDIR/bin/check_linux_req"
  if [ -x "$c" ]; then
    say "  ${DIM}Microchip's checker reports in RPM names -- translate before believing it.${R}"
    say ""
    "$c" 2>&1 | sed 's/^/  /'
  else
    warn "Microchip's check_linux_req not found at $c"
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
  check)     cmd_check ;;
  cables)    head2 "Programmer cables"; cables_show; say "" ;;
  env)       cmd_env ;;
  *) die "unknown command: $1  (try: it-fpga --help)" ;;
esac
