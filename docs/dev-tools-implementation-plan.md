# Developer Tooling Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `dev_tools` Ansible role (toolchains + shared Python venv + VS Code extensions) and PowerShell 7.4.16 LTS to `base_packages`, integrated before hardening.

**Architecture:** New `dev_tools` role runs `base_packages → app_config → dev_tools → stig_harden → scap_scan`. Software comes from the Ubuntu archive + the existing Microsoft VS Code repo; PowerShell is a pinned `.deb`. Full rationale in [dev-tools-design.md](dev-tools-design.md).

**Tech Stack:** Ansible (ansible-core 2.16), Ubuntu 24.04, apt, pip/venv, `code` CLI, `pwsh`.

**Note on "tests":** No unit framework. Validation per task = `python -c yaml.safe_load_all` (runs on the Windows control box) + `ansible-playbook --syntax-check` (run on the VM). The **integration test is the VM `ansible-pull` run** in Task 8.

---

## Contents

- [File structure](#file-structure)
- [Task 1: group_vars toggles + role defaults](#task-1-group_vars-toggles--role-defaults)
- [Task 2: toolchains.yml](#task-2-toolchainsyml)
- [Task 3: Python environment](#task-3-python-environment)
- [Task 4: VS Code extensions + skel wiring](#task-4-vs-code-extensions--skel-wiring)
- [Task 5: role entrypoint + pipeline wiring](#task-5-role-entrypoint--pipeline-wiring)
- [Task 6: PowerShell in base_packages](#task-6-powershell-in-base_packages)
- [Task 7: push + syntax-check on the VM](#task-7-push--syntax-check-on-the-vm)
- [Task 8: full VM integration run + lockfile](#task-8-full-vm-integration-run--lockfile)
- [Self-review](#self-review)

## File structure

| File | Responsibility |
|---|---|
| `group_vars/all.yml` (modify) | User-facing dev-tooling toggles (user, venv path, versions) |
| `roles/dev_tools/defaults/main.yml` (create) | Package + extension lists (implementation detail) |
| `roles/dev_tools/tasks/main.yml` (create) | Import the three task files |
| `roles/dev_tools/tasks/toolchains.yml` (create) | apt toolchains + docker group |
| `roles/dev_tools/tasks/python_env.yml` (create) | `/opt/eng-venv`, libs, kernel, `eng` cmd |
| `roles/dev_tools/tasks/vscode.yml` (create) | extensions + `/etc/skel` wiring |
| `roles/dev_tools/files/eng-requirements.txt` (create) | the ~150 Python libraries |
| `roles/base_packages/tasks/main.yml` (modify) | + PowerShell 7.4.16 LTS block |
| `local.yml` (modify) | insert `dev_tools` between `app_config` and `stig_harden` |

---

## Task 1: group_vars toggles + role defaults

**Files:**
- Modify: `group_vars/all.yml`
- Create: `roles/dev_tools/defaults/main.yml`

- [ ] **Step 1: Add the dev-tooling toggles to `group_vars/all.yml`** (append before the SCAP section)

```yaml
# =============================================================================
# DEVELOPER TOOLING (dev_tools role; full lists live in roles/dev_tools/defaults)
# =============================================================================
dev_tools_user: austin_case_adm        # owns VS Code extensions + docker group
eng_venv_path: /opt/eng-venv           # shared Python environment ("eng" command)
dotnet_sdk_package: dotnet-sdk-8.0      # .NET SDK from the Ubuntu archive (LTS)
# PowerShell LTS (installed in base_packages as a pinned .deb for PowerStrux)
powershell_version: "7.4.16"
```

- [ ] **Step 2: Create `roles/dev_tools/defaults/main.yml`**

```yaml
---
dev_toolchain_packages:
  - build-essential        # gcc, g++, make
  - gdb
  - cmake
  - doxygen
  - graphviz
  - default-jre            # UMLet is a Java app
  - gnat                   # Ada compiler
  - gprbuild
  - python3.12-venv
  - python3-dev
  - libffi-dev
  - libssl-dev
  - libxml2-dev
  - libxslt1-dev
  - "{{ dotnet_sdk_package }}"
  - docker.io

vscode_extensions:
  - ms-dotnettools.vscode-dotnet-runtime
  - AdaCore.ada
  - ms-dotnettools.csharp
  - ms-dotnettools.csdevkit
  - ms-vscode.cpptools
  - twxs.cmake
  - ms-vscode.cmake-tools
  - ms-vscode-remote.remote-containers
  - ms-azuretools.vscode-docker
  - cschlosser.doxdocgen
  - mhutchie.git-graph
  - donjayamanne.githistory
  - eamodio.gitlens
  - ms-vscode.makefile-tools
  - esbenp.prettier-vscode
  - ms-python.vscode-pylance
  - ms-python.python
  - ms-python.debugpy
  - evilz.vscode-reveal
  - MS-SarifVSCode.sarif-viewer
  - TheUMLetTeam.umlet
  - vscodevim.vim
  - ms-vscode-remote.remote-wsl
  - ms-vscode-remote.remote-ssh
  - ms-vscode.remote-explorer
  - ms-vscode-remote.remote-ssh-edit
```

- [ ] **Step 3: Validate + commit**

```bash
py -c "import yaml; [list(yaml.safe_load_all(open(f,encoding='utf-8'))) for f in ['group_vars/all.yml','roles/dev_tools/defaults/main.yml']]; print('OK')"
git add group_vars/all.yml roles/dev_tools/defaults/main.yml
git commit -m "dev_tools: add toggles + package/extension lists"
```

---

## Task 2: toolchains.yml

**Files:** Create `roles/dev_tools/tasks/toolchains.yml`

- [ ] **Step 1: Write the file**

```yaml
---
- name: Install developer toolchain packages (compilers, SDKs, Docker)
  ansible.builtin.apt:
    name: "{{ dev_toolchain_packages }}"
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Add the developer user to the docker group
  # docker group is root-equivalent — documented dev-workstation exception.
  ansible.builtin.user:
    name: "{{ dev_tools_user }}"
    groups: docker
    append: true

- name: Ensure the docker service is enabled and running
  ansible.builtin.systemd_service:
    name: docker
    enabled: true
    state: started
```

- [ ] **Step 2: Validate** — `py -c "import yaml; list(yaml.safe_load_all(open('roles/dev_tools/tasks/toolchains.yml',encoding='utf-8'))); print('OK')"`
- [ ] **Step 3: Commit** — `git add roles/dev_tools/tasks/toolchains.yml && git commit -m "dev_tools: toolchains + docker group"`

---

## Task 3: Python environment

**Files:**
- Create: `roles/dev_tools/files/eng-requirements.txt`
- Create: `roles/dev_tools/tasks/python_env.yml`

- [ ] **Step 1: Create `files/eng-requirements.txt`** — one package per line, exactly the ~150 names the user provided (anyio … yamlordereddictloader). Unpinned for the first build; Task 8 freezes a lockfile.

- [ ] **Step 2: Create `python_env.yml`**

```yaml
---
- name: Create the shared engineering virtualenv
  ansible.builtin.command:
    cmd: python3.12 -m venv {{ eng_venv_path }}
    creates: "{{ eng_venv_path }}/bin/python"

- name: Upgrade pip/setuptools/wheel in the venv
  ansible.builtin.pip:
    name: [pip, setuptools, wheel]
    state: latest
    virtualenv: "{{ eng_venv_path }}"

- name: Install engineering Python libraries into the venv
  ansible.builtin.pip:
    requirements: "{{ role_path }}/files/eng-requirements.txt"
    virtualenv: "{{ eng_venv_path }}"

- name: Ensure the venv directory is traversable by all users
  ansible.builtin.file:
    path: "{{ eng_venv_path }}"
    state: directory
    mode: "0755"

- name: Register a system-wide Jupyter kernel for the venv
  ansible.builtin.command:
    cmd: >
      {{ eng_venv_path }}/bin/python -m ipykernel install
      --prefix /usr/local --name eng --display-name "Eng (Python 3.12)"
    creates: /usr/local/share/jupyter/kernels/eng/kernel.json

- name: Expose the venv via an 'eng' command for all users
  ansible.builtin.copy:
    dest: /etc/profile.d/eng.sh
    mode: "0644"
    content: |
      # Activate the shared engineering Python environment:  run `eng`
      eng() {{ '{' }} . {{ eng_venv_path }}/bin/activate; {{ '}' }}
```

- [ ] **Step 3: Validate** — yaml parse `python_env.yml` (expect OK)
- [ ] **Step 4: Commit** — `git add roles/dev_tools/files/eng-requirements.txt roles/dev_tools/tasks/python_env.yml && git commit -m "dev_tools: /opt/eng-venv + libraries + jupyter kernel"`

> Note: `ipykernel` is in the requirements list, so the kernel-install step has its dependency. The `{{ '{' }}`/`{{ '}' }}` escapes keep the bash function braces from being parsed as Jinja.

---

## Task 4: VS Code extensions + skel wiring

**Files:** Create `roles/dev_tools/tasks/vscode.yml`

- [ ] **Step 1: Write the file**

```yaml
---
# VS Code extensions are per-user. Install for the primary user, then seed
# /etc/skel so future accounts inherit them + the venv interpreter default.
- name: Ensure the primary user's VS Code config dir exists
  become: true
  become_user: "{{ dev_tools_user }}"
  ansible.builtin.file:
    path: "/home/{{ dev_tools_user }}/.config/Code/User"
    state: directory
    mode: "0700"

- name: Install VS Code extensions for {{ dev_tools_user }}
  become: true
  become_user: "{{ dev_tools_user }}"
  environment:
    HOME: "/home/{{ dev_tools_user }}"
  ansible.builtin.command:
    cmd: code --install-extension {{ item }} --force
  loop: "{{ vscode_extensions }}"
  register: code_ext
  changed_when: "'successfully installed' in (code_ext.stdout | default(''))"
  failed_when:
    - code_ext.rc != 0
    - "'already installed' not in (code_ext.stdout | default(''))"

- name: Set the venv as the VS Code default interpreter (primary user)
  become: true
  become_user: "{{ dev_tools_user }}"
  ansible.builtin.copy:
    dest: "/home/{{ dev_tools_user }}/.config/Code/User/settings.json"
    mode: "0644"
    content: |
      {
        "python.defaultInterpreterPath": "{{ eng_venv_path }}/bin/python"
      }

- name: Ensure /etc/skel VS Code dirs exist
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: "0755"
  loop:
    - /etc/skel/.vscode
    - /etc/skel/.config/Code/User

- name: Seed installed extensions into /etc/skel for future accounts
  ansible.builtin.copy:
    src: "/home/{{ dev_tools_user }}/.vscode/extensions/"
    dest: /etc/skel/.vscode/extensions/
    remote_src: true
    mode: preserve

- name: Seed the default interpreter setting into /etc/skel
  ansible.builtin.copy:
    dest: /etc/skel/.config/Code/User/settings.json
    mode: "0644"
    content: |
      {
        "python.defaultInterpreterPath": "{{ eng_venv_path }}/bin/python"
      }
```

- [ ] **Step 2: Validate** — yaml parse `vscode.yml` (expect OK)
- [ ] **Step 3: Commit** — `git add roles/dev_tools/tasks/vscode.yml && git commit -m "dev_tools: VS Code extensions + /etc/skel wiring"`

---

## Task 5: role entrypoint + pipeline wiring

**Files:**
- Create: `roles/dev_tools/tasks/main.yml`
- Modify: `local.yml`

- [ ] **Step 1: Create `roles/dev_tools/tasks/main.yml`**

```yaml
---
# Developer tooling. Runs AFTER app_config and BEFORE stig_harden — needs
# internet and must finish before hardening locks down /tmp / PAM / network.
- name: Install developer toolchains (compilers, SDKs, Docker)
  ansible.builtin.import_tasks: toolchains.yml

- name: Provision the shared Python environment
  ansible.builtin.import_tasks: python_env.yml

- name: Install and wire VS Code extensions
  ansible.builtin.import_tasks: vscode.yml
```

- [ ] **Step 2: Insert `dev_tools` into `local.yml`** between `app_config` and `stig_harden`

```yaml
    - role: app_config       # clamav daemon/freshclam, wireshark group, etc.
    - role: dev_tools        # compilers, /opt/eng-venv, VS Code extensions, docker
    - role: stig_harden      # Ansible Lockdown Ubuntu 24.04 STIG role + desktop fixups
```

- [ ] **Step 3: Validate** — yaml parse `local.yml` + `roles/dev_tools/tasks/main.yml`
- [ ] **Step 4: Commit** — `git add local.yml roles/dev_tools/tasks/main.yml && git commit -m "dev_tools: role entrypoint + wire into local.yml"`

---

## Task 6: PowerShell in base_packages

**Files:** Modify `roles/base_packages/tasks/main.yml`

- [ ] **Step 1: Append the PowerShell block** (after the editor block)

```yaml
# --- PowerShell (LTS) -------------------------------------------------------
# Required by the PowerStrux auditing tool. Pinned .deb from the official
# GitHub release (no third-party apt repo). Not added to /etc/shells.
- name: Download pinned PowerShell {{ powershell_version }} .deb
  ansible.builtin.get_url:
    url: "https://github.com/PowerShell/PowerShell/releases/download/v{{ powershell_version }}/powershell_{{ powershell_version }}-1.deb_amd64.deb"
    dest: "/tmp/powershell_{{ powershell_version }}.deb"
    mode: "0644"

- name: Install PowerShell from the .deb (apt resolves dependencies)
  ansible.builtin.apt:
    deb: "/tmp/powershell_{{ powershell_version }}.deb"
    state: present
```

- [ ] **Step 2: Validate** — yaml parse `roles/base_packages/tasks/main.yml`
- [ ] **Step 3: Commit** — `git add roles/base_packages/tasks/main.yml && git commit -m "base_packages: install PowerShell 7.4.16 LTS for PowerStrux"`

---

## Task 7: push + syntax-check on the VM

- [ ] **Step 1:** `git push origin main`
- [ ] **Step 2 (on the VM):** install role deps unchanged, then dry syntax-check:
  `sudo ansible-pull -U https://github.com/casea1/ubuntu-stig-build.git -C main -i localhost, local.yml --syntax-check`
  Expected: no syntax errors.

---

## Task 8: full VM integration run + lockfile

- [ ] **Step 1 (VM):** revert to the `clean-install` snapshot (host: `VBoxManage snapshot ubuntu-stig-test restorecurrent` while powered off) for a clean baseline, boot, re-run the full `ansible-pull`.
- [ ] **Step 2 (VM):** verify per the design's Verification plan — `pwsh -v`; `/opt/eng-venv/bin/python -c "import numpy, pandas, napalm, scapy, jupyterlab"`; `jupyter kernelspec list`; `sudo -u austin_case_adm code --list-extensions`; `id austin_case_adm | grep docker`; scan report exists.
- [ ] **Step 3:** capture the lockfile — `sudo /opt/eng-venv/bin/pip freeze > eng-requirements.lock.txt`, copy to `roles/dev_tools/files/`, switch `python_env.yml` to install from the lock, commit.

---

## Self-review

- **Spec coverage:** toolchains (T2), Python env + kernel + eng cmd (T3), extensions + skel (T4), PowerShell (T6), pipeline order (T5), reproducible lockfile (T8), STIG exceptions (documented in design; wired in the later triage todo). All spec sections map to a task.
- **Placeholder scan:** `eng-requirements.txt` content references the user's provided list (verbatim, created in T3 Step 1) rather than re-listing 150 lines — acceptable since the canonical list is fixed. No other placeholders.
- **Consistency:** variable names (`dev_tools_user`, `eng_venv_path`, `dotnet_sdk_package`, `powershell_version`, `vscode_extensions`, `dev_toolchain_packages`) are identical across defaults, tasks, and group_vars.
