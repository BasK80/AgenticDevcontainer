# Offline detection — the cloud/local branch selector probe

Resolved **2026-08-24** for
[Decide how the skills detect that cloud is unreachable](006-offline-detection.md).
Measured live against this container's real firewall (not assumed) — see
commands below, all reproducible with `curl`.

## The probe: one `curl`, classified by exit code + response header

```sh
curl -sS -D /tmp/.model-picker-probe-headers -o /dev/null -w '%{http_code}' \
     --connect-timeout 1.5 --max-time 3 \
     https://copilot-api.info-support.ghe.com/
rc=$?
```

Target is the **real Copilot API host** from
the entitlement asset, not a generic domain like
`github.com` — a generic domain can be allowlisted while the API host isn't
(or vice versa), so probing anything else risks a false verdict. Same
mechanism, same target for **ollama**: swap the URL for
`http://host.docker.internal:11434/api/tags` (see "ollama needs the identical
treatment" below).

**Classification**, verified live in this container:

| `rc` | Response headers/body | Meaning | Verdict |
| --- | --- | --- | --- |
| `0` | any status (200, 401, 404, …) | reached the real remote — auth/routing is a separate concern | **online** |
| `56` (HTTPS CONNECT tunnel failed) | `-D` header dump contains `X-Squid-Error: ERR_FIREWALL_BLOCKED` | **allowlist block** — misconfiguration | **blocked (not offline)** |
| `0`, `http_code=403`, plain-HTTP probe | body contains `FIREWALL: outbound request blocked` | same allowlist block, HTTP-scheme variant | **blocked (not offline)** |
| `28` (timeout) or a squid stock error template (`ERR_CONNECT_FAIL`, `ERR_DNS_FAIL`, etc. — not `ERR_FIREWALL_BLOCKED`) | — | squid itself couldn't reach the upstream | **offline** (see caveat below) |
| `5`/`6`/`7` connecting to `firewall:3128` itself (the proxy, not the target) | — | the proxy container is unreachable — breaks *everything* network-related, not just this probe | **offline**, but flag distinctly (see "infra-broken" below) |

### Why `-D` and not `-w '%{http_code}'` for the HTTPS case

Measured directly: for an HTTPS target, Squid's allowlist denial happens at
the `CONNECT` tunnel stage, so curl reports it as **exit 56** with
`http_code=000` — `-w` alone sees nothing useful. But `-D <file>` still
captures the tunnel's own response headers, including the one field that
uniquely identifies this failure mode:

```
HTTP/1.1 403 Forbidden
X-Squid-Error: ERR_FIREWALL_BLOCKED 0
```

`ERR_FIREWALL_BLOCKED` is **this repo's custom error page**
(`.devcontainer/firewall/Dockerfile`, `deny_info ERR_FIREWALL_BLOCKED all` in
`squid.conf`) — it fires for exactly one ACL outcome, off-allowlist domains,
and no other squid stock error page ever emits that name. It is a safe,
unambiguous signature to grep for.

For a plain-HTTP target, Squid can complete the request normally and deliver
its error body as an ordinary 403 response (measured: `http_code=403`, body
starts with `FIREWALL: outbound request blocked by the container
allowlist.`), so the header-dump trick isn't needed there — but the actual
Copilot/ollama endpoints are accessed over their real schemes (HTTPS for
Copilot, HTTP for ollama), so both code paths are needed depending on target.

## The caveat: "bug" and "genuinely offline" can look identical

CLAUDE.md's three-layer table is written from the perspective of a process
whose *own* DNS resolver or routing is broken (`EAI_AGAIN`, `ENETUNREACH`) —
that can't happen to a `curl`-based probe here, because `curl` always honors
`HTTPS_PROXY`/`HTTP_PROXY` (unlike the Node single-executable case CLAUDE.md
calls out) and never resolves the target host itself; Squid does. So from
inside this probe, "Squid's own DNS/upstream lookup is broken because the
firewall image is stale" and "there genuinely is no route to the internet"
produce the **same observable signature** — a squid stock error template,
not `ERR_FIREWALL_BLOCKED`. There is no further disambiguation available from
inside the container; CLAUDE.md's own remedy for the stale-image case is
"rebuild", which only a human can do.

**Resolution: don't try to out-guess this.** Treat anything that isn't a
confirmed `ERR_FIREWALL_BLOCKED` allowlist block as "offline" for routing
purposes (open the local-fallback gate — the task must still get an answer),
but always print the raw signal (`X-Squid-Error` value, or `rc`) alongside the
verdict. That satisfies CLAUDE.md's "don't retry blindly or assume offline" —
the *skill* doesn't silently assume, it shows its evidence, and a human who
recognizes the stale-image pattern from that raw string can rebuild and move
on. The one failure mode that **must never** be misread as offline is the
allowlist block, because its fix (`fw allow` from the host) is different in
kind and the skill can positively identify it — that's the case this probe is
built to get right.

**Separately, if literally the proxy connection itself fails** (curl can't
even reach `firewall:3128`), that's worse than "offline" — it means the whole
container's network path is broken, not just this one destination. Surface
this distinctly ("network layer unreachable, not just Copilot/ollama") rather
than folding it into the ordinary offline verdict, since the fix is
container-level (check `docker-compose.yml`/rebuild), not a routing decision.

## Ollama needs the identical treatment — checked, not assumed

Measured: a request to `http://host.docker.internal:11434/api/tags` is
**also proxied through Squid** (`no_proxy` is only
`localhost,127.0.0.1,firewall` — `host.docker.internal` is not in it), and it
succeeds with a real `200` because that host is present in the *live*
allowlist (`/policy/allowlist.acl`), not in any checked-in
`.devcontainer/firewall/features/*.list` file — meaning it was added at
runtime via `fw allow host.docker.internal [ttl]`, the same mechanism as any
cloud domain.

**Consequence, flagged for Bas (not this map's decision to make):** if that
was a TTL-scoped allow rather than a permanent one, it will silently expire
and the exact same probe will then report `ERR_FIREWALL_BLOCKED` for
*ollama* — which, read carelessly, looks like "local is down" when the real
fix is `fw allow host.docker.internal` again from the host, or promoting it
to a permanent allow. The classification table above already handles this
correctly (it's a blocked verdict, not an offline one) — this note is just
so the message text distinguishes "ollama not allowlisted" from "ollama
process not running" when it fires.

Both probes (cloud, local) run the same code path with a different target and
a different consequence when unreachable:

- cloud unreachable → local becomes the only option (open the local gate).
- local unreachable → cloud is the only option; if cloud is *also*
  unreachable, that's the genuine both-down case the ticket asked for a clear
  error on — surface it as such, don't let the router silently pick a `null`
  model.

## Caching: keep the probe out of the decision path (map invariant 6)

Store the verdict in `preferences.json` (per
the data schema — this is exactly the kind of thing
that "changes continuously as Bas works" and is owned by `pick-model`), one
block per target:

```json
"network": {
  "cloud": { "reachable": true, "signal": "http_200", "lastProbed": "2026-08-24T19:32:00Z" },
  "local":  { "reachable": true, "signal": "http_200", "lastProbed": "2026-08-24T19:32:00Z" }
}
```

- **Every routing decision reads the cache first.** A decision only makes the
  live `curl` call when the cached verdict is older than the TTL — satisfying
  invariant 6 (no decision *requires* a network call; most read a cache).
- **TTL: 60 seconds**, for both targets, both directions. Reasoning measured
  against real latency here: the blocked case returns in under a millisecond,
  the reachable case in well under a second, and worst case (genuine timeout)
  is capped at `--max-time 3`s — so a fresh probe is cheap enough to eat once
  a minute during rapid back-to-back task routing, while still being long
  enough that it won't re-probe on every single `pick-model` call in a tight
  loop. A **blocked** verdict gets the same 60s TTL rather than a longer one,
  on purpose — so that once Bas fixes an allowlist gap from the host, the very
  next routing decision within a minute self-heals without restarting a
  session.
- No separate "offline" cache entry is needed for invariant 7
  (`assumed`/`measured` provenance markers) — reachability isn't a fact that
  gets corrected by a model run, it's a live state, so `lastProbed` alone
  covers staleness.

## What the skill says, per verdict

1. **online** → route normally, no message.
2. **blocked** → route to local anyway (the task still needs an answer) but
   say so plainly and actionably: *"Copilot API (`copilot-api.info-support.ghe.com`)
   is not on the container allowlist — falling back to local. To fix: `curl -s
   http://firewall:8099` shows recent denials; allow the domain from the host
   with `docker exec <firewall-container> fw allow copilot-api.info-support.ghe.com`."*
   Never phrase this as if the network were simply down.
3. **offline** (unclassified network failure, including genuine no-route) →
   route to local, message is informational only: *"Cloud unreachable
   (signal: `<raw rc/X-Squid-Error>`) — routing locally."* No fix instructions
   are asserted, since the skill can't tell bug from genuine offline; if Bas
   recognizes the raw signal as the stale-image pattern from CLAUDE.md, that's
   his call to rebuild.
4. **proxy itself unreachable** → loud warning distinct from both of the
   above: *"Container network layer unreachable — this affects everything, not
   just this task. Check the firewall container."*
5. **both cloud and local unreachable** → hard stop with a clear error, per
   the ticket's own requirement — never silently pick a `null` model or guess.

## Consequence for the build tickets

Write the pick-model skill implements
this probe (plain `curl`+shell, so it degrades gracefully across opencode,
Claude Code and Copilot CLI per map invariant 4 — no dependency on a running
opencode server) and the five message variants above. It should also set
`OPENCODE_DISABLE_MODELS_FETCH`/pin `OPENCODE_MODELS_PATH` (found by
[ticket 002](002-opencode-model-switching.md)) so the *model catalogue* path
never makes a network call either — that's a separate invariant-6 leak this
ticket surfaced but doesn't own fixing.
