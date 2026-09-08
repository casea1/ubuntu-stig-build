#!/usr/bin/env python3
"""Ordering faults inside an Ansible role that only a FIRST build can expose.

Two checks, both learned the same way -- from a box, not from a review:

  1. A role that WRITES into a shared directory must also CREATE it.
  2. A systemd unit's ExecStart must not name a script the role installs LATER.
  3. A role must not RUN a command that only a LATER role in local.yml installs.

WHY THIS EXISTS. dev_tools copies it-vscode into /opt/it/scripts, but the role
that creates that directory -- it_scripts -- runs ~115 lines later in local.yml.
On an EXISTING box the directory was already there from an earlier pull, so the
bug was invisible; on a FIRST build dev-16 died with "Destination directory
/opt/it/scripts does not exist", and because a play stops at the first failure
every role after dev_tools was skipped -- the box came up UNHARDENED.
fpga_tools, usb_serial and remote_desktop each had the same bug and were each
found the same way, one box at a time. This finds the next one first.

Check 2 is the same bug one layer down. usb_serial wrote
usb-serial-bind.service, told systemd to start it, and installed the
usb-serial.sh its ExecStart names three tasks later. On dev-16 that was
203/EXEC -- and again the play stopped and the box went unhardened. And again
an existing box could not show it: the script was already there from the
previous pull.

The shared lesson is that a first build exercises ordering no later pull ever
will, so "it worked on the fleet" says nothing about it.

Ansible's `copy` does not create a missing parent directory, so check 1 is a
hard failure rather than a style point. YAML is parsed rather than grepped
because the create-the-directory tasks are loops of inline dicts and the paths
are Jinja expressions -- both of which defeated a regex version of this check.
"""
import re
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


def exec_paths(task):
    """Scripts an inline systemd unit's ExecStart= lines name."""
    found = []
    for module, args in task.items():
        if not isinstance(args, dict):
            continue
        body = args.get("content")
        if not isinstance(body, str) or "ExecStart" not in body:
            continue
        # A unit that guards itself is not a fault, and reporting it anyway is
        # how a checker earns its reputation for crying wolf (trap 38).
        # `ExecStart=-` and `ExecStartPre=-` tell systemd to ignore a failure;
        # ConditionPathExists= skips the unit entirely when the file is absent.
        if "ConditionPathExists=" in body:
            continue
        for line in body.splitlines():
            match = re.match(r"\s*ExecStart=(?!-)(.+)$", line)
            if not match:
                continue
            # The whole remainder, resolved BEFORE splitting: a Jinja path
            # contains spaces ("{{ it_scripts_dir | default(...) }}/x.sh"), so
            # taking the first token first captures "{{" and finds nothing --
            # which is exactly how the first version of this check passed a
            # file that had the bug in it.
            resolved = literal(match.group(1))
            if resolved and resolved.split():
                found.append(resolved.split()[0])
    return found


def check_exec_order(role_name, task_files):
    """A unit must not run a script its own role installs later in the file.

    Only compared WITHIN one tasks file, where the order is unambiguous.
    Across files the order comes from main.yml's imports, and guessing at it
    would produce the false positives that get a checker ignored.
    """
    rc = 0
    for path in task_files:
        try:
            with open(path) as fh:
                tasks = list(walk(yaml.safe_load(fh)))
        except yaml.YAMLError:
            continue        # check 1 already reported the parse failure

        installed = {}      # script path -> index of the task installing it
        for index, task in enumerate(tasks):
            for dest in paths_for(task, ("dest",)):
                if not creates_dir(task):
                    installed.setdefault(dest, index)

        for index, task in enumerate(tasks):
            for script in exec_paths(task):
                if script not in installed or installed[script] <= index:
                    continue
                print(f"{role_name}: {os.path.basename(path)} defines a unit "
                      f"running {script} at task {index + 1}, but installs it "
                      f"at task {installed[script] + 1}")
                rc = 1
    return rc


