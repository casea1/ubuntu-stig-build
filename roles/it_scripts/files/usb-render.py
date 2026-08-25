#!/usr/bin/env python3
"""Render `usbguard list-devices` into something a person can read.

The raw output is one long line per device, most of it base64 hashes, with the
two facts that matter buried: what KIND of device it is (the class byte, shown
as "with-interface 09:00:00") and what it is plugged into (parent-hash). On a
laptop with a dock that is twenty near-identical lines and no way to tell a
keyboard from a flash drive.

So: decode the class, build the tree from parent-hash, drop the hashes, and
flag the classes that can act on their own initiative -- a keyboard can type
(BadUSB), storage can carry data out, a radio can reach the network. Those are
the ones worth a second look before authorising.

Reads the raw output on stdin. `it-usb list --raw` skips this entirely.
"""
import re, sys


# USB base class -> what it actually is. The raw output shows "with-interface
# 09:00:00", which tells a human nothing; the class byte is the single most
# useful fact about a device on an allow-list.
CLASS = {
    "00": "per-interface", "01": "audio", "02": "network", "03": "HID",
    "05": "physical", "06": "imaging", "07": "printer", "08": "MASS STORAGE",
    "09": "hub", "0a": "network-data", "0b": "smartcard", "0d": "content-sec",
    "0e": "video", "0f": "healthcare", "10": "audio/video", "11": "billboard",
    "12": "USB-C bridge", "dc": "diagnostic", "e0": "wireless", "ef": "misc",
    "fe": "app-specific", "ff": "vendor",
}
# Classes that can act on their own initiative: a keyboard can type, storage can
# carry data in or out. These are the ones worth a second look on this fleet.
RISKY = {"03", "08", "e0"}


def parse(text):
    devs = []
    for line in text.splitlines():
        m = re.match(r"^\s*(\d+):\s+(allow|block|reject)\s+(.*)$", line)
        if not m:
            continue
        num, state, rest = m.group(1), m.group(2), m.group(3)
        def field(name):
            mm = re.search(name + r'\s+"([^"]*)"', rest)
            return mm.group(1) if mm else ""
        vid = re.search(r"\bid\s+(\S+)", rest)
        ifaces = re.findall(r"\b([0-9a-f]{2}):[0-9a-f]{2}:[0-9a-f]{2}", rest)
        devs.append({
            "n": num, "state": state,
            "id": vid.group(1) if vid else "?",
            "name": (field("name") or "(unnamed)").strip(),
            "port": field("via-port"), "serial": field("serial"),
            "hash": field("hash"), "parent": field("parent-hash"),
            "classes": sorted(set(ifaces)),
        })
    return devs


def classify(d):
    if not d["classes"]:
        return ""
    names, risky = [], False
    for c in d["classes"]:
        names.append(CLASS.get(c, c))
        if c in RISKY:
            risky = True
    seen, out = set(), []
    for n in names:
        if n not in seen:
            seen.add(n); out.append(n)
    return ("! " if risky else "  ") + ",".join(out)


def render(devs, colour=True):
    by_hash = {d["hash"]: d for d in devs if d["hash"]}
    kids, roots = {}, []
    for d in devs:
        if d["parent"] and d["parent"] in by_hash:
            kids.setdefault(d["parent"], []).append(d)
        else:
            roots.append(d)
    G, R, Y, Z = ("\033[32m", "\033[31m", "\033[33m", "\033[0m") if colour else ("",) * 4
    out = []

    def emit(d, depth):
        col = G if d["state"] == "allow" else R
        label = "allow" if d["state"] == "allow" else d["state"].upper()
        cls = classify(d)
        mark = (Y + "!" + Z) if cls.startswith("!") else " "
        names = cls[2:].split(",")
        shown = names[0] + ("+" if len(names) > 1 else "")
        # The device NAME goes last so the tree indent has room to be a tree.
        tree = ("   " * (depth - 1) + "\u2514\u2500 ") if depth else ""
        out.append(f"{d['n']:>4}  {col}{label:<6}{Z}{mark} {d['id']:<10} "
                   f"{shown:<14} {d['port']:<9} {tree}{d['name']}")
        for k in sorted(kids.get(d["hash"], []), key=lambda x: int(x["n"])):
            emit(k, depth + 1)

    for r in sorted(roots, key=lambda x: int(x["n"])):
        emit(r, 0)
    return "\n".join(out)


if __name__ == "__main__":
    text = sys.stdin.read()
    devs = parse(text)
    if not devs:
        print("(no devices)"); sys.exit(0)
    colour = "--no-colour" not in sys.argv and sys.stdout.isatty()
    print(f"{'#':>4}  {'STATE':<7} {'VID:PID':<10} {'CLASS':<14} {'PORT':<9} DEVICE")
    print(render(devs, colour))
    n_block = sum(1 for d in devs if d["state"] != "allow")
    risky = [d for d in devs if any(c in RISKY for c in d["classes"])]
    print()
    print(f"{len(devs)} device(s), {n_block} not authorised."
          f"  '!' = can act on its own (keyboard, storage, radio): {len(risky)}")
    if n_block:
        print("Authorise one with:  sudo it-usb allow <#> --permanent"
              "   (or: sudo it-usb enroll)")
