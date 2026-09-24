# Reference

Lookup tables. For "how do I do X", see [procedures.md](procedures.md).

## Contents

| | |
|---|---|
| **[Traps](#traps)** | things that have already cost us a box — read once |
| **[Profiles](#profiles)** | what each one builds |
| **[Commands](#commands)** | every `it-*` and what it does |
| **[Paths](#paths)** | where everything lives |
| **[Configuration](#configuration)** | the variables worth knowing |
| **[AI stack](#ai-stack)** | nodes, ports, stacks, volumes, models |
| **[AI nodes — as-built](#ai-nodes--as-built-2026-08-28)** | what the two boxes actually run, drift and faults included |
| **[Software inventory](#software-inventory)** | IA/DCSA inventory per profile |

---

## Traps

Each of these caused a real outage or a wrong conclusion.

**1. Docker bypasses ufw.** Published container ports are DNAT'd before ufw's INPUT chain, so ufw rules do not filter them. Confirmed on dev-ai2: port 5000 was absent from ufw and still reachable from the LAN. `DOCKER-USER` is empty. MLflow is protected by an nginx allow-list instead; every other published port is effectively open on the LAN. The systemic fix — `DOCKER-USER` rules in `ai_firewall` — is not written yet.

**2. Ansible overwrites on-box edits.** *(To update a live AI node without this happening, skip the `ai-runtime` tag — [procedures.md §5.8](procedures.md#58-update-a-live-ai-node-without-touching-the-containers).)* Every file `ai_compose` places is a plain `copy`/`template`: `compose.yaml`, `.env`, `fips_off`, dashboards. Only `.oikb.yaml` is preserved. A hand-edit is lost on the next pull, and the container is recreated with it. For a genuine per-box exception use `compose.override.yaml`, which nothing manages.

**3. Ansible's `copy` and `link` only ever create.** Removing something from a profile needs an explicit `state: absent` task, or a box that got it from an earlier build keeps it forever. `it_scripts` does this for the AI and EMI tooling; copy that pattern.

**4. ClamAV silently does nothing on a FIPS host.** OpenSSL in FIPS mode refuses MD5, which is what ClamAV hashes content with, so the engine loads every signature and then scans **zero bytes**, reports every file clean, and exits 0. No error an operator would see. Upstream [clamav#1786](https://github.com/Cisco-Talos/clamav/issues/1786), open, no fix, and not configurable around — Ubuntu's FIPS OpenSSL takes FIPS from the kernel flag, so even `OPENSSL_CONF=/dev/null` fails. The fix is `clamav_container`. **`sudo it-clamav test` is the only thing that settles it.**

**5. nmap does not run on a FIPS box either.** It initializes OpenSSL at startup, the FIPS provider gives it no usable cipher suite, and it quits before probing anything — `library has no ciphers`. Same root cause as trap 4 and equally unconfigurable: nmap links the host OpenSSL. Fixed the same way — `nmap_container` builds an image on a stock base and `it-vulnscan` falls back to it, reporting `OK (via container)`. When neither works it records `NMAP-FAULT` and item 28 FAILs. **A vuln report reading "0 open ports, nothing flagged" because the scanner never started is the exact failure this repo keeps meeting.**

**6. clamd needs 60–90 s after a restart** before its socket answers — it binds only after loading ~3.6M signatures. A test in that window falls back to the broken host engine and looks exactly like a broken container.

**7. The FIPS carve-out for containers.** vLLM and Docling images have no FIPS OpenSSL provider and abort at startup, so they bind-mount a `fips_off` file over `/proc/sys/crypto/fips_enabled`. The host kernel stays FIPS. Do not "clean this up".

**8. Docling's models are baked into its image**, with runtime downloads disabled. Mounting a volume over its model cache **hides** them and docling crash-loops. To add a model, mount its own subdirectory, never the parent.

**9. Image tags are pinned**, so `docker compose pull` is not an update. Patching a container means editing the tag in this repo.

**10. Volumes are external**, so `docker compose down -v` cannot delete model weights or databases. It also means Postgres keeps its original password on an existing volume regardless of the env var.

**11. Open WebUI RAG settings are `PersistentConfig`.** Env seeds a *fresh* database only. On an existing box they must be changed in the UI.

**12. SSG's two cron audit OVALs disagree about a trailing slash.** One STIG rule (UBTU-24-200270), two automated checks, and they want the watch written differently — verified against `ssg-ubuntu2404-ds.xml` 0.1.81:

```
/etc/cron.d/      contains: ^\s*-w\s+/etc/cron.d/\s+-p\s+wa(\s|$)+     <- requires the slash
/var/spool/cron   contains: ^\s*-w\s+/var/spool/cron\s+-p\s+wa(\s|$)+  <- requires NO slash
```

Writing both with a trailing slash — which is exactly what DISA's fix text tells you to do — passes `audit_rules_etc_cron_d` and fails `audit_rules_var_spool_cron`. `auditctl` normalises the slash away, so `auditctl -l` prints the same thing either way and DISA's own check text (which greps the **kernel**) is satisfied by both forms; only the file-reading OVAL cares. `audit_cron_watches` in `group_vars` carries the exact text per path. **Do not tidy them into a consistent form.**

**17. A symlink into `/opt/it` reads as "command not found" to a non-admin.**
`/opt/it` is `2770 root:sudo`. Every `it-*` command is a symlink in
`/usr/local/sbin` pointing there, so for a user outside the `sudo` group `stat()`
on the target fails with EACCES, bash skips the PATH entry and reports
**`command not found`** — not "Permission denied", which is what you would go
looking for. The command is installed and the user may even hold a sudoers grant
for it. `sudo <cmd>` works (sudo resolves the path as root); the bare name does
not. Any script a non-admin group is meant to run therefore goes in
`it_scripts_public`, which installs it as a real file in `/usr/local/sbin`
(`it-repo` for the `dta` group). `dta-log` solves the same problem the other way,
by living in `/opt/dta` (2750 root:dta) with a link in `/usr/local/bin`.

**18. A snap browser cannot open a file in `/opt`, and says "File not found".**
Firefox on 24.04 is a **snap**. It runs in its own mount namespace containing
the user's home and, if the interface is connected, removable media — and no
`/opt` at all. Point it at `file:///opt/_AuditFiles/<report>.html` and it
reports *File not found* for a file that is right there and readable, which
sends you hunting a permissions problem that does not exist. `chmod` cannot
fix it; the path does not exist inside the sandbox. `run-powerstrux open`
copies the newest report into the auditor's home (0600 in a 0700 directory)
and opens that. The same applies to anything else under `/opt` or `/srv` you
try to open from the desktop.

**19. Everything in `/etc/skel` is copied again for every account.** `useradd -m`
duplicates the whole tree per user, so a large file seeded there is paid for on
every account the build creates and every one an admin creates afterwards. VS
Code extensions were seeded there for convenience; on ASP-2 that reached **3.0 GB
across 27,395 files**, and `useradd -m` measured **65 seconds** — reported, twice,
as `it-adduser` hanging. Nothing in the account-creation path was wrong. Keep
`/etc/skel` to dotfiles: `sudo du -sh /etc/skel` should be kilobytes.

**20. A new account has no AccountsService record, so GNOME shows the generic
avatar.** `desktop_branding` sets `Icon=` in `/var/lib/AccountsService/users/<user>`
for every user *that exists when it runs*, and seeds `/etc/skel/.face`. GNOME
reads AccountsService, not `~/.face` — so an account created between pulls
inherits the image file and still shows the default picture until the next pull
happens to enumerate it. `it-adduser` writes the record itself now.

**21. A malformed `/opt/it/site.yml` stops the ENTIRE pull, before any role runs.**
`local.yml` loads it with `include_vars` in `pre_tasks`, so a YAML error there
fails the play at task 2 — nothing is applied, and the failure names the file
rather than whatever you were actually trying to change. `expected '<document
start>'` is the usual one: it means a `---` or `...` appears mid-file and the
content after it is a second document. **Appending to site.yml by hand is how
this happens** — `it-pull --profile <name>`, `it-offload`, `it-repo enable` and
`run-powerstrux schedule` all edit it properly. `sudo it-pull status` now
reports a file that will not parse, before the pull does. Check by hand with:

```bash
sudo grep -n '^\(---\|\.\.\.\)' /opt/it/site.yml
python3 -c "import yaml; yaml.safe_load(open('/opt/it/site.yml'))"
```

**13. A passing benchmark is not a compliant box.** `usg fix` leaves `PermitRootLogin prohibit-password`, which satisfies the STIG rule (it only forbids a root *password* login) while still allowing root in **by SSH key** — which the org checklist forbids outright. Found on ASP-2 with a 96.41 % scan. Check what the rule actually asserts, not just its color.

**12b. `ufw limit` breaks any web service, and it presents as the app being broken rather than the firewall.** `limit` drops a source that opens **6 or more connections in 30 seconds**. That is right for SSH and RDP, which open one. A browser opens six per host before it has parsed the page, so an HTTP service trips it on the first real load. Confirmed on dev-18: the code-server **login page** is a couple of requests and loads fine, the password is accepted, and then the editor behind it opens dozens at once — from that moment every request from that PC times out. The give-away is in the kernel log, and it names the engineer's own workstation:

```
sudo journalctl -kf | grep 'UFW LIMIT BLOCK'
[UFW LIMIT BLOCK] ... SRC=192.168.1.244 DST=192.168.1.103 ... DPT=8080 SYN
```

The repo had `rule: limit` on **code-server** (8080:8099) and on **Cockpit** (9090) — both web consoles. Both are now `allow` with a source restriction (`dev_code_server_allow_from`, `cockpit_allow_from`), which is the protection rate-limiting was reaching for and does not deliver. **The old rule has to be deleted, not just superseded:** ufw evaluates in order, so a `LIMIT` ahead of the new `ALLOW` still wins — the pull deletes it explicitly. Do not add a web port to `stig_firewall_limit_ports`.

**12c. `/opt/it/site.yml` that does not parse stops a box updating, permanently, and the line the parser names is not the cause.** `local.yml` loads it in `pre_tasks`, so the play stops before a single role runs. That makes it self-sustaining: the fix for anything on that box ships THROUGH a pull. dev-ai2 sat on `70ee4fb` with main nine commits ahead, unable to receive the very guard that would have caught the write.

```
expected '<document start>', but found '<block mapping start>'
  in "/opt/it/site.yml", line 41, column 1
```

That message means the YAML document **ended** above line 41 and ordinary content resumed. **Do not go to line 41** -- a parser reports where it could not continue, which for this fault is always below the cause. On dev-ai2 the offending line was in the twenties.

**And do not go looking for `...` or `---`.** Those end a document, but so does anything that completes it on its own, and the search finds nothing in the common case. On dev-ai2 `grep -nE '^[[:space:]]*(\.\.\.|---|%)'` matched **zero lines**. The actual cause was a key that had **lost its colon**: `key "value"` is a bare top-level scalar, which is a complete document by itself, so every setting below it became a second document. A closed `{flow mapping}` does the same.

Ask the parser instead of guessing. `it-pull` now does this for you before it launches anything, printing the first document's ROOT NODE -- if that is a `Scalar`, the line is named exactly:

```bash
sudo it-pull            # refuses, with the analysis
sudo python3 -c 'import yaml; yaml.safe_load(open("/opt/it/site.yml")); print("ok")'
```

Related messages, so the text tells you which fault you have: a bare `---` after line 1 gives *"expected a single document in the stream"*; a line starting with `%` gives *"...but found '<scalar>'"*; a tab gives *"while scanning for the next token"*.

**12e. A slow desktop on a deployed box is WAITING on the network, and the desktop services that appear broken are downstream of that.**

Everything an app does at startup that touches a name or a user goes through the resolver and NSS. On a fielded box both can hang: the resolvers it was given in the lab are unreachable, and `sss` in `nsswitch.conf` with a dead sssd stalls every `getpwnam()` (trap 12f). Nothing caches a failure, so the cost is per lookup, paid by sudo, PAM, GNOME, D-Bus and X alike.

**The desktop user services then fail as a CONSEQUENCE.** `xdg-desktop-portal`, `ibus` and `gnome-keyring` are systemd user services with start timeouts; a startup lookup that hangs gets them killed, and the journal fills with `Failed to start xdg-desktop-portal.service`, `Failed to start org.freedesktop.IBus.session.GNOME.service` and `Gkr-pam: unable to locate daemon control file`. That trio looks like a broken session and is not one. It then **compounds**: with the portal dead, every GTK app additionally waits out a ~25 s D-Bus activation timeout before falling back and opening anyway.

**The fix is the resolver, not the desktop.** `network_online` writes a `127.0.1.1` line so the box's own hostname never goes to DNS, and turns off NetworkManager's connectivity probe, which off-network can only time out. `it-repair --only identity` handles the sssd half.

**Do not "fix" the session environment for this.** It was tried here, on the theory that an xrdp session exports no `XDG_CURRENT_DESKTOP` and so the portal cannot choose a backend. **That theory is false and was never checked before it was written down.** Measured in an xrdp session on a lab box carrying none of it:

```
$ echo "[$XDG_CURRENT_DESKTOP]"          [GNOME]
$ systemctl --user is-active xdg-desktop-portal.service    active
```

The give-away was there the whole time and was ignored: the lab boxes ran the identical role and identical xrdp config and were **fine**, so whatever differed had to be the environment the boxes moved into, not the session. `/etc/X11/Xsession.d/56it-session-env` is kept as insurance -- every export in it is guarded on the value being unset, so it is inert wherever the session is already correct -- but it is **not** what fixed anything.

**And the strongest single clue is where the delay sits.** A slow DCSA **login banner** prints before authentication, so no desktop fault can reach it. If the banner is slow, stop looking at the session and go to trap 12f.

**12f. A dead `sssd` makes the box slow BEFORE anyone logs in.** `libnss-sss` puts `sss` into the `passwd`/`group`/`shadow` lines of `nsswitch.conf`, so every `getpwnam()` asks sssd. With sssd not running -- installed for a domain join that has not happened, or failing with *"couldn't load the configuration database"* -- those lookups wait rather than fail, and the cost is paid by the login banner, PAM, sudo, GDM and the session alike.

**Where the delay sits is the diagnosis.** A dead desktop portal (trap 12e) cannot slow a banner printed *before* authentication; a stalled NSS lookup can. If the DCSA banner is slow to appear, stop looking at the desktop.

This build deliberately does **not** install sssd -- `group_vars` explains why: `libpam-sss`'s postinst runs `pam-auth-update --package`, which regenerates `common-auth` on an unjoined box, and that is how ASP-2 became unloggable. If sssd is present, `it-domain stage` or a join put it there. `it-repair --only identity` measures a local lookup and, under `fix`, takes `sss` out of `nsswitch.conf` while leaving `libpam-sss` alone -- rewriting the auth stack to fix a slow lookup trades an inconvenience for a box nobody can log into.

**12g. Neither LUKS nor GRUB records when its credential last changed, so it has to be written down at the time.** A LUKS2 header stores the keyslot's cipher, PBKDF parameters, salt and iterations, and **no timestamp** -- the format has no field for one. So "was the imaging passphrase rotated after deployment?" cannot be answered from the header afterwards, at any point. `it-luks-passwd` and `it-grub set` now append to `/etc/stig-build/credential-changes.log` as they run, and `it-repair --only creds` reads it back alongside what the system itself can prove: whether the GRUB drop-in still holds the CHANGEME sentinel, and whether the staged imaging passphrase is still sitting at `/etc/luks/initial-passphrase`. A rotation done with `cryptsetup` directly leaves no trace and never will.

**12h. The retries that make Pro reliable in the lab cost a fielded box seven minutes a pull.** `pro enable` calls `contract.refresh()` first, and off-network that POST hangs for its full ~30 s (trap 42). With `retries: 5, delay: 15` that is 5x30 + 4x15 = **210 seconds per call**, and there are two of them (`usg`, `fips-updates`) -- so an air-gapped box spends about seven minutes of every pull waiting for a host it cannot reach, for calls that cannot succeed. The retries are right in the lab, where the failure is transport and intermittent; they are pure cost once the box is deployed.

`pro_attach` now probes Canonical once and skips `attach`/`enable` when it cannot be reached. The probe is deliberately **asymmetric** and it has to be:

| result | meaning | action |
|---|---|---|
| fails | the box definitely cannot reach Canonical | skip, and say so |
| passes | **proves nothing** | behave exactly as before, retries included |

A pass cannot be trusted because trap 42 is precisely the case where a GET to that host answers 200 in 0.3 s while `pro enable`'s POST hangs for 30 s. So the probe can rule the network out, never in -- which is all that is needed.

**It is an HTTP request, not a TCP connect.** A transparent proxy, or a firewall that accepts and then drops, completes the handshake and reports success for a host that is unreachable: measured in a proxied sandbox, an unroutable address "connected" in 6 ms. Nothing already enabled is affected either way -- this changes how long a pull takes, not the box's posture.

**12i. On Windows 11 + Ubuntu 24.04 there IS no fast path, and turning the client's quality DOWN is what turns it off.** This is the ceiling every other RDP setting sits under, and it is decided before any of them are read. `xrdp/xrdp_encoder.c:xrdp_encoder_create()` refuses to build an encoder unless **all three** hold:

```c
if (client_info->mcs_connection_type != CONNECTION_TYPE_LAN) { return 0; }   /* 0x06 */
if (client_info->bpp < 24)                                   { return 0; }
/* ...then: jpeg_codec_id, or rfx_codec_id, or h264_codec_id — else return 0 */
```

When it returns 0 there is no encoder thread at all: every update goes down the **legacy bitmap path in xrdp's single main thread**, RLE-compressed per bitmap and MPPC-compressed per PDU. That is why applications still *open* fast — opening a window is a small damage region — while **dragging** one is choppy. Dragging is the largest sustained damage region a desktop produces.

Three consequences, each of which contradicts the obvious move:

1. **`mcs_connection_type` is the client's Experience setting**, read verbatim from `connectionType` in TS_UD_CS_CORE (`libxrdp/xrdp_sec.c`). Only `0x06` — "LAN (10 Mbps or higher)" — counts. Windows 11's default is *Detect connection quality automatically*, which sends `0x07`. So **the shipped default already disables the encoder, and every step "down" the quality list disables it harder.** Anyone tuning the Windows side by lowering quality is making it worse and will never find this by experiment.
2. **`max_bpp` below 24 disables the encoder outright.** It is not the bandwidth dial it looks like. `max_bpp: 16` is a *last resort for a genuinely slow link*, not a responsiveness setting.
3. **Windows 11's mstsc no longer advertises RemoteFX at all** ([xrdp #2400](https://github.com/neutrinolabs/xrdp/issues/2400)) — Win 10 logged `xrdp_caps_process_codecs: RemoteFX, codec id 3`, Win 11 logs nothing. It offers NSCodec instead, which xrdp 0.9.24 records in `ns_codec_id` and **never uses**. Ubuntu 24.04 ships `xrdp 0.9.24-4` / `xorgxrdp 0.9.19-1`, and GFX/H.264 — the replacement for RemoteFX — arrived in **xrdp 0.10**, which is not in noble or noble-backports.

**So on this fleet, today, no client-side or `xrdp.ini` setting can produce an accelerated session.** Say that out loud before anyone spends a day on the Experience tab. `it-rdp perf` now reads it off the box instead of guessing: `LogLevel=INFO` is the shipped default and `xrdp_caps_process_codecs:` lines are logged at INFO, so `/var/log/xrdp.log` already says which codecs the last client offered.

**What is still worth doing on the legacy path**, in order:

| lever | why |
|---|---|
| **`bulk_compression=false`** | the *second* compressor, and it was missed for a year. `bitmap_compression` is per-bitmap RLE; `bulk_compression` is MPPC over every outgoing PDU (`libxrdp/xrdp_rdp.c`), in the same single thread. The package ships it **true** and this role never set the key, so the fleet was paying both. Now `dev_rdp_bulk_compression`, default false |
| **resolution**, and `use multimon:i:0` | still the cheapest lever, and the only one that cuts compositing and encoding at once. A second monitor doubles every pixel |
| **`connection type:i:6` + `networkautodetect:i:0`** | does not unlock a codec on Win 11, but stops mstsc throttling itself and is the precondition the day the server is upgraded. `it-rdp client` prints the whole `.rdp` |
| **`tcp_send_buffer_bytes`** | untried here. xrdp only calls `setsockopt` when the key is **present** (`xrdp_listen.c` guards on `> 0`), so today the kernel autotunes. The case for setting it is not bandwidth — it is that a drag hands xrdp megabytes at once and a small socket buffer makes its single thread block in `write()` mid-frame ([xrdp #1483](https://github.com/neutrinolabs/xrdp/issues/1483): "seamless window dragging" at 4 MiB). The case against is that an explicit `SO_SNDBUF` disables autotuning. `dev_rdp_tcp_send_buffer_bytes`, default empty. **Set `net.core.wmem_max` with it** — Ubuntu ships it at 212992 and the clamp is silent; xrdp logs what the kernel actually gave back at INFO and `it-rdp perf` reads it |

**Choppy redraw and late typing are different faults.** Redraw is compositing plus encoding; typing is the input path, and none of the redraw levers touch it. The two on the input side are `use_fastpath=both` in `xrdp.ini` -- the lighter input PDU, now set by the role -- and **ibus**, which puts an input-method hop on every keystroke and can be removed with `im-config -n none` where no non-Latin input is needed.

**A lighter session is not available here.** GNOME Flashback was tried on dev-16 and withdrawn: its panel and the **classification banner** want the same screen edge, and the banner covered the toolbars. On this fleet the banner wins.

| busy process | cause | lever |
|---|---|---|
| `gnome-shell` / `Xorg` | software rendering -- xorgxrdp has no GPU path, so a full GNOME Shell is llvmpipe | lower the resolution |
| `xrdp` | encoding and compressing every update, single-threaded | `bulk_compression`, `bitmap_compression`, `max_bpp` |
| nothing much | the link, or xrdp blocked in `write()` | `tcp_send_buffer_bytes` |

Measured on a deployed box: **`xrdp` at 70%** with gnome-shell and Xorg idle — consistent with the legacy path above, since that is where the compression happens.

Note what did NOT help, since it rules out a whole family of guesses: disabling GNOME animations, and unchecking font smoothing on the Windows client. Neither touches the encode path.

**The real fixes, neither of them small**, are in CLAUDE.md's open threads: an xrdp 0.10.x build (GFX + H.264, so Win 11 gets an accelerated codec again) or `gnome-remote-desktop`, which is already in noble at 46.3, is Wayland-native, and does AVC444 — but replaces the whole xrdp login path this repo hardens, PAM stack included.

**12j. `apt autoremove` silently takes FIPS off a deployed box.** Confirmed on dev-13/14/15. `pro enable fips-updates` installs `ubuntu-fips` as a **dependency**, so apt marks it auto-installed; nothing depends on it afterwards; and a routine `apt autoremove` -- the one `apt upgrade` suggests, in the sentence everyone agrees to -- decides it is unused and removes it.

What that leaves is the hard part to spot:

| | |
|---|---|
| `/etc/default/grub.d/fips.cfg` | **emptied** by the postrm, so no `fips=1` |
| the FIPS kernel images | **still installed** -- separate packages, so `dpkg -l \| grep fips` looks reassuring |
| `pro status` | `fips-updates: disabled` |
| `/proc/sys/crypto` | **gone entirely** -- the directory, not just the value |
| every file-based compliance check | still passes |

So the box reboots onto a generic kernel and looks completely normal. `uname -r` is the only thing that disagrees, and nobody reads it.

`pro_attach` now runs `apt-mark manual` over every installed `*fips*` package, which exempts them from autoremove. **`manual`, not `hold`:** manual still allows security updates, and a held FIPS kernel would be a worse problem than the one it solves.

**Recovering a box that has already lost it** is `sudo it-fips` -> `fix` -> `boot` -> reboot -> `confirm`, written up in procedures 4.2b, and it works in the space *provided the kernel images are still there*. It recreates `fips.cfg` with `fips=1`, marks the packages manual, sets `GRUB_RECORDFAIL_TIMEOUT`, and switches with a **one-shot** `grub-reboot` so a failed boot self-recovers. If the kernel images are gone too, it cannot be fixed offline at all: that kernel comes from Ubuntu Pro and `pro enable` needs Canonical.

**12v. A GUI launcher inherits the session's working directory, which is `/`.** FlashPro Express defaults a new project to the current directory, so an engineer starting it from the app grid gets a permission error creating a project on `/` or `/tmp`, and has to know to browse to their own home — which reads as the tool being broken and is not. Vivado and Libero default their project paths the same way. The FPGA launchers therefore `cd "$HOME"` before exec'ing the tool; the `cd` is non-fatal, because an unreadable home is a different fault and should not stop the tool starting.

**12s. Being IN the group can be what denies you: `drwx---rwx` is 0707.** A share mounted over sshfs came back `root:sentry` with mode **0707** — owner `rwx`, **group `---`**, other `rwx`. A member of `sentry` got permission denied; a user *not* in `sentry` could have walked in. Unix permission checking stops at the FIRST matching class — owner, then group, then other — so group membership selects the empty group bits and never falls through to `other`. Membership made it worse, which is why it reads as a broken ACL rather than a mode.

The mode came from the server. sshfs has **no `file_mode`/`dir_mode`** (those are cifs options), so with `default_permissions` the kernel enforces whatever the remote reports, and Windows OpenSSH synthesises modes from NTFS ACLs that do not map cleanly. `umask` cannot repair it either: it clears bits, it cannot add the group bits that are missing.

So `it-sshfs` does not use `default_permissions`. Access is gated by the PARENT directory instead — the mount lives at `/media/<group>/<name>` with `/media/<group>` at `0750 root:<group>`. Traversal is checked locally against real group membership, which is the thing we actually control; the remote side stays authorised by the service account's NTFS rights.

**12r. Ubuntu's FIPS parameter is `bootdev=`, not Red Hat's `boot=`, and a box needs BOTH it and `fips=1`.** The FIPS check runs from the initramfs and verifies itself against `.hmac` files on `/boot`; where `/boot` is a separate filesystem -- which LVM + LUKS leaves it -- it has to be told where. Ubuntu's name for that is `bootdev=/dev/disk/by-uuid/<uuid>`, written into `99-fips.cfg` by `ubuntu-fips` when `pro enable fips-updates` runs. A working box shows both:

```
BOOT_IMAGE=/vmlinuz-6.8.0-139-fips root=/dev/mapper/ubuntu--vg-ubuntu--lv ro audit=1 fips=1 bootdev=/dev/disk/by-uuid/<uuid>
```

`apt autoremove` empties `99-fips.cfg`, and a `fips.cfg` rebuilt with `fips=1` alone leaves FIPS requested with no way for the initramfs to verify itself -- it fails naming a missing bootdev argument, and everything downstream (the LUKS unlock included) fails with it. That cost dev-13 and dev-15 a week, because the obvious repair is to restore `fips=1` and the missing half is invisible unless you compare `/proc/cmdline` against a box that works. **Do not substitute Red Hat's `boot=`:** it is a different parameter, `initramfs-tools` reads it as the name of a script under `/scripts`, and it panics the kernel (trap 12l). The two look interchangeable and are not. `it-fips` now reports a missing `bootdev=` as a failure and `it-fips fix` writes both; the `boot=` stripper is anchored so it cannot eat `bootdev=`.

**12q. A stale FIPS initramfs looks for the wrong disk, and it reads as a wrong passphrase.** dev-13 and dev-15 stopped at the unlock prompt with `device /dev/nvme1n1p3 is not a valid LUKS device`, `No used slots detected`, and rejected every correct passphrase -- while the same header read perfectly from the running system. `initramfs-tools` bakes `conf/conf.d/cryptroot`, naming where the encrypted root lives, into each image **when that image is built**. Both boxes had lost FIPS and then run on the generic kernel for weeks, so their FIPS initramfs was a snapshot from before all of it and pointed somewhere that is no longer the root disk -- where it found the unprovisioned second NVMe, which genuinely is not LUKS. The fix is one stock command:

```bash
sudo update-initramfs -u -k all
```

Two things that made this expensive to find. The running system cannot show it: `/etc/crypttab` is correct, and only the packed image says what the next boot will do (`unmkinitramfs <img> /tmp/x && grep -rh source= /tmp/x`). And the kernel prints `blake2b-256-generic is disabled due to fips` alongside the failure, which is the crypto API logging disabled algorithms as they register and has nothing to do with it -- the headers on both boxes are sha256 throughout. `it-fips fix` now rebuilds the initramfs when `/etc/crypttab` is newer than the FIPS image, and `it-luks check` prints the `source=` each installed kernel carries against the real UUID.

**12r. A LUKS2 header hashed with blake2b cannot be read by a FIPS kernel at all.** dev-13 and dev-15 stop at the passphrase prompt saying `device /dev/nvme1n1p3 is not a valid LUKS device`, `not a supported LUKS device`, `No used slots detected` -- and the kernel prints `blake2b-256-generic is disabled due to fips` alongside it. Nothing is wrong with the keyslots. A LUKS2 header names a hash per keyslot (AF) and per digest; if any of them is blake2b, FIPS removes the algorithm from the kernel crypto API, cryptsetup cannot verify the header, and the whole device reads as not-LUKS. Every passphrase is then rejected because nothing ever got as far as checking one -- which looks exactly like a wrong password and is not. It is invisible from a generic kernel, where blake2b works fine. **This was NOT what happened on dev-13 or dev-15** -- their headers are sha256 throughout and the blake2b lines there were unrelated kernel noise (see 12q) -- but the failure mode is real and `it-luks check` reports the header hashes so it can be ruled out in one line. `it-luks check` reports the header's hashes and names any that are not FIPS-approved; run it BEFORE switching a box to FIPS, not after. The approved set is SHA-1, SHA-2 and SHA-3; anything else in a `Hash:` or `AF hash:` line will do this.

**12p. These boxes have TWO encrypted disks, and every LUKS helper looked at one.** `blkid -t TYPE=crypto_LUKS -o device | head -1` is the idiom, and it is wrong here: the workstations carry `nvme0n1p3` *and* `nvme1n1p3`, each a separate LUKS2 volume with its own keyslots and its own clevis binding (slot 2 on one, slot 3 on the other). So `it-fips` reported the KDFs of whichever `blkid` listed first, `it-fips luks` converted only that one, and `it-fips retire <slot>` would have removed a keyslot from a device the operator was not looking at. Every helper now takes the device as an argument and the callers loop over `luks_devices`; `retire` refuses to run without a device name when more than one disk exists. When reading a `luksDump`, check which disk it came from before acting on a slot number — a slot number means nothing on its own.

**12o. With Secure Boot on, `grub-reboot` is not a one-shot -- it is permanent.** `GRUB_DEFAULT=saved` makes `00_header` run `if [ "${next_entry}" ]; then set default=...; set next_entry=; save_env next_entry` **before the menu is drawn**. `save_env` writes to grubenv, GRUB under Secure Boot is locked down, and the write is refused -- printing `error: prohibited by secure boot policy` at exactly that point, on every boot. `next_entry` is therefore never cleared, so the "one boot only" entry is selected every time and **a kernel that fails to come up is retried forever instead of falling back**. That is the opposite of why `grub-reboot` was chosen for this fleet. Clear a stuck one with `sudo grub-editenv - unset next_entry`; `it-fips confirm` does it while pinning the kernel properly, `it-fips` fails the box while one is stuck, and `it-fips boot` warns as it arms. A second consequence: `recordfail` is written by the same mechanism, so on these boxes `GRUB_RECORDFAIL_TIMEOUT` may never be consulted -- set it anyway, it costs nothing and the box may not always have Secure Boot on.

**12n. Microchip's `check_linux_req` is a RHEL script and reports Ubuntu as broken.** It tests the distro against RHEL/AlmaLinux and then looks for RPM package names, so on a box where everything is installed it prints the OS as unsupported and the dependencies as missing. An engineer reading that wall of FAILs acts on it. `it-fpga check` therefore does **not** run it by default: it runs `ldd` against Libero, FlashPro Express and Vivado instead, which asks the question the vendor script is really asking -- does this binary have every library it needs -- and answers it against the box's own linker, where a package name cannot be wrong. `it-fpga check --vendor` still runs the vendor script, with the caveat printed underneath its output rather than above it.

**12w. `ufw limit` locks out the management host, and it presents as a timeout.** SSH and RDP are opened with `ufw limit`, which **drops a source IP after six connections in thirty seconds** — not per account, not per service. A toolkit that runs `it-pull` across the fleet opens several sessions in a row from one address, trips it, and then the operator's own SSH *and* RDP from that same machine are dropped too. Because ufw **DROPs** rather than rejects, the symptom is a connection timeout with **nothing in the ssh log**: the packets never reached sshd, so every log an admin thinks to check is silent. It looks intermittent because it depends on how many connections happened to fall inside the window.

Confirm it from the kernel log, which is the only place it appears:

```bash
sudo journalctl -k | grep -i '\[UFW LIMIT BLOCK\]' | tail
```

The fix is an `allow` **inserted ahead of** the limit rule — ufw evaluates in order, so appending one does nothing. `stig_firewall_limit_exempt_sources` does this for every rate-limited port plus RDP. The trade is real: a listed source has no brute-force throttle at all, so list management hosts as `/32`, not a LAN.

**12z. `it-stack-diff` covers compose files and nothing else, so the sidecar configs are the gap.** Several stacks bind-mount a file next to `compose.yaml` — `open-webui/nginx.conf`, `mlflow/nginx.conf`, `prometheus/prometheus.yml`, `oikb/.oikb.yaml`, `magpie/magpie_config.yaml`, `grafana-otel/grafana/*`. A missing bind-mount source is **not** an error: Docker creates a **directory** at that path and the container starts against it, so nginx fails on a config that is a folder and the fault reads as an image problem. The 2026-09-21 capture surfaced two of these that exist on a box and in no template: `open-webui/nginx.conf` (the new `open-webui-proxy`, which is now the only thing publishing 3000) and `magpie/magpie_config.yaml`. Capture them by hand — the compose diff will never show them missing.

The same capture found three things worth naming separately:

| what | effect |
|---|---|
| **oikb moved 8081 -> 8082, which is also magpie's port** | both publish `8082:8080` on dev-ai2. Whichever starts second fails to bind. They are independent stacks, so nothing sequences them |
| **`prometheus` lost its `prometheus-data` volume** | see below -- it is two separate faults, not one |
| **`vllm-vision`'s `logging:` is nested under `deploy:`** | a key in the wrong place is silently ignored by compose, so that one service has no log rotation while the file looks like it does |

**Prometheus, in detail, because both halves are invisible.** The upstream image declares `VOLUME [ "/prometheus" ]` (confirmed in `prometheus/prometheus` v3.14.0's Dockerfile), and the as-built compose mounts nothing there. Docker therefore creates an **anonymous volume** — a random 64-hex name, bound to that one container. So:

- every `docker compose up -d` that recreates the container starts with an **empty TSDB**. No error, no warning; the graphs simply begin at "now".
- the previous volumes are not removed, they are **orphaned**. They accumulate as dangling volumes, and a later `docker volume prune` deletes the history nobody knew was still there.
- `docker compose down -v` does remove them, so the one command gotcha 6 says is safe against named external volumes is *not* safe here.

The repo's version mounts `prometheus-data:/prometheus`, external, which survives all three. That half is still open.

**The config half is CLOSED (2026-09-22).** The box mounted `/opt/it/docker/grafana/prometheus.yml` by **absolute path** while `ai_compose` templated the scrape config to `/opt/stacks/prometheus/prometheus.yml` and nowhere else — so the managed file was ignored and the file actually in use was hand-made and unmanaged. That file carries System 1's address, so **after `it-set-ip` renumbered the node, Prometheus kept scraping the old one**, and the template that exists to prevent exactly that was read by nobody. The mount is now the relative `./prometheus.yml`, which is the rendered file. Note that the architects' docs described the absolute path as deliberate; this resolves that disagreement in favour of the managed file and they should be told. Migration steps: [procedures.md §5.9](procedures.md#59-moving-the-docker-asset-root-one-time-off-optitdocker).

**12ae. "Up but not answering" and "starting" look identical, and only the clock tells them apart — a nine-day AV outage on ASP-2 hid behind that.** Found 2026-09-23.

`clamav_container` runs clamd in a container because the host engine cannot detect anything under FIPS. clamd binds its socket only **after** loading the signature set — 60–90 s for ~3.6M signatures — so "the unit is active, the container is in `docker ps`, and the socket does not answer" is the *normal* state right after a restart. It is also exactly what a **hung** container looks like, forever.

`it-clamav` had no time bound on that check, so ASP-2 reported:

> `still starting -- clamd loads the signature set before it binds its socket (~60-90s after a restart). Re-run it in a minute.`

The container's newest log line was **nine days old**. clamd writes a `SelfCheck: Database status OK` every ~10 minutes, so it had stopped doing anything on 14 Sep. Re-running in a minute would never have helped, and every scan in that window had silently fallen back to the host engine — which on a FIPS box reports `OK` for everything including EICAR. **The box had had no working anti-virus for nine days and the diagnostic tool was reassuring the operator each time it was run.**

Two signals fix it, and both are cheap:

- **Container uptime** (`docker inspect -f '{{.State.StartedAt}}'`). Under `CTR_START_GRACE` (300 s) it is starting; past that with a dead socket it is wedged.
- **Newest log line** (`docker logs --tail 1 --timestamps`). clamd SelfChecks every ~10 minutes, so an hour of silence is a liveness failure independent of the socket — a container can be `Up 9 days` to Docker and have been doing nothing for eight of them.

`it-clamav test` and `it-clamav` now say `WEDGED -- up 9d 0h and the socket has never answered. This is NOT 'still starting'`, name how long the box has been unprotected, and run the postmortem.

**The general lesson is worth more than the ClamAV specifics.** Any "still initialising, try again shortly" state needs a deadline, or it is indistinguishable from failure and reads as reassurance. A check that cannot ever say "this has taken too long" is not a check.

Same pass fixed a second one in that tool: the *"can a non-admin DTA use the daemon?"* section read `/etc/clamav/clamd.conf` unconditionally, so on every containerised box it reported the **host** socket missing and "the daemon is not running" — true of the host daemon, which is masked there on purpose, and wrong about the question being asked. It now reads whichever config is actually serving and says so.

**12ad. A sudoers command written with no arguments permits ANY arguments, so a "narrow" grant can be wide open and still read as narrow.** Caught while testing the `it-serial` grant, and it applies to every `sudoers.d` drop-in in this repo.

This looks like a careful, enumerated grant:

```
%dialout ALL=(root) /usr/local/sbin/it-serial, \
                /usr/local/sbin/it-serial list, \
                /usr/local/sbin/it-serial free --all, \
                /usr/local/sbin/it-serial free tty[a-zA-Z0-9]*
```

It is not. The **first** entry names the command with no argument spec, and in sudoers that means *any* arguments are acceptable — so it subsumes every line under it and the real grant is "`it-serial`, with whatever you like". Measured: with that line present, `sudo it-serial free /dev/sda` was **permitted by sudo** and only the script's own validation refused it. The fix is one token — `""` is how sudoers spells "this command and no arguments":

```
%dialout ALL=(root) /usr/local/sbin/it-serial "", \
```

With it, the same command is refused with *"Sorry, user eng1 is not allowed to execute..."* before the script is ever reached.

Two things follow. First, a grant whose first entry is the bare command is worth nothing, however carefully the rest is written — and it will pass a review by eye, because it reads as a list of allowed forms. Second, **defence in depth is doing real work here**: the reason the mistake was harmless in practice is that `it-serial` validates its own argument (`^tty(USB|ACM|S)[0-9]+$`) and never accepts a PID. A script that trusted sudoers to have constrained it would have been a root-kills-any-PID primitive handed to a non-admin group. Write both; assume neither.

The existing `it-repo` grant was checked and is fine — every one of its entries carries arguments.

**12ac. On a FIPS box SMB cannot carry the evidence off, and `guest` is not the loophole it looks like.** This cost a week, because each wrong answer looked like the right one.

NTLMv2 is built on HMAC-MD5. A FIPS kernel removes MD5 from the crypto API, so `mount.cifs` cannot allocate the transform and the session setup fails — with **ENOENT, the same errno a missing share returns**. So it presents as a wrong share name or a bad password, and is neither. The log line that names it is `Could not allocate shash TFM 'hmac(md5)'` followed by `Error -2 during NTLMSSP authentication` (dev-14, 2026-09-04).

The repair that seems obvious is `guest`, and it is half a repair. `guest` only means "send no username or password" — the client still performs whatever session setup `sec=` asks for, and every default in this repo said `sec=ntlmssp`. So guest failed for exactly the same reason. Forcing `sec=none` (which `it-offload`, `it-powerstrux offload` and `it-smb` all now do whenever auth is guest, stripping any `sec=` the options carry) is the other half — and **it still does not work**: SMB2 and SMB3 carry even an anonymous session over NTLMSSP. Tested at every dialect against the deployed server on 2026-09-16.

So there is no SMB configuration that moves evidence off a FIPS box that is not Kerberos-joined. **The transport is SFTP**, on both offloads:

| | how to turn it on |
|---|---|
| PowerStrux reports | `it-powerstrux offload transport sftp` then `it-powerstrux offload sftp <user@host:/path>` |
| auditd trail (AU-4) | `usg_audit_offload_sftp_enabled: true` + `usg_audit_offload_sftp_dest` in `site.yml` |

It is also the better fit, independent of FIPS: nothing is left mounted, so a compromised file server has no path back onto the box, and the far-side service account can be given **create-only** rights — a box drops its report and cannot read back, alter or delete what any other box wrote. A mount cannot be constrained that way without the same NTFS work, and tempts someone to browse. `docs/procedures.md` → "Getting the PowerStrux reports to the auditors" has the `icacls` commands.

Three things that fail on the way in, in the order they actually happen:

1. **The service account is a Windows administrator.** OpenSSH then reads `C:\ProgramData\ssh\administrators_authorized_keys` and ignores the account's own `authorized_keys` entirely, so key auth appears to do nothing. Make it a normal user.
2. **The host key is not pinned.** `StrictHostKeyChecking` stays on and `BatchMode` is set — an unattended job that trusts whatever answers on port 22, or that can sit at a prompt, is not an evidence transport. `ssh-keyscan -H <host> >> /etc/stig-build/ssh/known_hosts`, after checking the fingerprint against the server.
3. **A Windows path needs a leading slash**: `/C:/Evidence/PowerStrux`. Without it sftp resolves it relative to the account's home directory and the reports land there silently.

And one that was ours: until 2026-09-22 `cmd_run` gated the push on `SMB_ENABLED` **and a non-empty `SMB_SHARE`**, which no sftp box has — so a correctly configured sftp offload built its week folder, reported success, and pushed nothing. `it-powerstrux offload test` was SMB-only for the same reason and could not have caught it. Both are transport-aware now.

**12ab. The console is not a fallback on these servers, because USBGuard blocks the keyboard — and the documented recovery does not work here.** Worth settling before a box is moved, not after.

What does *not* block a console login: there is no `securetty`, no `pam_access`, and the `ai` profile installs no desktop (`dev_rdp_enabled` is development-only), so a normal local account logs in at tty1 with its own password. PAM is not the problem.

**USBGuard is.** Its policy is generated from the devices attached *at that moment*, and a server has no built-in keyboard — so the allow-list only ever contained the keyboard that happened to be plugged in during the build (dev-ai1 carries 6 allow-rules, dev-ai2 five). External HID is deliberately not blanket-allowed, because a keystroke-injection device presents as a keyboard. Plug a different keyboard or a KVM in at the far site and **nothing types**.

The recovery the role used to document — boot to recovery/single-user and `systemctl disable --now usbguard` — **cannot work on this fleet**: single-user runs `sulogin`, `sulogin` wants the **root** password, and root is locked here by design. It hands you a prompt you cannot answer.

What works needs only the GRUB password, which is set:

1. At the GRUB menu press `e`. **The keyboard works here** — GRUB runs long before USBGuard is loaded, which is the whole reason this is recoverable at all.
2. Append to the `linux` line: `systemd.mask=usbguard.service`
3. `Ctrl-X`. The box boots normally with USBGuard masked **for that boot only**, so you log in as yourself, with your own password, and no shell trick.
4. Fix the policy, reboot, USBGuard is back. Nothing persists.

**Better: do not need it.** `it-usb trust <vid:pid> [serial]` pre-authorises a device **without it being plugged in**, so the keyboard waiting at the far site can be allow-listed before the box leaves this one. Disabling USBGuard for the move is the worse trade — it leaves the boxes unprotected in transit, which is exactly when physical custody is weakest.

**And you may not need the console at all:** a reboot applies netplan. A box staged with `it-net`, powered off, moved, cabled and powered on comes up on the new address with no keyboard involved. The console is the fallback, which is precisely why it has to actually work.

**12aa. Ansible's explicit `mode:` strips an inherited ACL, so a default ACL does not grant what you think.** Giving a second, non-admin group read access to `/opt/stacks` cannot be done in the file mode — the directories are `root:sudo 2750` and a mode carries one group. A POSIX ACL is the mechanism, and this is the trap in it:

```
touch          file  -> inherits  group:aiops:r--   from the directory's default ACL
install -m 0640 file -> NO named entry at all
```

Every file `ai_compose` writes has an explicit `mode:`, which is the second case — so a default ACL on the directory is removed from each file on **every pull**. The entries therefore have to be applied to the FILES as well, after they are written, which is why `ai_ops_access.yml` runs last in the role.

The same mechanic is what protects the secrets, and it was verified rather than assumed: a `0600` file inside a directory carrying the default ACL comes out `user::rw-`, `group::---`, `other::---` — no named entry, no mask to raise. So `.env` cannot leak even by inheritance. It is still stripped explicitly, because a future change to that mode should not quietly open them.

Tested with a real unprivileged account in the group: `compose.yaml` readable, `.env` denied.

**Do not solve this with the `docker` group.** Membership is root-equivalent — `docker run -v /:/host` is a root shell on the host — so on a STIG box it is a privilege escalation and a finding, and it is not logged. `ai_ops_sudo_commands` is command-scoped and goes through sudo's audit trail instead.

**12z-bis. A direct node-to-node cable needs NO compose change, and `it-net ip` cannot configure one.** Both mistakes are natural and both are wrong in an instructive way.

*Why no compose change.* Every service publishes on `0.0.0.0`, which means it already listens on **every** interface including a new direct link. Nothing about the bind decides which cable a packet takes — the **destination address the client uses** does, plus routing. So the only thing that has to change is the peer address (`SYSTEM2_ADDR` on System 1, `OPEN_WEBUI_URL` / `SYSTEM1_HOSTS_ENTRY` on System 2), which is exactly what `it-set-ip --peer` rewrites. The only compose files that need touching are the ones with a literal address typed in — `it-set-ip scan` finds those.

*Why not `it-net ip --iface <second NIC>`.* Two reasons, both expensive:
- it **requires** `--gateway` and always writes `routes: - to: default`. A second default route is not a faster path, it is a coin toss over which one the kernel picks.
- `write_netplan()` does `cat > 99-it-net.yaml` — it **replaces** the file with a single interface stanza, so pointing it at the second NIC **deletes the LAN interface's address**. On a deployed box that is a site visit.

`it-net link` writes a separate `98-it-link.yaml` (netplan merges the directory, and the two files describe different interfaces so nothing collides) carrying an address and nothing else: no gateway, no default route, no DNS, `optional: true` so a missing cable cannot hold up boot for two minutes. It refuses the default-route interface outright. `write_netplan` now warns before discarding a second interface rather than doing it silently.

Three things that bite after the link is up:
1. **The allow-lists.** `ai_mlflow_allow_cidrs` / `ai_openwebui_allow_cidrs` end in `deny all`. A cross-node request now arrives from the LINK subnet, not the LAN one, so anything going through those proxies is denied until that subnet is added.
2. **A pulled cable takes RAG down with no fallback**, because the peer name now resolves only to the link. Rollback is one command: `it-set-ip --peer <the LAN address>`.
3. **Jumbo frames must match on both ends.** A mismatch does not fail cleanly — small packets work, large ones vanish, and it presents as "embeddings work but document upload hangs". `ping -M do -s <mtu-28> <peer>` settles it.

**12y-bis. `it-set-ip` could not run at all, and nothing noticed.** `ENVF` was read at the `CUR_PEER` probe near the top but only ever *assigned* much further down, as the loop variable of the `.env` rewrite. The script runs under `set -u`, so referencing it killed the process on startup — `it-set-ip: line 233: ENVF: unbound variable` — before any argument was parsed. It would have been found at the worst possible moment: standing at a box on the new network, with the renumber as the thing that has to work. Found by running the script against a fixture rather than reading it. `ENVF` is now assigned from `env_files | head -1` beside the probe that uses it.

**12y. `it-set-ip` renumbers everything except the address someone typed into a compose file.** It rewrites `.env` (`SYSTEM2_ADDR`, `OPEN_WEBUI_URL`), `/opt/it/site.yml`, `/etc/hosts` and the ufw rules, then recreates the containers — and reports success. An address written **into** `compose.yaml` instead of left as `${SYSTEM2_ADDR}` is reached by none of that, so the endpoint silently keeps pointing at the lab subnet after the box has moved. dev-ai2 has exactly this: `vllm-gptoss` carries a literal `192.168.1.110`.

It now **reports** such lines before the recreate, and flags the case where one of them is the old peer address. It does not edit them — every file `ai_compose` places is a plain copy (gotcha 2), so an on-box edit is a deliberate exception and this script is not what gets to overwrite it. `--no-recreate` renumbers the files and leaves the containers alone, for a move where nothing should be restarted yet.

**12x. `/etc/polkit-1/rules.d` owned root:root silently disables EVERY polkit rule.** polkitd does not run as root: `/usr/lib/systemd/system/polkit.service` carries `User=polkitd`, so the daemon reads its rules as uid `polkitd`. The package ships the directory **root:polkitd 0750** for exactly that reason. `local_accounts` used to enforce `root:root 0750`, which the daemon cannot traverse — so every JS rule in it was ignored: the `dta` USB rule, the `network_admin_group` rule, and `remote_desktop`'s colord/packagekit rule. Nothing is logged. polkit just falls back to each action's shipped default, which for NetworkManager is `auth_admin_keep` — an admin password prompt a non-sudo user cannot satisfy, i.e. the exact symptom the rule was written to remove.

It presents as "the rule is not matching", and the give-away is `pkcheck` answering with the **default action's** annotation rather than a grant:

```bash
pkcheck --action-id org.freedesktop.NetworkManager.settings.modify.system --process $$
# polkit\56retains_authorization_after_challenge=1
# -> non-zero; that annotation belongs to auth_admin_keep, so no rule returned YES
ls -ld /etc/polkit-1/rules.d          # want: drwxr-x--- root polkitd
```

Repair without a pull, then restart the daemon — polkitd watches the directory, but only once it can open it, so a box being fixed does not notice on its own:

```bash
sudo chgrp polkitd /etc/polkit-1/rules.d && sudo systemctl restart polkit
```

Restarting polkit is safe on a live box: it is dbus-activated, holds no session state, and every caller re-resolves it on the next check. Do not "fix" this by loosening the mode to 0755 while the group is still wrong — the rules are policy and the package's 0750 is correct; it is the **group** that was wrong.

**12u. `netdev` and `systemd-network` grant nothing: NetworkManager asks polkit.** A user added to both still gets an authentication dialog asking for an ADMIN password when changing an IP. `netdev` is a Debian convention NetworkManager does not consult, and `systemd-network` belongs to systemd-networkd, which does not manage these boxes. The prompt is polkit's `auth_admin_keep` default for a subject that is not in `sudo`. The grant is a JS rule in `/etc/polkit-1/rules.d/`, and `local_accounts` writes one for `network_admin_group` when `network_admin_enabled` is true — scoped to `settings.modify.system` and `network-control` only, not the whole `org.freedesktop.NetworkManager.*` namespace. Off by default, and it **is** a privilege grant: a member can renumber a fielded machine without sudo, so record it as a deviation before enabling it. polkitd reads `rules.d` live, so no restart is needed once the directory is readable by it — see trap 12x, which is why the rule appeared to do nothing on the first fleet that got it.

**12t. "Please install software as a super user" does NOT mean run FlashPro with sudo.** The full message is `cannot search for FP6 programmers, cyusb.conf file not present under /etc folder. Please install software as a super user`, and the obvious response is the wrong one. Run as root the tool then fails with:

```
qt.qpa.xcb: could not connect to display
qt.qpa.plugin: Could not load the Qt platform plugin "xcb" ... Aborted
```

which is trap 29 — root has no Xauthority cookie for the user's RDP session, so Qt cannot reach a display. The message means the vendor's **setup script** wants root, once: `fp6_env_install`, which writes `/etc/cyusb.conf` and the udev rules. `sudo it-fpga fixup` now finds it under the Microchip tree, runs it, and repairs the 0600 modes it leaves behind under the STIG umask (trap 12m). After that the tool is launched **as the engineer**. The same two-message sequence appears whenever a box has the toolchain but never had the USB setup run, so it looks like a broken install and is not one.

**12m. FlashPro Express fails on `cyusb.conf`, and it is the umask again.** Microchip tells the engineer to run `sudo ./fp6_env_install`; that script writes `/etc/cyusb.conf` and its udev rules, and under the STIG's `umask 077` it creates them **0600 root:root**. FlashPro Express runs as the ENGINEER, so it cannot read the file the vendor just installed for it, and the error names `cyusb.conf` rather than the permissions on it -- the same shape as trap 5 and the same cost in wasted hours. `it-fpga fixup` now chmods it 0644, reloads udev, and says so. Do **not** work around it by launching FlashPro with sudo: root has no Xauthority cookie for the user's RDP session, so it then fails on X11 instead (trap 29). If the tool still cannot see the programmer after this, the remaining two are USBGuard (`it-usb enroll` -- it authorises the cable before udev ever names it) and group membership of `plugdev`, which needs a fresh login to take effect.

**12l. `boot=UUID=<uuid>` is a Red Hat parameter and it PANICS Ubuntu.** Every FIPS guide that mentions it is a dracut guide: dracut's fips module uses `boot=` to mount `/boot` and find the kernel's `.hmac`. Ubuntu uses initramfs-tools, where `boot=` names the initramfs **boot script** instead -- `/init` does `BOOT=${x#boot=}`, defaults it to `local`, and at line 287 runs `. "/scripts/${BOOT}"`. `boot=UUID=1234` therefore sources `/scripts/UUID=1234`, which does not exist; `init` exits; the kernel panics with `attempted to kill init`, immediately after `Begin: mounting root file system`. The only valid values are `local`, `nfs` and `casper`.

Ubuntu's FIPS integrity check runs from inside the initramfs and needs no `boot=` whatsoever -- the box that died this way (dev-16) had already printed `Fips check done` four lines above the panic, which is the proof. Recovery needs a screen and a keyboard: at the GRUB menu press `e`, delete the `boot=UUID=...` word from the `linux` line, `Ctrl-X`. `it-fips fix` strips it from `/etc/default/grub` and `/etc/default/grub.d/*.cfg`, and `it-fips` fails the box while it is present; both check the generated `grub.cfg` too, not just the intent.

**12k. Backticks inside a double-quoted shell string RUN the command.** Three times in this repo, a message meant to *tell* someone to run something would have run it instead:

```sh
bad "Run `it-clamav test` for the likely cause"        # runs it-clamav test
say "Peripherals added later need `it-usb enroll`"     # runs it-usb enroll -- INTERACTIVE, rewrites the USBGuard policy
bad "one `apt autoremove` from being removed"          # runs apt autoremove
```

All three sat on an **error path**, which is the worst place for it: that code runs only once something has already gone wrong, so normal use never reaches it and nobody notices. The `it-usb enroll` one lived in `it-go-classified` -- it would have fired while taking a box classified.

Use `'single quotes'` when naming a command inside a message, or escape the backtick. Sweep for survivors:

```bash
find roles tools -name '*.sh' | while read -r f; do
  awk -v F="$f" '!/^[[:space:]]*#/ && /"[^"]*`/ && !/\\`/ {print F":"FNR}' "$f"
done
```

**13. Audit rules on disk are not audit rules in the kernel, and they may not be in `rules.d`.** Two separate traps in one place. First, `usg fix` writes **`/etc/audit/audit.rules` directly**, not `rules.d/*.rules` — so an empty `rules.d` is normal on a USG box, and counting only `rules.d` reports "no rules" on a box with a full ruleset. Second, whatever is on disk still has to reach the kernel: the STIG sets auditd `-e 2` (immutable), after which new rules are refused until a reboot. Either way **every file-based OVAL still passes**, because those check files. ASP-2 ran with **1 rule in the kernel** against 8.5 KB in `audit.rules` and the 96.41 % scan said nothing. `it-checklist` item 6 counts whichever source holds rules and compares it against the kernel. Diagnose with:

> **Mind the glob.** `/etc/audit/rules.d` is `root:root 0750`, so `sudo cat /etc/audit/rules.d/*.rules` fails with *"No such file or directory"* — your **unprivileged shell** expands the glob before `sudo` runs, and it cannot read the directory. That looks exactly like an empty directory and is not. Wrap it: `sudo sh -c 'cat ...'`.

```bash
sudo auditctl -l                                              # what the kernel enforces
sudo grep -cvE '^\s*(#|$)' /etc/audit/audit.rules             # what usg fix wrote
sudo sh -c "cat /etc/audit/rules.d/*.rules | grep -cvE '^[[:space:]]*(#|$)'"   # rules.d
sudo auditctl -s | grep enabled                               # 2 = immutable, needs a reboot
sudo augenrules --check                                       # is audit.rules out of step with rules.d?
```

**14. A green playbook is not evidence.** ASP-2's compliance score barely moved (88.476 → 88.703) across a full remediation run — two whole categories of fix were being written correctly and still failing, because a stale file was poisoning rules that were otherwise satisfied and PAM values were being written into a file nothing read. Neither showed as an Ansible failure. **The re-audit is the evidence.**

**16. Blacklisting `usb-storage` does not disable USB storage.** SSG's UBTU-24-300039 covers that one module, which drives the bulk-only transport. A USB3 device that speaks USB Attached SCSI binds **`uas`**, a separate module the rule never mentions — so the scan passes green while a modern USB SSD mounts normally. `usg_remediate` blacklists both wherever `usb_storage_enabled` is false. Conversely, neither module has anything to do with **non-storage** USB: dongles, serial/COM adapters (`ftdi_sio`, `cp210x`, `ch341`, `cdc_acm`), HID and printers are unaffected, and **USBGuard** is what blocks those until `it-usb enroll` authorizes them. Verify with `lsmod | grep -E '^(usb_storage|uas)'` (empty is correct) — not with the scan result.

**22. Two offloads, and only one of them carries the report.** `/etc/cron.weekly/audit-offload` (`it-offload`) has only ever collected the rotated **auditd** trail — its extra-file stage takes files, not directories, and nothing pointed it at `/opt/_AuditFiles`. Its schedule is also unrelated to `powerstrux-audit.timer`, so even pointed there it could run *before* the week's report existed. The PowerStrux reports go out through **`it-powerstrux offload`** instead, which is pulled in by `powerstrux-audit.service` (`Wants=`) and ordered `After=` it, so it starts when the audit finishes however long that took. Do not "fix" this by adding `/opt/_AuditFiles` to `usg_audit_offload_extra`; it would log *unreadable, not collected* and still race.

**23. A hyphen in a `/etc/profile.d` function name breaks every `sh` login.** `/etc/profile` sources `/etc/profile.d/*.sh`, and for an `sh` login that shell is **dash**, which rejects a hyphen in a function name — `Syntax error: Bad function name`, printed at every login on every workstation. Bash accepts it, so it passes an interactive test and fails for cron, scripts and `sh -l`. The FPGA helpers are `vivado_env` / `libero_env` with underscores for exactly this reason; do not "tidy" them. Test any profile.d change with `dash -c '. /etc/profile.d/x.sh'`, not just bash.

**24. Starting a license daemon from a login script starts one per shell.** Both FPGA vendors' guides end their environment script with `lmgrd -c License.dat`, then tell you to hunt the stale daemon with `lsof -i :1702` when checkout fails with *"Cannot locate license file"*. The port was simply taken by the copy the last shell started. A local daemon is `fpga-lmgrd.service`, one per machine. Better still, use a license server and run no daemon at all.

**25. FlexLM needs two ports, and one of them is random.** `lmgrd` listens where you configured it; the *vendor* daemon (`snpslmd`, `xilinxd`) picks a random port at startup unless it is pinned with `PORT=` on the `DAEMON` line in the server's license file. Through a firewall the symptom is a license server that answers on the port you opened and still fails every checkout. `it-fpga status` probes the `lmgrd` port and says this when it succeeds.

**26. Ubuntu 24.04 publishes only a CURATED i386 subset, and one unresolvable name fails the whole apt transaction.** Ubuntu stopped building a full 32-bit archive after 19.10. `libgtk2.0-0t64:i386` pulls `libcups2t64:i386` -> `libgnutls30t64:i386`, which noble does not satisfy for i386; same chain via `libsystemd0:i386` -> `libgcrypt20:i386`. Every FPGA vendor guide on the internet lists these as prerequisites, and apt refuses the **entire** install — which on dev-14 took the 64-bit half down with it and stopped the pull. `fpga_tools` splits the 64-bit list (strict) from the 32-bit one (probed, best-effort) and reports by name what it skipped. Never pin a version or side-load a foreign `.deb` to force one in; `sudo it-fpga check` lists what is missing and why.

**27. `apt-cache policy` does not tell you whether a package can be installed.** It answers "does this NAME have a candidate", which is a different question from "does its dependency closure resolve". `libgtk2.0-0t64:i386` has a candidate on noble and still cannot be installed. The tell is in apt's own wording: *"not installable"* means no candidate, *"not going to be installed"* means there is one and the resolver refused — and a policy probe cannot distinguish them. This cost a second failed pull on dev-13 after the first fix used policy as the oracle. The correct oracle is **`apt-get -s -q install -y <pkg>`**, which resolves the whole tree, does no dpkg work, and exits 100 when it cannot. Both `fpga_tools` and `it-fpga check` use it.

**28. Ansible's free-form `shell:` splits arguments, and double quotes inside Jinja break it.** `shell: |` with `{{ x | default("") }}` in the body fails at parse time with *"failed at splitting arguments, either an unbalanced jinja2 block or quotes"* — before anything runs, so it looks like a YAML error and is not. Use the `cmd:` key (`shell:` → `cmd: |`), which is not split. Same script, same Jinja, parses fine.

**29. The STIG umask makes every sudo-run vendor installer produce a root-only tree.** `umask 077` is the baseline setting, so an installer run under `sudo` -- which Vivado and Libero both need, to write `/tools` and `/opt` -- creates `0700` directories and `0600` files throughout. Engineers then get *"Permission denied"* sourcing `settings64.sh`, which reads as a failed install and is not one; the natural workaround, running the tool under `sudo su`, then fails differently because root has no `.Xauthority` cookie for the user's RDP session (*"Can't connect to X11 window server"*). Neither error names the cause. `sudo it-fpga fixup` applies `chgrp -R <access group>` + `chmod -R g+rX,o-rwx` -- capital X, so data files do not come out executable -- and the pull now corrects it on every run. Beware the near-miss: a tree with perfect modes is still unreachable if a PARENT blocks traverse, with an identical error, and "traversable" is not "other-executable" -- a group member walks a 0750 directory owned by that group fine. `it-fpga status` checks the parent chain with that distinction. Applies to anything else installed the same way.

**30. Libero needs RHEL-era libraries Ubuntu does not package, and one of them must NOT be symlinked.** Its installer stops at `libpng15.so.15`, and there is no `libpng15` in noble. `libtinfo5` for Vivado is a symlink onto ncurses 6 and works; **libpng is not the same case** -- 1.5 -> 1.6 made the structs opaque, an ABI break, so a symlink onto libpng16 links and then misbehaves rather than failing at load. `it-fpga compat build` compiles libpng 1.5.30 from upstream into `/opt/microchip/compat/lib`, which only Libero sees via `LD_LIBRARY_PATH`. Never put it in `/usr/lib`: an unmaintained libpng in front of every program on the box is a worse problem than the one it solves. `it-fpga compat` runs `ldd` on the Libero binaries so the whole missing set shows up at once.

**31. `sudo` strips `LD_*` from the environment even with `-E`.** `LD_LIBRARY_PATH=... sudo -E cmd` looks like it passes the variable and does not: sudo removes `LD_PRELOAD`, `LD_LIBRARY_PATH` and friends unconditionally, because honouring them would let any sudo user load their own code into a root process. The symptom is a library you have definitely built and definitely put on the path still reported missing. Use `sudo env LD_LIBRARY_PATH=... cmd` instead, which sets it inside the elevated process. Note that `sudo env` does not rescue a **GUI**: `DISPLAY` and `XAUTHORITY` go the same way, and root has no X cookie for the user's session, so a graphical installer still dies with *"could not connect to display"*. The answer there is not to elevate at all -- `it-fpga install libero` hands the directory over instead. Same family as the `env_reset` trap: `VAR=x sudo cmd` sets it for sudo, not for the command.

**32. A stale RDP session breaks the NEXT login, and the error names GNOME.** You authenticate over RDP and the window closes a second later; sesman logs *"Window manager exited with non-zero exit code 1"* and the session log says `gnome-session-binary: WARNING: Session manager already running!`. It is not the consent banner, not `gnome-initial-setup` and not a credential problem. An earlier session for the same user was never reaped -- its `Xorg`, `xrdp-chansrv` and per-session `xrdp-sesman` are all still running -- so sesman finds `/tmp/.X11-unix/X10` occupied, starts the new session on `:11`, and gnome-session there finds the orphan still owning `org.gnome.SessionManager` on that user's bus. **One GNOME session per user is a hard limit**, so it exits 1 and xrdp drops the connection. `sudo it-rdp status` names the orphans, `sweep` reaps them, `reset <user>` is the blunt version, and `xrdp-reap.timer` does it unattended every 15 minutes so the person who hits it is not waiting on an admin.

**Normal reconnect is not the problem.** xrdp resumes a disconnected session perfectly well -- `Policy=Default` matches on `<User,BitPerPixel>` only, so coming back on a different monitor or from a different machine still finds your desktop. What breaks it is **restarting `xrdp-sesman`**: the sessions it holds are reparented to init and it comes back with an empty table, so it can no longer match anything to resume and starts a new session beside the old one. A pull that changed `sesman.ini` used to do that to a room full of people. The handler now defers while sessions are live, and `KillDisconnected` + `dev_rdp_disconnected_time_limit` bound how long a genuinely abandoned session sits. Note `DisconnectedTimeLimit` is **ignored** unless `KillDisconnected` is true, and values under 60 are forced to 60.

**Identifying an orphan needs systemd, not the process tree.** The test is "is this `Xorg` a descendant of the `xrdp-sesman` systemd is currently running", asked with `systemctl show -p MainPID`. A PPID-of-1 rule is not enough: on a box mid-incident there are SEVERAL `xrdp-sesman` processes with PPID 1 -- the live one and every session orphaned by a restart -- and picking the wrong one either spares an orphan or kills a working desktop. Observed on dev-13: the running sesman was 277906 while an orphaned session's was 182320, both PPID 1. With no running sesman the sweep treats nothing as an orphan, because reaping on a guess logs out a room.

**And the sweep must stay inside xrdp's display range.** `X11DisplayOffset`..`MaxDisplayNumber`, 10-63 by default. gdm keeps live sockets at `/tmp/.X11-unix/X1024` and `X1025` (seen on dev-13), and deleting those breaks the console greeter -- the one way back in when RDP is what is broken.

**33. Libero 2025.1 moved Designer, and the symptom is "no app tile".** The binaries used to be at `<install dir>/Libero/bin64/libero`; 2025.1 puts them at `<install dir>/Libero_SoC/Designer/bin64/libero`. Every probe in `fpga_tools` used the old path, so a correct install was read as "not installed" -- no app-grid tile, no `libero` command, `it-fpga status` saying NOT INSTALLED, and `it-fpga check` reporting Microchip's own checker missing. Nothing in the install says anything is wrong, which is the trap. `fpga_libero_designer_dir` / `fpga_libero_bin` carry it now, `libero_env()` adds every candidate directory that exists rather than one hardcoded layout, and `it-fpga` falls back to a `find` when the configured path is not there. Check a new release with `find <install dir> -maxdepth 5 -type f -name libero` before assuming the tree is the same shape.

**34. A role-level tag is inherited by every task, and `--skip-tags` beats a task's own tag.** `fpga_tools` and `remote_desktop` carried `tags: [packages]` on the ROLE in `local.yml`, and their script-shipping tasks carried `tags: [scripts]` so that "shipping a fix to `it-fpga` is a light pull". It never was: `it-pull` (light) is `--skip-tags packages,...`, the task's inherited `packages` matched the skip, and Ansible skips whenever ANY of a task's tags is in `--skip-tags` -- regardless of its other tags. The whole role was silently skipped on every light pull, so a fixed `it-fpga` sat in the repo and never reached a box, and `it-fpga status` kept printing a message that had already been removed upstream. `--tags scripts` still worked, which is what made it look like the tags were fine. The role-level tags are gone; the apt tasks inside those roles carry `packages` themselves. **Never put `packages` on a role that also ships scripts.** **It happened again on 2026-09-09, and it hid a fix that was already written.** `dev_tools` still carried a role-level `tags: [packages]` after `fpga_tools` and `remote_desktop` had theirs removed, so `it-pull light` skipped the entire role -- including `it-vscode link --all`, the task that repairs the root-owned home directories of trap 44. dev-16 pulled, reported `ok=319 changed=14`, and the ownership was untouched: a clean-looking pull that did none of the thing it was run for. The heavy halves (`toolchains`, `nodejs`, `python_env`) carry the tag on their own `import_tasks` now, and the script halves carry `scripts`. **When you remove a role-level tag, check every role, not the one in front of you** -- and verify by resolving the tags rather than reading them, which is what caught this.

**35. `ansible.builtin.shell` runs under dash, which has no `set -o pipefail`.** `/bin/sh` on Ubuntu is dash, and the shell module uses it unless told otherwise. `set -o pipefail` there is not a no-op -- dash exits **2** with *"Illegal option -o pipefail"*, so the task fails and the pull stops, wherever it happens to be. It stopped a light pull on dev-15 half way through `remote_desktop`, after the sesman settings were written and before `it-rdp` was installed, leaving the box in a state neither the old nor the new config describes. Either add `executable: /bin/bash` (what every other pipefail task in this repo does) or write the pipeline so it does not need it -- an `if cmd | grep -q x; then` already takes its status from the last command in the pipe, which is usually the whole point.

**36. A `0750 root:root` script cannot self-elevate, and `it-help` says "(cannot read its script)".** Every `it-*` command starts with `[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"` so it can be typed without `sudo` -- but the shell has to READ AND EXECUTE the file before that first line runs. Installed `root:root 0750`, nobody but root can, so the command fails with *Permission denied* instead of prompting, and `it-help` cannot read its header to describe it. `it_scripts` installs everything `root:{{ ia_it_group }} 0750` (in a `2750` directory); five commands added by other roles -- `it-fpga`, `it-rdp`, `it-vscode`, `it-codeserver`, `it-inventory` -- did not, which is why those five behaved differently from the other seventeen. Two correct patterns: `root:<admin group> 0750` in `/opt/it/scripts` for an admin command, or a real `root:root 0755` file in `/usr/local/sbin` when more than one group must reach it (`it_scripts_public`, and `it-powerstrux`, which auditors and admins both run). World-executable is not a privilege there -- the script elevates through sudo, which still decides who may do anything. A command living under `/opt/_AuditFiles` hits this too regardless of its own mode: that directory is `2770 root:audit`, so an admin who is not an auditor cannot traverse it.

**37. Prose that loses its `#` is valid bash, so `bash -n` passes and the script eats itself.** An edit to `it-fpga`'s usage block dropped the comment marker from three lines. `every user gets Libero SoC / FPExpress / SmartHLS` is a **syntactically valid command invocation**, so the syntax check was clean and the file shipped. At run time those lines executed, and one of them began with `it-fpga` -- so the script invoked itself, forever: screens full of *"every: command not found"* and *"/: Is a directory"*, ending in `bash: warning: shell level (1000) too high`. A `#`-less line inside a header is the worst case of this precisely because headers contain the command's own name. Two checks, because neither alone is enough: `tools/check-script-headers.sh` asserts every line between the shebang and the first line of code is a comment or blank, and **running the script with `--help`** reproduces a load-time fault that no static check can see. `bash -n` proves a file parses, never that it means what you wrote.

**38. A bash function name is resolved when the line RUNS, so a typo hides in an error path.** `it-smb`'s new probe called `explain_mount_error`; the function is `explain_cifs`. `bash -n` was clean, `--help` was clean, the probe ran fine right up to the point where a mount failed -- and then printed `command not found` instead of the diagnosis, at the exact moment the operator needed it. Static checks in `tools/`, both of which are cheap to run and neither of which `bash -n` subsumes: `check-script-functions.sh` (every internal call resolves to a definition in the file or one it sources) and `check-script-headers.sh` (trap 37). The function check has to skip **heredoc bodies** -- these scripts write grub.cfg, systemd units and `.desktop` entries, and `password_pbkdf2 $SUPERUSER $hash` is GRUB syntax, not a call. A checker that cries wolf stops being run.

**39. NVIDIA prebuilt modules are FLAVOUR-LOCKED, and the wrong one fails silently.** `linux-modules-nvidia-<branch>-<variant>-generic` does not load on a `-fips` kernel: there is no matching `nvidia.ko`, so the module is simply absent. Nothing errors at install time and nothing errors at boot — `lsmod | grep nvidia` returns 0 and `nvidia-smi` is not even installed, because `nvidia-headless-no-dkms-*` does not ship it. Found on all three development boxes: an RTX A4000 present, the proprietary stack installed by hand, and the card completely unused while the console ran on nouveau. `gpu_fips_module` exists for exactly this and is gated `when: is_ai`, so it never ran there. Two things follow. **The development profile is CPU-only by design** — Vivado, Vitis and Libero do not use a GPU, and `xorgxrdp` is a software X server, so an RDP session renders on the CPU whatever card is fitted. And if a GPU is ever genuinely needed on a development box, `gpu_fips_module` needs a different gate AND a different tag: `ai-gpu` is skipped by `it-pull` in **both** light and full modes, so enabling the role alone would leave it never running.

**40. `pro enable <service>` is not free when the service is already enabled, and on FIPS it can kill the pull.** It contacts contracts.canonical.com first -- *"One moment, checking your subscription first"* -- before it looks at local state. On dev-15 that came back `An unexpected error occurred: [CRYPTO] unknown error (_ssl.c:3026)`, a TLS failure inside the pro client on a FIPS kernel, and `usg_harden` stopped the entire pull **on a box where `fips-updates` was already enabled and nothing needed doing**. Everything after that role -- `desktop_hardening`, `usg_remediate`, `usbguard`, `powerstrux`, `it_scripts` -- never ran, so the box was left half-configured by a task that had no work to do. The old guard tolerated `is already enabled` **in pro's own output**, which only helps when pro gets far enough to say it. Read the enabled set out of `pro status --format json` and skip the call entirely. Same lesson as traps 35 and 38: ask the system what is true, do not parse the command's complaint. Note also that a **skipped** registered variable has no `rc`, so a later `when` testing `_x.rc` throws -- test `is not skipped` first.

**41. A first build exercises ordering that no later pull ever will, and dev-16 failed twice on it.** Both faults were invisible on every existing box, because the thing that was missing had been put there by an earlier pull. **(a)** `dev_tools` ships `it-vscode` into `/opt/it/scripts` at line 164 of `local.yml`; `it_scripts`, which creates that directory, is at line 279. `copy` does not create a missing parent, so the first build died with `Destination directory /opt/it/scripts does not exist`. **(b)** `usb_serial` wrote `usb-serial-bind.service`, told systemd to start it, and installed the `usb-serial.sh` its `ExecStart` names three tasks later -- 203/EXEC. Each time the consequence was the same and is the real point: **a play stops at the first failure**, so every role after it (`fpga_tools`, `remote_desktop`, `usg_harden`, `usg_remediate`, `usbguard`, `powerstrux`, `it_scripts`) never ran and the box came up **unhardened** behind a recap that read `failed=1`. `tools/check-role-ordering.py` now checks three shapes of this -- a role writing into a shared dir it does not create, a unit whose `ExecStart` names a script the role installs later, and a role running a command only a LATER role in `local.yml` installs -- parsing the task YAML because regex could not follow the loops of inline dicts or the Jinja paths. Writing it found a third instance in `remote_desktop`, saved only by an `ExecStart=-` and a `ConditionPathExists=`; those units are also reordered now, and the checker skips a unit that guards itself so it does not cry wolf (trap 38). Two further notes, both about trusting a green checker. The cross-role check passed at first because it could not SEE `it_scripts` -- that role installs most of the `it-*` commands through a loop over its defaults, so every path was an unresolvable Jinja expression and "provides nothing" read as "nothing is wrong". And the ExecStart check silently found nothing, because a Jinja path contains spaces and `ExecStart=(\S+)` captured `{{`. **A check that reports OK proves nothing until you reintroduce the bug and watch it fail** -- run it against a deliberate inversion before believing it. And peripheral roles should not be able to abort hardening: `usb-serial-bind` is now `failed_when: false` with the real state read back from `systemctl is-active`, not from the task result that `failed_when` just falsified.

**42. `curl` proving contracts.canonical.com is up does NOT mean `pro enable` can reach it.** dev-16 could not enable `usg` or `fips-updates`. The subscription was not the problem -- `pro status --all` showed a full **Ubuntu Pro** contract valid to 2027 with both services `ENTITLED yes`, and `esm.ubuntu.com` answered 200. Neither were the apt sources: plain `us.archive.ubuntu.com` + `security.ubuntu.com`, no mirror. The error only appears once you stop swallowing it: `pro enable usg` -> *"An unexpected error occurred: The read operation timed out"*. `pro enable` calls `contract.refresh()` before it does anything, and that POST to `/v1/contracts/<id>/context/machines/<machine>` hangs with the request sent and **no response status line**, for the full 30s timeout. Meanwhile `curl https://contracts.canonical.com/v1/resources` returns **200 in 0.3s**, and an earlier POST in the same run succeeded after **10.6s** -- so the host is up, the path is intermittent and slow, and a GET from curl tells you nothing about a POST from the client. Suspect a middlebox: dev-15 failed on the same endpoint with `[CRYPTO] unknown error (_ssl.c:3026)`, a different symptom of a TLS path that is not clean. `pro config show` confirmed no proxy is configured and none is needed. Both `pro enable` calls now retry (5 attempts, 15s apart). Two things follow. **Enable the services by hand once** -- `sudo pro enable usg` until it takes -- and the pull never calls `pro enable` again for them, because trap 40's guard reads the enabled set from `pro status` and skips. And a diagnosis that ends "the host is reachable" is not finished: reach it **the way the failing client does**.

**43. `pro enable fips-updates` on noble can fail on a dependency inside Canonical's own repo, and pro then hides the evidence.** dev-16, Pro-attached with `fips-updates` ENTITLED, on `6.8.0-139-generic`:
```
ubuntu-fips-userspace : Depends: libgcrypt20 (= 1.12.0-2ubuntu0.1~Fips1~rc11)
                                 but 1.10.3-2ubuntu0.2 is to be installed
                        Depends: libgnutls30 (= 3.8.3-1.1ubuntu3.6+Fips1.2)
```
Note the second line has **no "but ... is to be installed" clause** -- that shape means the version has no candidate at all, i.e. the `fips-updates` noble suite does not currently publish a dependency its own `ubuntu-fips-userspace` requires. Nothing on the box causes this and nothing on the box fixes it. `~rc11` in a version pro is installing is itself worth noticing.
**The evidence is destroyed on the way out.** On a failed install pro logs `"Apt install failed, removing apt config for fips-updates"` and deletes the sources file, the preferences file and the apt lists. So `apt-get -s install ubuntu-fips` afterwards says *"Unable to locate package"* -- the package looks nonexistent rather than unsatisfiable, which sends you diagnosing the wrong thing (it sent me). The unmet dependency exists in exactly one place: **`/var/log/ubuntu-advantage.log`**, root-readable only. Same trap for `usg`: after a failed enable, `apt-cache policy usg` reports no such package.
Note also that pro retries the apt install four times itself, ~10s apart, before giving up -- so an `enable` that fails this way burns a minute and looks like a hang.
**ROOT CAUSE, CONFIRMED 2026-09-08: our own i386 multiarch, three libraries deep. Nothing upstream is broken.**
The full chain, every link now verified on dev-16:
```
ubuntu-fips-userspace  needs  libgcrypt20   = 1.12.0-...~Fips1~rc11   (amd64: published)
libgcrypt20 1.12.0     needs  libgpg-error0 >= 1.56
fips-updates publishes        libgpg-error0 1.58-2                    (amd64 ONLY)
box has                       libgpg-error0:i386 1.47-3build2.1       <-- THE LOCK
```
`libgpg-error0` is `Multi-Arch: same`, so its amd64 and i386 copies must hold one version. The `fips-updates` suite is **amd64-only**, so there is no i386 1.58 to move to, so the amd64 copy is frozen at 1.47, so the FIPS libgcrypt cannot install, so the metapackage reports an unmet dependency. `libgnutls30t64` fails the same way through its own i386 sibling. **One cause, three symptoms, and `fpga_tools` is what puts every one of those i386 copies on the box.**
The fix is ordering, and `pro_attach` already does it: enable FIPS before `fpga_tools` turns on i386 and a clean amd64-only box takes it. Boxes built before the i386 work existed (dev-13/14/15) got FIPS for exactly that reason -- not a carve-out, just sequence.
**FOUR wrong diagnoses preceded this, and the pattern in every one was stopping a link short and filling the gap with a conclusion:**
1. *"the subscription is infra-only"* -- it is full Pro; `pro status --all` said so.
2. *"`libgnutls30` does not exist on noble"* -- it is a **virtual** package, `Provides:` by `libgnutls30t64`. An empty `apt-cache policy` version table means virtual, not absent; a genuinely unknown name gets `N: Unable to locate package`.
3. *"i386 is the cause"* (first attempt) -- right answer, wrong evidence, abandoned when removing `libgcrypt20:i386` did not help. It did not help because that removal leaves `libgpg-error0:i386` behind: it is a DEPENDENCY of libgcrypt20, not a reverse-dependency, so nothing cascaded to it.
4. *"fips-updates does not publish libgpg-error0"* -- **asserted without ever running `apt-cache policy libgpg-error0`.** It publishes 1.58-2. This one nearly sent a bug report to Canonical for their own correctly-built package.
**Technique that works, in order:** take the metapackage out of the question and install the leaf at an exact version (that produced the libgpg-error0 line); then check the policy of *every* package named in the resulting error, including the ones you assume are fine; and remember `apt-get -s remove <pkg>` shows only reverse-dependencies, so a blocking DEPENDENCY one level down stays invisible. Do not truncate `apt-cache showpkg` with `head` -- `Reverse Provides:` is at the end.

**44. `install -d -o USER a/b/c` owns the LEAF only -- every parent it creates belongs to root, and that is what made RDP slow.** `it-vscode link` ran `install -d -m 0700 -o "$u" -g "$g" "$h/.local/share/code-server/extensions"` as root. The leaf came out right; `~/.local`, `~/.local/share`, `~/.local/share/code-server` and `~/.vscode` came out `root:root 0755`, from the caller's identity and umask. Reproduce it in four lines and the ownership pattern is byte-for-byte what dev-18 showed.
**A root-owned `~/.local/share` is not cosmetic.** The user cannot create anything inside it, so `ibus-table` cannot make its own directory, crashes at every login with `PermissionError: [Errno 13] .../.local/share/ibus-table`, and the GNOME session stalls waiting on the input method. That is the "RDP takes forever" complaint, on every account of every development box, and it was ours -- not xrdp, not the network, not the air-gap. The earlier "first app is slow, then fine" reports are the same fault surfacing at a different moment.
The fix is two functions, because there are two problems. `mkdir_owned` walks the path and chowns only the directories it actually creates, returning early on any that exists so nothing pre-existing is touched. `fix_home_ancestors` repairs the boxes already damaged -- inside the user's own home only, only where the owner is wrong, ownership only. The pull runs `it-vscode link --all` every time, so an existing box repairs itself on the next pull.
**Worth generalizing: any `install -d`, `mkdir -p` or Ansible `file:` that creates a path under someone's home creates its parents as root.** Ansible's `file:` module has exactly the same behavior -- `owner:` applies to `path`, not to the parents it implicitly creates. Check the ancestors, not just the thing you meant to make.

**45. Two minutes of every boot went to a wait-online that was waiting for nothing.** dev-16, `systemd-analyze blame`:
```
2min 309ms systemd-networkd-wait-online.service
   5.988s NetworkManager-wait-online.service
```
and `networkctl list` showed all ten links **`unmanaged`**. NetworkManager is the netplan renderer on the desktop profiles, so `systemd-networkd` owns nothing -- but its wait-online is enabled by default, waits for links it does not manage, and times out at 120s on every boot. `NetworkManager-wait-online` had already satisfied `network-online.target` six seconds in, so the two minutes bought exactly nothing.
**Do not simply disable the wait.** Real units order behind `network-online.target` here: the SMB audit offload mount, the PowerStrux offload and the FPGA license daemon. Remove it and those start before the network is up. The `network_online` role masks only the wait-online that has nothing to wait for, and only when the other one is enabled to take over.
**The condition is read from the box, never inferred from the profile.** An `ai` node on Ubuntu Server has networkd as its renderer, where this unit is the one doing the real work -- masking it there would leave `network-online.target` with no provider and hang everything ordered behind it instead. The role counts managed links with `networkctl list` and unmasks again if that ever changes, so a rebuild onto a different renderer self-corrects. A failed probe means no change.
Boxes with several NICs make this worse but are not the cause: dev-16 has nine, one routable. Where networkd genuinely IS the renderer, the equivalent fix is `--any` in a drop-in, since wait-online otherwise waits for ALL managed links and one unplugged port holds up the boot.

**15. Pre-USG leftovers.** Two separate outages traced to files the current baseline neither writes nor removes, left by the old ansible-lockdown role (`/etc/audit/rules.d/stig.rules`, and `pam_faillock` lines in `common-auth` with `pam_unix`'s jump offset never recalculated). Assume there are others on any box built before the USG switch.

---

## Profiles

Set with `deployment_profile` in `group_vars/all.yml`, or `PROFILE=` on `bootstrap.sh`. Default `development`. `desktop`/`server` are aliases for `development`/`ai`.

| Profile | For | What it builds |
|---|---|---|
| `development` | Engineering workstation | Dev toolchain, GNOME desktop over **RDP**, code-server, Cockpit |
| `ai` | Two-node inference server | Docker + NVIDIA + Dockge + the compose stacks. Headless |
| `emi` | Imaging / field workstation, **classified-capable** | `development` app set minus RDP, plus VPN/recon/CJK-IME, an imaging firewall (DHCP/TFTP/DNS/OpenVPN), and a camera + mic lockdown. FIPS + LUKS/TPM on, full `usg fix` |
| `emi-unclass` | Same hardware, **unclassified only** | As `emi` but FIPS/LUKS/TPM off and the disruptive `usg fix` skipped. USG audit + ufw/dconf/banner hardening still apply. No `auto_audit`, no DTA gate on USB |
| `baseline` | An already-built box | Provision + harden only. No app installs, no RDP |

Every profile attaches Ubuntu Pro, creates the org accounts/groups and `/opt/ia` + `/opt/it`, runs USBGuard, and drops a USG report in `/opt/ia/usg`.

Gating is computed in `group_vars` — `is_ai`, `is_emi`, `emi_classified`, `is_development`, `is_baseline`. "All profiles except emi-unclass" is a real pattern; see `local_auto_audit_enabled`.

---

## Commands

All self-elevate with `sudo`. Scripts live in `/opt/it/scripts`, symlinked into `/usr/local/sbin`.

> **`it-help` lists all of this, on the box.** It discovers the commands from
> what is actually installed, so it is right for that machine's profile without
> anyone maintaining a list. `it-help <command>` prints one command's full
> options; `it-help --all` prints every one.

### Every profile

| Command | Does |
|---|---|
| `it-pull` | Re-run the baseline. `it-pull` (light — config + scripts, no apt, no scan, **no container touched**), `full` (+ packages and a fresh audit/scan), `scripts` (that role alone), `ai` (opts into the compose stacks), **`load [PATH]`** (air-gapped: adopt a baseline repo carried in on media — mirrors it to `/srv/baseline.git`, sets `REPO_URL` in `pull.conf`, admin-only, verifies the repo by content and requires a typed `YES` — **`--yes`/`-y`, or `IT_PULL_ASSUME_YES=1`, substitutes for that keystroke and nothing else**, for pushing a baseline over SSH with no tty; validation, the mirror swap, ownership and the `pull.conf` write are unchanged, an invalid repo is refused with the same message and status, and the adoption is logged to syslog naming the invoking user. `it-pull load --help` for the detail), `check` (Ansible `--check`; unreliable — check mode can report the opposite of the truth, see procedures §1.10), `status` (behind origin? plus the incoming commits and files), `log`. Reads the repo/branch off the box's own `ansible-pull` checkout; override in `/etc/stig-build/pull.conf` |
| `it-baseline` | Capture what the box actually IS, so the repo can be checked against it — **read-only**, writes `/opt/it/baseline-<host>-<stamp>.txt`. Answers "if this were rebuilt from a pull tomorrow, what would be missing?", which is a different question from `it-checklist`. The load-bearing sections are the unmanaged ones: `apt-mark showmanual`, `dpkg --verify`, unit files in `/etc/systemd/system`, `/usr/local/{bin,sbin}`, sysctl/modprobe/udev drop-ins. Secret-bearing files are listed by name, mode and size **only** — the capture is meant to leave the box. `--brief`, `--stdout` |
| `it-repair` | **The slow-box command.** Finds and fixes the faults that make a hardened box crawl or stop a desktop session starting: root-owned directories in a home (trap 44 — the black screen with an X cursor), `systemd-networkd-wait-online` waiting 120 s for links it does not manage (trap 45), code-server instances started at boot, orphaned RDP sessions, duplicate FPGA tiles, failed units, queued apport crash dialogs. Reports boot times, disk and the kernel audit-rule count without touching them. **`check` (default) changes nothing; `fix` applies.** `--only a,b,c`, `--list`. **Self-contained** — it reads no config and calls nothing else from this repo, so it can be copied to a fielded box on its own when a whole baseline cannot reach it |
| `it-net` | Address, DNS and time source, set before a box is deployed. `status`, `ip`, `dhcp`, `dns`, `ntp`, `apply`. **`check`** is the read-only half: it MEASURES rather than lists, timing a lookup of the box's own name and of a name that cannot exist, then reporting the gateway, chrony sync, NetworkManager's connectivity probe and any wait-online unit that is enabled and failing. Every finding names the command that fixes it, and it needs no sudo. Exit 1 while anything is outstanding |
| `it-status` | Everything at a glance |
| `it-host` | OS, kernel, FIPS, uptime, disks |
| `it-luks` | Encryption state + TPM binding |
| `it-luks-rebind` | Re-bind LUKS to the current PCRs after a firmware change |
| `it-luks-passwd` | Rotate the disk passphrase. Forces `--pbkdf pbkdf2`: LUKS2 defaults a new slot to argon2id, which FIPS mode will not process, so a rotation done on a generic kernel writes a slot the FIPS kernel cannot use |
| `it-fips` | **The whole FIPS repair.** `status` (default) answers two questions separately: is it FIPS now, and will it still be after a reboot. `auto` does all of it -- strips a `boot=` (RHEL parameter, panics Ubuntu, trap 12l), restores `fips=1`, `apt-mark manual`, sets `GRUB_RECORDFAIL_TIMEOUT`, re-adds `--unrestricted` across every generator in `/etc/grub.d`, converts argon2 keyslots -- then arms a ONE-SHOT boot, or pins the kernel if the box is already in FIPS mode. `fix` is the config half alone; `luks` the keyslots alone; `retire <slot>` removes an orphaned keyslot, refusing to touch the TPM binding or the last typeable slot; `boot` / `confirm` are the one-shot and the commit; `undo` restores the GRUB config. Checks Secure Boot signing and reports a gated **submenu** as the normal thing it is -- `10_linux` never puts `$CLASS` on a submenu line, and reading that as a lockout reported a healthy box as broken |
| `it-pro` | The Ubuntu Pro subscription — which USG, FIPS and ESM all come from. `status` (default; flags a **free/personal/trial** contract, which entitles USG and FIPS exactly like a paid one so nothing else looks wrong), `token <file>` (stored token only — governs a REBUILD), `switch <file>` (**this box**: detach, re-attach, re-enable its services, store it), `attach`, `refresh`. `usg_harden` attaches only an UNATTACHED box, so changing the token file alone leaves a trial-attached box on that trial forever — `switch` is the only thing that moves it. The token can be the argument itself, a file containing it, `-` for stdin, or omitted for a prompt that is not echoed — classified by what it is, so a token and a filename cannot be confused. An argument is visible in `ps` and left in shell history; the command says so once |
| `it-grub` | `status` / `hash` (fleet) / `set` (one box) — GRUB password |
| `it-usb` | USBGuard: `status`, `list`, `blocked`, `enroll`, `allow`, `trust` |
| `it-serial` | **Who is holding a serial port, and take it back.** `list` (default) shows every `ttyUSB`/`ttyACM` and populated `ttyS`, the holder's user, PID, how long it has been open and where to find them (`screen -r <session>`, or the tmux pane); `free <dev>` / `free --all` / `free --mine` end it (SIGHUP → SIGTERM → SIGKILL, so screen and minicom close the port and remove their own lock); `locks` finds and clears stale `/run/lock/LCK..*`. **Runnable by the `dialout` group, not just admins** — it self-elevates through a sudoers grant scoped by argv. It needs root because the kernel does: `/proc/<pid>/fd` is `0500` owned by the process owner, so nothing unprivileged can see who holds a port another user opened (`fuser` and `lsof` read the same `/proc` and are equally blind), and `/run/lock` is sticky, so another user's stale lock cannot be removed. Refuses PID 1, anything owned by root, and anything under `system.slice` — a getty on a serial console or ModemManager probing a port is never killed. Every kill is logged to `authpriv` with the invoking user |
| `it-checklist` | The org checklist, one line per item. `--fail-only`, `--out FILE`, and **`--fix`** — prints how to close every FAIL and what each MANUAL item needs from a human. Prints steps, changes nothing |
| `it-oscap` | Run an OpenSCAP DISA-STIG scan now |
| `it-powerstrux` | **`install` first, then `sudo it-pull scripts`, THEN `enable`.** The timer and its service are ansible's, and the role skips them while `Initiate-PowerstruxLA.ps1` is absent — so straight after `install` the tool exists and the units do not, and `enable` used to fail with systemd's bare *"unit file powerstrux-audit.timer does not exist"*. It now explains itself. Run the PowerStrux audit. `open` copies the newest report to `~/PowerStrux-Reports/` and opens it — **necessary**, because Firefox is a snap and cannot see `/opt` (trap 18). Also `status`, `schedule "<spec>"`, `enable`/`disable`; a schedule change is persisted to `site.yml` |
| `it-powerstrux offload` | Carries the week's report off the box: one folder per ISO week (`/opt/ia/powerstrux-offload/<YYYY>-W<nn>/` — report + run logs + `PowerStruxLAConfig.txt` + a sha256 `MANIFEST.txt`), pushed to the evidence drop box. `setup`, `status`, `test`, `run [--local]`, `on`/`off`, `push on`/`off`, **`transport smb\|sftp`**, **`sftp <user@host:/path>`**, `opts`, `extra`, `list`, `log`, `where`. **On a FIPS box the transport must be `sftp`** — SMB cannot authenticate without a Kerberos join, guest included (trap 12ac). Every write lands in both `/etc/stig-build/powerstrux-offload.conf` (immediate) and `/opt/it/site.yml` (survives the pull) |
| `it-powerstrux install` | Install PowerStrux from a staged vendor zip: unpack, place the module under PowerShell's `Modules/`, set the reporting window (8 days) and report directory (`/opt/_AuditFiles`) in `PowerStruxLAConfig.txt`. `--zip`, `--days`, `--dir`, `--days-key`, `--dir-key`, `--force-config`. Finds the module by its entry point rather than an expected folder name, keeps an existing hand-tuned config, and edits a config key only where it already exists — a release that renames one gets a clear failure and a printout of the real keys, never an appended line the tool ignores. `it-powerstrux config` re-runs just the two settings |
| `it-powerstrux offload` | Carry the week's report off the box. `status` (default), `setup`, `creds`, `test`, `run [--local]`, `extra list\|add\|remove`, `list`, `log [N]`, `on\|off`, `push on\|off`, `audit on\|off`, `containers on\|off`, `opts <cifs-options>`, `where`. Builds one dated folder per ISO week — the report, its run logs, `PowerStruxLAConfig.txt`, a sha256 `MANIFEST.txt` — and copies it to a Windows share. Runs **after** the scheduled audit, not on a clock of its own. Writes both `/etc/stig-build/powerstrux-offload.conf` (immediate) and `/opt/it/site.yml` (survives the pull) |
| `it-ckl` | Build the DISA `.cklb`/`.ckl` from the scan + `answers.yml` |
| `it-stig` | `status` / `run` / `scan` / `checklist` / `archive` — wraps the two above |
| `it-domain` | `status`, `preflight`, `stage`, `join`, `test`, `leave`, `pam-restore`. Joins a box to AD. **`preflight` changes nothing** and checks the things that actually make joins fail: SRV records, clock skew, ports 88/389/445/464/3268, PAM health. `join` backs up the PAM stack first — `realm join` regenerates it |
| `it-sshfs` | **The file share that works on a FIPS box.** Mounts a remote folder over SSH as a systemd automount: `add --name N --remote USER@HOST:/PATH [--group G]`, `key`, `test`, `mount`, `umount`, `remove`. Generates its own ed25519 key (0600, never leaves the box -- no password on disk), pins the server's host key interactively with the fingerprint shown, and uses `allow_other` + `default_permissions` so ONE machine-authenticated mount serves every member of the entitled group. `test` reports resolve / port / key present / host key pinned / key auth / remote path / mount separately, and names the Windows trap: a normal user's keys go in `C:\Users\<u>\.ssh\authorized_keys`, an **administrator's** in `C:\ProgramData\ssh\administrators_authorized_keys`, so a service account must not be an administrator |
| `it-smb` | `status`, `add`, `test`, `mount\|umount [--all]`, `creds`, `remove`, `log`. Mounts Windows/SMB shares as systemd **automount** units — an unreachable server cannot delay boot, and the share mounts on first access. `test NAME` walks cifs-utils → credentials → DNS → port 445 → a real mount attempt, and translates the cifs status code into a cause. **`test //SERVER/SHARE`** probes a share this box does NOT manage and configures nothing — reachability, whether that share name actually exists (asked of the server with `smbclient -L`, which is the one thing `mount` cannot distinguish from a permission failure), and a read-only mount that is undone. Backslashes are accepted; credentials are prompted, never taken as an argument, and live in a 0600 temp file removed on exit including Ctrl-C |
| `it-offload` | `status`, `setup`, `creds`, `containers on\|off`, `push on\|off`, `test`, `log [N]`, `apply`. Configures the weekly **auditd** offload — what is collected, the remote share, the credentials. Writes to `/opt/it/site.yml` so it survives `ansible-pull`; re-running is idempotent. **It does not collect the PowerStrux reports** — that is `it-powerstrux offload` |
| `it-clamav` | `check`, `list`, `install`, **`scan PATH...`**, `test`, `sync`, `rollback`, `revert`, `image-save`, `image-load`. `scan` proves the engine detects EICAR **before** trusting a verdict and refuses to scan if it does not — a CLEAN from an unverified engine is worse than no scan. Reports unreadable paths as PARTIAL rather than folding them into "0 infected". Records every run in `/var/log/clamav-scan.log` |
| `it-goclassified` | Pre-classification gate. `--report` for machine checks only |
| `it-repo` *(was `it-offline-repo` until 2026-09-01; the old symlink is removed on the next pull)* | `scan` / `load` / `enable` / `disable` / `verify` — run apt off a local repo. `scan` finds repo trees on attached media; `load` (no path needed) mirrors **only this box's release** — all of its pockets including `-security` — incrementally, packages first then indexes. `--prune`, `--dry-run`, `--suite <name>`. **`howto [topic]`** is a package-management cheat sheet — apt, dpkg, single `.deb` files, pip on 24.04, the local repo, what needs a reboot. It prints commands and runs none; `it-repo howto` alone lists every section, `it-repo howto python` one of them |
| `it-users` | Every local account on one screen: state, days until the password expires, last login, groups. `--all` includes system accounts, `--wide` stops truncating groups, `--csv` and `--out FILE` for evidence (the saved copy is written without color). `show <user>` details one account **and what a pull will do to it** |
| `it-users lock/unlock/delete/groups` | The admin half. `lock` sets a password lock **and an account expiry** -- `passwd -l` alone does not stop SSH KEY auth, because the key path never reads the hash. Each command refuses to strand the box (never the last account that can reach root, never the account you are sudo'd from) and says when ansible will undo it: a `local_users` account is **recreated** by the next pull, and its groups are **rewritten** (`append: false`). The lock and the expiry survive a pull; the shell does not |
| `it-adduser` | Create a local account. Asks the type (standard/dta/admin/audit) and derives both the username suffix and the group set from it, then **how to set the password: type one, generate a temporary one, or leave it locked**. `--temp` / `--lock` skip the question for scripted use |
| `it-passwd` | Reset a password, unlock the account, and clear its faillock counter. Asks the same three-way question as `it-adduser`: type one, **generate a temporary one** (`--temp`), or keep the current one. `--list` shows every account's state and expiry; `--unlock-only` skips the password |
| `it-fpga` *(development only)* | The FPGA toolchains: `status` (default — what is installed, license reachability, cables), `license --server <port>@<host> [--xilinx …]` / `--file <License.dat>` / `--none`, `check`, `fixup`, **`install xilinx`** (unattended, from a staged `.bin` + saved config, under `systemd-run` so it survives a dropped session), `install --save-config`, **`desktop`** (import the vendor's own app tiles system-wide — the installers write them into the installing user's home, so Libero SoC / FPExpress / SmartHLS / PFSoC MSS otherwise belong to one account; each gets a wrapper that sets the environment, because the vendor's Exec line does not), `cables`, `env`. The baseline installs the scaffolding, **not** Vivado or Libero — those are baked into the image. A license change writes both `/etc/profile.d/*.sh` and `/opt/it/site.yml` |
| `it-vscode` *(development)* | One copy of the VS Code extension set for the box. `status` (default), `link <user>\|--all`, `unlink`, `copy`, `verify`. Users get **symlinks** into `/opt/vscode-extensions`, so an account costs bytes rather than 3 GB; `/etc/skel` holds the same links so `useradd` stays instant. `verify` asks the editor what it can actually see |
| `my-ide` *(development)* | **What an engineer actually uses**, plus an **IDE (in a browser)** tile in the applications grid that runs it with no arguments. `my-ide` starts their own instance and opens it; `stop`, `status`, `password`, `remote` (the LAN address for a Windows PC), `always`/`never` (start at login). No sudo — it drives the same systemd **user** unit `it-codeserver` manages. Opens `https://localhost:<port>`, which is also what avoids the certificate warning, since the self-signed cert is issued to *localhost* |
| `it-codeserver` *(development)* | **`mine` is the engineer's half, and needs no privilege at all** — the instance is a systemd **user** service, so `it-codeserver mine start|stop|restart|enable|log` is theirs to run, and `it-codeserver mine` prints their URL, password and state. It takes no username, acting on the caller. Nothing starts at boot because a user manager exists only inside a session; `linger <user> on` is the deliberate per-person exception. Admin forms: `status` (default, shows LINGER), `password <user>`, `url`, `start`/`stop`/`restart` (into that user's manager), `linger`, `log`. code-server is single-user per instance, so each engineer runs their own on `dev_code_server_port + (uid - 1000)`. Entitlement is membership of `dev_code_server_group` — applied by the pull, not by enabling the unit |
| `it-rdp` *(development)* | RDP sessions and the stale ones. `status` (default — live sessions, orphans, the reaping settings, and whether a pull deferred a sesman restart), `sweep` (reap ORPHANS only; never touches a live session), `reset <user>` (end that user's sessions — their desktop closes, so it asks), `restart` (restarts xrdp + sesman, refusing while sessions are live). The fault it exists for is an RDP window that closes a second after authentication |
| `it-serial` *(development)* | USB serial adapters the kernel does not recognize. `status` (default — plugged in, bound, and whether a normal user can open the port), `bind`, `add <vid:pid>` (bind now **and** persist to `site.yml`), `ports`. `ftdi_sio` only binds IDs in its compiled-in table, so a Sealevel adapter (`0c52:e402`) enumerates and produces no `/dev/ttyUSB*` at all, with nothing logged — it reads as dead hardware. The ID is added to the driver's table by a boot-time oneshot, because that table lives in the module and is lost on every reboot |
| `it-set-classification` | Set the banner level |
| `it-inventory` | Hardware/serials/listening ports → `/opt/it/inventory-<host>.txt` |
| `pam-auth-check` | Can `common-auth` authenticate at all? Read-only |

### EMI profiles only

| Command | Does |
|---|---|
| `it-vulnscan` | nmap `vuln` scripts + AV scan → `/opt/ia/vulnscans`. Falls back to the containerised nmap when the host one cannot start under FIPS; `image-save`/`image-load` stage that image for an air-gapped box. Records `NMAP-FAULT` / `ENGINE-FAULT` and exits non-zero when a scanner did not actually run. `VULNSCAN_AV_PATHS` overrides what the AV half walks |
| `dta-log` | Record and scan a data transfer → `/opt/dta/logs` |

### AI profile only

| Command | Does |
|---|---|
| `it-ai` | `up`, `down`, `stop`, `restart`, `status`, `logs`, `stacks`, `model`, `run`, `oikb` |
| `it-models` | What model weights are present, and how big |
| `it-docker` | Docker/container health |
| `it-restart` | Restart the Docker layer |
| `it-set-ip` | Renumber a node — rewrites `site.yml`, `/etc/hosts`, every `.env` |
| `it-model-export` | Gather models + images onto a USB (online box) |
| `it-model-import` | Load them on the fielded box |
| `it-stack-diff` | On-box compose files vs the `ansible-pull` clone |
| `it-net link` | A direct node-to-node cable: address only, no gateway, no default route, no DNS, `optional: true`. Its own netplan file so `it-net ip` cannot delete it, and it refuses the default-route interface. `link status` shows the unaddressed NICs to choose from |
| `it-set-ip scan` / `fix` | Literal addresses typed **into** a compose file — the one thing a renumber cannot reach. `fix` suggests the `.env` variable already carrying that address, so the value stays current afterwards, backs up each file, and says the two things that catch people out: the running container is unchanged until `docker compose up -d`, and the next pull overwrites the file |
| `it-docker audit` | **Running containers vs the compose files on disk.** A reboot does NOT apply a compose edit — the daemon restarts the stored container and never reads `compose.yaml` — so the two routinely disagree and only `docker compose up -d` closes the gap. Reports both sides of the GPU budget, restart policies, Open WebUI's live endpoints, host-port collisions between stacks, anonymous volumes, project/directory mismatches, literal addresses `it-set-ip` cannot reach, and secrets referenced without a `${VAR:?}` guard |

---

## Paths

| Path | What |
|---|---|
| `/opt/ia/` | IA area, `root:sudo 2770`. Admins enter without `sudo` |
| `/opt/ia/usg/` | `usg audit` reports (HTML + XCCDF) — the compliance score |
| `/opt/ia/oscap/build,scheduled,manual/` | OpenSCAP artifacts, one directory per writer so retention never prunes another's evidence |
| `/opt/ia/stig/content,checklists,evidence/` | DISA's manual STIG XCCDF (shipped by `scap_scan`, no longer staged by hand), generated checklists, archived bundles |
| `/opt/ia/goclassified/` | Pre-classification records |
| `/opt/ia/vulnscans/` | `it-vulnscan` reports (EMI) |
| `/opt/ia/audit-offload/` | Weekly staged audit logs (`it-offload`) |
| `/opt/ia/powerstrux-offload/<YYYY>-W<nn>/` | The week's PowerStrux folder: report, run logs, config, `MANIFEST.txt`. Always kept locally even after a successful push. `root:audit 0750`, newest 26 weeks |
| `/opt/_AuditFiles/` | PowerStrux reports and `logs/`. `root:audit 2770` — reading needs the `audit` group. Also holds `run-powerstrux.sh` and `powerstrux-offload.sh` |
| `/opt/it/` | IT admin area, same ownership |
| `/opt/it/scripts/` | The `it-*` scripts |
| `/opt/it/site.yml` | **Per-node overrides. Beats `group_vars`.** Never in git |
| `/opt/it/clamavsigs/` | Drop ClamAV signature archives here |
| `/opt/it/apt-sources-backup/` | Online apt sources parked by `it-repo enable` |
| `/opt/dta/incoming,outgoing,logs/` | Data-transfer staging and records (EMI) |
| `/tools/Xilinx`, `/opt/microchip` | FPGA toolchains (development). **Not managed by Ansible** — baked into the image or installed by hand. Root-owned, NOT under a home directory: `$HOME` is the vendors' single-machine advice and means one 30+ GB copy per engineer |
| `/etc/profile.d/{xilinx,microchip}.sh` | The FPGA environment every user gets at login. `vivado_env` / `libero_env` load the heavy `PATH` per shell |
| `/usr/local/bin/{vivado,vitis,libero}` | Launchers. Source the vendor settings for that one process, not for every login shell. Written only when the toolchain is actually installed |
| `/usr/share/applications/fpga-*.desktop` | App-grid tiles for every user. The vendors' installers do not make usable ones — a `--batch Install` under sudo puts them in `/root/Desktop` |
| `/etc/stig-build/fpga/License.dat` | Node-locked FPGA license, `0600 root:root`. Absent when a license server is used, which is the fleet default |
| `/opt/vscode-extensions/` | The box's single copy of the VS Code extension set. Users hold symlinks into it; `/etc/skel` holds the same. root:root 0755 |
| `/etc/code-server/<user>.password` | Per-user code-server password, `0600 root:root`. Generated once, stable across pulls |
| `/opt/stacks/<stack>/` | AI compose stacks — Dockge watches this dir |
| `/srv/repo/` | The carried offline apt repo. `root:root 0755` |
| `/etc/stig-build/` | Root-only. Generated `*.pw`, the GRUB hash, `profile` — which records the deployment profile and the **baseline revision** this box last pulled — and the offload configs/credentials |
| `/etc/stig-build/powerstrux-offload.conf` | What `it-powerstrux offload` reads. Rendered from `site.yml` by the pull; the commands write both |
| `/etc/stig-build/powerstrux-offload.cred` | The share service account, `0600 root:root`. Never in git, never in `site.yml` |
| `/etc/luks/initial-passphrase` | Read once to bind the TPM, then deleted |
| `/var/lib/clamav-container/` | The containerised scanner's own signature database |

`/etc/stig-build/site.yml` still works as a legacy location for per-node overrides.

---

## Configuration

Everything is in [`group_vars/all.yml`](../group_vars/all.yml), with comments. Per-node overrides go in `/opt/it/site.yml` — see [`site.yml.example`](site.yml.example).

The ones worth knowing:

| Variable | Default | Effect |
|---|---|---|
| `deployment_profile` | `development` | Which build |
| `emi_classified` | true unless `emi-unclass` | FIPS + LUKS/TPM + full `usg fix` |
| `editor_choice` | `vscode` | `vscode` \| `vim` \| `neovim`. The only setting that removes an internet dependency |
| `dev_tools_user` | `austin_case_adm` | **Must match the account you created in the installer** |
| `usg_fix_enabled` | true | The disruptive `usg fix disa_stig` |
| `usg_enable_fips` | true | FIPS kernel via Pro. Needs a reboot |
| `usg_fix_pam_stack` | **false** | Regenerates `common-auth`. Off by choice — see [compliance.md](compliance.md) |
| `usg_chrony_servers` | `ntp.ubuntu.com` | Set to your enclave's time server; an air-gapped box cannot reach a public pool |
| `usg_faillock_unlock_time` | 900 | Seconds. `0` = admin reset only |
| `usg_fix_log_permissions` | true | `/var/log` file modes (UBTU-24-700010). Swept at build time and daily by `stig-log-perms.timer` |
| `usg_fix_library_group` | true | `chgrp root` on `*.so*` under the library dirs (UBTU-24-300009) |
| `audit_cron_rules_enabled` | true | `72-cron.rules` — watch `/etc/cron.d` and the cron spool, key `cronjobs` (UBTU-24-200270) |
| `audit_reboot_rules_syscalls` | `reboot`, `kexec_load` | Names are resolved per-arch before the rule is written — i386 says `sys_kexec_load`, x86_64 says `kexec_load`, and a wrong name aborts the **whole** rule load |
| `usg_sudo_logfile_enabled` | true | Create `/var/log/sudo.log` + `Defaults logfile` so UBTU-24-500010's watch can load |
| `ia_retention_keep` | 3 | How many of each pull-created evidence file to keep (scan sets, `.cklb`, USG reports). Per file **kind**, so a scan set stays whole. `1` keeps only the newest |
| `ia_retention_targets` | see `group_vars` | Which directories and globs the prune covers. Scheduled/ad-hoc oscap dirs are excluded — they self-prune via `scap_schedule_keep` |
| `usg_disable_smartcard_rules` | 3 rules | De-selected in the USG tailoring. Rules **absent from USG's own bundled content** get an explicit `<select selected="false">` added, so a scan against the newer `ssg_content_version` de-scopes them too |
| `grub_password_pbkdf2` | `CHANGEME` | The role skips until a real hash is vaulted |
| `tpm_luks_enabled` | true except `emi-unclass` | Binds LUKS to PCR 7 |
| `offline_repo_enabled` | false | Switch apt to `/srv/repo`. Set by `it-repo enable` |
| `offline_repo_dta_load_enabled` | true | Sudo grant letting the `dta` group run `it-repo scan/status/load` (four exact argv forms, no wildcard, not NOPASSWD). On EMI the admin cannot mount removable media and the DTA cannot write `/srv/repo`, so without it the tree has to be copied to local disk first. Written by `local_accounts`, removed when the toggle or `local_usb_transfer_enabled` is false |
| `base_packages_full_upgrade` | false | `apt full-upgrade` early in the build |
| `scap_stig_manual_xccdf` | `U_CAN_…_V1R6_Manual-xccdf.xml` | DISA's manual STIG, shipped in `roles/scap_scan/files/`. Update on a new STIG release |
| `usg_audit_on_pull` | `build` | When `usg audit` runs during a pull. `build` = only on a box with no report yet; `always` = every pull (pre-2026-08 behavior, what `it-pull full` passes); `never` = timer only. The `usg_harden`-stage audit is now skipped whenever `usg_remediate` will re-audit — one evaluation, not two |
| `scap_scan_on_pull` | `build` | Same for `oscap xccdf eval`. A routine pull runs **no** benchmark evaluation; evidence comes from the first build, the weekly `oscap-scan.timer`, and `it-stig run` |
| `scap_ckl_on_pull` | true | Build the `.cklb` from the scan that just ran. Now also requires that a scan actually ran this pull — without one it would rewrite an identical checklist every time |
| `local_accounts_enabled` | true | Org users/groups/ACL'd folders |
| `powerstrux_offload_enabled` | true | Build a week folder after each scheduled audit. With the share off it stages locally only — which is what an air-gapped box carries out on media |
| `powerstrux_offload_window_days` | 8 | How far back "this week" reaches. 8 not 7, so a run the `Persistent=true` timer caught up late is still collected |
| `powerstrux_offload_keep` | 26 | Week folders held locally before pruning (~6 months) |
| `powerstrux_offload_smb_enabled` | false | Copy each week folder to a Windows share |
| `powerstrux_offload_smb_share` / `_subdir` | — / hostname | `//fileserver/audit$` and the per-box folder under it |
| `powerstrux_offload_smb_auth` | `domain` | `domain` \| `workgroup` \| `guest`. Decides what `mount.cifs` gets in `domain=` — an AD domain, or the **file server's own name** for a local account |
| `powerstrux_offload_smb_options` | `vers=3.1.1,sec=ntlmssp,…` | An older NAS or Server 2008 R2 needs `vers=2.1`; `it-powerstrux offload test` says so when the mount fails |
| `powerstrux_offload_include_audit` / `_containers` / `_extra` | false / false / `[]` | Also put the auditd archive, `docker logs`, or named paths/globs in the week folder. A directory in `_extra` is copied whole |
| `powerstrux_offload_oncalendar` | `""` | Empty = chained to the audit run, which is what you want. Set a calendar spec only to give the offload a schedule of its own as well |
| `fpga_tools_enabled` | development only | The FPGA scaffolding. i386 multiarch is an approved deviation on the engineering workstations and has no business on EMI or an AI node |
| `fpga_license_mode` | `none` | `server` \| `local` \| `none`. `server` is the fleet answer: no local daemon, no per-box `License.dat`, no MAC registration |
| `fpga_license_microchip` / `_xilinx` | — | `<port>@<host>`, comma-separated for a redundant triad. Set here for a fleet default, or per box with `it-fpga license` |
| `fpga_tools_access_group` | `sentry` | Who may use the installed toolchains. root owns them, this group reads and executes, nobody else reads them. Every standing account is in `sentry`, so every engineer gets full use |
| `fpga_tools_enforce_access` | true | The pull corrects the group and modes when they are wrong. One stat per tree when correct; recursive only when not |
| `fpga_device_group` | `plugdev` | Who may talk to the JTAG programmers. `dialout` covers USB-serial consoles; both are in `local_users_common_groups` |
| `fpga_ncurses5_shim` | true | Symlink `libtinfo.so.5`/`libncurses.so.5` onto the ncurses 6 sonames. Vivado hangs at *"Generating installed device list"* without it |
| `desktop_initial_setup` | false | GNOME's first-login "Welcome!" wizard. Suppressed: the image already sets locale and keyboard, `it-adduser` provisions the account, and a closed-space box has no online accounts to add. Its broken-looking icon is the wizard itself — it ships none the theme resolves |
| `dev_code_server_group` | `sentry` | Who gets a code-server instance. Every standing account joins `sentry`, so a new engineer gets one on the next pull. Empty = the primary user only |
| `dev_code_server_exclude` | `[]` | Accounts in that group that should not get one. Locked accounts are skipped already (by shell); this is for `dta`/`audit`, which are in `sentry` too |
| `dev_code_server_port` / `_uid_base` / `_port_span` | 8080 / 1000 / 20 | `port = base + (uid - uid_base)`. Derived from the UID so it is stable per person; a UID outside the span is skipped rather than colliding. The span is what ufw opens |
| `dev_code_server_bind_addr` | `0.0.0.0` | **N IDEs on the LAN, one per engineer.** `127.0.0.1` takes them off it (RDP browser or SSH tunnel) and the pull removes the ufw rule |
| `vscode_shared_extensions_dir` | `/opt/vscode-extensions` | One copy of the extension set for the whole box |
| `dev_tools_vscode_skel_seed` | false | The old behavior: a real 3 GB copy in `/etc/skel`, so every `useradd` copies it. Superseded by the symlink store |
| `ai_model_fetch` | — | Fetch model weights during the build |
| `ai_compose_deploy` | — | Bring the stacks up during the build |

---

## AI stack

### The two nodes

| Node | Hostname | Job |
|---|---|---|
| System 1 | `dev-ai1` | Front end + chat model — Open WebUI, vLLM, pgvector, PgBouncer, Redis |
| System 2 | `dev-ai2` | Helpers — embedding/vision vLLM, Docling, Tika, Grafana, Prometheus, MLflow, oikb |

The hostname picks the role.

### Open in a browser

| What | URL |
|---|---|
| Chat (Open WebUI) | `http://dev-ai1:3000` |
| Grafana | `http://dev-ai2:3001` — first login `admin`/`admin` |
| MLflow | `http://dev-ai2:5000` |
| Doc wiki | `http://dev-ai2:4321` |
| Dockge / Cockpit | `:9001` / `:9090` on each box |

### Stacks

One Dockge stack per service, each with its own `compose.yaml` and root-only `.env`. All share the external `oi` network and external named volumes.

**System 1**

| Stack | Port | Profile | Job |
|---|---|---|---|
| `vllm-gptoss` | `:8000` | default | Chat model (gpt-oss-120B) |
| `vllm-granite` | `:8001` | `granite` | Alternate chat model |
| `pgvector` | internal | default | Accounts, chats, settings + vector index |
| `pgbouncer` | internal | default | Connection pooler — every DB URL points here |
| `redis` | internal | default | Websocket coordination + cache |
| `open-webui` | `:3000` | default | The chat website |

**System 2**

| Stack | Port | Profile | Job |
|---|---|---|---|
| `vllm-embed` | `:8002` | default | RAG embeddings |
| `vllm-vision` | `:8003` | default | Vision / image understanding |
| `docling` | `:5001` | default | Document structure + OCR |
| `tika` | `:9998` | default | Text extraction, other file types |
| `grafana-otel` | `:3001` `:4317` `:4318` | default | Grafana + OTel |
| `prometheus` | `:9091` | default | Scrapes the vLLM/docling `/metrics` |
| `mlflow` | `:5000` | default | Experiment tracking, nginx-fronted, 5 replicas |
| `openwiki-view` | `:4321` | default | Browse the generated doc wiki |
| `oikb` | `:8081` | `oikb` | Knowledge-base sync → System 1 |
| `hfcli` | — | `tools` | Download models into volumes |
| `openwiki` | — | `tools` | Generate a doc wiki from a repo |

Stack name ≠ container name for `docker logs`: `vllm-gptoss` → `vllm-server`, `docling` → `docling-serve`, `grafana-otel` → `open-webui-lgtm`, `mlflow` → `mlflow` + `mlflow-db` + `mlflow-proxy`, `openwiki-view` → `openwiki-view` + `openwiki-view-proxy`.

**Postgres is reached through PgBouncer.** Open WebUI runs 9 uvicorn workers, each with its own pool, which exhausted Postgres' connection slots — so `DATABASE_URL` and `VECTOR_DB_URL` point at `pg-bouncer:5432`. The pooler runs in **transaction** mode, so session state does not persist between statements: anything needing it (session-level `SET`, advisory locks, `LISTEN`/`NOTIFY`) must talk to `pgvector:5432` directly. Neither publishes a port — the `oi` network is the only way in, deliberately, since ufw cannot filter a published container port (trap 1).

**Break-glass.** The pre-split single-file compose stays at `/opt/docker/docker-compose.consolidated.yaml` (was `/opt/it/docker/...` before 2026-09-22), not deployed and deliberately not named `docker-compose.yaml`. Same volumes, so `docker compose -f ... up -d` brings the node up as one project with no data move.

### How the nodes talk

Containers cannot resolve the peer's hostname, so cross-node addressing comes from `site.yml` IPs rendered into each `.env`.

- **System 1 → System 2** (`ai_system2_addr`): embeddings `:8002`, vision `:8003`, Docling `:5001`, OTel `:4317`
- **System 2 → System 1** (`ai_system1_addr`): oikb calls Open WebUI's API on `:3000`. Opt-in — no API key, no oikb

### Volumes

**System 1**

| Volume | Contents | Mount |
|---|---|---|
| `vllm` | gpt-oss-120b weights (~61 GB) | `/gpt120b` |
| `granite32b` | granite-4.1-30b weights | `/granite30b` |
| `encodings` | tiktoken vocab for gpt-oss | `/etc/encodings` |
| `pgvector-data` | Postgres + vector store | `/var/lib/postgresql/data` |
| `open-webui` | Users, chats, uploads | `/app/backend/data` |
| `redis-data` | Redis persistence | `/data` |

**System 2**

| Volume | Contents | Mount |
|---|---|---|
| `granite-embed` | granite-embedding-small-english-r2 | `/granite-embed` |
| `granite-vision` | granite-vision-4.1-4b | `/granite-vision` |
| `lgtm-data` | Grafana dashboards + TSDB | `/data` |
| `prometheus-data` | Scraped metrics | `/prometheus` |
| `mlflow-artifacts` | MLflow artifact store | `/mlflow/artifacts` |
| `postgres_mlflow_data` | MLflow's Postgres | `/var/lib/postgresql/data` |
| `openwiki-out` | Generated wiki markdown | `/work` |

**Docling has no volume** — its models ship baked into the image (trap 8).

```bash
sudo docker volume inspect vllm                  # find its Mountpoint
sudo du -sh /var/lib/docker/volumes/vllm/_data   # size on disk
```

### Model API names

What to send as `model` to the OpenAI-compatible endpoints. This is vLLM's `--served-model-name`, **not** the Hugging Face repo path.

| Model | Node | Port | API name |
|---|---|---|---|
| gpt-oss-120b | S1 | `:8000` | `gpt-oss-120b` |
| granite-4.1-30b | S1 | `:8001` | `granite-4.1-30b` |
| granite-embedding-small-english-r2 | S2 | `:8002` | `granite-embedding-small-english-r2` |
| granite-vision-4.1-4b | S2 | `:8003` | `granite-vision-4.1-4b` |

System 1's two chat models are **alternates** — both are served tensor-parallel across its two 48 GB GPUs and only one fits.

---

## AI nodes — as-built, 2026-08-28

**This records what the boxes ACTUALLY run, faults included.** It is not a target state and not a repo description — where the live config differs from `roles/ai_compose/files/stacks/`, the live config is what is written here, because that is what an assessor will find and what an engineer will be debugging. The repo remains the intended state; the drift table below is the delta.

Captured read-only from both nodes. Nothing was changed. Reproduce with `sudo it-stack-diff --full` plus the runtime capture in [procedures.md §4](procedures.md).

### Nodes

| | System 1 | System 2 |
|---|---|---|
| Host | `dev-ai1` | `dev-ai2` |
| Address | 192.168.1.104 | 192.168.1.110 |
| Kernel | 6.8.0-136-fips | 6.8.0-136-fips |
| FIPS | enabled (`fips_enabled=1`) | enabled |
| GPU | **2 ×** RTX 6000 Ada, 48 GB, driver 595.84 | **1 ×** RTX 6000 Ada, 48 GB, driver 595.84 |
| Docker | 29.6.2, Compose v5.3.1 | 29.6.2, Compose v5.3.1 |
| Baseline at capture | `06d49fc` | `6b458b1` |
| Pending apt updates | 51 | 47 |

Both baselines are behind `main`, and they differ from each other — the two nodes are not on the same commit.

### System 1 — running containers

| Container | Image | Published | Restart | Mem limit | GPU |
|---|---|---|---|---|---|
| `open-webui` | `ghcr.io/open-webui/open-webui:v0.10.2` | `3000→8080`, **`8050→8050`** | unless-stopped | — | — |
| `vllm-server` | `vllm/vllm-openai:v0.22.1-cu129-ubuntu2404` | `8000` | unless-stopped | — | both |
| `pgvector` | `pgvector/pgvector:pg16-trixie` | — | unless-stopped | **2 G** | — |
| `pg-bouncer` | `edoburu/pgbouncer:v1.25.1-p0` | **`5432→5432`** | unless-stopped | — | — |
| `redis` | `redis:7.2.14-bookworm` | — | unless-stopped | — | — |
| `dockge` | `louislam/dockge:1` | `9001→5001` | always | — | — |
| `clamav-container` | `clamav/clamav:1.4.3` | — | **no** | 3 G | — |

`vllm-granite` is defined but not running — it sits behind the `granite` profile and only one chat model fits VRAM. Correct behavior.

### System 2 — running containers

| Container | Image | Published | Restart | GPU |
|---|---|---|---|---|
| `vllm-embed` | `vllm/vllm-openai:v0.22.1-…` | `8002` | unless-stopped | yes |
| `docling-serve` | `ghcr.io/docling-project/docling-serve-cu128:v1.24.0` | `5001` | **no** | yes |
| `tika` | `apache/tika:3.3.1.0` | `9998` | unless-stopped | — |
| `open-webui-lgtm` | `grafana/otel-lgtm:0.29.0` | `3001→3000`, `4317`, `4318` | unless-stopped | — |
| `prometheus-standalone` | `prom/prometheus:v3.14.0` | `9091→9090` | unless-stopped | — |
| `mlflow-db` | `pgvector/pgvector:pg16-trixie` | — | unless-stopped | — |
| `mlflow-mlflow-1…5` | `mlflow:v3.15.1-psycopg2` | — | unless-stopped | — |
| `mlflow-proxy` | `nginx:1.30.4-alpine` | `5000` | unless-stopped | — |
| `pg-bouncer` | `edoburu/pgbouncer:v1.25.1-p0` | **`5432→5432`** | unless-stopped | — |
| `openwiki-view` | `openwiki:latest` | `4321→8080` | unless-stopped | — |
| `openwiki-view-proxy` | `openwiki-view:latest` | (shares netns) | unless-stopped | — |
| `dockge` | `louislam/dockge:1` | `9001→5001` | always | — |
| `clamav-container` | `clamav/clamav:1.4.3` | — | **no** | — |

**Not running:**

| Container | State | Consequence |
|---|---|---|
| `vllm-vision` | Exited (0), 2 weeks | **Open WebUI on System 1 still lists `http://192.168.1.110:8003/v1` as a chat endpoint.** The vision model is a dead endpoint from the UI's point of view. |
| `oikb` | Exited (1), 2 weeks | Its `profiles: ["oikb"]` guard was commented out on the box, so it starts by default and crash-loops. In the repo the profile keeps it off. |

### Drift from the repo

Every item below is the **box** differing from `roles/ai_compose/files/stacks/`. A pull with `ai_compose` un-skipped would revert all of it.

**System 1**

| Stack | Repo | On the box | Why it matters |
|---|---|---|---|
| `pgbouncer` | no `ports:` at all | `5432:5432` | Postgres reachable from the LAN. A published container port **cannot** be filtered by ufw (trap 1), so this is genuinely open. |
| `open-webui` | `3000:8080` only | also `8050:8050` | Undocumented second listener. |
| `pgvector` | `limits: memory 4G` | `2G` | Halved. Under RAG load this is where an OOM would come from. |
| `vllm-gptoss` | `${SYSTEM2_ADDR}` | hardcoded `192.168.1.110` | `it-set-ip` cannot renumber the box. |
| `vllm-gptoss` | `--override-generation-config={"temperature":1.0,"top_p":1.0,"repetition_penalty":1.1}` | dropped | Sampling defaults differ from the accredited config. |

**System 2**

| Stack | Repo | On the box | Why it matters |
|---|---|---|---|
| `mlflow` (`pg-bouncer`) | no `ports:` | `5432:5432` | Same LAN exposure as System 1, second instance. |
| `docling` | `restart: unless-stopped` | commented out | **Docling does not come back after a reboot.** Runtime confirms `restart=no`. |
| `oikb` | `profiles: ["oikb"]` | commented out | Starts unguarded, crash-loops. |
| `vllm-vision` | no `logging:` block | `logging:` **misindented under `deploy:`** | Not a valid service key there, so the container has **no log rotation**. |
| `prometheus` | `container_name: prometheus`, named volume `prometheus-data`, `./prometheus.yml` | `prometheus-standalone`, **anonymous** volume, `/opt/it/docker/grafana/prometheus.yml` | TSDB is in an unnamed volume nothing tracks — **still open**. Config path **closed 2026-09-22**: the repo's mount is now `./prometheus.yml` and the asset root moved to `/opt/docker`. |

**Both nodes**

| Item | State |
|---|---|
| `/opt/stacks/ai` | symlink → `/opt/it/docker`; holds `docker-compose.consolidated.yaml`, `docker-compose.yaml.bac`, `.env`, `fips_off` — the pre-split layout. **Both it and the target are retired** as of 2026-09-22; the asset root is `/opt/docker` and the symlink is removed by hand in [procedures.md §5.9](procedures.md#59-moving-the-docker-asset-root-one-time-off-optitdocker) |
| `/opt/stacks/ai-system1` / `ai-system2` | empty directories, no compose file |
| `DOCKER-USER` chain | `-N DOCKER-USER` — **empty**, confirming trap 1 fleet-wide |

### Network exposure, as measured

Published container ports bypass ufw entirely (trap 1). What is actually reachable on the LAN:

| Node | Port | Service |
|---|---|---|
| S1 | 3000 | Open WebUI |
| S1 | 8000 | vLLM gpt-oss-120b (no auth) |
| S1 | 8050 | Open WebUI, second listener (undocumented) |
| S1 | **5432** | **PgBouncer → Postgres** |
| S1/S2 | 9001 | Dockge |
| S2 | 3001 / 4317 / 4318 | Grafana / OTLP |
| S2 | 5000 | MLflow (behind its nginx allow-list) |
| S2 | 5001 | Docling |
| S2 | 8002 | vLLM embeddings |
| S2 | 9091 | Prometheus |
| S2 | 9998 | Tika |
| S2 | **5432** | **PgBouncer → MLflow Postgres** |
| S2 | 4321 | OpenWiki viewer |

**The ufw allow-list for 8002 names the wrong host.** Both nodes carry `8002/tcp ALLOW IN 192.168.1.102`, but System 1 is **192.168.1.104**. Embeddings work today only because the published port bypasses ufw. The day `DOCKER-USER` rules are added — the planned fix for trap 1 — RAG embeddings break unless this is corrected first.

### Volumes

System 1: `open-webui`, `pgvector-data`, `redis-data`, `vllm`, `encodings`, `granite32b`, `dockge_data`. Unused leftovers: `docling-models`, `granite-embed`, `portainer_data`.

System 2: `granite-embed`, `granite-vision`, `lgtm-data`, `mlflow-artifacts`, `postgres_mlflow_data`, `openwiki-out`, `docling-models`, `dockge_data`, `pg-bouncer`, plus **seven anonymous hash-named volumes** (one is Prometheus' TSDB) and `portainer_data` from a container that no longer exists.

`docling-models` exists on both nodes and is mounted by nothing — correct, per trap 8: Docling's models are baked into the image and mounting over the cache hides them.

---

## Software inventory

IA / DCSA inventory. Versions are pinned in `group_vars/all.yml`, the compose files, and the image Dockerfiles.

### Every profile

| Software | Version | Publisher | Purpose |
|---|---|---|---|
| Ubuntu | 24.04 LTS | Canonical | Host OS |
| Ubuntu Security Guide (`usg`) | via Pro | Canonical | DISA STIG remediation + audit |
| OpenSCAP + SSG content | distro / pinned | OpenSCAP, ComplianceAsCode | Compliance scanning |
| ClamAV | distro | Cisco Talos | Anti-virus |
| USBGuard | distro | USBGuard project | USB device allow-listing |
| chrony | distro | chrony project | Time sync |
| AIDE | distro | AIDE project | File integrity |
| Cockpit | distro | Red Hat | Web management console |
| PowerShell | 7.4.16 LTS | Microsoft | `pwsh`; required by PowerStrux auditing |
| cifs-utils, smbclient, net-tools, unzip, cron | distro | — | Common tooling |
| clevis + tpm2-tools | distro | Latchset / tpm2-software | TPM-bound LUKS unlock |

### `development` and `emi` additionally

| Software | Version | Publisher | Purpose |
|---|---|---|---|
| GCC / build-essential, CMake, gdb | distro | GNU, Kitware | C/C++ toolchain |
| Python 3.12 + `/opt/eng-venv` | distro | PSF | Shared engineering venv (~140 libs) |
| Node.js | 22.x LTS | NodeSource | JS runtime |
| VS Code | latest | Microsoft | Editor (`editor_choice`) |
| code-server | opt-in | Coder | VS Code in the browser (`development` only) |
| Wireshark / tshark | distro | Wireshark Foundation | Packet capture, gated to `wireshark_users` |
| PuTTY | distro | PuTTY project | Serial / SSH client |
| Docker (docker.io) | distro | Docker Inc. | Containers |
| xrdp + xorgxrdp | distro | xrdp project | RDP (`development` only) |
| nmap | distro | Nmap project | Vulnerability scanning (`emi` only) |
| OpenVPN, tftpd-hpa, isc-dhcp-server, dnsmasq | distro | — | Imaging services (`emi`), installed **disabled** |

### `ai` additionally

| Software | Version | Publisher | Purpose |
|---|---|---|---|
| NVIDIA GPU driver | ≥ 595.71.05 | NVIDIA | GPU driver |
| NVIDIA Container Toolkit | ≥ 1.19.1 | NVIDIA | GPU access in containers |
| docker-ce / -cli / containerd.io | 29.6.1 / 2.2.6 | Docker Inc., CNCF | Container engine |
| docker-buildx / compose / model / sbx plugins | 0.35.0 / 5.3.1 / 1.2.6 / 0.35.0 | Docker Inc. | Build, Compose v2, model runner, sandbox |
| Dockge | pinned | Dockge project | Compose stack UI |

**Container images (pulled)**

| Image | Version | Publisher | Purpose |
|---|---|---|---|
| vllm/vllm-openai | v0.22.1-cu129-ubuntu2404 | vLLM project | LLM inference (S1, S2) |
| open-webui | v0.10.2 | Open WebUI | Chat UI (S1) |
| pgvector/pgvector | pg16-trixie | pgvector | DB + vector store (S1) |
| redis | 7.2.14-bookworm | Redis | Coordination + cache (S1) |
| edoburu/pgbouncer | v1.25.1-p0 | edoburu | Postgres pooler (S1, S2) |
| apache/tika | 3.3.1.0 | Apache | Text/metadata extraction (S2) |
| docling-serve | v1.24.0 (cu128) | IBM / Docling | Structure + OCR (S2) |
| grafana/otel-lgtm | 0.29.0 | Grafana Labs | Monitoring (S2) |
| nginx | 1.30.4-alpine | nginx / F5 | Wiki viewer front-end (S2) |
| prom/prometheus | v3.14.0 | Prometheus | Metrics scraper (S2) |

**Container images (built on the box)**

| Image | Version | Publisher | Purpose |
|---|---|---|---|
| mlflow | v3.15.1 (+psycopg2) | MLflow / LF AI & Data | Experiment tracking (S2) |
| openwiki | 0.3.3 (Node 22.23.1) | openwiki project | Generate a doc wiki (S2) |
| openwiki-view | latest (nginx 1.30.4) | this repo | LAN front-end, vendors its JS so it renders offline (S2) |
| oikb | latest (base oikb 0.3.6) | Open WebUI | Sync data sources into KBs (S2) |
| hfcli | latest (Python 3.12) | Hugging Face | Download models into volumes (S2) |
| repomix | latest (Node 22.23.1) | repomix project | Pack a repo into one file (S2) |

> `oikb`, `hfcli` and `repomix` are **not pinned** (`git clone` with no ref, `pip --upgrade`, `npm latest`). `openwiki` is pinned via `ARG OPENWIKI_VERSION` and is the pattern the others should follow. Open item.

**AI models** (Hugging Face, all Apache-2.0, tracking repo `main` with no revision pin — open item)

| Model | Publisher | Purpose |
|---|---|---|
| gpt-oss-120b | OpenAI | Primary text generation (S1) |
| granite-4.1-30b | IBM | Secondary text generation, switchable (S1) |
| granite-embedding-small-english-r2 | IBM | Embeddings / RAG (S2) |
| granite-vision-4.1-4b | IBM | Vision / document understanding (S2) |

Plus `o200k_base.tiktoken` and `cl100k_base.tiktoken` (OpenAI) — vocab for the gpt-oss harmony tokenizer.

> **granite-docling-258M is not deployed.** Adding it needs a custom docling image with the weights baked in — see trap 8.

External sources read by oikb (GitLab, Confluence, S3, per `site.yml`) are org services, not installed software.
