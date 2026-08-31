# pick-model — method reference

Everything here is *method* — how to decide. The *facts* it operates on (task
types, exemplars, model costs, hardware tiers, consent state) live in the
data directory (see § Configuration) and must be read live, never recited. If
a number or model name below looks concrete, it's an example from a past run,
not something to trust without re-reading the file. The specification this
implements is
[Task taxonomy and routing policy](assets/taxonomy-and-routing.md) —
this file is the implementation, not a second copy of the spec; read that
asset for the *why* behind anything that looks arbitrary below.

## Configuration

Data directory: `$MODEL_PICKER_DATA_DIR`, falling back to
`/workspace/.model-picker` if unset (this repo's own bind-mount choice, not a
universal default). Three files: `hardware.json`, `models.json`,
`preferences.json`. The directory is gitignored — it is per-machine, live state.

**First run in a fresh checkout.** If the data directory is missing or empty,
seed it by copying `seed/*.json` from this skill folder into it:

```sh
mkdir -p "${MODEL_PICKER_DATA_DIR:-/workspace/.model-picker}"
cp -n .agents/skills/pick-model/seed/*.json "${MODEL_PICKER_DATA_DIR:-/workspace/.model-picker}/"
```

Treat every seeded fact as **stale until re-confirmed** — the seed carries
`lastConfirmed`/`lastVerified` dates and provenance markers precisely so that
staleness stays visible. Re-verify hardware with `ollama-curate` and the
Copilot catalogue against the live provider before trusting either.

If `seed/` is also absent and `preferences.json` is missing, this is a true
first run — create it with the five starting task types from
[the taxonomy asset](assets/taxonomy-and-routing.md),
every default marked `"provenance": "assumed"`, and continue.

## File ownership

- `preferences.json` — **this skill owns it entirely.** Task types, axes,
  exemplars, per-type online/offline defaults, consent records, failure
  counters. `ollama-curate` never reads or writes it.
- `hardware.json` — this skill owns only the `creditAllowance` key. Never
  touch `hardware`/`ollamaEndpoint` — those belong to `ollama-curate`.
- `models.json` — this skill owns every `github-copilot/*` and `anthropic/*`
  entry, plus the `githubCopilotPricingCorrections` and
  `anthropicPricingMechanics` top-level blocks. It may write *narrow* tier
  corrections into an `ollama/*` entry's `maxFullyResidentContext` after
  reading a real `/api/ps` result post-run, but never re-derives a full
  `fitFormula` from scratch — that's `ollama-curate`'s refresh job.
- **Write convention:** read-modify-write, merge only the keys you own —
  same discipline `llm-switch.sh`'s `_opencode_write_config()` and
  `ollama-curate` already use in this repo. Single-user, sequential-tool-call
  tool; no locking designed for.
- Every written fact gets a `lastConfirmed`/`lastVerified` date and a
  provenance marker where the schema has one — staleness must always be
  visible, never silent.

## Credit allowance and balance

This whole section, as written below, is **GitHub Copilot-specific** — the
fetch mechanism it describes only exists for that provider. See "Anthropic —
no fetchable balance" at the end of this section for the `anthropic/*` path.

**Fetched, never asked.** A single call returns both the allowance and the
live remaining balance:

```
GET https://api.<host>/copilot_internal/user
Authorization: Bearer <token>
```

`<host>` derives from the logged-in host (`github.com` → `api.github.com`;
a GHE tenant → `api.<tenant>`). Read
`quota_snapshots.premium_interactions`.

**Token resolution, in order** — stop at the first that yields one:

1. `$GITHUB_TOKEN` or `$GH_TOKEN`
2. `gh auth token` (add `--hostname <host>` when not github.com)
3. `~/.copilot/config.json` → `copilotTokens["<host>:<login>"]`

**Fields to trust:** `entitlement` (monthly allowance), `remaining` and
`percent_remaining` (live), and the top-level `quota_reset_date`.
**Do not use `credits_used`** — it lags materially behind `remaining`
(observed staying flat across two hours while `remaining` kept falling).

