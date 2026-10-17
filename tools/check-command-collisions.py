#!/usr/bin/env python3
"""Two roles must never install the same command name, and a retired name
must not be one something still installs.

Both have happened: it_scripts listed `it-codeserver` as retired and deleted
dev_tools' copy on every pull; usb_serial and it_scripts both installed
`it-serial`, so the later one silently replaced the other.

Scans local.yml's roles (legacy is a separate playbook on separate boxes, and
repeats it_scripts' names on purpose) for task `dest:` paths under
/usr/local/sbin and /usr/local/bin, plus it_scripts' link lists.
Exit 1 on any finding.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = re.compile(r"^/usr/local/s?bin/([A-Za-z0-9_.+-]+)$")
SKIP_ROLES = {"legacy"}


def walk(node):
    """Yield every mapping in a task tree, blocks included."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def task_files(role):
    return sorted((ROOT / "roles" / role / "tasks").glob("*.yml"))


installed = {}  # name -> set of "role/file"


def add(name, where):
    installed.setdefault(name, set()).add(where)


roles = sorted(p.name for p in (ROOT / "roles").iterdir() if p.is_dir())
for role in roles:
    if role in SKIP_ROLES:
        continue
    for tf in task_files(role):
        try:
            doc = yaml.safe_load(tf.read_text()) or []
        except yaml.YAMLError as e:
            print(f"YAML error in {tf}: {e}")
            sys.exit(1)
        for m in walk(doc):
            dest = m.get("dest")
            if isinstance(dest, str):
                hit = BIN.match(dest.strip())
                if hit:
                    add(hit.group(1), f"{role}/{tf.name}")

defaults = yaml.safe_load((ROOT / "roles/it_scripts/defaults/main.yml").read_text())
for key in ("it_scripts_common", "it_scripts_ai", "it_scripts_emi", "it_scripts_public"):
    for entry in defaults.get(key) or []:
        link = (entry or {}).get("link")
        if link:
            add(link, f"it_scripts ({key})")

problems = []
for name, where in sorted(installed.items()):
    # it_scripts installs each list entry through two tasks (file + link); one
    # role installing a name twice is not a collision.
    owners = {w.split("/")[0].split(" ")[0] for w in where}
    if len(owners) > 1:
        problems.append(f"{name}: installed by more than one role -- {', '.join(sorted(where))}")

for name in defaults.get("it_scripts_retired_links") or []:
    if name in installed:
        problems.append(f"{name}: listed in it_scripts_retired_links but still installed by "
                        f"{', '.join(sorted(installed[name]))} -- it is deleted on every pull")

if problems:
    print("FAIL")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print(f"OK: {len(installed)} command names, each installed by one role; no retired name is still installed")
