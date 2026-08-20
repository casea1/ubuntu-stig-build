# Security & Compliance

Security and compliance reference for the IA / assessment team and our DCSA rep. Covers four things:

- **Hardening posture** the build enforces.
- **DCSA / DoD RMF control-implementation summary** (authorization context, control baseline, NIST 800-53 mapping, AI-specific risk, POA&M list).
- **Container-runtime compliance** (why there's no Docker STIG, how the container layer is secured).
- **Software inventories** (linked, per profile).

Everything is provisioned by the version-controlled `ubuntu-stig-build` Ansible baseline: repeatable, auditable, identical across the fleet. Operations: [`operate.md`](operate.md). Build/imaging: [`build.md`](build.md). Per-node overrides: [`site.yml.example`](site.yml.example). Overview: [`../README.md`](../README.md).

## Contents

- [Hardening posture](#hardening-posture)
  - [Additionally remediated by usg_remediate (every run, idempotent)](#-additionally-remediated-by-usg_remediate-every-run-idempotent)
  - [Approved deviations (documented, not "failures")](#-approved-deviations-documented-not-failures)
  - [Open POA&M: need a secret or infra (NOT auto-applied)](#-open-poam-need-a-secret-or-infra-not-auto-applied)
  - [NTP / time source](#ntp--time-source)
  - [Admin working folders /opt/ia and /opt/it](#admin-working-folders-optia-and-optit)
- [DCSA / DoD RMF compliance posture](#dcsa--dod-rmf-compliance-posture)
  - [Authorization context](#authorization-context)
  - [System description](#system-description)
  - [Compliance baseline (what the build enforces)](#compliance-baseline-what-the-build-enforces)
  - [NIST SP 800-53 Rev 5 control-family mapping (representative)](#nist-sp-800-53-rev-5-control-family-mapping-representative)
  - [Configuration Management (CM family)](#configuration-management-cm-family)
  - [AI-specific risk considerations](#ai-specific-risk-considerations)
  - [Open items / POA&M (stated honestly)](#open-items--poam-stated-honestly)
  - [Assessment artifacts we can provide](#assessment-artifacts-we-can-provide)
- [Container-runtime compliance (why "no Docker STIG")](#container-runtime-compliance-why-no-docker-stig)
  - [1. USG hardens the OS, not Docker](#1-usg-hardens-the-os-not-docker)
  - [2. There is no applicable DISA STIG for docker-ce](#2-there-is-no-applicable-disa-stig-for-docker-ce)
  - [3. How the container layer is secured (CIS Docker Benchmark alignment)](#3-how-the-container-layer-is-secured-cis-docker-benchmark-alignment)
  - [4. Optional evidence: docker-bench-security](#4-optional-evidence-docker-bench-security)
  - [5. Control mapping (NIST 800-53 Rev 5)](#5-control-mapping-nist-800-53-rev-5)
- [Software inventories](#software-inventories)

---

## Hardening posture

Both profiles apply **Canonical USG `usg fix disa_stig`** (the DISA-STIG remediation), which closes most of the benchmark. Rule-level view:

- What the build remediates on top of `usg fix`.
- What's an approved deviation.
- What stays an open POA&M.

Per-rule detail (rule IDs, rationale): **[operate.md → POA&M](operate.md#poam-findings-not-auto-remediated-by-the-build)** and the **[residual-remediation table](operate.md#residual-findings-auto-remediated-by-usg_remediate)**. The [DCSA / DoD RMF compliance posture](#dcsa--dod-rmf-compliance-posture) gives the same picture at the RMF level.

USG audit report auto-copies to `/opt/ia/` every run (HTML + XCCDF), readable by the admin (`sudo`) group. Regenerated after remediation + firewall, so it reflects the fully-built box. Hand it to your assessor; re-run any time:

```bash
sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml
```

### ✅ Additionally remediated by `usg_remediate` (every run, idempotent)

`usg fix` is stamped run-once and its in-role audit is a mid-build snapshot. The `usg_remediate` role runs **after** USG + the firewall and closes these (none can lose password/SSH login):

| Finding (SSG rule) | STIG ID | What we do |
| --- | --- | --- |
| Smart Card Logins in PAM (`smartcard_pam_enabled`) | n/a | comment `pam_pkcs11.so` out of the auth stack → stops the "no smart card found" spam (this fleet is **password-login only**) |
| `/var/log` file perms (`file_permissions_var_log_stig`) | UBTU-24-700010 | strip setuid/exec/other bits off log files |
| `/var/log/audit` mode (`directory_permissions_var_log_audit`) | UBTU-24-901380 | `0750` when auditd's `log_group` is non-root, `0700` when it is root — the required mode is conditional, and a flat `0750` fails the scan on a `log_group = root` box |
| **Privileged-command audit rules** (`audit_rules_privileged_commands_*`, `audit_rules_execution_*`) | UBTU-24-900080…900330 | `usg fix` writes only part of the set (`su`/`fdisk`/`kmod`/`modprobe`/`unix_update` pass, ~19 others fail). We write the remainder to `/etc/audit/rules.d/72-privileged-commands.rules` — existing paths only, skipping any command another file already covers |
| audit rules.d perms (`file_permissions_etc_audit_rulesd`) | UBTU-24-900040 | `chmod 0600` on anything with user-exec or group/other bits |
| journal dir + `journalctl` perms (`dir_permissions_system_journal`, `file_permissions_journalctl`) | UBTU-24-700020/700030 | journal dirs to `2750` or tighter; `journalctl` to `0740` (root-execute only — read logs with `sudo journalctl`) |
| Account lockout (`accounts_passwords_pam_faillock_*`) | UBTU-24-200610 | `deny`/`fail_interval`/`unlock_time`/`audit`/`silent` in `/etc/security/faillock.conf`. **`unlock_time` defaults to 900 s, not 0** — the benchmark accepts any value ≥ 0, and a permanent lock on a standalone laptop is a self-inflicted outage. Set `usg_faillock_unlock_time: 0` if your ISSM requires the literal reading |
| Failed-logon delay (`accounts_passwords_pam_faildelay_delay`) | UBTU-24-300017 | `pam_faildelay.so delay=4000000` in `common-auth`, placed **before** the terminal `requisite pam_deny.so` so it actually runs on a failed login |
| Remote time server (`chronyd_specify_remote_server`, `chronyd_server_directive`) | UBTU-24-600160 | write `server <host> iburst` to `sources.d`, drop `pool` (see **NTP** below) |
| ufw active (`check_ufw_active`) | UBTU-24-300041 | firewall roles enable ufw; re-asserted here |

### ⚠️ Approved deviations (documented, not "failures")

| Control | Why | Where |
| --- | --- | --- |
| Smart Card / CAC + SSSD (`smartcard_pam_enabled`, `service_sssd_enabled`, `sssd_enable_user_cert`) | password-login only; local accounts, no directory/CAC → **de-selected in the USG tailoring** so they don't count against you | `usg_disable_smartcard*` |
| ufw rate-limit **all** ports (`ufw_rate_limit`, UBTU-24-600200) | on `ai`, rate-limiting the Open WebUI / vLLM / Docling ports throttles inference. Only **management** ports (SSH/RDP/Cockpit/Dockge) are `ufw limit`ed | firewall roles |
| GNOME login-banner **text**, blank-screensaver, USB→`dta` *(development profile only; the AI nodes disable USB storage)* | mission requirements (DCSA banner, org wallpaper, USB data-transfer) | operate.md POA&M |
| Banner **text** rules (`banner_etc_issue_net`, `dconf_gnome_login_banner_text`, `banner_etc_profiled_ssh_confirm`) | these check for the **exact DoD** string; we deliberately show the DCSA banner instead. Three permanent findings, accepted by choice — they close only by abandoning the DCSA text | `usg_remediate` §1b |
| SSH banner **path** (`sshd_enable_warning_banner_net`) | the rule wants `Banner /etc/issue.net`; we point sshd at `/etc/dcsa-warning-banner`, a file USG never rewrites, so an interrupted re-run can't silently restore the DoD text. One finding traded for banner durability | `usg_remediate` §1b |
| USB storage driver (`kernel_module_usb-storage_disabled`) | the EMI laptop's data-transfer (`dta`) workflow needs USB mass storage. USBGuard now gates which devices are authorised at all, which is the compensating control | `usbguard` role |

### ❌ Open POA&M: need a secret or infra (NOT auto-applied)

| Finding | To close it |
| --- | --- |
| **UEFI/GRUB boot-loader password** (`grub2_uefi_password`, UBTU-24-102000) | The **only `high` finding left.** The `grub_password` role is written and skips until a hash is vaulted — generate one with `it-grub hash` and set `grub_password_pbkdf2`. This matters more here than the severity suggests: LUKS is TPM-sealed to PCR 7 only, which does not measure the kernel command line, so without it physical access → root shell on decrypted data |
| **Audit-log offload** (`auditd_offload_logs`, UBTU-24-900950) | The rule wants *"a crontab script running weekly to offload audit events of standalone systems"* — **not** necessarily a remote collector, so this is closable on an air-gapped box with a weekly offload to removable media. Needs a destination decision first |
| **Password hashing rounds** (`accounts_password_pam_unix_rounds_password_auth`, UBTU-24-400220) | Implemented but **off by default** (`usg_fix_pam_rounds`). The benchmark's value (100000) is an SHA-512 iteration count, but Ubuntu 24.04 hashes with **yescrypt**, where `rounds` is a small cost parameter libxcrypt clamps into single digits. Measure `passwd` cost on a test box before enabling |
| **Full-disk encryption** (`Encrypt Partitions`) | bake LUKS into the Ubuntu autoinstall (pre-install; see operate.md) |

> **FIPS mode (`is_fips_mode_enabled`) is ENABLED** (`usg_enable_fips: true`). `usg_harden` runs `pro enable fips-updates` (installs the FIPS kernel/modules) and flags a reboot. The check passes **after that reboot**. It swaps the running kernel: validate on a throwaway box if you run unusual crypto/dev tooling. Set `usg_enable_fips: false` to defer it (POA&M).
>
> **GPUs + FIPS:** Canonical's prebuilt NVIDIA modules are kernel-flavour-locked, so the FIPS kernel swap would break `nvidia-smi`. On the `ai` profile the **`gpu_fips_module`** role stages the matching `linux-modules-nvidia-*-fips` module (from the `fips-updates` repo) in the same run, so the GPU comes back automatically on the single FIPS reboot. No manual DKMS/driver rebuild.

### NTP / time source

The chrony remediation defaults `usg_chrony_servers` to **`ntp.ubuntu.com`**. Change this to your enclave's internal NTP server(s) in `group_vars/all.yml`. The STIG config check passes either way, but actual time sync needs a *reachable* server (an air-gapped net can't reach the public pool):

```yaml
# group_vars/all.yml
usg_chrony_servers:
  - 10.0.0.1          # your site time server(s), written as `server <host> iburst`
  - 10.0.0.2
```

Set `usg_chrony_servers: []` to leave chrony untouched (the finding then stays a POA&M).

### Admin working folders `/opt/ia` and `/opt/it`

The `managed_dirs` role creates both on every box:

- Owned `root:{{ ia_it_group }}` (default `sudo`), mode `2770` + a default ACL.
- Only admins (the `sudo` group) can enter them; no `sudo` prefix needed to create/edit files or run commands inside.
- Files created there stay group-shared even under the STIG's `umask 077`.
- `/opt/ia` doubles as the USG report drop.
- Change the owning group with `ia_it_group`, or set `managed_dirs_enabled: false` to skip.

---

## DCSA / DoD RMF compliance posture

Summarizes how the two-node AI inference platform and its automated build (`ubuntu-stig-build`) implement DoD/DCSA security controls, to support an RMF Assessment & Authorization (A&A) package and the DCSA ISSP discussion.

> **Scope / disclaimer.** This is a **control-implementation summary**, not an authorization. The system operates under the Risk Management Framework (RMF); the **Authorizing Official (AO)** makes the final risk determination and grants the ATO. This document describes the technical baseline and evidence we bring to that decision, and states our open items (POA&Ms) honestly.

### Authorization context

- **Process:** NIST RMF (DoDI 8510.01) as administered by DCSA (DAAPM / NIST SP 800-53 Rev 5), assessed in eMASS.
- **Categorization:** As a National Security System, categorized per **CNSSI 1253** (confidentiality/integrity/availability) with the applicable classified/overlay controls; final categorization set with the ISSM/ISSP.
- **Control baseline:** NIST SP 800-53 Rev 5, implemented via the **DISA Canonical Ubuntu 24.04 LTS STIG** using **FIPS 140-validated cryptography**.

### System description

Self-hosted, on-premises AI chat/document system on two hardened Ubuntu 24.04 servers. Runs **fully disconnected (air-gapped)** after build: models and inference run locally, no external/cloud AI calls at runtime.

All data (prompts, responses, documents, vector index) stays inside the accreditation boundary. **Inference only**: static weights are read-only, not retrained/updated by user data.

- **System 1 (`dev-ai1`):** user chat UI (Open WebUI), chat LLM engine (vLLM), database (PostgreSQL/pgvector: accounts, chats, document vectors), websocket/cache store (Redis).
- **System 2 (`dev-ai2`):** document extraction (Docling, Apache Tika), embedding + vision models (vLLM), monitoring (LGTM/Grafana), experiment tracking + model registry (MLflow), knowledge-base sync (oikb).

### Compliance baseline (what the build enforces)

Every box is provisioned by a version-controlled Ansible build: repeatable, auditable, identical across the fleet (supports CM-2/CM-6, configuration-as-code evidence). Rule-level view of what's additionally remediated, deviated, or left open: [Hardening posture](#hardening-posture) above.

| Area | Implementation |
|------|----------------|
| **STIG hardening** | Canonical **USG** applies the **DISA `disa_stig` profile**; `usg audit` produces XCCDF + HTML compliance reports (evidence artifacts). |
| **FIPS cryptography** | **Ubuntu Pro FIPS** (FIPS 140-validated modules); FIPS kernel enabled fleet-wide (`fips=1`), verified via `/proc/sys/crypto/fips_enabled`. |
| **Data at rest** | **LUKS full-disk encryption**; TPM2-sealed auto-unlock bound to Secure Boot state (PCR 7); install passphrase retained as recovery. |
| **Audit** | `auditd` enabled with STIG rules; low-disk actions configured; journald/log permissions hardened. |
| **Identity & access** | Local least-privilege accounts and groups; locked (non-empty) default passwords; PAM **faillock** (lockout), fail-delay, password policy, session timeout + concurrent-session limits. |
| **Boundary protection** | Host firewall (**ufw default-deny inbound**, rate-limited); only required service ports opened, cross-node ports restricted by source IP. |
| **Access banner** | **DCSA Authorized Warning Banner** presented at GUI/console/SSH logon (the unclassified EMI variant substitutes an unclassified EMI warning banner; the banner-enable control is satisfied in both cases). |
| **Least functionality** | Lean package set; unneeded listening services disabled + masked (e.g. **CUPS**/`:631` on all profiles, `disable_cups`); privileged management surfaces (Cockpit, Dockge) restricted to admin subnets. |
| **Removable media** | USB mass storage disabled on the AI nodes (USG blacklists the `usb-storage` module on a server; no carve-out). The authorized data-transfer group carve-out (udev + polkit) is development-profile only and is not enabled here. |
| **Continuous monitoring** | `usg audit` re-run at end of build and re-runnable any time; OpenSCAP available offline; Ubuntu Pro **ESM + Livepatch** for ongoing vulnerability/patch management. |

### NIST SP 800-53 Rev 5 control-family mapping (representative)

| Family | How this baseline supports it |
|--------|-------------------------------|
| **AC** Access Control | Least-privilege accounts/groups, sudo control, session limits/timeout, warning banner, restricted admin interfaces. |
| **AU** Audit & Accountability | `auditd` with STIG ruleset (host); **Open WebUI audit log** (`AUDIT_LOG_LEVEL=METADATA`, attributable user activity: who/endpoint/when/result) plus OpenTelemetry to the LGTM/Grafana stack on System 2; log-permission hardening. |
| **CM** Configuration Management | Config-as-code (Ansible), pinned package/image versions, reproducible baseline, `usg` compliance scans. |
| **IA** Identification & Auth | PAM password policy/faillock; FIPS-validated crypto for auth (IA-7). *(CAC/PIV, see POA&M.)* |
| **SC** System & Comm. Protection | FIPS 140-validated crypto (SC-13), LUKS data-at-rest (SC-28), host firewall/boundary (SC-7), TLS for management. |
| **SI** System & Info Integrity | ClamAV (dev baseline), Ubuntu Pro patching/ESM/Livepatch, STIG integrity settings. |
| **SR/SA** Supply Chain / Sys & Svcs Acq. | Pinned open-source component versions; images buildable/mirrorable internally; model weights hash-verifiable and stageable offline. |

### Configuration Management (CM family)

The build is configuration-as-code, so it maps directly onto the CM family. The `ubuntu-stig-build` git repo is the authoritative baseline; every box is provisioned from it, so the fielded configuration equals the documented one.

| Control | How the build meets it |
|---|---|
| **CM-2 Baseline Configuration** | The full baseline is version-controlled Ansible (`group_vars/all.yml`, roles, compose files) in git. Commits and tags version the baseline and support rollback. |
| **CM-2(2) Automation support** | `ansible-pull` is idempotent: a re-run applies only the delta and corrects drift back to baseline. `usg_remediate` re-asserts residual STIG settings every run; `usg audit` regenerates current-state evidence on demand. |
| **CM-3 Configuration Change Control** | Changes are made in the repo and flow through git commits + pull requests (reviewable diffs, full history). The repo is the change record; a re-pull overwrites ad-hoc box edits, so the baseline stays authoritative. |
| **CM-4 Impact Analysis** | Validate on a throwaway VM before imaging production (the DISA profile can be breaking). `HARDEN=0` runs an audit-only first pass to assess impact before `usg fix` is applied. |
| **CM-5 Access Restrictions for Change** | Repo write access gates baseline changes. On the box, config changes need root/sudo; admin folders `/opt/ia` and `/opt/it` are restricted to the `sudo` group (mode `2770` + ACL); secrets (Pro token, LUKS passphrase, DB/API keys) stay out-of-band, root-only, never in the repo. |
| **CM-6 Configuration Settings** | Mandated settings come from the DISA STIG applied by USG (`usg fix disa_stig`) plus documented tunables in `group_vars/all.yml` (lockout counts, timeouts, audit retention, banner, FIPS). `usg audit` (XCCDF + HTML) is the settings-compliance evidence; deviations are enumerated in [Hardening posture](#hardening-posture). |
| **CM-7 Least Functionality** | Lean per-profile package sets; provisioning services installed but disabled + stopped; `ufw` default-deny inbound with only required ports opened; Cockpit/Dockge restricted to admin subnets; USB mass storage disabled on the AI nodes. |
| **CM-8 System Component Inventory** | Component versions pinned across `group_vars`, the compose files, and the Dockerfiles. Per-profile software lists ([dev-workstation](dev-workstation.md#software-list), [ai-stack](ai-stack.md#software-list)) enumerate tool, version, publisher, and purpose; images and model repos are listed with versions. |
| **CM-9 Configuration Management Plan** | Organizational/procedural control. This repo is the technical baseline the site CM Plan references; the plan itself is a program document. |
| **CM-10 / CM-11 Software Usage & User-Installed Software** | Components are open-source with tracked licenses (software lists). Standard users are non-privileged; installs require sudo. The `docker` group (root-equivalent) is a documented developer-workstation exception; no unmanaged package channels are enabled. |
| **CM-14 Signed Components** | Third-party apt repos (Docker, NVIDIA, Microsoft) are added with GPG-key verification; distro packages are apt-signed. Images and model weights are hash-verifiable and mirrorable to an internal registry for provenance. Full SBOM/signing attestation is an SSP/POA&M item. |

### AI-specific risk considerations

Questions an AO/ISSP raises about an AI system specifically; our position:

- **Data stays in-boundary.** No runtime calls to external/cloud AI services; inference is local. Accredit at the classification level of the data it will process.
- **No model learning from user data.** Inference runs against static, read-only weights; prompts/responses are not used to retrain.
- **Data at rest is encrypted** (LUKS); chats/documents/vectors persist only in encrypted local storage inside the boundary.
- **Software provenance.** All components open-source with **pinned versions**; container images and the **open-weight models** (Apache-2.0) can be **hash-verified and mirrored to an internal registry** for air-gapped operation (supports SR/SA controls and software assurance review).
- **User accountability.** Application access via named local accounts; host `auditd` plus Open WebUI/telemetry provide an activity record.
- **Spillage/handling** governed by the site's data-handling procedures; the platform does not exfiltrate and can run disconnected.

### Open items / POA&M (stated honestly)

Known deviations to remediate or risk-accept with the AO. None hidden; each is documented in [`operate.md`](operate.md) and `group_vars/all.yml`.

| Item | Status / plan |
|------|---------------|
| **CAC/PIV multifactor (IA-2)** | Currently **password-only** (accounts locked until a password is set). CAC/PIV is the DoD expectation; the build de-selects the smartcard STIG rules as a documented deviation and can re-enable them once CAC readers/certs/SSSD are fielded. **Primary POA&M for the AO discussion.** |
| **GRUB/UEFI bootloader password (CM/AC)** | Ships as a safe sentinel; set a vaulted PBKDF2 hash to close. |
| **Audit-log offload (AU-4/AU-6)** | Local audit logging is on; central `audisp-remote` collector not yet configured (needs a log server). POA&M until a collector exists. |
| **FIPS inside inference containers** | **Host is fully FIPS**; the inference/extraction containers (vLLM, and docling via its bundled OpenCV/OpenSSL) use standard crypto. Those images ship no FIPS provider and aren't FIPS-validated, so on the FIPS host their OpenSSL selftest aborts unless carved out. Container traffic is host-local/enclave-internal. Documented POA&M; host-level FIPS is what the STIG assesses. |
| **AI/ML software assurance** | vLLM, Open WebUI, Docling, etc. are open-source and not separately accredited; recommend internal image scanning + registry mirroring as part of the SSP. |

### Assessment artifacts we can provide

- **This repository** (`ubuntu-stig-build`): the full, reviewable configuration-as-code baseline.
- **`usg audit` reports** (XCCDF `.xml` + HTML) collected to `/opt/ia` on each box. STIG compliance evidence per host.
- **[`operate.md`](operate.md):** control-by-control subsystem detail and every documented deviation/POA&M.
- **[Container-runtime compliance](#container-runtime-compliance-why-no-docker-stig):** why there's no docker-ce STIG and how the container layer is secured (CIS Docker Benchmark).
- **Architecture overview:** [`operate.md`](operate.md).
- Host inventory, FIPS status, and encryption/TPM binding evidence on request.

*Prepared to support A&A discussions. Final control selection, categorization, and authorization are determined with the ISSM/ISSP and the AO.*

---

## Container-runtime compliance (why "no Docker STIG")

Common question: the OS is STIG-hardened by USG, is Docker STIG'd too? Short answer: **USG does not cover Docker, there is no applicable DISA STIG for the Docker engine we run, and the container layer is secured to the CIS Docker Benchmark.**

### 1. USG hardens the OS, not Docker

Canonical's USG applies the **DISA Ubuntu 24.04 LTS STIG**, an **operating-system** benchmark. It does not assess or configure the Docker daemon, container settings, or images. "The box passed `usg audit`" is an **OS** statement; the container runtime is a separate control surface.

### 2. There is no applicable DISA STIG for docker-ce

- The only Docker STIG DISA publishes is the **"Docker Enterprise 2.x Linux/UNIX STIG"**, written for **Docker Enterprise / Mirantis (UCP, DTR, RBAC)**, a different product. We run **`docker-ce`** (Community Edition). The Enterprise STIG's controls are product-specific (UCP/DTR web consoles, enterprise RBAC) and **do not map** to a plain `docker-ce` + Compose host.
- DISA's **Container Platform SRG** and the **Kubernetes STIG** target orchestration platforms (OpenShift/Kubernetes). We run **plain Docker Compose**, no orchestrator, so those don't apply.

**Conclusion:** no drop-in STIG to run against this Docker host. That's why industry and DoD assessors use the **CIS Docker Benchmark** for `docker-ce` instead.

### 3. How the container layer *is* secured (CIS Docker Benchmark alignment)

The `docker_hardening` role (ai profile) applies CIS-aligned daemon settings, **merged** into `/etc/docker/daemon.json` (the NVIDIA GPU runtime is preserved):

| Setting | CIS ref | Effect |
|---------|---------|--------|
| `no-new-privileges: true` | 5.25 (daemon-wide) | No container can gain privileges via setuid binaries |
| `live-restore: true` | 2.14 | Containers survive a daemon restart (availability) |
| `userland-proxy: false` | 2.15 | Kernel hairpin NAT instead of `docker-proxy` (smaller attack surface) |
| `log-opts` size/rotate | 6.x | Bounded container log growth |

Plus, by design of the stack:

- **No privileged containers**, no host PID/IPC/network sharing; the AI workload runs unprivileged.
- **Least capabilities** where practical (e.g. Redis runs `cap_drop: ALL` + only `SETGID/SETUID/DAC_OVERRIDE`).
- **Network isolation.** Services share a single user-defined bridge (`oi`); only required ports published, cross-node ports firewall-restricted to the peer (USG's ufw default-deny + `ai_firewall`).
- **Docker socket** not mounted into workload containers (only Dockge, an admin tool, restricted to admins).
- **Host is FIPS + STIG-hardened** (the kernel/OS the containers share), and the **model runs inference only**. See [AI-specific risk considerations](#ai-specific-risk-considerations).
- **Image provenance.** All images pinned by exact tag, can be **mirrored to an internal registry** and hash-verified for air-gap (supply-chain / SR controls).

### 4. Optional evidence: docker-bench-security

Run CIS's own scanner and file the report with the USG reports in `/opt/ia`:

```bash
sudo docker run --rm --net host --pid host --userns host --cap-add audit_control \
  -v /etc:/etc:ro -v /var/lib:/var/lib:ro -v /usr/lib/systemd:/usr/lib/systemd:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  docker/docker-bench-security | sudo tee /opt/ia/docker-bench-$(date +%Y%m%d).txt
```

### 5. Control mapping (NIST 800-53 Rev 5)

| Control | How the container layer supports it |
|---------|-------------------------------------|
| **CM-6 / CM-7** | Hardened, version-controlled daemon config; least functionality (no privileged/host-namespace containers) |
| **AC-6** | `no-new-privileges`, least-capability containers, no workload access to the Docker socket |
| **SC-7** | User-defined network isolation + host firewall (default-deny), only required ports published |
| **SI-7 / SR** | Pinned, mirrorable, hash-verifiable images; reproducible build |

*Bottom line for the AO/ISSP: the host is STIG+FIPS hardened by USG; the Docker layer (no docker-ce STIG exists) is hardened to the CIS Docker Benchmark and documented here. `docker-bench-security` provides on-demand evidence.*

---

## Software inventories

Per-profile software lists (Software/Tool, Version, Publisher, Purpose) live with each profile page:

- **[Developer workstation software list](dev-workstation.md#software-list)**
- **[AI stack software list](ai-stack.md#software-list)**

Everything is pinned and reproducible via the `ubuntu-stig-build` baseline, and can be mirrored to an internal registry / staged offline for air-gap. External data sources read by oikb (GitLab / Confluence / S3, per `site.yml`) are org services, not installed software.
