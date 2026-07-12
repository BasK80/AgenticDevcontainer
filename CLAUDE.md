# Project agent guide

<!-- Read automatically by Claude Code at session start. The opencode equivalent
     is AGENTS.md (kept in sync with this file). -->

## Network environment

This workspace runs inside a security-hardened dev container with **no direct
route to the internet**. All outbound HTTP/HTTPS traffic is forced through a
Squid forward proxy (the `firewall` container) that enforces a **default-deny
allowlist**.

If a network request fails, do **not** retry blindly, switch to a different
host, or assume the remote service is down. First read the error signature — it
tells you which of three layers blocked the request:

| Symptom | Layer | Cause & fix |
| --- | --- | --- |
| HTTP `403` from the proxy (body explains the block) | **Allowlist** | The destination domain is not allowed. This is the most common cause. Confirm and allow the domain (see below). |
| `EAI_AGAIN` / `getaddrinfo ENOTFOUND` / every lookup fails | **DNS** | The container's resolver (dnsmasq on the firewall) isn't answering. The firewall image runs dnsmasq and binds it to this project's `FIREWALL_IP` automatically (baked into the image + entrypoint), so this only shows up on a stale build — **rebuild the firewall + dev container** and it clears. |
| `ENETUNREACH` even though DNS resolves and the domain is allowed | **Proxy bypass** | A process is connecting directly instead of through the proxy — e.g. a Node single-executable app (the `copilot` binary that runs `web_fetch`) ignores `NODE_OPTIONS=--use-env-proxy`. The compose file sets `NODE_USE_ENV_PROXY=1` to cover this, so it too only shows up on a stale build — **rebuild the dev container**. |

Once DNS and the proxy work, the **allowlist** is the only layer you tune day to
day. The DNS resolver and proxy-env handling are baked into the firewall image
and `docker-compose.yml`, so they need no per-clone setup.

**To confirm a domain was blocked** (run inside the container):

```sh
curl -s http://firewall:8099   # recent firewall denials, newest last
```

**If DNS or proxy-bypass failures persist** (`EAI_AGAIN` / `ENETUNREACH`): they
come from a stale firewall/dev-container image, not from anything editable inside
the container. Rebuild the stack — *Dev Containers: Rebuild Container*, or on the
host `docker compose -f .devcontainer/docker-compose.yml up -d --build` — then
verify with `getent hosts github.com` (DNS) and a `web_fetch` of
`https://github.com` (proxy).

**To allow a domain**, tell the user to add it from the **host** — a process
inside the container cannot modify its own allowlist, by design:

- Control web UI: <http://127.0.0.1:8088>
- On the host: `docker exec <firewall-container> fw allow <domain> [ttl-seconds]`
- Whole feature-sets (npm, azure, copilot, …) toggle on/off via the control UI
  or `docker exec <firewall-container> fw feature on|off <name>`.
- **User-defined feature-sets** (groups of domains for a specific tool or service)
  can be created, edited, and deleted at runtime — they are stored in
  `/policy/features.d/` on the `policy` volume and persist across restarts:
  - `docker exec <firewall-container> fw feature create <name> --domain x.com`
  - `docker exec <firewall-container> fw feature delete <name>`
  - Same operations are available in the web UI's **Feature Sets** tab.
- Permanent built-in default: add the domain to the relevant feature list under
  `.devcontainer/firewall/features/` (or create a new one) and rebuild the
  firewall image.

See `README.md` → "Manage the allowlist from the host" for details.

## Read-only mounts

Parts of this container's filesystem are **bind-mounted read-only** from the
host. Direct edits to these files from inside the container will fail with a
permission or read-only filesystem error.

When a task requires changes to a read-only file:

1. **Do not** attempt to edit the file in place — it will fail.
2. Instead, create a shell script under `/workspace/` (e.g.,
   `/workspace/apply-<description>.sh`) containing the commands needed
   to apply the changes (using `sed`, `tee`, `cp`, etc.).
3. Make the script executable (`chmod +x`).
4. Tell the user to run the script **from the host**, where the filesystem is
   writable.

This approach works because `/workspace` is shared between the container and
the host, so scripts placed here are accessible from both sides.

**Known read-only paths** (defined in `.devcontainer/docker-compose.yml`):

- `/workspace/.devcontainer/development/Dockerfile`
- `/workspace/.devcontainer/development/post-create.sh`
- `/workspace/.devcontainer/development/post-start.sh`
- `/workspace/.devcontainer/firewall/` (entire directory)
- `/workspace/.devcontainer/control/` (entire directory)
- `/workspace/.devcontainer/docker-compose.yml`
- `/workspace/.devcontainer/devcontainer.json`
- `/workspace/.devcontainer/.env`
- `/workspace/.devcontainer/initialize.sh`
- `/workspace/.vscode/tasks.json`
- `/home/devuser/.gitconfig`
