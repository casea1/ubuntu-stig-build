#!/usr/bin/env python3
"""it-ckl -- build a DISA STIG checklist with the answers already filled in.

The manual workflow is: run a SCAP scan, import the results into STIG Viewer,
then hand-answer everything SCAP did not cover. The second half is the tedious
part, and most of it is the same answer on every box in the fleet -- the same
deviations, the same compensating controls, the same POA&M wording. That does
not need a human retyping it per machine; it needs to live in the repo.

So this merges three things into one checklist:

  1. the manual STIG XCCDF   -- the skeleton: every V-ID DISA defines
  2. the SCAP results        -- authoritative status for every automated rule
  3. answers.yml (from this repo) -- our adjudication of everything else

What comes out is a .cklb (STIG Viewer 3) or .ckl (STIG Viewer 2) where
Not_Reviewed means "genuinely needs a human on THIS box", not "nobody has typed
it in yet".

Usage:
  it-ckl [--stig FILE] [--results FILE] [--answers FILE]
         [--out FILE] [--format cklb|ckl|both] [--summary]

Everything has a default; on a built box `sudo it-ckl` is enough.

  --stig      manual STIG XCCDF (*Manual-xccdf.xml). Default: newest in
              /opt/ia/stig/. Download once from cyber.mil and drop it there --
              it is public, and it is the only input this cannot generate.
  --results   oscap results. Default: the newest file that actually contains
              rule-results, tried in order -- stig-viewer-*, stig-arf-*, then
              the `usg audit` output in /opt/ia. `oscap --stig-viewer` output
              can be empty of rule-results depending on the content, which is
              why this falls through rather than trusting one filename.
  --map       SCAP datastream used to translate SSG rule ids to STIG ids.
              Default: the SSG content on the box. Only needed when scanning
              with SSG content -- see below.
  --answers   the repo's adjudications. Default: /opt/ia/stig/answers.yml

WHY --map EXISTS: the manual STIG names rules UBTU-24-200640 / V-270691, but a
scan run against ComplianceAsCode SSG content names the same rule
xccdf_org.ssgproject.content_rule_banner_etc_issue_net. There is no shared key,
so a naive join matches nothing. SSG's datastream carries the link as an xccdf
<reference> on each Rule, so this reads it and builds the mapping. Scanning with
DISA's own SCAP benchmark instead makes the ids line up directly and no mapping
is needed; both work.

Several SSG rules can map to one STIG id. In that case ANY failure makes the
STIG rule Open -- a rule is not satisfied just because part of it is.
"""
import argparse
import glob
import json
import os
import re
import socket
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

STIG_DIR = "/opt/ia/stig"
OSCAP_DIR = "/opt/ia/oscap"

# oscap result -> checklist status. Anything not listed stays not_reviewed:
# "notchecked" and "error" genuinely mean a human has to look.
RESULT_MAP = {
    "pass": "not_a_finding",
    "fixed": "not_a_finding",
    "fail": "open",
    "error": "not_reviewed",
    "unknown": "not_reviewed",
    "notapplicable": "not_applicable",
    "notchecked": "not_reviewed",
    "notselected": "not_applicable",
    "informational": "not_reviewed",
}
CKL_STATUS = {
    "not_a_finding": "NotAFinding",
    "open": "Open",
    "not_applicable": "Not_Applicable",
    "not_reviewed": "Not_Reviewed",
}
VALID = set(CKL_STATUS)


def strip_ns(tag):
    return tag.split("}", 1)[-1] if "}" in tag else tag


def newest(pattern):
    hits = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    return hits[0] if hits else None


def text_of(el):
    if el is None:
        return ""
    return re.sub(r"\s+\n", "\n", "".join(el.itertext())).strip()


