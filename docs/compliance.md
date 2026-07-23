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
| `/var/log/audit` mode (`directory_permissions_var_log_audit`) | n/a | `chmod 0750` |
| Remote time server (`chronyd_specify_remote_server`, `chronyd_server_directive`) | UBTU-24-600160 | write `server <host> iburst` to `sources.d`, drop `pool` (see **NTP** below) |
| ufw active (`check_ufw_active`) | UBTU-24-300041 | firewall roles enable ufw; re-asserted here |

### ⚠️ Approved deviations (documented, not "failures")

| Control | Why | Where |
| --- | --- | --- |
| Smart Card / CAC + SSSD (`smartcard_pam_enabled`, `service_sssd_enabled`, `sssd_enable_user_cert`) | password-login only; local accounts, no directory/CAC → **de-selected in the USG tailoring** so they don't count against you | `usg_disable_smartcard*` |
| ufw rate-limit **all** ports (`ufw_rate_limit`, UBTU-24-600200) | on `ai`, rate-limiting the Open WebUI / vLLM / Docling ports throttles inference. Only **management** ports (SSH/RDP/Cockpit/Portainer) are `ufw limit`ed | firewall roles |
| GNOME login-banner **text**, blank-screensaver, USB→`dta` *(development profile only; the AI nodes disable USB storage)* | mission requirements (DCSA banner, org wallpaper, USB data-transfer) | operate.md POA&M |

### ❌ Open POA&M: need a secret or infra (NOT auto-applied)

| Finding | To close it |
| --- | --- |
| **UEFI/GRUB boot-loader password** (`grub2_uefi_password`) | provide a hashed password (`grub2-mkpasswd-pbkdf2`) out-of-band |
| **Audit-log offload** (`auditd_offload_logs`) | point at a remote collector (`stig_audit_remote_server`) |
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

- **System 1 (`dev-ai1`):** user chat UI (Open WebUI), chat LLM engine (vLLM), database (PostgreSQL/pgvector), session store (Redis).
- **System 2 (`dev-ai2`):** document extraction (Docling, Apache Tika), embedding + vision models (vLLM), monitoring (LGTM/Grafana), knowledge-base sync (oikb).

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
| **Access banner** | **DCSA Authorized Warning Banner** presented at GUI/console/SSH logon. |
| **Least functionality** | Lean package set; privileged management surfaces (Cockpit, Portainer) restricted to admin subnets. |
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
- **Docker socket** not mounted into workload containers (only Portainer, an admin tool, restricted to admins).
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
