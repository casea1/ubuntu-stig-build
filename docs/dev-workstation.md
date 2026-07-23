# Development Workstation Profile (`development`)

Profile page for the engineering workstation. Overview and the software list. Build steps are [build.md Track A](build.md#track-a-development-workstation); day-to-day ops (accounts, RDP, USB policy, TPM/LUKS) are in [operate.md](operate.md); hardening/compliance is [compliance.md](compliance.md).

## What it builds

DISA-STIG-hardened Ubuntu 24.04 Desktop (GNOME) engineering workstation:

- **GNOME desktop over RDP** (`remote_desktop`): installs the GUI + xrdp so users RDP in, even on headless server hardware. RDP is TLS + rate-limited, goes through PAM (STIG lockout applies).
- **Dev toolchain** (`dev_tools`): compilers, .NET, the `/opt/eng-venv` shared Python env, VS Code + extensions, Docker.
- **Browser VS Code** (code-server) at `https://<host>:8080`.
- **Cockpit** web console at `https://<host>:9090`.
- **DCSA login banner** (GUI, console, SSH) + optional top/bottom **classification banner**.
- **Org accounts/groups** and **USB mass storage restricted to the `dta` group** (udev + polkit). The USB carve-out is development-profile only; the AI servers disable USB storage.

Hardened by Canonical USG (`usg fix disa_stig`), same as the `ai` profile. Needs an Ubuntu Pro token.

## Software list

Software inventory for the development workstation. Versions are pinned in `group_vars/all.yml` and the role defaults (`roles/dev_tools/defaults/main.yml`, `roles/base_packages/tasks/development.yml`).

### Operating system & base tooling

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| Ubuntu | 24.04 LTS Desktop (Noble Numbat) | Canonical | Host OS + GNOME desktop |
| git | distro | Git project | Version control |
| cifs-utils | distro | Samba team | Mount SMB/CIFS shares |
| net-tools | distro | net-tools project | `ifconfig`/`route`/`netstat` network admin |
| Python | 3.12 | Python Software Foundation | Scripting, venvs |
| openssh-client | distro | OpenBSD | SSH/SCP client |

### Languages & build toolchains

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| build-essential (gcc, g++, make) | distro | GNU / GCC | C/C++ compile toolchain |
| gdb | distro | GNU | Debugger |
| cmake | distro | Kitware | Build system |
| GNAT + gprbuild | distro | FSF / AdaCore | Ada compiler + project builder |
| .NET SDK | 8.0 (LTS) | Microsoft | C# / .NET SDK |
| default-jre (OpenJDK) | distro | OpenJDK | Java runtime (UMLet) |
| doxygen | distro | Doxygen project | Source documentation |
| graphviz | distro | Graphviz project | Graph/diagram rendering |
| docker.io | distro (Moby) | Docker / Ubuntu | Containers for development |
| `/opt/eng-venv` | Python 3.12 (~140 libs) | Built on box (PyPI) | Shared data-science + network-automation Python env (NumPy/Pandas/SciPy/JupyterLab, NAPALM/Netmiko/Scapy/ncclient/junos-eznc); `eng` command + Jupyter kernel |

### Editor & IDE

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| VS Code | latest (Microsoft apt repo) | Microsoft | Primary IDE |
| VS Code extensions (26) | latest | Various (Microsoft, AdaCore, GitLens, ...) | C/C++, C#/.NET, Ada & SPARK, Python/Pylance, CMake, Docker, GitLens, Remote-SSH, UMLet, etc. Full list in `roles/dev_tools/defaults/main.yml` |
| code-server | latest (Coder installer) | Coder | VS Code in the browser (`https://<host>:8080`) |

### Remote access & management

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| GNOME desktop | ubuntu-desktop-minimal | GNOME / Canonical | Desktop environment |
| GDM | distro | GNOME | Display / login manager |
| xrdp | distro | neutrinolabs (xrdp project) | RDP server (GNOME over RDP) |
| Cockpit | distro | Cockpit project | Web server-management console (`:9090`) |

### Security & analysis tools

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| ClamAV | distro | Cisco / ClamAV | Antivirus (daemon + freshclam + weekly scan) |
| OpenSCAP (`oscap`) | distro | OpenSCAP project | SCAP compliance scanner |
| Wireshark + tshark | distro | Wireshark Foundation | Packet capture/analysis (gated to the `wireshark` group) |
| PuTTY + putty-tools | distro | Simon Tatham (PuTTY) | SSH/serial client + `plink`/`pscp`/`psftp` |
| PowerShell | 7.4.16 LTS | Microsoft | `pwsh`; required by the PowerStrux auditing tool |

### Network provisioning services (installed, disabled by default)

Installed for PXE/imaging use, left disabled + stopped until deliberately configured. They will show as SCAP findings; document as mission-need exceptions.

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| tftpd-hpa | distro | H. Peter Anvin / Debian | TFTP server (PXE boot) |
| isc-dhcp-server | distro | ISC | DHCP server (PXE) |
| dnsmasq | distro | Simon Kelley | Lightweight DNS/DHCP for provisioning |
