#!/usr/bin/env python3
"""Validate that /etc/pam.d/common-auth can actually authenticate.

Written after an EMI laptop locked its operator out with a common-auth that
LOOKED correct: pam_unix.so was present, every module existed, the file was
well-formed. It denied every login anyway, because the jump offsets were wrong.

    auth [success=2 default=ignore] pam_unix.so     <- on success, skip 2
    auth [success=1 default=ignore] pam_sss.so
    auth [default=die] pam_faillock.so authfail     <- skipped
    auth [success=1 default=ignore] pam_faillock.so authsucc   <- lands, skip 1
    auth [default=die] pam_faillock.so authfail     <- skipped
    auth [success=1 default=ignore] pam_faillock.so authsucc   <- lands, skip 1
    auth required pam_faildelay.so                  <- skipped
    auth requisite pam_deny.so                      <- LANDS HERE: denied

pam_faillock had been inserted twice by a line-editing task and pam_unix's
success=2 was never recalculated. A correct password authenticated and was then
walked into pam_deny. No syntax check catches this; you have to follow the jumps.

So: follow the jumps. Assume the primary authenticator succeeds and see where
control ends up. Reaching pam_permit or running off the end is success; landing
on pam_deny means the stack rejects every password on the box.

Exit 0 = the stack can authenticate. Exit 1 = it cannot. Exit 2 = cannot tell.
"""
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/etc/pam.d/common-auth"


def parse(path):
    """-> [(control, module, raw)] for auth lines only, in file order."""
    out = []
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError as exc:
        print(f"UNKNOWN cannot read {path}: {exc}")
        sys.exit(2)
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^auth\s+(\[[^\]]*\]|\S+)\s+(\S+)", line)
        if m:
            out.append((m.group(1), m.group(2), line))
    return out


def jump(control):
    """Modules to skip when this line returns PAM_SUCCESS."""
    if control.startswith("["):
        m = re.search(r"\bsuccess=(\d+)\b", control)
        if m:
            return int(m.group(1))
        if re.search(r"\bsuccess=(ok|done)\b", control):
            return 0
        return 0
    return 0  # required / requisite / optional all fall through


stack = parse(PATH)
if not stack:
    print(f"UNKNOWN no auth lines in {PATH}")
    sys.exit(2)

# Duplicate module+args lines are the fingerprint of a line-editing task that
# ran more than once, which is how the offsets get out of step in the first
# place. Worth reporting even when the walk happens to survive them.
seen, dupes = set(), []
for _, mod, raw in stack:
    key = raw.split(None, 1)[1] if " " in raw else raw
    key = re.sub(r"^\S+\s+", "", raw)  # drop the control field
    if key in seen:
        dupes.append(key)
    seen.add(key)

idx = next((i for i, (_, mod, _) in enumerate(stack) if mod.startswith("pam_unix")), None)
if idx is None:
    print(f"BROKEN {PATH} has no pam_unix.so auth line -- no password authentication")
    sys.exit(1)

# Walk the success path from pam_unix.
path_taken, i, steps = [], idx, 0
while 0 <= i < len(stack) and steps <= len(stack) + 2:
    control, mod, _ = stack[i]
    path_taken.append(mod)
    if mod.startswith("pam_deny"):
        print(f"BROKEN {PATH}: a successful password lands on {mod} and is DENIED")
        print("       success path: " + " -> ".join(path_taken))
        if dupes:
            print("       duplicate lines (likely cause): " + "; ".join(sorted(set(dupes))))
        sys.exit(1)
    if mod.startswith("pam_permit"):
        break
    if control.startswith("sufficient"):
        break
    i += 1 + jump(control)
    steps += 1
else:
    if steps > len(stack) + 2:
        print(f"BROKEN {PATH}: the jump chain loops")
        sys.exit(1)

print(f"OK {PATH}: success path reaches " + " -> ".join(path_taken))
if dupes:
    print("WARNING duplicate auth lines present: " + "; ".join(sorted(set(dupes))))
sys.exit(0)