def parse_stig(path):
    """Manual STIG XCCDF -> (benchmark metadata, [rule dicts])."""
    root = ET.parse(path).getroot()
    meta = {"title": "", "release_info": "", "stig_id": root.get("id", "")}
    rules = []

    for child in root:
        tag = strip_ns(child.tag)
        if tag == "title" and not meta["title"]:
            meta["title"] = text_of(child)
        elif tag == "plain-text" and child.get("id") == "release-info":
            meta["release_info"] = text_of(child)

    for group in root.iter():
        if strip_ns(group.tag) != "Group":
            continue
        gid = group.get("id", "")
        gtitle = ""
        rule_el = None
        for child in group:
            t = strip_ns(child.tag)
            if t == "title":
                gtitle = text_of(child)
            elif t == "Rule":
                rule_el = child
        if rule_el is None:
            continue

        r = {
            "group_id": gid,
            "group_title": gtitle,
            "rule_id": rule_el.get("id", ""),
            "severity": rule_el.get("severity", "medium"),
            "weight": rule_el.get("weight", "10.0"),
            "rule_version": "",
            "rule_title": "",
            "discussion": "",
            "check_content": "",
            "fix_text": "",
            "ccis": [],
            "legacy_ids": [],
        }
        for child in rule_el:
            t = strip_ns(child.tag)
            if t == "version":
                r["rule_version"] = text_of(child)
            elif t == "title":
                r["rule_title"] = text_of(child)
            elif t == "description":
                raw = text_of(child)
                m = re.search(r"<VulnDiscussion>(.*?)</VulnDiscussion>", raw, re.S)
                r["discussion"] = (m.group(1) if m else raw).strip()
            elif t == "ident":
                val = text_of(child)
                if val.startswith("CCI-"):
                    r["ccis"].append(val)
                else:
                    r["legacy_ids"].append(val)
            elif t == "fixtext":
                r["fix_text"] = text_of(child)
            elif t == "check":
                for cc in child:
                    if strip_ns(cc.tag) == "check-content":
                        r["check_content"] = text_of(cc)
        rules.append(r)
    return meta, rules


SSG_CONTENT = [
    "/usr/share/xml/scap/ssg/content/ssg-ubuntu24*-ds*.xml",
    "/usr/local/share/scap/ssg-ubuntu24*-ds*.xml",
]
# Worst-to-best. When several SSG rules map to one STIG id, the worst wins:
# a STIG rule is not satisfied because part of it passed.
SEVERITY = ["fail", "error", "unknown", "notchecked", "informational",
            "pass", "fixed", "notapplicable", "notselected"]


def build_id_map(paths):
    """{ssg_rule_id: STIG id} from the <reference> elements in a datastream."""
    mapping = {}
    for path in paths:
        if not path or not os.path.exists(path):
            continue
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            continue
        for rule in root.iter():
            if strip_ns(rule.tag) != "Rule":
                continue
            rid = rule.get("id", "")
            if not rid:
                continue
            for child in rule:
                if strip_ns(child.tag) != "reference":
                    continue
                val = (child.text or "").strip()
                if re.fullmatch(r"[A-Z]{2,6}-\d\d-\d{6}", val):
                    mapping[rid] = val
                    if "content_rule_" in rid:
                        mapping[rid.split("content_rule_", 1)[1]] = val
                    break
    return mapping


def parse_results(path):
    """oscap XCCDF results -> {identifier: result}, indexed every way we can.

    oscap's --stig-viewer output keys rule-results by the DISA rule id, but a
    plain --results file keys them by the SSG id. Index whatever is there under
    every key we can derive, and let the lookup try each in turn -- that way one
    generator handles both inputs instead of silently producing an empty
    checklist from the wrong file.
    """
    idx = {}
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        sys.exit(f"cannot parse results file {path}: {exc}")
    for rr in root.iter():
        if strip_ns(rr.tag) != "rule-result":
            continue
        idref = rr.get("idref", "")
        res = ""
        for child in rr:
            if strip_ns(child.tag) == "result":
                res = text_of(child)
        if not idref or not res:
            continue
        idx[idref] = res
        # SV-270645r1066430_rule -> also index V-270645 and the bare SV id
        m = re.match(r"^SV-(\d+)r\d+_rule$", idref)
        if m:
            idx.setdefault(f"V-{m.group(1)}", res)
        m = re.search(r"(UBTU-\d\d-\d+)", idref)
        if m:
            idx.setdefault(m.group(1), res)
        # xccdf_org.ssgproject.content_rule_foo -> foo
        if "content_rule_" in idref:
            idx.setdefault(idref.split("content_rule_", 1)[1], res)
    return idx


