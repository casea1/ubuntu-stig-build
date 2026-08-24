#!/usr/bin/env python3
"""Strip the non-compliant privileged-command lines from a legacy audit rules file.

Background. A box first built under the pre-USG ansible-lockdown role carries
/etc/audit/rules.d/stig.rules, whose privileged-command rules use the old form:

    -a always,exit -F path=/usr/bin/chage -F perm=x -F auid>=1000 -F auid!=-1 -k privileged-chage

USG writes the same commands in the form the benchmark's OVAL requires:

    -a always,exit -F path=/usr/bin/chage -F perm=x -F auid>=1000 -F auid!=unset -F key=privileged

Both load fine. But each audit_rules_privileged_commands_* OVAL requires EVERY
matching line to conform, so the legacy line fails the rule even though the
compliant line sits right beside it. That was 22 findings on ASP-2.

Retiring the whole file fixed those 22 and broke 21 others -- the same file was
the ONLY source of the session-event, usergroup-modification, xattr, sudoers,
login-event and cron.d rules, which USG does not write at all. Deleting it
traded one set of findings for another.

So prune instead of delete. Only lines that actually break a rule are removed:
a `-F path=` rule carrying the legacy `auid!=-1`. Watch rules (-w) and syscall
rules keep working -- their OVALs accept the legacy form, which is why they
passed before -- so coverage is preserved and nothing is silently lost.

Usage: audit-rules-prune.py FILE [RULESDIR] [--check]
  --check  report what would change, write nothing (exit 1 if changes pending)
"""
import glob
import os
import re
import shutil
import sys

# A privileged-command rule in the legacy form: path-based AND auid!=-1.
LEGACY = re.compile(r"^\s*-a\s+always,exit\b.*-F\s+path=(\S+).*-F\s+auid!=-1\b")
# The form the strict OVALs require.
COMPLIANT = re.compile(r"^\s*-a\s+always,exit\b.*-F\s+path=(\S+).*-F\s+auid!=unset\b.*-F\s+key=")


def compliant_paths(rulesdir, exclude):
    """Paths that already have a benchmark-conformant rule somewhere else.

    A legacy line is only safe to drop when the path is covered elsewhere.
    modprobe is the case that proves it: not every privileged-command OVAL is
    strict, so before this file was retired modprobe PASSED on its legacy line
    alone. Dropping that line without a replacement turns a passing rule into a
    failing one -- which is exactly the trade the wholesale retirement made,
    21 times over.
    """
    covered = set()
    for path in glob.glob(os.path.join(rulesdir, "*.rules")):
        if os.path.abspath(path) == os.path.abspath(exclude):
            continue
        try:
            with open(path) as fh:
                for line in fh:
                    m = COMPLIANT.match(line)
                    if m:
                        covered.add(m.group(1))
        except OSError:
            continue
    return covered


def prune(path, rulesdir=None, check=False):
    rulesdir = rulesdir or os.path.dirname(os.path.abspath(path))
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return 2

    covered = compliant_paths(rulesdir, path)
    keep, dropped, orphans = [], [], []
    for line in lines:
        m = LEGACY.match(line)
        if m and m.group(1) in covered:
            dropped.append((line, m.group(1)))
        else:
            keep.append(line)
            if m:
                orphans.append(m.group(1))

    for o in sorted(set(orphans)):
        print(f"    KEEPING legacy rule for {o}: nothing else covers that path."
              f" Add it to usg_audit_privileged_commands to get a compliant rule.")

    if not dropped:
        print(f"OK {path}: nothing safe to drop ({len(lines)} lines kept)")
        return 0

    print(f"{path}: dropping {len(dropped)} legacy line(s) already covered elsewhere,"
          f" keeping {len(keep)}")
    for _, who in dropped:
        print(f"    - {who}")
    if check:
        return 1

    shutil.copy2(path, path + ".pre-prune")
    with open(path, "w") as fh:
        fh.writelines(keep)
    print(f"    wrote {path} (original at {path}.pre-prune)")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__)
        sys.exit(2)
    sys.exit(prune(args[0], args[1] if len(args) > 1 else None, "--check" in sys.argv))