**Applies to Copilot-routed models only.** Run this whole section only when
the candidate model's `provider` is `github-copilot`. For `ollama`, Anthropic
or Foundry routes, omit the credit story entirely — those don't touch this
allowance, and showing it would be actively misleading. This matters whenever
a harness is pointed at a subscription rather than at metered credits.

**Fetch once per session**, cache under `hardware.json.creditAllowance` with
`monthlyCredits`, `remaining`, `percentRemaining`, `resetDate`,
`source: "fetched"` and a timestamp. Reuse it for the rest of the session.
Within a long session the cached figure drifts — that is accepted.

**Degrade silently.** If no token resolves, or the call fails, or the host is
blocked by the firewall, express costs in money alone and say nothing about
allowance or balance. Never fall back to asking for a seat type: the
published per-seat figures (1,900 Business / 3,900 Enterprise) are *starting
points an organisation may raise per user*, not a lookup table. One verified
account reported `copilot_plan: "business"` against an actual entitlement of
15,000 — the published figure would have been wrong by a factor of 7.9.

**Treat the allowance as personal** unless you learn otherwise: an individual
budget within the organisation rather than a pool shared across seats.

**Assume credits stop hard when exhausted.** Some sources describe overage as
billable rather than a cutoff; that is not safe to rely on. The API reports
`overage_permitted: true` alongside `overage_entitlement: 0`, which is
ambiguous, and verifying it would mean exhausting the allowance. The
conservative reading — a wall — is the one this skill acts on.

**Endpoint caveat:** `/copilot_internal/user` is undocumented and may change
without notice — hence the best-effort treatment above. It has been verified
against a GHE Data Residency tenant, not against github.com. The *documented*
billing routes (`/users/{u}/settings/billing/usage`,
`/user/settings/billing/usage`,
`/enterprises/{e}/settings/billing/usage`) returned **404** on that tenant, and
pool-level billing endpoints require administrator or billing-manager rights,
so don't reach for either.

### Anthropic — no fetchable balance

**Never attempt a live fetch for an `anthropic/*` model.** Per
`models.json`'s `anthropicPricingMechanics.balanceNotFetchable`, every
Anthropic usage/cost API requires an org-admin or primary-owner credential —
there is no low-privilege analogue to Copilot's `copilot_internal/user`.
Degrade straight to **cost-only**: state the estimate in money, with no
balance, no percentage, no parenthetical credit count (Anthropic has no
"credits" unit the way GitHub AI Credits does — inventing one would be
actively misleading).

If the user states a figure themselves (e.g. "$118 of $150"), treat it as
**manual/self-reported** — usable for a session's conversation, never cached
under `hardware.json.creditAllowance` with `source: "fetched"`, and never
re-derived or refreshed by this skill on their behalf. It is very likely the
usage-credits *overage* layer rather than the (unpriced) base rolling-window
pool — see `anthropicPricingMechanics.twoLayeredQuota` — so don't present it
as "your monthly allowance" without that caveat if it comes up.

The one channel the user can check themselves: `claude.ai` → Settings →
Usage. Name it if asked where to look; do not attempt to reach it
programmatically.

## Pace warning

Outside the consent gate, surface the balance **only** when consumption is
running ahead of the calendar: warn when the fraction of allowance remaining
is smaller than the fraction of the billing period remaining, computed
against `quota_reset_date`.

A flat percentage threshold would misfire — 20% remaining is alarming
mid-month but ample on the day before reset.

**When the pace warning fires, the skill shifts from informing to steering:**
actively propose cheaper models for the task rather than merely stating the
cost. The user always overrules. Below the threshold, the recommendation
never depends on the balance — the same task yields the same answer.

## Matching a task

**Exemplars first, axis inference as fallback** — because the skill's own
reasoning is not free; it spends tokens in whatever session is active.

1. Compare the task description against each task type's `exemplars` in
   `preferences.json`, textually — cheap, no reasoning required. Take the
   best match if it's a good one.