def rank(res):
    return SEVERITY.index(res) if res in SEVERITY else len(SEVERITY)


def apply_id_map(idx, mapping):
    """Fold SSG-keyed results onto their STIG ids, the WORST result winning.

    Several SSG rules routinely cover one STIG id (setxattr and friends are one
    STIG rule and seven SSG rules). If any of them failed, the STIG rule is not
    satisfied, so the worst result is the honest one to carry forward.
    """
    contributors = {}
    for ssg_id, res in list(idx.items()):
        stig_id = mapping.get(ssg_id)
        if not stig_id:
            continue
        contributors.setdefault(stig_id, []).append((ssg_id, res))
        cur = idx.get(stig_id)
        if cur is None or rank(res) < rank(cur):
            idx[stig_id] = res
    return len(contributors), contributors


def load_answers(path):
    """Adjudications keyed by STIG id / V-ID / rule id.

    Deliberately parsed with a small reader rather than PyYAML: these boxes are
    air-gapped and python3-yaml is not guaranteed to be installed. The format is
    a restricted subset -- top-level keys, then indented `field: value` with
    optional `|` blocks -- which is all the answer file needs.
    """
    answers = {}
    if not path or not os.path.exists(path):
        return answers
    key = None
    field = None
    block = None
    with open(path) as fh:
        for raw in fh.readlines() + ["\x00"]:
            line = raw.rstrip("\n")
            if line == "\x00" or (line and not line[0].isspace() and not line.startswith("#")):
                if key and field and block is not None:
                    answers[key][field] = "\n".join(block).strip()
                block = field = None
                if line == "\x00":
                    break
                key = line.split(":", 1)[0].strip().strip('"\'')
                answers[key] = {}
                continue
            if key is None or not line.strip() or line.strip().startswith("#"):
                if block is not None and line.strip():
                    block.append(line.strip())
                continue
            if block is not None:
                if line.startswith("    ") or line.startswith("\t\t"):
                    block.append(line.strip())
                    continue
                answers[key][field] = "\n".join(block).strip()
                block = field = None
            m = re.match(r"^\s+([A-Za-z_]+):\s*(.*)$", line)
            if m:
                field, val = m.group(1), m.group(2).strip()
                if val in ("|", ">"):
                    block = []
                else:
                    answers[key][field] = val.strip('"\'')
    return answers


def lookup(rule, table):
    for k in (rule["rule_version"], rule["group_id"], rule["rule_id"], *rule["legacy_ids"]):
        if k and k in table:
            return table[k]
    return None


def target_data():
    def sh(cmd):
        try:
            return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                                  timeout=5).stdout.strip()
        except Exception:
            return ""
    ip = sh("ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'")
    mac = sh("ip -o link show 2>/dev/null | awk '$2!~/^lo:/ {print $(NF-2); exit}'")
    return {
        "target_type": "Computing",
        "host_name": socket.gethostname(),
        "ip_address": ip,
        "mac_address": mac,
        "fqdn": socket.getfqdn(),
        "comments": "",
        "role": "None",
        "is_web_database": False,
        "technology_area": "",
        "web_db_site": "",
        "web_db_instance": "",
    }


