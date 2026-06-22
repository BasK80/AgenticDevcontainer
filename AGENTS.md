# Project agent guide

<!-- Read automatically by opencode (and other AGENTS.md-aware tools) at session
     start. The Claude Code equivalent is CLAUDE.md (kept in sync with this file). -->

## Network environment

This workspace runs inside a security-hardened dev container with **no direct
route to the internet**. All outbound HTTP/HTTPS traffic is forced through a
Squid forward proxy (the `firewall` container) that enforces a **default-deny
allowlist**.

If a network request fails, the most likely cause is **not** a DNS problem, a
connectivity outage, or a wrong URL — it is that the destination domain is not
on the allowlist. Do **not** retry blindly, switch to a different host, or
assume the remote service is down. A blocked request returns an HTTP `403` from
the proxy whose body explains the block.

**To confirm a domain was blocked** (run inside the container):

```sh
curl -s http://firewall:8099   # recent firewall denials, newest last
```

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
