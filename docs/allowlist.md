# Allowlist management

## Manage the allowlist from the host

```bash
# Set once in your host shell (or add to ~/.bashrc / ~/.zshrc):
FW="claude-$(basename "$PWD")-firewall"

docker exec      "$FW" fw allow pypi.org                   # permanent allow
docker exec      "$FW" fw allow files.pythonhosted.org 60  # temporary allow, 60s TTL
docker exec      "$FW" fw deny  pypi.org                   # remove an allow (re-block); perm + temp
docker exec      "$FW" fw list                             # show the live, compiled allowlist
docker exec      "$FW" fw blocks                           # recent blocked requests
docker exec -it  "$FW" fw log                              # follow the access log

docker exec      "$FW" fw feature list                     # feature-sets + their domains + on/off
docker exec      "$FW" fw feature on  azure                # enable a feature-set
docker exec      "$FW" fw feature off npm                  # disable a feature-set
```

Changes take effect within ~5s (the firewall watcher reloads Squid). Run these on the **host**, not inside the dev container — `development` is deliberately unable to reach the management plane.

## Web dashboard (localhost only)

A single-page dashboard is served by the `control` container at **<http://127.0.0.1:8088>**. It is bound to `127.0.0.1` only — the same localhost-only pattern as the Azure login ports — and is not reachable from inside `development`.

| Section | What it shows |
|---|---|
| **Live Traffic** | Real-time stream of every proxied request, colour-coded green (allowed) / red (denied). Collapsible; filter text persists across reloads. |
| **Feature sets** | One row per toggleable feature-set (`anthropic`, `github`, `npm`, …) with an **Enable**/**Disable** button and the domains it grants. A feature pulled in by another's dependency (e.g. `github` for `copilot`) is badged **via dep** and shows what requires it. |
| **Allowlist** | **Manual (permanent)** entries you added by hand, **Temporary** TTL entries (live countdown), and the read-only **Baseline (always on)** set. Each manual/temporary row has a **Remove** button. Domains granted by a feature-set live in the Feature sets card, not here. |
| **Recently Blocked** | Domains with at least one denied request, grouped by host and sorted by recency. One-click **Permanent** / **5m** / **15m** / **1h** and **Custom…** allow buttons per row. |

Every mutation from the dashboard writes to the same shared `policy` volume that the `fw` script modifies directly, so the CLI and the dashboard are always in sync.

## Configuring the allowlist (feature-sets)

The allowlist is split into a small always-on **baseline** plus named
**feature-sets** you toggle on or off. The baseline is only what's needed to
open and operate the dev container itself (VS Code server + marketplace, Debian/
Microsoft apt, a generic JS CDN); everything project-specific is a feature.

| Feature | Grants access to | Default |
|---|---|---|
| `anthropic` | Claude Code / Anthropic API (`api.anthropic.com`, `claude.ai`) | **on** |
| `github` | git, `gh`, GitHub package/skill installs | **on** |
| `npm` | npm / yarn registries | **on** |
| `opencode` | opencode's model catalogue (`models.dev`) | **on** |
| `copilot` | GitHub Copilot inference (`*.githubcopilot.com`); **depends on `github`** | off |
| `pypi` | Python package index | off |
| `golang` | Go module proxy + checksum DB | off |
| `azure` | Azure AI Foundry (Entra ID, ARM, Foundry portal, data plane) | off |
| `infosupport` | Info Support LLM gateway (test) | off |

Definitions live in `.devcontainer/firewall/features/*.list` (one file per
feature, domain-per-line, with an optional `# depends:` header). They are baked
read-only into the firewall image — adding or editing a feature is a maintainer
action (edit + rebuild the firewall), so a process inside the dev container
cannot grant itself new domains.

**Toggle a feature** (effective within ~5s, no rebuild):

```bash
docker exec "$FW" fw feature on  azure     # or use the control web UI
docker exec "$FW" fw feature off pypi
```

Enabling a feature transparently pulls in its dependencies (turning on `copilot`
also allows `github`'s domains, even if `github` is off). Manual `fw allow`
additions and TTL entries are kept separate from features; removing a
feature-granted domain with `fw deny` is refused and points you at
`fw feature off <name>`.

> **🔒 Maximise security — disable what you don't use.** The defaults enable
> `anthropic`, `github`, `npm`, and `opencode` (the API-key agentic tools and
> their common ecosystem). For the tightest egress surface, **turn off the
> agentic frameworks you don't run**
> — if you only use Claude Code, `fw feature off opencode`; if you only use
> opencode, `fw feature off anthropic`; enable `copilot` only when you actually
> use Copilot. Likewise leave `pypi` / `golang` / `azure` / `infosupport` off
> unless the project needs them. To reproduce the old "everything allowed"
> behaviour, enable every feature: `for f in anthropic github npm opencode copilot pypi golang azure infosupport; do docker exec "$FW" fw feature on $f; done`.

## See blocks from inside the dev container

- Each blocked request shows up as a `403` proxy error in your tools.
- Read-only recent-blocks feed: `curl -s http://firewall:8099`

## Debugging blocked traffic

```bash
# From inside the dev container:
curl -s http://firewall:8099 | tail -30

# From the host (FW="claude-$(basename "$PWD")-firewall"):
docker exec      "$FW" fw blocks                           # last 30 access log lines
docker exec -it  "$FW" fw log                              # live tail
docker exec      "$FW" fw list                             # current compiled allowlist
docker exec      "$FW" fw allow <hostname>                 # add the missing destination
docker exec      "$FW" fw allow <hostname> 300             # 5-minute temporary allow while debugging
```