2. Only when nothing matches well, run full axis inference: reason about the
   five axes below, find the closest existing type, or mint a new one with
   its own exemplars (so it's cheap forever after) and append it to
   `preferences.json`.

**The five axes** — inferred and displayed, never asked:

| Axis | Values | Notes |
| --- | --- | --- |
| Reasoning depth | trivial / moderate / hard | |
| Agentic depth | none / few / many | tool calls, file edits in a chain |
| Stakes | low / medium / high | how expensive a wrong answer is to *detect and fix* — not the same as reasoning depth |
| Input size | small / medium / large | this *is* the context length; drives both the cloud long-context penalty and local VRAM fit |
| Output size | small / large | output tokens cost 5–12x input — a first-class cost axis |

No latency axis — "I'm waiting on this" isn't derivable from task text; the
user says "fast" when they mean it.

**Print the axis line and matched type before acting.** A wrong exemplar
match is common and *confidently* wrong (a high-stakes rewrite can read like
a routine edit) — visibility before action is the only mitigation. "That's
not `doc-edit`" is the correction, and it only works if the match was shown.

**Spanning tasks** (edits docs *and* refactors code in one go): the **more
demanding type wins**. Under-provisioning costs a retry; over-provisioning
costs credits the user can see and object to.

**The taxonomy is open.** Never hardcode the five starting types' names or
axis values in reasoning — read them from `preferences.json`. New types are
minted when a real task doesn't fit, not guessed in advance.

## Offline detection

One `curl`, classified by exit code + a header dump. Everything needed to
execute the probe is below.

- Probe target: the **real API host**, not a generic domain — a generic
  domain can be allowlisted while the real endpoint isn't. Cloud:
  `https://copilot-api.info-support.ghe.com/`. Local:
  `http://host.docker.internal:11434/api/tags` (read the actual resolved
  endpoint from `hardware.json.ollamaEndpoint`, don't hardcode the host).
- **Read the cached verdict first.** `preferences.json.network.{cloud,local}`
  — `{reachable, signal, lastProbed}`. Only probe live if `lastProbed` is
  older than 60 seconds. This upholds the design rule that no routing
  decision *requires* a network call.
- Classify by exit code and, for HTTPS targets, the `-D` header dump's
  `X-Squid-Error` value:
  - reached the real remote (any status) → **online**
  - `X-Squid-Error: ERR_FIREWALL_BLOCKED`, or an HTTP body containing
    `FIREWALL: outbound request blocked` → **blocked (allowlist gap)** — the
    one case that must **never** be phrased as offline; its fix (`fw allow`
    from the host) is different in kind
  - a squid stock error template (`ERR_CONNECT_FAIL`, `ERR_DNS_FAIL`, a
    timeout) → **offline** — cannot be distinguished from a stale firewall
    image from inside the container; show the raw signal, don't guess further
  - can't reach `firewall:3128` itself → **network layer unreachable** — a
    container-infra problem, not a routing decision; surface distinctly,
    loudly
- **Branch:** cloud unreachable (blocked or offline) → route locally, cloud
  reachable → route to cloud by default (see § Routing policy). Local *also*
  unreachable when cloud is down → hard stop with a clear error, never
  silently pick a `null` model.
- **Message per verdict** (say plainly, never assert a fix you can't
  confirm):
  1. online → no message, route normally.
  2. blocked → *"`<host>` is not on the container allowlist — falling back to
     local. `curl -s http://firewall:8099` shows recent denials; ask the user
     to allow it from the host."*
  3. offline → *"Cloud unreachable (signal: `<rc/X-Squid-Error>`) — routing
     locally."* No fix asserted — this skill can't tell bug from genuine
     offline.
  4. network layer unreachable → *"Container network layer unreachable — this
     affects everything, not just this task."*
  5. both down → hard error, not a silent local pick.
- Cache the fresh verdict back to `preferences.json.network` with
  `lastProbed`. Same 60s TTL for a blocked verdict as a reachable one, on
  purpose — a fixed allowlist gap should self-heal within a minute without a
  session restart.

## Harness reachability

**A model is only a candidate if the harness running this skill can actually
reach it.** The catalogue can hold entries for providers this harness has no
way to switch to at all — a Claude Code session can never become
`github-copilot` or `ollama`, and a Copilot CLI session can never become
`anthropic`. Filter *before* ranking by cost, not after, or the skill ends up
recommending switches it has no way to carry out:

| Current harness | Reachable providers | Detection |
| --- | --- | --- |
| Claude Code | `anthropic` only | `$CLAUDECODE == "1"` (verified live — this env var is set inside a real Claude Code session) |
| GitHub Copilot CLI | `github-copilot` only | absence of `$CLAUDECODE`; no live-verified positive signal found yet — treat as the default when neither Claude Code's nor opencode's signal fires, and correct this row the first time it's actually checked from inside Copilot CLI |
| opencode | `ollama`, `github-copilot`, and `anthropic` if `llm-switch.sh`'s `use-anthropic`/`use-anthropic-key` has been run for it | no live-verified positive signal found yet — same caveat as the Copilot CLI row |

`ollama` is never reachable from Claude Code or Copilot CLI regardless of
network state — this is a harness capability gap, not an offline-detection
case (no ollama-to-Claude-Code proxy shim exists, and building one is out of
scope for this skill).

**Known loose edge:** whether an opencode session's `anthropic` route is
actually reachable depends on which provider `llm-switch.sh` last switched
it to (`use-anthropic`/`use-anthropic-key` vs. `use-foundry`/default) — read
`llm-mode`'s live state rather than assuming either way if this matters for
a specific session.

## Routing policy

**Cloud is the default for every task type.** Pick the cheapest cloud model
that will succeed on the matched type's axes, **among the providers §
Harness reachability says this session can actually use.** Take the local
branch only when § Offline detection says cloud is unreachable — local is
justified by *offline capability*, not by credits (the credit-cost asset
found the credit lever is *which* cloud model, not local-vs-cloud — routing
doc work locally saves a few credits; routing a refactor to a cheaper cloud
model saves dozens).

**Online model choice:** among models whose `provider` is reachable from
this harness, and whose declared capabilities cover the
matched type's axes (tool-calling for any agentic depth above `none`,
sufficient context for the input size), pick the cheapest by
`costPerMTokUSD` — resolved through § Cost computation below, never the raw
field directly. **A type's stored `defaults.online.modelKey` is a hint, not
a mandate:** if that model's provider isn't reachable from the current
harness (e.g. a `github-copilot/*` default read while running inside Claude
Code), ignore it for this session and pick fresh from the reachable subset
instead — do not silently fall back to an unreachable model, and do not
treat the mismatch as an error.

**Offline model choice:** read the matched type's `defaults.offline.modelKey`
from `preferences.json`. If it's `null`, **say plainly this task type has no
offline coverage** — do not silently degrade to a worse-fitting model that
happens to be installed. `ollama-curate` owns which models exist and their
tiers; this skill only reads that data, it doesn't re-derive VRAM fit.

**Set `num_ctx` per request, never rely on ollama's default.** Ollama
defaults context length **from VRAM** (`<24 GiB usable → 4096`), so every
local call is silently capped at 4k unless `num_ctx` is set explicitly to
input + expected output tokens for *this* task. This holds regardless of
whether KV-cache quantisation is enabled on the host.

## Cost computation

**Enforced code path, not a convention:** when a `models.json` model entry
has a non-null `costOverride`, use `costOverride.effectiveCostPerMTokUSD` —
never the raw `costPerMTokUSD` sibling field. The raw field is known-wrong
for at least the `-fast` variants; reading it directly is a bug, not a
simplification.

**Before trusting a model's plain `costPerMTokUSD`, apply
`githubCopilotPricingCorrections` (top-level block in `models.json`) if this
model wasn't already cached with a `costOverride`/`longContextTier` reflecting
it:**

1. **Fast variants** — if the model id ends in `-fast`, its real cost is 2x
   the non-fast counterpart's, per `fastVariantMultiplier`. One of the three
   currently known (`claude-opus-4.8-fast`) has this individually documented;
   the other two (`-4.6-fast`, `-4.7-fast`) are overridden **by analogy
   only** — keep whatever provenance marker distinguishes that (this skill
   should preserve `"assumed"` there, never silently upgrade it to
   `"measured"`).
2. **Long-context tier** — if the model id is a key in
   `longContextTier.modelsWithTier`, and the task's input-token estimate
   exceeds the listed threshold, double both input and output cost for this
   estimate. Every other entitled model has no long-context tier at all —
   don't invent one.
3. **Data-residency surcharge** — genuinely unresolved whether it applies to
   this account (see `dataResidencySurcharge.activeForUser: "unknown"`).
   Don't bake in
   the +10%; if you want to convey the uncertainty, say the estimate carries
   roughly a ±10% band, don't present a single number as more precise than
   it is.

**For `anthropic/*` models, read `anthropicPricingMechanics` instead — it is
not a drop-in replacement for the three corrections above, several are
absent by design:** no long-context tier exists at all (don't double
anything past a token threshold — see `noLongContextTier`), no `-fast`
variant is actuable from Claude Code today (don't invent a costOverride for
one), and the same unresolved ±10% data-residency band applies via
`dataResidencySurcharge`. The one thing to actively flag: per
`twoLayeredQuota`, ranking by `costPerMTokUSD` is a best-available heuristic
until the user is confirmed to be in the usage-credits overage layer — say
so if asked how confident the estimate is, don't present it as exact.

**Estimate tokens** from the matched type's `inputSize`/`outputSize` axis
values (map them to rough token counts consistent with how the type was
scoped — e.g. "large" input for `doc-review` means the actual files in
scope, not a fixed constant) — the point is a number good enough to rank
models and size the consent gate, not a byte-exact prediction.

## Consent gate

Protects **credits**, not patience — local is offline-only now, so there's
no "slow local model" case left for a gate to guard against.

- **Per task type, remembered.** The first time a type wants an expensive
  model, ask; cache the yes/no under that type's `consent.expensiveModelApproved`
  and the cost level under `consent.approvedAtCostLevel`. Never ask again for
  that type at or below that level.
- **Fires above ~$1.00**, or when a new estimate reaches roughly **3× the
  level already approved** for that type. Both are absolute — no percentage
  of the allowance is involved.
- **Express the cost as money first, credits second** — "~$1.50 (≈150
  credits)". Money is the quantity that means something without a
  denominator; the credit count is the unit the API reports and belongs in
  the parenthesis, not in front. **This "credits" parenthetical is
  Copilot-specific** — for `anthropic/*` models there is no credit unit at
  all, so state money alone ("~$1.50"), never invent an equivalent.