def build(meta, rules, results, answers, contributors=None):
    contributors = contributors or {}
    out, counts = [], {}
    for r in rules:
        status = "not_reviewed"
        details = ""
        comments = ""

        res = lookup(r, results)
        if res is not None:
            status = RESULT_MAP.get(res, "not_reviewed")
            details = f"Automated: OpenSCAP evaluated this rule as '{res}'."
            who = contributors.get(r["rule_version"]) or contributors.get(r["group_id"])
            if who:
                # The map indexes each SSG rule under both its full id and its
                # short name, so collapse to the short name or every rule is
                # listed twice.
                uniq = {n.split("content_rule_", 1)[-1]: v for n, v in who}
                shown = ", ".join(f"{n}={v}" for n, v in sorted(uniq.items()))
                details += f"\nSCAP rules checked: {shown}"

        ans = lookup(r, answers)
        if ans:
            want = (ans.get("status") or "").strip().lower()
            # An answer file overrides a SCAP PASS only when it says so
            # explicitly. Otherwise a stale hand-written note could quietly
            # mark a genuinely failing control as compliant, which is the one
            # mistake that makes the whole checklist untrustworthy.
            override = (ans.get("override") or "").strip().lower() in ("1", "true", "yes")
            if want in VALID and (status == "not_reviewed" or override or status == "open"):
                if status == "open" and not override and want != "open":
                    comments = (f"NOTE: answers.yml proposes '{want}' but SCAP reports a"
                                f" FAILURE. Left Open -- set override: true to accept the"
                                f" adjudication, or fix the finding.")
                else:
                    status = want
            if ans.get("finding_details"):
                details = (details + "\n\n" if details else "") + ans["finding_details"]
            if ans.get("comments"):
                comments = (comments + "\n\n" if comments else "") + ans["comments"]

        counts[status] = counts.get(status, 0) + 1
        out.append(dict(r, status=status, finding_details=details, comments=comments,
                        overrides={}, uuid=str(uuid.uuid4()),
                        reference_identifier="", rule_id_src=meta["stig_id"],
                        classification="Unclassified", group_tree=[]))
    return out, counts


def write_cklb(path, meta, rules):
    doc = {
        "title": f"{meta['title']} -- {socket.gethostname()}",
        "id": str(uuid.uuid4()),
        "active": False,
        "mode": 1,
        "has_path": True,
        "target_data": target_data(),
        "stigs": [{
            "stig_name": meta["title"],
            "display_name": meta["title"],
            "stig_id": meta["stig_id"],
            "release_info": meta["release_info"],
            "uuid": str(uuid.uuid4()),
            "reference_identifier": "",
            "size": len(rules),
            "rules": rules,
        }],
        "cklb_version": "1.0",
    }
    with open(path, "w") as fh:
        json.dump(doc, fh, indent=2)


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


