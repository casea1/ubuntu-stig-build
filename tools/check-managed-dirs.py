#!/usr/bin/env python3
"""A role that WRITES into a shared directory must also CREATE it.

WHY THIS EXISTS. dev_tools copies it-vscode into /opt/it/scripts, but the role
that creates that directory -- it_scripts -- runs ~115 lines later in local.yml.
On an EXISTING box the directory was already there from an earlier pull, so the
bug was invisible; on a FIRST build dev-16 died with "Destination directory
/opt/it/scripts does not exist", and because a play stops at the first failure
every role after dev_tools was skipped -- the box came up UNHARDENED.
fpga_tools, usb_serial and remote_desktop each had the same bug and were each
found the same way, one box at a time. This finds the next one first.

Ansible's `copy` does not create a missing parent directory, so this is a hard
failure rather than a style point. YAML is parsed rather than grepped because
the create-the-directory tasks here are loops of inline dicts and the paths are
Jinja expressions -- both of which defeated a regex version of this check.
"""
import sys, glob, os, yaml

# Shared directories that a LATER role owns. Writing here means creating here.
SHARED = ("/opt/it/scripts", "/etc/stig-build")

# Jinja expressions this repo uses for those paths, resolved to what they mean.
VARS = {"it_scripts_dir": "/opt/it/scripts", "it_dir": "/opt/it"}


def literal(value):
    """Best-effort resolution of a path that may be a Jinja expression."""
    if not isinstance(value, str):
        return None
    out = value
    for name, path in VARS.items():
        if name in out:
            start = out.index("{{")
            end = out.index("}}") + 2
            out = out[:start] + path + out[end:]
            break
    return out.strip().rstrip("/") if "{{" not in out else None


def walk(tasks):
    """Yield every task, descending into block/rescue/always."""
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        nested = False
        for key in ("block", "rescue", "always"):
            if key in task:
                nested = True
                yield from walk(task[key])
        if not nested:
            yield task


def paths_for(task, keys):
    """Every literal path a task names under `keys`, loop items expanded."""
    found = []
    items = task.get("loop") or task.get("with_items") or [None]
    if not isinstance(items, list):
        items = [None]
    for module_args in task.values():
        if not isinstance(module_args, dict):
            continue
        for key in keys:
            raw = module_args.get(key)
            if not isinstance(raw, str):
                continue
            if "item." in raw or raw.strip() in ("{{ item }}",):
                field = raw.split("item.")[-1].split()[0].strip("} \"'") \
                        if "item." in raw else None
                for entry in items:
                    if isinstance(entry, dict) and field in entry:
                        found.append(literal(entry[field]))
                    elif isinstance(entry, str) and field is None:
                        found.append(literal(entry))
            else:
                found.append(literal(raw))
    return [p for p in found if p]


def creates_dir(task):
    """Does this task create a directory (file: state=directory)?"""
    for module, args in task.items():
        if not module.endswith("file") or not isinstance(args, dict):
            continue
        if args.get("state") == "directory":
            return True
    return False


def main():
    rc = 0
    for role in sorted(glob.glob("roles/*/")):
        name = os.path.basename(role.rstrip("/"))
        written, created = set(), set()
        for path in glob.glob(os.path.join(role, "tasks", "**", "*.yml"),
                              recursive=True):
            try:
                with open(path) as fh:
                    tasks = yaml.safe_load(fh)
            except yaml.YAMLError as exc:
                print(f"{name}: cannot parse {path}: {exc}")
                rc = 1
                continue
            for task in walk(tasks):
                if creates_dir(task):
                    created.update(paths_for(task, ("path", "dest")))
                else:
                    written.update(paths_for(task, ("dest", "path")))

        for shared in SHARED:
            # A file written INTO the shared dir (or a subdirectory of it).
            if not any(p.startswith(shared + "/") for p in written):
                continue
            if any(c == shared or c.startswith(shared + "/") for c in created):
                continue
            print(f"{name}: writes into {shared} but never creates it")
            rc = 1

    if rc == 0:
        print("OK: every role that writes into a shared dir creates it first")
    return rc


if __name__ == "__main__":
    sys.exit(main())