- **Always state the remaining balance in the gate** when the model is
  Copilot-routed and a balance was fetched — "~$32.91 left this period,
  resets 1 Sep". If no balance is available, show the cost alone rather than
  guessing. **For `anthropic/*` models, never state a balance** — see §
  Credit allowance and balance's "Anthropic — no fetchable balance": there is
  nothing to fetch, so the gate always shows cost alone there.
- **Inform-only — it never blocks.** State the estimate and proceed; consent
  is about the user knowing, not gating the call. The one exception is the
  pace warning (see § Pace warning), where the skill starts proposing cheaper
  models — still without blocking.
- **Re-ask when a new estimate greatly exceeds the consented level** — the
  gap this closes: approving Opus once for a 20-credit `code-agentic` task
  must not silently cover a 250-credit one under the same type/consent pair.
- **Never skip the gate for lack of allowance data.** The dollar threshold
  is computable from the model's cost alone.

## Escalation

**Only on the user's explicit word. Never automatic.**

- When the user says a result was inadequate, step up to a better model for that
  type and record the failure against the model that failed
  (`preferences.json`'s per-type `failureCounters`, keyed by model).
- **A pattern of two-to-three failures for the same model shifts that type's
  default floor** — one failure does not. Read the counter, don't guess a
  threshold each time.
- Never infer failure yourself from output length, tone, or a hunch — that's
  exactly the judgment call LLMs are worst at, and it would escalate on fine
  answers and accept bad ones with equal confidence. The user's word is the only
  trigger.

## Actuation — opencode only

A prose skill cannot address the running opencode server directly by shell
(no discoverable port, no lock file, no `OPENCODE_SERVER_URL`) — but a
**plugin-provided tool** solves this cleanly, because the tool executes
*inside* the opencode process and gets `client`/`sessionID` for free.

**Corrected from this skill's original design:** the design specified "a
`/pick-model` slash command via `PluginInput`'s `client`/`serverUrl`." Once
the actual SDK types were read (building this skill), that turned out to be
inconsistent — slash-command registration
(`api.command.register`/`api.keymap.registerLayer`) only exists on an
undocumented, separate **TUI plugin** export shape (`TuiPluginApi`), not on
the documented **server plugin** shape that actually carries
`client`/`serverUrl` (`PluginInput`). Rather than ship against an unverified,
undocumented API, actuation is a **plugin tool** instead
(`.opencode/plugin/pick-model.ts`, tool name `pickmodel_switch`) — which
uses only the documented, stable server-plugin surface (`Hooks.tool`, exactly
as shown in `@opencode-ai/plugin`'s own bundled example) and is arguably
better UX besides: no separate manual slash-command step, no stale-file
handoff to get wrong.

1. **This skill (running as the LLM in the opencode session) calls the
   `pickmodel_switch` tool directly**, in the same turn it decides a model —
   `{ providerID, id, variant? }`. No file write, no second round-trip.
2. **The tool validates before switching**, against `GET /api/model` and
   `POST /api/session/{sessionID}/model` — because the switch endpoint
   itself returns success and silently stores a bogus model/provider
   otherwise — verified live, not assumed.
   If validation fails, it reports that plainly instead of switching.
   **Implementation note, verified live rather than assumed:** the plugin's
   `client` (`PluginInput.client`) is the v1 SDK client, which has no
   `.model`/`session.switchModel` methods — those only exist on the `/api/*`
   routes. Plain `fetch()` against the server's own `serverUrl` for those
   routes fails every time with a generic connection error, even though the
   identical URL is reachable by `curl` from a shell at the same moment —
   a real self-connection limitation of fetching the plugin's own hosting
   server from inside its own tool execution (an external fetch, e.g. to
   ollama, works fine from the same call). The fix, confirmed working live:
   call through `client._client.get/post({ url, body })` — the generic,
   untyped transport the typed `client.*` methods are themselves built on —
   which reaches `/api/*` routes without that limitation. See the comment
   block at the top of `pick-model.ts` for the full trail.
3. **`sessionID`** comes from the tool's own execution context
   (`ToolContext.sessionID`, provided automatically by opencode) — nothing
   this skill needs to discover or pass in itself.
4. **In Claude Code and Copilot CLI**, no such tool exists and no server is
   addressable at all — print the exact equivalent (e.g. "switch to
   `github-copilot/gpt-5.6-luna`") and say plainly that automatic switching
   isn't available there. The reasoning must stand alone as text (map
   invariant 4) — advice degrades gracefully, actuation is an opencode-only
   bonus.

## Pin the model catalogue

Set `OPENCODE_DISABLE_MODELS_FETCH=1`, or pin `OPENCODE_MODELS_PATH` to a
local catalogue file you supply yourself (opencode also honours
`OPENCODE_MODELS_URL`), so that even the *catalogue lookup* never makes a
network call — otherwise
the "no decision requires a network call" rule would have a leak one layer
below the routing decision itself. This is environment
configuration, not something this skill sets per-call; note it once and move
on if it's not already set.

## Tier-correction write-back

After a local run, read `/api/ps` for `size`/`size_vram` and compare against
the ollama model's cached `maxFullyResidentContext` prediction. If they
disagree, correct that single field with today's date — this is a narrow,
opportunistic fix, not a re-derivation of `fitFormula`/`slopeBytesPerToken`
(that full-formula ownership stays with `ollama-curate`, which also owns the
`ollamaKvCacheAssumptions` fingerprint those formulas depend on).
