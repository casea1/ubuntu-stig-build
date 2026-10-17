#!/usr/bin/env python3
"""Every `when:` / `failed_when:` / `changed_when:` condition must be a string
(or a list of strings).

An unquoted condition containing ": " -- e.g. `- x is search('Status: active')`
-- is parsed by YAML as a MAPPING, and Ansible treats a non-empty mapping as
true, so the guard silently always passes. It let the legacy firewall task run
on a VM without ufw. Quote the whole condition.
"""
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEYS = ("when", "failed_when", "changed_when", "until")


def walk(node, path):
    if isinstance(node, dict):
        for k in KEYS:
            if k in node:
                v = node[k]
                items = v if isinstance(v, list) else [v]
                for it in items:
                    if not isinstance(it, (str, bool)):
                        yield f"{path}: {k}: {it!r} is a {type(it).__name__}, not a string -- quote it"
        for v in node.values():
            yield from walk(v, path)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v, path)


files = subprocess.check_output(["git", "ls-files", "*.yml"], cwd=ROOT).decode().split()
problems = []
for f in files:
    if not (f.startswith("roles/") or f in ("local.yml", "legacy.yml")):
        continue
    for doc in yaml.safe_load_all((ROOT / f).read_text()):
        problems.extend(walk(doc, f))

if problems:
    print("FAIL")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print(f"OK: every condition in {len(files)} YAML files is a string")
