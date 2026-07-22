# Developer Tooling Layer — Design

Status: **proposed** · Date: 2026-06-02 · Target: Ubuntu 24.04 Desktop STIG build

## Contents

- [Context & goal](#context--goal)
- [Scope](#scope)
- [Decisions (recorded from brainstorming)](#decisions-recorded-from-brainstorming)
- [Architecture](#architecture)
- [Component detail](#component-detail)
- [VS Code extension ID map](#vs-code-extension-id-map)
- [group_vars additions](#group_vars-additions)
- [STIG impact & documented exceptions](#stig-impact--documented-exceptions)
- [Verification plan (on the test VM)](#verification-plan-on-the-test-vm)
- [Assumptions (confirmed 2026-06-02)](#assumptions-confirmed-2026-06-02)

## Context & goal

The base build provisions + STIG-hardens an Ubuntu 24.04 Desktop and scans it with
OpenSCAP. This change adds a **developer-workstation tooling layer** on top: a set of
VS Code extensions, the toolchains those extensions front-end, a shared Python
environment with ~150 libraries, and PowerShell (needed by the PowerStrux auditing
tool). The box remains STIG-hardened; the dev tooling introduces a small, documented
set of exceptions (compilers, Docker) justified by mission need.

## Scope

**In:** system compilers/SDKs, Docker engine, PowerShell (LTS), a shared `/opt` Python
venv + Jupyter kernel + ~150 libs, the 26 listed VS Code extensions wired machine-wide.

**Out:** the SPARK prover (`gnatprove`) — GNAT compiler only; exact Python patch
`3.12.4` — we use Ubuntu's `python3.12` (3.12.3, CVE-patched); Windows STIG/PowerStrux
server config (separate track).

**Already present (no change):** `git`, `clamav`/`clamav-daemon`/`clamav-freshclam`
(installed in `base_packages`, configured in `app_config`).

## Decisions (recorded from brainstorming)

| Decision | Choice |
|---|---|
| Toolchain depth | **Full dev workstation** — install the toolchains the extensions need |
| Python version | **System `python3.12`** via apt (3.12.x), not exact 3.12.4 |
| Python libs home | **Shared venv at `/opt/eng-venv`**, world-readable, baked into image |
| Docker group | **Add primary user to `docker`** (root-equivalent; documented exception) |
| Extension reach | **Machine-wide via `/etc/skel`** — every current/future account inherits |
| Ada | **GNAT compiler only** (`gnat`/`gprbuild`); SPARK prover deferred |
| PowerShell | **7.4.16 LTS**, pinned `.deb` from GitHub release (no new apt repo) |

## Architecture

Pipeline order in `local.yml` becomes:

```
base_packages → app_config → dev_tools → stig_harden → scap_scan
```

`dev_tools` runs **after** app config and **before** hardening — it needs internet and
must complete before `/tmp` noexec / PAM / network controls are applied.

- **`base_packages`** (existing role) gains one block: install **PowerShell 7.4.16 LTS**
  from a pinned `.deb` (audit dependency; present regardless of dev tooling).
- **`dev_tools`** (new role) with `main.yml` importing three focused task files:
  - `toolchains.yml` — system compilers/SDKs/Docker via apt
  - `python_env.yml` — `/opt/eng-venv`, libraries, Jupyter kernel, `eng` command
  - `vscode.yml` — extensions + machine-wide wiring

All non-archive software is sourced as **pinned release artifacts** (PowerShell `.deb`,
SSG datastream) — the only third-party apt repo remains `packages.microsoft.com/repos/code`
(already added for VS Code itself). `.NET`, Docker, GNAT, etc. come from the Ubuntu archive.

## Component detail

### A. System toolchains — `dev_tools/toolchains.yml` (apt)

`build-essential` (gcc/g++/make), `gdb`, `cmake`, `doxygen`, `graphviz`, `default-jre`
(UMLet is Java), `gnat`, `gprbuild`, `dotnet-sdk-8.0` (Ubuntu archive, LTS), `docker.io`,
`python3.12-venv`, `python3-dev`, and sdist build deps `libffi-dev` `libssl-dev`
`libxml2-dev` `libxslt1-dev`. Then add `{{ dev_tools_user }}` to the `docker` group.

### B. PowerShell — `base_packages` (pinned `.deb`)

`get_url` `powershell_7.4.16-1.deb_amd64.deb` from the v7.4.16 GitHub release →
`apt install ./<deb>` (apt resolves libicu/libssl from the archive). Idempotent via a
`creates`/`which pwsh` guard. Installs `/usr/bin/pwsh`; **not** added to `/etc/shells`
(so it is not a valid login shell). Version pinned in `group_vars` as `powershell_version`.

### C. Python environment — `dev_tools/python_env.yml`

1. Create venv at `/opt/eng-venv` (mode 0755, root-owned) using `python3.12 -m venv`.
2. `pip install -r files/eng-requirements.txt` — the user's ~150 packages, verbatim.
3. Register a **system-wide** Jupyter kernel named `Eng (Python 3.12)` under
   `/usr/local/share/jupyter/kernels/eng` (visible to all users).
4. Install `/etc/profile.d/eng.sh` exposing `eng` → activates the venv (prompt shows `(eng)`).
5. **Reproducibility:** first clean build installs unpinned; we then `pip freeze` the venv
   into `files/eng-requirements.lock.txt` and switch the role to install from the lock so
   every imaged Dell is byte-identical. (Bump deliberately, re-freeze.)

### D. VS Code extensions — `dev_tools/vscode.yml` (machine-wide)

Install each extension once (as `{{ dev_tools_user }}`, via `code --install-extension`),
then **seed `/etc/skel/.vscode/extensions` and `/etc/skel/.config/Code/User/settings.json`**
so any account — present or created later — inherits the extensions plus
`python.defaultInterpreterPath = /opt/eng-venv/bin/python`. The primary account is also
configured directly.

## VS Code extension ID map

| # | Listed name | Marketplace ID |
|---|---|---|
| 1 | .NET Install Tool | `ms-dotnettools.vscode-dotnet-runtime` |
| 2 | Ada & SPARK | `AdaCore.ada` |
| 3 | C# | `ms-dotnettools.csharp` |
| 4 | C# Dev Kit | `ms-dotnettools.csdevkit` |
| 5 | C/C++ | `ms-vscode.cpptools` |
| 6 | CMake | `twxs.cmake` |
| 7 | CMake Tools | `ms-vscode.cmake-tools` |
| 8 | Dev Containers | `ms-vscode-remote.remote-containers` |
| 9 | Docker | `ms-azuretools.vscode-docker` |
| 10 | Doxygen | `cschlosser.doxdocgen` |
| 11 | Git Graph | `mhutchie.git-graph` |
| 12 | Git History | `donjayamanne.githistory` |
| 13 | GitLens | `eamodio.gitlens` |
| 14 | Makefile Tools | `ms-vscode.makefile-tools` |
| 15 | Prettier | `esbenp.prettier-vscode` |
| 16 | Pylance | `ms-python.vscode-pylance` |
| 17 | Python | `ms-python.python` |
| 18 | Python Debugger | `ms-python.debugpy` |
| 19 | Reveal | `evilz.vscode-reveal` *(reveal.js presentations — confirmed)* |
| 20 | SARIF Viewer | `MS-SarifVSCode.sarif-viewer` |
| 21 | UMLet | `TheUMLetTeam.umlet` |
| 22 | Vim | `vscodevim.vim` |
| 23 | WSL | `ms-vscode-remote.remote-wsl` *(no-op on Linux)* |
| 24 | Remote - SSH | `ms-vscode-remote.remote-ssh` |
| 25 | Remote Explorer | `ms-vscode.remote-explorer` |
| 26 | Remote - SSH: Editing Configuration Files | `ms-vscode-remote.remote-ssh-edit` |

## group_vars additions

```yaml
dev_tools_user: austin_case_adm          # account that owns extensions / docker membership
eng_venv_path: /opt/eng-venv
powershell_version: "7.4.16"
dotnet_sdk_package: dotnet-sdk-8.0
# vscode_extensions: [ ... 26 IDs ... ]   # list lives in the role for readability
```

## STIG impact & documented exceptions

This formally makes the box a **developer workstation**. New items to capture as
POA&M / `stig_skip_tags` during triage, each with a mission-need justification:

- **Compilers present** (`gcc`, `g++`, `gnat`, `make`) — required for C/C++/Ada development.
- **Docker engine + `docker` group** — required for Dev Containers; group membership is
  root-equivalent and must be justified + access-controlled.
- **PowerShell** — minimal impact; binary only, not a login shell.

`.NET`/Docker/GNAT come from the trusted Ubuntu archive; PowerShell + SSG are pinned,
checksummable release artifacts. No additional third-party apt repos beyond the existing
Microsoft VS Code repo.

## Verification plan (on the test VM)

- `pwsh -v` returns 7.4.16; `which pwsh` → `/usr/bin/pwsh`.
- `/opt/eng-venv/bin/python -c "import numpy, pandas, napalm, scapy, jupyterlab"` succeeds.
- `jupyter kernelspec list` (any user) shows the `eng` kernel.
- `sudo -u austin_case_adm code --list-extensions` shows all 26 IDs.
- `id austin_case_adm` includes `docker`.
- Full pipeline still reaches `scap_scan` and produces a report.

## Assumptions (confirmed 2026-06-02)

1. **Reveal = `evilz.vscode-reveal`** (reveal.js presentations) — confirmed.
2. **Single account** (`austin_case_adm`) for now; no other accounts created at this time.
   Extensions install for that account; `/etc/skel` seeding is kept as harmless
   future-proofing so any later account inherits them automatically.
