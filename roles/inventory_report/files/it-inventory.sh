#!/usr/bin/env bash
# it-inventory -- basic hardware/system inventory for post-imaging reference.
# Writes a plain-text report to <dir>/inventory-<hostname>.txt (default dir /opt/it).
# Re-run any time (needs root for serials/SMART):  sudo it-inventory
# Re-run AFTER the post-build reboot for accurate FIPS + GPU state.
#
# Deliberately basic for now (serials, MACs, BIOS, disks, GPU). Extend as needed.
set -u

OUT_DIR="${1:-/opt/it}"
HOST="$(hostname)"
OUT="${OUT_DIR}/inventory-${HOST}.txt"

have() { command -v "$1" >/dev/null 2>&1; }
sec()  { printf '\n===== %s =====\n' "$1"; }
kv()   { printf '%-16s: %s\n' "$1" "${2:-n/a}"; }

mkdir -p "$OUT_DIR" 2>/dev/null

{
echo "IT INVENTORY REPORT"
kv "Host"        "$HOST"
kv "Generated"   "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
kv "Note"        "FIPS/GPU reflect the moment this ran; re-run after reboot for final state"

sec "System / chassis"
if have dmidecode; then
  kv "Manufacturer" "$(dmidecode -s system-manufacturer 2>/dev/null)"
  kv "Model"        "$(dmidecode -s system-product-name 2>/dev/null)"
  kv "Service tag"  "$(dmidecode -s system-serial-number 2>/dev/null)"   # Dell service tag
  kv "System UUID"  "$(dmidecode -s system-uuid 2>/dev/null)"
  kv "Chassis SN"   "$(dmidecode -s chassis-serial-number 2>/dev/null)"
else
  echo "(dmidecode not installed)"
fi

sec "BIOS / firmware"
if have dmidecode; then
  kv "BIOS vendor"  "$(dmidecode -s bios-vendor 2>/dev/null)"
  kv "BIOS version" "$(dmidecode -s bios-version 2>/dev/null)"
  kv "BIOS date"    "$(dmidecode -s bios-release-date 2>/dev/null)"
fi
if have mokutil; then kv "Secure Boot" "$(mokutil --sb-state 2>/dev/null | tr '\n' ' ')"; fi
kv "FIPS enabled" "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo n/a)"
if [ -e /sys/class/tpm/tpm0 ]; then
  kv "TPM" "present (major $(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo '?'))"
else
  kv "TPM" "not found"
fi

sec "CPU / memory"
if have lscpu; then lscpu | grep -E 'Model name|^Socket|^Core|^Thread|^CPU\(s\)'; fi
if have free; then free -h | sed -n '1,2p'; fi
if have dmidecode; then
  echo "-- DIMMs (size | manufacturer | part | serial) --"
  dmidecode -t memory 2>/dev/null | awk '
    /Memory Device/      { size=""; man=""; part=""; sn="" }
    /^\tSize:/           { sub(/^\tSize: */,""); size=$0 }
    /^\tManufacturer:/   { sub(/^\tManufacturer: */,""); man=$0 }
    /^\tPart Number:/    { sub(/^\tPart Number: */,""); part=$0 }
    /^\tSerial Number:/  { sub(/^\tSerial Number: */,""); sn=$0;
                           if (size !~ /No Module Installed/ && size != "")
                             printf "  %s | %s | %s | %s\n", size, man, part, sn }'
fi

sec "Storage (disks + serials)"
if have lsblk; then
  lsblk -d -o NAME,TYPE,SIZE,MODEL,SERIAL,ROTA 2>/dev/null | grep -vE '^loop|^sr'
fi
if have nvme; then
  echo "-- nvme list --"
  nvme list 2>/dev/null
fi
if have smartctl; then
  for d in /dev/sd? /dev/nvme?n?; do
    [ -e "$d" ] || continue
    echo "-- $d --"
    smartctl -i "$d" 2>/dev/null | grep -E 'Model|Serial|Firmware|User Capacity|Rotation Rate|Form Factor'
  done
fi

sec "Volume layout (LVM / LUKS)"
if have lsblk; then lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | grep -E 'crypt|lvm|part|disk'; fi
if have vgs;  then echo "-- vgs --"; vgs 2>/dev/null; fi
if have lvs;  then echo "-- lvs --"; lvs 2>/dev/null; fi

sec "Network interfaces (MAC / IP)"
for i in /sys/class/net/*; do
  n="$(basename "$i")"
  [ "$n" = "lo" ] && continue
  mac="$(cat "$i/address" 2>/dev/null)"
  state="$(cat "$i/operstate" 2>/dev/null)"
  ipa="$(ip -o -4 addr show "$n" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
  printf '  %-12s MAC=%s  state=%s  ipv4=%s\n' "$n" "${mac:-?}" "${state:-?}" "${ipa:-none}"
done

sec "GPU (NVIDIA)"
if have nvidia-smi; then
  nvidia-smi --query-gpu=index,name,serial,uuid,memory.total,vbios_version,driver_version \
    --format=csv 2>/dev/null || nvidia-smi -L 2>/dev/null || echo "(nvidia-smi present but query failed)"
else
  echo "(nvidia-smi not available -- the driver loads after the post-build reboot)"
fi

sec "Listening ports -> process -> package"
# Checklist: "capture port traffic and associated processes to a report file for
# installed software". Every LISTENING socket, the process behind it, and the
# package that owns that binary. Needs root for the pid/process columns.
if have ss; then
  printf '  %-5s %-24s %-22s %s\n' PROTO LISTEN PROCESS PACKAGE
  ss -H -tulpn 2>/dev/null | while read -r proto _ _ _ local _ rest; do
    pname=$(printf '%s' "$rest" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p')
    pid=$(printf '%s' "$rest"  | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
    pkg="-"
    if [ -n "$pid" ] && [ -r "/proc/$pid/exe" ]; then
      exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
      if [ -n "$exe" ] && have dpkg; then
        pkg=$(dpkg -S "$exe" 2>/dev/null | cut -d: -f1 | head -1)
        [ -z "$pkg" ] && pkg="(unpackaged: $exe)"
      fi
    fi
    printf '  %-5s %-24s %-22s %s\n' "$proto" "$local" "${pname:-?}${pid:+/$pid}" "$pkg"
  done
  echo
  echo "  NOTE: container-published ports show as docker-proxy/dockerd, not the"
  echo "  service inside. Cross-reference with: docker ps --format '{{.Names}} {{.Ports}}'"
  if have docker; then
    echo
    echo "  Container port publications:"
    docker ps --format '    {{.Names}}  {{.Ports}}' 2>/dev/null || echo "    (docker present, not queryable as this user)"
  fi
else
  echo "(ss not available -- install iproute2)"
fi

sec "Operating system"
kv "Hostname" "$HOST"
if have lsb_release; then kv "Distro" "$(lsb_release -ds 2>/dev/null)"; fi
kv "Kernel" "$(uname -r)"

echo
echo "End of report."
} > "$OUT" 2>&1

chmod 0640 "$OUT" 2>/dev/null
echo "Wrote $OUT"
