# Security measures

**Default-DENY outbound network via a separate firewall container.** The dev container (`development`) is on a Docker `internal: true` network with **no route to the internet**. The only egress path is a Squid proxy running in a sibling `firewall` container that enforces a domain allowlist, split into an always-on baseline plus toggleable [feature-sets](allowlist.md#configuring-the-allowlist-feature-sets) (see [.devcontainer/firewall/features/](../.devcontainer/firewall/features)). Denied requests return a readable `403` whose body is a **firewall-aware plain-text page** explaining that the host is off the allowlist and how to add it — so AI tools (including ones with no project-prompt hook, like the Copilot CLI) surface actionable guidance instead of retrying a "connection failed". `CLAUDE.md` and `AGENTS.md` carry the same network-topology note for Claude Code and opencode. Tools that ignore `HTTP(S)_PROXY` fail closed (no route out), they don't bypass the firewall.

**Out-of-band management plane (QoL).** A third `control` container hosts the `allow`/`deny` commands, the policy volume, and the web dashboard. It sits on a separate network (`egress` only, never `internal`) and is therefore unreachable from `development`. The hard isolation is the network topology — `development` has no route to `control` regardless of what `control` runs. `control` is a convenience layer: the security would hold even if it were removed and the policy volume were edited directly. An agent inside `development` cannot modify its own allowlist.

**Domain-based filtering.** The allowlist is hostnames, not snapshotted IPs — resilient to CDN/Azure IP rotation. No periodic re-resolution needed.

**Azure browser callback ingress (localhost-only).** To support `az login` browser flow in-container, localhost ports `8400-8999` are published from host to `development`. The firewall only filters egress, so inbound publishes don't bypass it. Limited to `127.0.0.1` on the host.

**Non-root user, no sudo.** Container runs as `devuser` (UID 1000) with no sudo privileges whatsoever.

**Resource limits.** CPU (4 cores), memory (8 GB), PID (512) caps prevent a runaway agent from affecting the host.

**Read-only git identity.** `~/.gitconfig` is bind-mounted read-only — the agent cannot rewrite git hooks or other config.

**SSH key isolation (optional).** SSH agent forwarding is supported but disabled by default. When enabled, keys stay on the host and the container can only sign operations, never read key material. See the [caveats](operations.md#caveats) section for platform-specific setup.

**No Docker socket.** `/var/run/docker.sock` is not mounted. Mounting it is a one-line host root escalation.

**VS Code extensions are a trust boundary — vet them.** An extension is code that runs automatically, and the two execution locations have very different blast radii:
- **Workspace extensions** run *inside* this container as `devuser`, so they are subject to the firewall (they cannot reach a non-allowlisted host). But they auto-execute on attach and can read anything `devuser` can — `ANTHROPIC_API_KEY`, `~/.claude/settings.json`, your workspace — and a malicious one could tunnel that data out over an **allowlisted** domain (the marketplace, a CDN, or `github.com` if that feature-set is on). The firewall narrows the exfil channel; it does not close it.
- **UI / host extensions** run on the **host**, entirely outside this container and its firewall. A malicious host extension is a host compromise and is **not** contained by anything here.

Mitigations: pin a reviewed set in `devcontainer.json` (`customizations.vscode.extensions` — host-controlled and read-only in the container, so an in-container agent can't add to it); keep the allowlist minimal (disable [feature-sets](allowlist.md#configuring-the-allowlist-feature-sets) you don't use, to shrink the exfil surface); and treat `~/.vscode-server/extensions` as throwaway — it's on the writable layer, so a rebuild clears any extension dropped at runtime. The `/security-test` skill (Test 12) probes the in-container portion of this surface; host extensions remain your responsibility to vet.

**Project-scoped volumes.** All persistent state (Claude config, caches, history) lives in named Docker volumes prefixed with the project directory name. Separate projects = separate volumes.

## Validating the perimeter

The bundled **`security-test`** skill turns the measures above into a repeatable, adversarial check. Run it from any of the three agents inside the container — `/security-test` in Claude Code, or "run the pentest" in opencode / the Copilot CLI — and it works through a fixed set of escape, exfiltration, and tamper probes (direct egress bypass, host-filesystem reads, Docker-host and control-container reachability, perimeter-config and allowlist/policy tamper, privilege/namespace escape, credential exfiltration via a harmless canary, persistent installs, mail sending, IPv6 bypass, and the VS Code extension surface).

Verdict semantics are inverted on purpose: a **blocked** attempt is a pass (the perimeter **HELD**); an attempt that **gets through** is a **BYPASS** finding. The skill prints a per-test table, an overall PASS/FAIL, and a list of host follow-ups it can't perform itself (e.g. confirming a runtime install is gone after a rebuild). Approve the probe commands when the agent asks, and watch the [block feed](allowlist.md#see-blocks-from-inside-the-dev-container) (`curl -s http://firewall:8099`) or the [dashboard](allowlist.md#web-dashboard-localhost-only) while it runs. Re-run it after any change to the container's security configuration.
