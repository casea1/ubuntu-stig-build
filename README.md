# Handoff to Claude Code — ubuntu-stig-build

**You (Claude Code) are picking up a project from a Claude chat session.** This repo is a
complete, syntax-validated Ansible-pull project that provisions and DoD-STIG-hardens an
**Ubuntu 24.04 Desktop (GNOME)** machine, then produces an OpenSCAP compliance report.
Your job is to help the user (Austin) push it to GitHub and then work through the
finishing items listed below.

---

## First actions

1. **Initialize and push to GitHub.** Create a new repo (ask Austin for the name/visibility;
   the bootstrap workflow assumes it ends up **public** so `ansible-pull` and the raw
   `curl` calls work without auth — confirm that's acceptable or adjust, see Open Item #5).
   ```bash
   git init && git add -A && git commit -m "Initial STIG build scaffold from Claude chat"
   git branch -M main
   git remote add origin https://github.com/<user>/ubuntu-stig-build.git
   git push -u origin main
   ```
2. **Find/replace the placeholders.** `<you>` appears in `bootstrap.sh` and `OPERATIONS.md`
   and must become the real GitHub org/user. Grep for it:
   ```bash
   grep -rn '<you>' .
   ```
3. **Read `OPERATIONS.md`** — that's the human-facing run guide. This README is just the
   handoff brief for you.

---

## What's already done (don't redo)

- Full role structure: `base_packages`, `app_config`, `stig_harden`, `scap_scan`.
- All YAML validated as parseable (`python3 -c "yaml.safe_load_all"` across every file).
- Run order locked in `local.yml`: **install → configure → harden → scan**. This ordering
  is deliberate and load-bearing — hardening sets `noexec` on /tmp + tightens umask/PAM,
  which breaks pip/apt if it runs first. Do not reorder.
- ClamAV daemon + freshclam + weekly scan timer; Wireshark capture gated to a
  `wireshark` group (STIG requirement); PuTTY GUI + putty-tools; Python3; VS Code (default,
  switchable to vim/neovim via `group_vars/all.yml`).
- Hardening via `ansible-lockdown/UBUNTU24-STIG` (CAT I+II on, CAT III off), plus
  GNOME/GDM fixups (DoD login banner, idle lock) the *server* STIG omits.
- SCAP scan auto-detects the datastream filename and emits an HTML report + a
  DISA-STIG-Viewer-importable XML (via `--stig-viewer`).

---

## Open items to work through WITH Austin

These need a live machine or a decision from Austin — verify, don't guess.

1. **Verify two names against the pinned role release.** In `requirements.yml` the role
   tracks `main`; once Austin picks a tagged release, pin it, then confirm:
   - the GUI-guard variable name — code currently uses `ubtu24stig_desktop_gui`
     (set from `ubtu24stig_gui`). Check the role's `defaults/main.yml` for the real name.
   - the SSG content package name in `roles/scap_scan/tasks/main.yml`
     (`ssg-debderived`) — naming has drifted (ssg-debian / ssg-base / ssg-debderived)
     across Ubuntu releases. The datastream auto-detection is resilient, but the apt
     package name may need correcting.

2. **Desktop-vs-Server STIG triage.** DISA only ships a *Server* 24.04 STIG (latest v1r5).
   On GNOME, expect findings about the display manager / graphical target. After the first
   real scan, walk the HTML report with Austin, decide which GUI findings become documented
   exceptions, and populate `stig_skip_tags` in `group_vars/all.yml` with the actual control
   tag names (currently a placeholder).

3. **Test on a throwaway VM first.** Before imaging the real Dell, run a full pass on a
   disposable Ubuntu 24.04 Desktop VM. The Lockdown role explicitly warns it can make
   breaking changes. Keep `ubtu24stig_fullauto: false` for that first run so it pauses on
   risky controls. Capture the scan, iterate, then flip to unattended only once trusted.

4. **Pin the role version** after a clean test pass, so every imaged Dell is identical.

5. **Repo visibility / auth.** `bootstrap.sh` uses unauthenticated `curl` + `ansible-pull`,
   which assumes a public repo. If Austin wants it private, switch to a deploy token / SSH
   key flow and update `bootstrap.sh` accordingly.

6. **Windows servers (separate track).** Austin also has Windows servers needing STIG. That's
   a different toolchain (DISA GPO packages / PowerShell DSC / `ansible.windows`). Out of
   scope for this repo — spin up a separate project if/when he wants it.

---

## Repo layout

```
ubuntu-stig-build/
├── README.md              # this handoff brief (for Claude Code)
├── OPERATIONS.md          # human run guide (imaging steps, gotchas)
├── local.yml              # ansible-pull entrypoint
├── requirements.yml       # pulls ansible-lockdown/UBUNTU24-STIG
├── bootstrap.sh           # one-command first-boot runner
├── group_vars/all.yml     # all toggles: users, editor, STIG cats, skip tags
└── roles/
    ├── base_packages/     # apt installs
    ├── app_config/        # clamav + wireshark group + scan timer
    ├── stig_harden/       # Lockdown role import + GNOME fixups
    └── scap_scan/         # oscap eval -> reports
```
