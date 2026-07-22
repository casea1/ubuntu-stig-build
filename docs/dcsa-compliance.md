# DCSA / DoD Compliance Posture — AI Inference Stack

**Purpose.** This document summarizes how the two-node AI inference platform and its
automated build (`ubuntu-stig-build`) implement DoD/DCSA security controls, to support
an RMF Assessment & Authorization (A&A) package and the discussion with our DCSA
Information System Security Professional (ISSP) / rep.

> **Scope / disclaimer.** This is a **control-implementation summary**, not an
> authorization. The system operates under the Risk Management Framework (RMF); the
> **Authorizing Official (AO)** makes the final risk determination and grants the ATO.
> This document describes the *technical baseline and evidence* we bring to that
> decision, and states our open items (POA&Ms) honestly.

---

## Contents

- [1. Authorization context](#1-authorization-context)
- [2. System description](#2-system-description)
- [3. Compliance baseline (what the build enforces)](#3-compliance-baseline-what-the-build-enforces)
- [4. NIST SP 800-53 Rev 5 control-family mapping (representative)](#4-nist-sp-800-53-rev-5-control-family-mapping-representative)
- [5. AI-specific risk considerations](#5-ai-specific-risk-considerations)
- [6. Open items / POA&M (stated honestly)](#6-open-items--poam-stated-honestly)
- [7. Assessment artifacts we can provide](#7-assessment-artifacts-we-can-provide)
- [8. Talking points for the DCSA meeting](#8-talking-points-for-the-dcsa-meeting)

## 1. Authorization context

- **Process:** NIST RMF (DoDI 8510.01) as administered by DCSA (DAAPM / NIST SP 800-53
  Rev 5), assessed in eMASS.
- **Categorization:** As a National Security System, categorized per **CNSSI 1253**
  (confidentiality/integrity/availability) with the applicable classified/overlay
  controls; final categorization set with the ISSM/ISSP.
- **Control baseline:** NIST SP 800-53 Rev 5, implemented technically via the
  **DISA Canonical Ubuntu 24.04 LTS STIG** using **FIPS 140-validated cryptography**.

## 2. System description

A **self-hosted, on-premises** AI chat/document system on two hardened Ubuntu 24.04
servers. It can run **fully disconnected (air-gapped)** after build — models and all
inference run **locally**, with **no external/cloud AI calls at runtime**. All data
(prompts, responses, documents, vector index) stays **inside the accreditation
boundary**. The language model performs **inference only** — the static model weights
are read-only and are **not retrained/updated by user data**.

- **System 1 (`dev-ai1`)** — user chat UI (Open WebUI), the LLM engine (vLLM), database
  (PostgreSQL/pgvector), session store (Redis), local monitoring (LGTM/Grafana).
- **System 2 (`dev-ai2`)** — document text extraction (Docling, Apache Tika).

## 3. Compliance baseline (what the build enforces)

Every box is provisioned by an **automated, version-controlled Ansible build** —
giving a **repeatable, auditable, identical** configuration across the fleet
(supports CM-2/CM-6, configuration-as-code evidence).

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
| **Removable media** | USB mass storage restricted to an authorized data-transfer group (udev + polkit). |
| **Continuous monitoring** | `usg audit` re-run at end of build and re-runnable any time; OpenSCAP available offline; Ubuntu Pro **ESM + Livepatch** for ongoing vulnerability/patch management. |

## 4. NIST SP 800-53 Rev 5 control-family mapping (representative)

| Family | How this baseline supports it |
|--------|-------------------------------|
| **AC** Access Control | Least-privilege accounts/groups, sudo control, session limits/timeout, warning banner, restricted admin interfaces. |
| **AU** Audit & Accountability | `auditd` with STIG ruleset (host); **Open WebUI audit log** (`AUDIT_LOG_LEVEL=METADATA` — attributable user activity: who/endpoint/when/result) plus OpenTelemetry to the local LGTM stack; log-permission hardening. |
| **CM** Configuration Management | Config-as-code (Ansible), pinned package/image versions, reproducible baseline, `usg` compliance scans. |
| **IA** Identification & Auth | PAM password policy/faillock; FIPS-validated crypto for auth (IA-7). *(CAC/PIV — see POA&M.)* |
| **SC** System & Comm. Protection | FIPS 140-validated crypto (SC-13), LUKS data-at-rest (SC-28), host firewall/boundary (SC-7), TLS for management. |
| **SI** System & Info Integrity | ClamAV (dev baseline), Ubuntu Pro patching/ESM/Livepatch, STIG integrity settings. |
| **SR/SA** Supply Chain / Sys & Svcs Acq. | Pinned open-source component versions; images buildable/mirrorable internally; model weights hash-verifiable and stageable offline. |

## 5. AI-specific risk considerations

These are the questions an AO/ISSP will raise about *an AI system* specifically; our position:

- **Data stays in-boundary.** No runtime calls to external/cloud AI services; inference
  is local. Accredit the system at the classification level of the data it will process.
- **No model learning from user data.** The model runs inference against static,
  read-only weights; user prompts/responses are not used to retrain the model.
- **Data at rest is encrypted** (LUKS); chats/documents/vectors persist only in
  encrypted local storage inside the boundary.
- **Software provenance.** All components are open-source with **pinned versions**;
  container images and the **open-weight models** (Apache-2.0) can be **hash-verified and
  mirrored to an internal registry** for air-gapped operation (supports SR/SA controls
  and software assurance review).
- **User accountability.** Application access via named local accounts; host `auditd`
  plus Open WebUI/telemetry provide an activity record.
- **Spillage/handling** is governed by the site's data-handling procedures; the platform
  does not exfiltrate and can be operated disconnected.

## 6. Open items / POA&M (stated honestly)

These are known deviations to remediate or risk-accept with the AO. None are hidden;
each is documented in `OPERATIONS.md` and `group_vars/all.yml`.

| Item | Status / plan |
|------|---------------|
| **CAC/PIV multifactor (IA-2)** | Currently **password-only** (accounts locked until a password is set). CAC/PIV is the DoD expectation; the build de-selects the smartcard STIG rules as a documented deviation and can re-enable them once CAC readers/certs/SSSD are fielded. **Primary POA&M for the AO discussion.** |
| **GRUB/UEFI bootloader password (CM/AC)** | Ships as a safe sentinel; set a vaulted PBKDF2 hash to close. |
| **Audit-log offload (AU-4/AU-6)** | Local audit logging is on; central `audisp-remote` collector not yet configured (needs a log server). POA&M until a collector exists. |
| **FIPS inside inference containers** | **Host is fully FIPS**; the vLLM container uses standard crypto (the image ships no FIPS provider, and vLLM/PyTorch are not FIPS-validated). Container traffic is host-local/enclave-internal. Documented POA&M; host-level FIPS is what the STIG assesses. |
| **AI/ML software assurance** | vLLM, Open WebUI, Docling, etc. are open-source and not separately accredited; recommend internal image scanning + registry mirroring as part of the SSP. |
| **USB data-transfer carve-out** | USB mass storage is re-enabled but restricted to an authorized group (mission need); documented deviation from the blanket-disable STIG control. |

## 7. Assessment artifacts we can provide

- **This repository** (`ubuntu-stig-build`) — the full, reviewable configuration-as-code baseline.
- **`usg audit` reports** (XCCDF `.xml` + HTML) collected to `/opt/ia` on each box — STIG compliance evidence per host.
- **`OPERATIONS.md`** — control-by-control subsystem detail and every documented deviation/POA&M.
- **Architecture overview** — `docs/ai-stack-kb.md`.
- Host inventory, FIPS status, and encryption/TPM binding evidence on request.

## 8. Talking points for the DCSA meeting

1. **On-prem, air-gap-capable, no cloud** — the data never leaves the boundary; this is the core risk-reduction argument for AI in a secure environment.
2. **STIG + FIPS baseline is automated and reproducible** — every box is identical and re-scannable; we can produce current `usg audit` evidence on demand.
3. **We're bringing our POA&Ms, not hiding them** — CAC/PIV, bootloader password, audit offload, and container-FIPS are the open items with clear remediation paths.
4. **Request:** authorization to field this baseline at the applicable classification level, with the POA&M items tracked in eMASS.

---
*Prepared to support A&A discussions. Final control selection, categorization, and
authorization are determined with the ISSM/ISSP and the AO.*