def write_ckl(path, meta, rules):
    t = target_data()
    p = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        "<!--DISA STIG Viewer :: 2.x-->",
        "<CHECKLIST><ASSET>",
        "<ROLE>None</ROLE><ASSET_TYPE>Computing</ASSET_TYPE>",
        f"<HOST_NAME>{esc(t['host_name'])}</HOST_NAME>",
        f"<HOST_IP>{esc(t['ip_address'])}</HOST_IP>",
        f"<HOST_MAC>{esc(t['mac_address'])}</HOST_MAC>",
        f"<HOST_FQDN>{esc(t['fqdn'])}</HOST_FQDN>",
        "<TARGET_COMMENT></TARGET_COMMENT><TECH_AREA></TECH_AREA>",
        "<TARGET_KEY></TARGET_KEY><WEB_OR_DATABASE>false</WEB_OR_DATABASE>",
        "<WEB_DB_SITE></WEB_DB_SITE><WEB_DB_INSTANCE></WEB_DB_INSTANCE>",
        "</ASSET><STIGS><iSTIG><STIG_INFO>",
        f"<SI_DATA><SID_NAME>title</SID_NAME><SID_DATA>{esc(meta['title'])}</SID_DATA></SI_DATA>",
        f"<SI_DATA><SID_NAME>releaseinfo</SID_NAME><SID_DATA>{esc(meta['release_info'])}</SID_DATA></SI_DATA>",
        f"<SI_DATA><SID_NAME>stigid</SID_NAME><SID_DATA>{esc(meta['stig_id'])}</SID_DATA></SI_DATA>",
        "</STIG_INFO>",
    ]
    for r in rules:
        def sd(name, val):
            return (f"<STIG_DATA><VULN_ATTRIBUTE>{name}</VULN_ATTRIBUTE>"
                    f"<ATTRIBUTE_DATA>{esc(val)}</ATTRIBUTE_DATA></STIG_DATA>")
        p.append("<VULN>")
        p.append(sd("Vuln_Num", r["group_id"]))
        p.append(sd("Severity", r["severity"]))
        p.append(sd("Group_Title", r["group_title"]))
        p.append(sd("Rule_ID", r["rule_id"]))
        p.append(sd("Rule_Ver", r["rule_version"]))
        p.append(sd("Rule_Title", r["rule_title"]))
        p.append(sd("Vuln_Discuss", r["discussion"]))
        p.append(sd("Check_Content", r["check_content"]))
        p.append(sd("Fix_Text", r["fix_text"]))
        p.append(sd("Weight", r["weight"]))
        for c in r["ccis"]:
            p.append(sd("CCI_REF", c))
        p.append(f"<STATUS>{CKL_STATUS[r['status']]}</STATUS>")
        p.append(f"<FINDING_DETAILS>{esc(r['finding_details'])}</FINDING_DETAILS>")
        p.append(f"<COMMENTS>{esc(r['comments'])}</COMMENTS>")
        p.append("<SEVERITY_OVERRIDE></SEVERITY_OVERRIDE><SEVERITY_JUSTIFICATION></SEVERITY_JUSTIFICATION>")
        p.append("</VULN>")
    p.append("</iSTIG></STIGS></CHECKLIST>")
    with open(path, "w") as fh:
        fh.write("\n".join(p))


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--stig")
    ap.add_argument("--results")
    ap.add_argument("--answers", default=os.path.join(STIG_DIR, "answers.yml"))
    ap.add_argument("--map")
    ap.add_argument("--out")
    ap.add_argument("--format", default="cklb", choices=("cklb", "ckl", "both"))
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()
    if args.help:
        print(__doc__)
        return 0

    stig = args.stig or newest(os.path.join(STIG_DIR, "*Manual-xccdf.xml")) \
        or newest(os.path.join(STIG_DIR, "*xccdf*.xml"))
    if not stig:
        sys.exit(f"no manual STIG XCCDF found in {STIG_DIR}.\n"
                 f"Download the Ubuntu 24.04 STIG from https://public.cyber.mil/stigs/downloads/,\n"
                 f"unzip it, and put the *Manual-xccdf.xml into {STIG_DIR}/ (once per STIG release).")
    # Pick a results file that actually CONTAINS rule-results.
    #
    # `oscap --stig-viewer` was the obvious input and turned out to produce a
    # file with zero parseable rule-results on this content -- the checklist
    # came out empty twice before that was visible. So rather than trusting one
    # filename, try the candidates newest-first and take the first that yields
    # results. The ARF and the `usg audit` output both carry them.
    if args.results:
        candidates = [args.results]
    else:
        candidates = [c for c in (
            newest(os.path.join(OSCAP_DIR, "stig-viewer-*.xml")),
            newest(os.path.join(OSCAP_DIR, "stig-arf-*.xml")),
            newest(os.path.join(OSCAP_DIR, "stig-results-*.xml")),
            newest("/opt/ia/usg-results-*.xml"),
        ) if c]
    if not candidates:
        sys.exit(f"no scan results in {OSCAP_DIR}. Run `sudo it-oscap` first.")

    meta, rules = parse_stig(stig)
    results, res, tried = None, {}, []
    for cand in candidates:
        got = parse_results(cand)
        tried.append((cand, len(got)))
        if got:
            results, res = cand, got
            break
    if results is None:
        print("None of the available results files contained any rule-results:",
              file=sys.stderr)
        for c, n in tried:
            print(f"  {c}  ({n})", file=sys.stderr)
        sys.exit("nothing to build a checklist from.")

    # Translate SSG rule ids onto STIG ids. Skipped harmlessly when the scan
    # already used DISA content, since nothing will match the mapping.
    map_paths = [args.map] if args.map else []
    if not map_paths:
        for pat in SSG_CONTENT:
            hit = newest(pat)
            if hit:
                map_paths.append(hit)
    id_map = build_id_map(map_paths)
    mapped, contributors = apply_id_map(res, id_map) if id_map else (0, {})

    ans = load_answers(args.answers)
    built, counts = build(meta, rules, res, ans, contributors)

    if args.debug:
        print("=" * 72)
        print("DEBUG -- the three key namespaces, so a zero match can be diagnosed")
        print("=" * 72)
        print("\n1. rule-result idrefs in the scan (first 5):")
        for k in list(res)[:5]:
            print(f"     {k}  = {res[k]}")
        print(f"   ({len(res)} keys total)")
        print("\n2. id map entries built from the datastream (first 5):")
        for k in list(id_map)[:5]:
            print(f"     {k}\n       -> {id_map[k]}")
        print(f"   ({len(id_map)} entries)")
        print("\n3. keys the manual STIG will look up (first 5 rules):")
        for r in rules[:5]:
            print(f"     version={r['rule_version']}  group={r['group_id']}  rule={r['rule_id']}")
        overlap = set(res) & set(id_map)
        print(f"\n4. scan keys that appear in the id map: {len(overlap)}")
        for k in list(overlap)[:5]:
            print(f"     {k} -> {id_map[k]}")
        print("=" * 72)
        print()

    matched = sum(1 for r in rules if lookup(r, res) is not None)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    base = args.out or os.path.join(STIG_DIR, f"{socket.gethostname()}-{stamp}")
    base = re.sub(r"\.(cklb|ckl)$", "", base)

    written = []
    if args.format in ("cklb", "both"):
        write_cklb(base + ".cklb", meta, built)
        written.append(base + ".cklb")
    if args.format in ("ckl", "both"):
        write_ckl(base + ".ckl", meta, built)
        written.append(base + ".ckl")

    print(f"STIG      : {meta['title']}  ({meta['release_info']})")
    print(f"Rules     : {len(rules)}")
    print(f"Scan      : {os.path.basename(results)}  "
          f"({len(res)} result keys)  -> {matched} rules matched")
    for c, n in tried[:-1]:
        print(f"            (skipped {os.path.basename(c)}: no rule-results in it)")
    if id_map:
        print(f"ID map    : {len(id_map)} SSG->STIG references from "
              f"{os.path.basename(map_paths[0])}  -> {mapped} STIG ids resolved")
    print(f"Answers   : {len(ans)} adjudications loaded from {args.answers}")
    print()
    for k in ("not_a_finding", "open", "not_applicable", "not_reviewed"):
        print(f"  {CKL_STATUS[k]:<16} {counts.get(k, 0)}")
    print()
    for f in written:
        print(f"Wrote {f}")
    if matched == 0:
        print("\nWARNING: no rule matched the scan results -- the checklist is empty.",
              file=sys.stderr)
        if not id_map:
            print("         No SSG->STIG id map was loaded. A scan run against SSG\n"
                  "         content uses SSG rule ids, which share no key with the\n"
                  "         manual STIG. Point --map at the SSG datastream:\n"
                  "           it-ckl --map /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml",
                  file=sys.stderr)
        else:
            print("         An id map WAS loaded, so the results file is probably not\n"
                  "         from this STIG's content. Check --results.", file=sys.stderr)
    if counts.get("not_reviewed"):
        print(f"\n{counts['not_reviewed']} rules still need a human. List them with:"
              f"\n  it-ckl --summary")
    if args.summary:
        print("\nNot_Reviewed:")
        for r in built:
            if r["status"] == "not_reviewed":
                print(f"  {r['group_id']:<12} {r['rule_version']:<18} {r['rule_title'][:70]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
