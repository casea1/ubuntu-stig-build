# Docker / Container-Runtime Compliance — Why "no Docker STIG," and How It's Secured

**For the IA team / DCSA.** A common question: *the OS is STIG-hardened by USG — is Docker STIG'd too?*
Short answer: **USG does not cover Docker, there is no applicable DISA STIG for the Docker engine we run,
and the container layer is instead secured to the CIS Docker Benchmark.** This document explains that
position so it can be stated plainly in the A&A package.

---

## 1. USG hardens the OS, not Docker

Canonical's USG applies the **DISA Ubuntu 24.04 LTS STIG** — an **operating-system** benchmark. It does
not assess or configure the Docker daemon, container settings, or images. So "the box passed `usg audit`"
is an **OS** statement; the container runtime is a separate control surface.

## 2. There is no applicable DISA STIG for docker-ce

- The only Docker STIG DISA publishes is the **"Docker Enterprise 2.x Linux/UNIX STIG"** — written for
  **Docker Enterprise / Mirantis (UCP, DTR, RBAC)**, a *different product*. We run **`docker-ce`** (the
  open-source Community Edition). The Enterprise STIG's controls are largely product-specific (UCP/DTR
  web consoles, enterprise RBAC) and **do not map** to a plain `docker-ce` + Compose host.
- DISA's **Container Platform SRG** and the **Kubernetes STIG** target orchestration platforms
  (OpenShift/Kubernetes). We run **plain Docker Compose**, no orchestrator, so those don't apply either.

**Conclusion:** there is no drop-in STIG to run against this Docker host — which is expected, and is why
industry (and DoD assessors) use the **CIS Docker Benchmark** for `docker-ce` instead.

## 3. How the container layer *is* secured (CIS Docker Benchmark alignment)

The `docker_hardening` role (ai profile) applies CIS-aligned daemon settings, **merged** into
`/etc/docker/daemon.json` (the NVIDIA GPU runtime is preserved):

| Setting | CIS ref | Effect |
|---------|---------|--------|
| `no-new-privileges: true` | 5.25 (daemon-wide) | No container can gain privileges via setuid binaries |
| `live-restore: true` | 2.14 | Containers survive a daemon restart (availability) |
| `userland-proxy: false` | 2.15 | Kernel hairpin NAT instead of `docker-proxy` — smaller attack surface |
| `log-opts` size/rotate | 6.x | Bounded container log growth |

Plus, by design of the stack itself:

- **No privileged containers**, no host PID/IPC/network sharing; the AI workload runs unprivileged.
- **Least capabilities** where practical (e.g. Redis runs `cap_drop: ALL` + only `SETGID/SETUID/DAC_OVERRIDE`).
- **Network isolation** — services share a single user-defined bridge (`oi`); only the required ports are
  published, and cross-node ports are firewall-restricted to the peer (USG's ufw default-deny + `ai_firewall`).
- **Docker socket** is not mounted into workload containers (only Portainer, an admin tool, restricted to
  admins).
- **Host is FIPS + STIG-hardened** (the kernel/OS the containers share), and the **model runs inference
  only** — see `dcsa-compliance.md`.
- **Image provenance** — all images are pinned by exact tag and can be **mirrored to an internal registry**
  and hash-verified for air-gap (supply-chain / SR controls).

## 4. Optional evidence: docker-bench-security

For an assessment artifact, run CIS's own scanner and file the report with the USG reports in `/opt/ia`:

```bash
sudo docker run --rm --net host --pid host --userns host --cap-add audit_control \
  -v /etc:/etc:ro -v /var/lib:/var/lib:ro -v /usr/lib/systemd:/usr/lib/systemd:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  docker/docker-bench-security | sudo tee /opt/ia/docker-bench-$(date +%Y%m%d).txt
```

## 5. Control mapping (NIST 800-53 Rev 5)

| Control | How the container layer supports it |
|---------|-------------------------------------|
| **CM-6 / CM-7** | Hardened, version-controlled daemon config; least functionality (no privileged/host-namespace containers) |
| **AC-6** | `no-new-privileges`, least-capability containers, no workload access to the Docker socket |
| **SC-7** | User-defined network isolation + host firewall (default-deny), only required ports published |
| **SI-7 / SR** | Pinned, mirrorable, hash-verifiable images; reproducible build |

---
*Bottom line for the AO/ISSP: the host is STIG+FIPS hardened by USG; the Docker layer — for which no
docker-ce STIG exists — is hardened to the CIS Docker Benchmark and documented here. `docker-bench-security`
provides on-demand evidence.*