def role_order(playbook="local.yml"):
    """Role names in the order local.yml runs them."""
    try:
        with open(playbook) as fh:
            plays = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError):
        return []
    order = []
    for play in plays or []:
        for entry in (play.get("roles") or []):
            name = entry.get("role") if isinstance(entry, dict) else entry
            if isinstance(name, str) and name not in order:
                order.append(name)
    return order


def run_paths(task):
    """Absolute paths a command:/shell: task executes."""
    found = []
    for module, args in task.items():
        if not module.endswith(("command", "shell")):
            continue
        raw = args.get("cmd") if isinstance(args, dict) else args
        if isinstance(args, dict) and raw is None:
            raw = args.get("_raw_params")
        if not isinstance(raw, str):
            continue
        first = raw.strip().split()[0] if raw.strip() else ""
        if first.startswith("/"):
            found.append(first)
    return found


def provided_links(role_dir):
    """Commands a role installs through a LOOP over its defaults.

    it_scripts -- the role that installs most of the it-* commands -- creates
    them with `dest: /usr/local/sbin/{{ item.link }}` over a list built in
    defaults/main.yml. That path is unresolvable as a literal, so without this
    the cross-role check saw it_scripts as providing NOTHING and passed by
    being blind rather than by being satisfied.
    """
    found = set()
    for name in ("defaults", "vars"):
        for path in glob.glob(os.path.join(role_dir, name, "*.yml")):
            try:
                with open(path) as fh:
                    data = yaml.safe_load(fh)
            except (OSError, yaml.YAMLError):
                continue
            for value in (data or {}).values():
                if not isinstance(value, list):
                    continue
                for entry in value:
                    if isinstance(entry, dict) and isinstance(entry.get("link"), str):
                        found.add("/usr/local/sbin/" + entry["link"])
    return found


def check_cross_role(provides, consumes, order):
    """A role must not run a command a LATER role installs.

    This is the check that would have caught dev-16's first failure without a
    box having to find it. Paths nothing in this repo installs are system
    binaries and are ignored.
    """
    rc = 0
    position = {name: i for i, name in enumerate(order)}
    for role, wanted in sorted(consumes.items()):
        if role not in position:
            continue
        for path in sorted(wanted):
            owners = [r for r, paths in provides.items() if path in paths]
            if not owners or role in owners:
                continue                      # system binary, or self-provided
            first = min((position.get(r, len(order)) for r in owners))
            if first > position[role]:
                late = [r for r in owners if position.get(r) == first]
                print(f"{role}: runs {path}, which {late[0]} installs -- "
                      f"and {late[0]} runs LATER in local.yml")
                rc = 1
    return rc


def main():
    rc = 0
    provides, consumes = {}, {}
    order = role_order()
    for role in sorted(glob.glob("roles/*/")):
        name = os.path.basename(role.rstrip("/"))
        written, created = set(), set()
        task_files = sorted(glob.glob(os.path.join(role, "tasks", "**", "*.yml"),
                                      recursive=True))
        rc |= check_exec_order(name, task_files)
        for path in task_files:
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

        provides[name] = (set(created) | {d for d in written if d}
                          | provided_links(role))
        consumes[name] = set()
        for path in task_files:
            try:
                with open(path) as fh:
                    tasks = list(walk(yaml.safe_load(fh)))
            except yaml.YAMLError:
                continue
            for task in tasks:
                consumes[name].update(run_paths(task))
                consumes[name].update(exec_paths(task))

        for shared in SHARED:
            # A file written INTO the shared dir (or a subdirectory of it).
            if not any(p.startswith(shared + "/") for p in written):
                continue
            if any(c == shared or c.startswith(shared + "/") for c in created):
                continue
            print(f"{name}: writes into {shared} but never creates it")
            rc = 1

    rc |= check_cross_role(provides, consumes, order)

    if rc == 0:
        print("OK: shared dirs created before use; no unit runs a script "
              "its role installs later; no role runs a command a later "
              "role installs")
    return rc


if __name__ == "__main__":
    sys.exit(main())
