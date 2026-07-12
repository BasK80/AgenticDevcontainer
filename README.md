# Agentic Dev Container

> **Personal project — public, but not a maintained product.** This is a personal project, shared as-is under the [MIT License](LICENSE); it may or may not see further development, and issues or pull requests may not be triaged or answered. It aims to be secure, but security is a design goal, not a guarantee — the container is one layer of defense, not a substitute for your own security practices, and you remain responsible for assessing its fitness before relying on it.

A generic hardened Dev Container for running AI coding agents safely. Provides default-deny network isolation, project-scoped state, and non-root execution out of the box — then makes that sandbox comfortable to live in, with first-class support for several agent frameworks (Claude Code, opencode, GitHub Copilot CLI) and LLM providers (Anthropic direct, Anthropic API key / gateway, Azure AI Foundry, GitHub Copilot).

## Goal

**Security is the primary goal.** This container exists so that a misbehaving or compromised agent cannot reach anything outside the project:

1. **Blast-radius containment.** Limits what a running agent can touch to the project workspace and an explicit allowlist of network destinations — no host home directory, no cloud credentials, no SSH keys.

2. **Project isolation.** Each project gets its own container, caches, and session state. No cross-project bleed.

**Ease of use is a close second.** A sandbox nobody wants to work in doesn't get used, so the container is also built to be productive and framework-agnostic — without ever relaxing the security boundary above:

