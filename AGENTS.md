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
- Permanent default: add the domain to
  `.devcontainer/firewall/allowlist.default` and rebuild the firewall image.

See `README.md` → "Manage the allowlist from the host" for details.
