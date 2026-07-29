#!/usr/bin/env bash
# Host status: hostname, FIPS, Secure Boot, disk, GPU, SSH banner.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
echo "== HOST =="
printf '  hostname    : %s\n' "$(hostname)"
printf '  fips        : %s\n' "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo n/a)"
printf '  secure boot : %s\n' "$(mokutil --sb-state 2>/dev/null | tr -d '\n' || echo unknown)"
printf '  root disk   : '; df -h / | awk 'NR==2{print $3" used / "$2" total ("$5" full)"}'
printf '  ssh banner  : '; head -1 /etc/issue.net 2>/dev/null | grep -qi DCSA && echo "DCSA" || echo "not DCSA (USG/DoD or default)"
echo "  gpu:"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,memory.used,memory.total,driver_version --format=csv,noheader 2>/dev/null | sed 's/^/    /'
else
  echo "    nvidia-smi unavailable (driver not loaded / needs reboot)"
fi