3. **Multiple agent frameworks, one container.** [Claude Code](https://claude.com/product/claude-code), [opencode](https://opencode.ai/), and the [GitHub Copilot CLI](https://github.com/features/copilot/cli) are all installed and ready to run side by side.

4. **Pluggable LLM providers.** A single `use-*` switch ([`llm-switch.sh`](docs/file-guide.md#devcontainerdevelopmentllm-switchsh)) routes `claude`/`opencode` across Anthropic direct, an Anthropic API key or gateway, and Azure AI Foundry; Copilot-backed models are available through opencode and the Copilot CLI.

5. **Comfortable out of the box.** A useful baseline of CLI tools, an auto-opening terminal, firewall-aware tooling that explains blocks instead of failing cryptically, and guidance for [adding your own tools](docs/operations.md#adding-tools-to-the-development-container) and skills.

## Security measures

- **Default-DENY outbound network** via a separate `firewall` container (Squid). The dev container has no direct route to the internet — all egress goes through a domain allowlist.
- **Out-of-band management plane.** The `control` container (dashboard + CLI) is on a separate network and is unreachable from `development` — an agent cannot modify its own allowlist.
- **Long-term audit log.** Every proxied request is recorded to a SQLite audit log (configurable retention, default 2 months), queryable from the host (`fw audit`) and the dashboard, with CSV export — an agent cannot reach or tamper with it.
- **Non-root user, no sudo.** Container runs as `devuser` (UID 1000).
- **No Docker socket.** `/var/run/docker.sock` is not mounted.
- **Resource limits.** CPU (4 cores), memory (8 GB), PID (512) caps.
- **Read-only git identity** and optional SSH key isolation.
- **Project-scoped volumes.** State is namespaced per project; no cross-project bleed.
- **VS Code extensions are a trust boundary** — vet what you install (see [Security measures](docs/security.md) for details).

See **[docs/security.md](docs/security.md)** for the full breakdown and how to validate the perimeter with the bundled `security-test` skill.

## How to use

There are two ways to adopt this setup — both use a GitHub fork so you can pull upstream improvements at any time:

- **Adding to an existing repo** — see **[docs/spin-off-existing-repo.md](docs/spin-off-existing-repo.md)** for a full walkthrough.
- **Starting a new project from scratch** — see **[docs/spin-off-new-project.md](docs/spin-off-new-project.md)** for a full walkthrough.

In both cases the short version is:

1. Fork this repo on GitHub, add it as a second `upstream` remote in your project, and merge in the infrastructure files. See the guides above for the exact commands.
2. "Reopen in Container" from VS Code or Cursor, or run `devcontainer up --workspace-folder .`
3. First build: a few minutes (three images). Subsequent starts: seconds. **Default auth: Claude on an Anthropic subscription** (`use-anthropic`, OAuth) — selected out of the box; run `claude login` when prompted. See [Choosing a provider](docs/providers.md#choosing-a-provider) for why this is the default and how to switch to Azure Foundry or a static API key.
4. A focused `zsh` terminal opens automatically when the workspace folder opens (VS Code asks to "Allow Automatic Tasks" once) and greets you with a banner of the available agents. Run `claude` (Claude Code), `opencode`, or `copilot` (GitHub Copilot CLI) in it.

For a step-by-step first-time setup guide (prerequisites, Windows/WSL, API key, troubleshooting), see **[USAGE.md](USAGE.md)**.

### Manage the allowlist

All allowlist management runs on the **host**, not inside the dev container:

```bash
FW="agentic-$(basename "$PWD")-firewall"
docker exec "$FW" fw allow pypi.org          # permanent allow
docker exec "$FW" fw deny  pypi.org          # remove
docker exec "$FW" fw feature on azure        # enable a built-in feature-set
docker exec "$FW" fw feature create mycdn \
  --domain cdn.example.com                   # create a user-defined feature-set
docker exec "$FW" fw feature delete mycdn    # delete a user-defined feature-set
docker exec "$FW" fw blocks                  # recent blocked requests
docker exec "$FW" fw audit --status denied   # query the long-term audit log
```

A web dashboard is available at **<http://127.0.0.1:8088>** (the default; the exact port is derived per project so multiple instances can run at once — the terminal banner that greets you on attach prints the concrete URL and project name for **this** instance). Use it to toggle features, allow/deny domains, browse the audit log, and create or edit user-defined feature-sets from the browser. See **[docs/allowlist.md](docs/allowlist.md)** for full reference including feature-sets, TTL allows, debugging, and the block feed.

### Audit log

Every proxied request (allowed and denied) is recorded to a long-term audit log — a SQLite database in the `firewall` container, on its own `auditlog` volume. Query it from the host with `fw audit`, or from the dashboard's **Audit Log** card (filter by time range / host / decision, then download the period as CSV):

```bash
FW="agentic-$(basename "$PWD")-firewall"
docker exec "$FW" fw audit                                   # last 50 entries
docker exec "$FW" fw audit --from 2026-06-01 --to 2026-06-10 # by date range
docker exec "$FW" fw audit --host github.com --status allowed
```

Retention defaults to **2 months** and is pruned daily. Override it per project by setting `AUDIT_RETENTION_DAYS` in `.devcontainer/.env` (e.g. `AUDIT_RETENTION_DAYS=90`).

### Running multiple instances in parallel

`initialize.sh` derives everything project-specific from the **workspace folder name**: the internal subnet, the firewall IP, and the published host ports (the control-UI port and the `az login` callback range). So you can open several *differently-named* projects at the same time without collisions — each gets its own subnet, its own firewall, and its own dashboard port. On attach, the terminal banner prints the concrete control-UI URL and project name for that instance, so you always know which dashboard belongs to which container.

Two folders with the **same name** intentionally collide (same subnet, ports, and container names) and cannot run simultaneously — rename one of the folders to run them side by side. This is a deliberate trade-off: a stable, predictable identity keyed off the folder name, instead of extra bookkeeping to disambiguate identical names.

## Documentation

| Document | Contents |
|---|---|
| **[docs/security.md](docs/security.md)** | Full security measures, VS Code extension trust boundary, perimeter validation |
| **[docs/providers.md](docs/providers.md)** | Choosing a provider, Anthropic key setup, Azure AI Foundry, GitHub Copilot (opencode), Copilot CLI |
| **[docs/allowlist.md](docs/allowlist.md)** | Managing the allowlist, web dashboard, feature-sets, debugging blocked traffic |
| **[docs/auditing.md](docs/auditing.md)** | Extending auditing beyond egress (process-exec via auditd/eBPF), the shared-kernel constraint and how to choose between approaches (with WSL2-specific notes), filesystem auditing |
| **[docs/operations.md](docs/operations.md)** | Multi-agent with worktrees, adding tools & skills, permission prompts, caveats, cleanup, minimal footprint |
| **[docs/file-guide.md](docs/file-guide.md)** | What every file in `.devcontainer/` does |
| **[docs/comparison.md](docs/comparison.md)** | How this compares to Docker Sandboxes, Microsoft MXC, and why it has no proprietary dependencies |
| **[docs/spin-off-existing-repo.md](docs/spin-off-existing-repo.md)** | Adding agent tooling to an existing repo, with upstream sync via a fork |
| **[docs/spin-off-new-project.md](docs/spin-off-new-project.md)** | Starting a brand-new project with agent tooling from day one, with upstream sync via a fork |
| **[USAGE.md](USAGE.md)** | Step-by-step first-time setup guide (prerequisites, Windows/WSL, troubleshooting) |
