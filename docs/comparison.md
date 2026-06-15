# Comparison with similar solutions

## Docker Sandboxes

[Docker Sandboxes](https://www.docker.com/products/docker-sandboxes/) (`sbx`) is a Docker product that wraps AI coding agents in disposable **microVMs** — a stronger isolation boundary than a plain container. It ships as a standalone CLI (no Docker Desktop required), defaults to `--dangerously-skip-permissions` mode because the microVM makes that safe, and lets agents run Docker inside the sandbox for nested use cases.

Key differences:

| | This project | Docker Sandboxes |
|---|---|---|
| **Isolation mechanism** | Docker network topology (internal-only network + Squid proxy); container-level isolation | MicroVM per session — harder boundary than a container, closer to a lightweight VM |
| **Network model** | Default-deny egress via a dedicated `firewall` container with a domain allowlist, hot-reload, and a live traffic dashboard | Configurable network policy, but filtered at the VM boundary rather than through an auditable proxy |
| **Lifecycle** | Persistent, project-scoped environment; survives restarts; named volumes for caches and auth | Disposable by design; torn down after each agent session |
| **IDE integration** | First-class VS Code / Cursor devcontainer — open the folder and everything is wired | CLI wrapper around your existing agent invocation; no IDE attachment |
| **Agent frameworks** | Claude Code, opencode, and the GitHub Copilot CLI co-exist in one image | Wraps any agent that runs as a CLI process |
| **Credential model** | OAuth / Entra by default; static keys explicitly deprioritised; firewall limits exfil surface | Host credentials are not mounted into the sandbox, but the key still lives on the host |
| **Requires Docker Desktop** | Docker Engine (or Desktop) to build/run the Compose stack | No — ships as a standalone `sbx` CLI |
| **Customisation** | Full control: Dockerfile, Compose, firewall policy, skills — open source | Policy surface is what `sbx` exposes |

The core tradeoff is **isolation depth vs. persistence**. Docker Sandboxes gives you a harder VM boundary and a zero-config CLI wrapper; this project gives you a persistent, auditable developer environment with a configurable egress filter and IDE integration. If you want to wrap a single agent invocation in a throwaway microVM with minimal setup, reach for `sbx`. If you want a long-lived coding environment you can inspect, extend, and commit to a repo, this project is the better fit.

## Microsoft MXC

[Microsoft eXecution Container (MXC)](https://github.com/microsoft/mxc) is a TypeScript SDK for sandboxed code execution — a library agent frameworks embed to run untrusted model output or plugin code safely. It supports lightweight OS-native backends (Windows AppContainer, Linux Bubblewrap, macOS Seatbelt) and heavier VM backends (MicroVM, Hyperlight).

Key differences:

| | This project | MXC |
|---|---|---|
| **Abstraction level** | A complete developer environment you attach a coding agent to | A library your agent framework calls to execute a snippet safely |
| **Granularity** | One long-lived container session per project | Per-execution sandboxes spun up and torn down for each tool call |
| **Isolation mechanism** | Separate Docker network + Squid proxy container; no route to internet except through an audited allowlist | OS sandbox primitives (Bubblewrap / AppContainer / Seatbelt) or MicroVMs |
| **Network control** | Default-deny egress with a domain allowlist, out-of-band management plane, and live traffic dashboard | Outbound blocking configurable per-execution via JSON policy |
| **Integration** | Drop `devcontainer/` into any repo; open in VS Code/Cursor | TypeScript SDK; requires embedding in an agent framework |
| **Maturity** | Production-grade perimeter, validated with the bundled `security-test` skill | Early preview — Microsoft explicitly states no MXC profile should be treated as a security boundary yet |

If you are an **agent framework author** who needs a safe way to exec model-generated code snippets within your product, MXC is the right primitive. This project is for the developer workstation layer — the environment the whole agent runs inside, not just a single tool call.

## No proprietary dependencies

This project is built entirely on techniques and tools you almost certainly already have or have easy acces to: Docker Compose for container orchestration, Squid for HTTP proxying, standard Unix network namespaces for isolation, OAuth / Entra for identity, and VS Code devcontainers for IDE integration. None of these are novel or supplier-specific — they are battle-tested, widely documented, and available on any platform that runs Docker. There is no proprietary runtime to install, no vendor account to create, and no SDK to embed. The low barrier to adoption is intentional: if you can run `docker compose up`, you can use this.
