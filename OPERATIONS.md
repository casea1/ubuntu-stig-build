# ubuntu-stig-build

Ansible-pull repo to provision and DoD-STIG-harden an **Ubuntu 24.04 Desktop (GNOME)**
machine, then produce an OpenSCAP compliance report — all in one run, while the box
still has internet, before it's moved to an air-gapped network.

## What it does, in order

1. **base_packages** — ClamAV, Wireshark/tshark, Python3 (+pip/venv), PuTTY (GUI) and
   putty-tools (plink/pscp/psftp), OpenSSH client, git, OpenSCAP, and your editor
   (VS Code by default; vim/neovim selectable).
2. **app_config** — Starts ClamAV daemon + freshclam updates + a weekly scan timer;
   restricts Wireshark capture to a `wireshark` group (STIG requirement).
3. **stig_harden** — Runs the `ansible-lockdown/UBUNTU24-STIG` remediation role
   (CAT I + II by default, CAT III off), plus GNOME/GDM-specific fixups (DoD login
   banner, idle screen lock) the *server* STIG doesn't cover.
4. **scap_scan** — Runs `oscap` against the DISA STIG profile and writes an HTML report
   plus a DISA-STIG-Viewer-importable XML into `/var/log/stig-scan`.

## One-time setup

Edit **`group_vars/all.yml`**:
- `wireshark_users` → real local accounts that need packet capture
- `editor_choice` → `vscode` | `vim` | `neovim`
- `ubtu24stig_cat3` → flip to `true` once you've validated low-severity controls
- `stig_skip_tags` → add control tags you must skip on Desktop (document each as a POA&M)

Push this repo to a **public** GitHub/GitLab repo.

## Running it on the Dell (during imaging, online)

```bash
sudo apt update && sudo apt install -y ansible git curl
# Install the pinned Lockdown role from requirements.yml:
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/requirements.yml -o /tmp/requirements.yml
sudo ansible-galaxy install -r /tmp/requirements.yml
# Run DETACHED as a systemd unit -- hardening restarts GDM mid-run, which would
# kill a foreground job launched from the GUI session. systemd-run survives it:
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://github.com/casea1/ubuntu-stig-build.git -C main -i localhost, local.yml
# Watch:  journalctl -u stig-build -f      Result: systemctl status stig-build
```

Or just run `bootstrap.sh` (below), which does all of that.

## Critical gotchas

- **Desktop vs Server STIG.** DISA only publishes a *Server* 24.04 STIG. On GNOME you
  WILL get findings about the display manager / graphical target. Don't let the Lockdown
  role disable the GUI — `ubtu24stig_gui: true` guards against that. Triage the GUI
  findings into documented exceptions.
- **Order is load-bearing.** Packages first, harden second, scan last. Hardening sets
  `noexec` on /tmp, tightens umask, and locks down PAM — doing it before installs can
  break pip and apt.
- **Pin the role version.** `requirements.yml` currently tracks `main`. Pin to a tagged
  release so every machine you image is identical, then bump deliberately.
- **Collect reports before air-gapping.** `/var/log/stig-scan/*.html` and the
  `stig-viewer-*.xml` are your audit artifacts. Grab them while the box is online.
- **First run interactive.** `ubtu24stig_fullauto: false` lets the role pause on risky
  changes. Only set `true` for unattended imaging after you trust the result.
- **Re-scan after air-gapping.** `oscap` works offline too (drop `--fetch-remote-resources`).
  Keep the SSG datastream on the box for periodic re-checks.

## Windows servers

This repo is Linux-only. STIG automation for Windows uses a different stack (PowerShell
DSC / the DISA-provided GPOs / Ansible `ansible.windows` + `microsoft.iis` etc.). Keep
that as a separate playbook.
