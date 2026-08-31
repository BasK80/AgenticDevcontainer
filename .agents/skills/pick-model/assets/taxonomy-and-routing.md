# Task taxonomy and routing policy

Decided **2026-08-24**. This is the specification that `pick-model`
implements; `../REFERENCE.md` is the implementation, not a second copy of it.

## Routing policy — local is offline-only

**Cloud is the default for every task type.** The router's job is *"the cheapest
cloud model that will actually succeed"*, with an offline branch that picks the
best local model that fits.

This **replaces** the three-tier policy set at charting time (fast local default
for doc + mechanical work, cloud for agentic coding, spill local behind a gate).
The reason is arithmetic: the credit lever is *which
cloud model*, not local-vs-cloud. For a 100k-in/10k-out turn, `claude-opus-5`
costs 75 credits, `claude-sonnet-5` 30, `gpt-5.6-luna` 3.2, against a monthly
allowance of 1,900 (Business) or 3,900 (Enterprise). Routing doc work to a local
7B saves ~3 credits; routing a refactor from Opus to Sonnet saves 45. The old
policy optimised the small lever and ignored the big one.

**Local's justification is offline capability** — a stated driver of the effort,
untouched by this — plus zero marginal cost once the pool is drained. It is not
justified by credits.

## The five axes

Axes are the skill's **internal reasoning scaffold, inferred and displayed —
never asked**. The user answers nothing in the common case.

**Selection axes** — what capability the task requires:

| Axis | Values |
| --- | --- |
| Reasoning depth | trivial / moderate / hard |
| Agentic depth | none / few / many (tool calls, file edits in a chain) |
| Stakes | how expensive a wrong answer is to **detect and fix** |

**Cost + local-feasibility axes** — what it will spend:

| Axis | Notes |
| --- | --- |
| Input size | **This *is* the context length** — one number, not two. Drives the cloud long-context 2× penalty *and* local VRAM fit. |
| Expected output size | Output tokens cost 5–12× input, so this is a first-class cost axis — not a detail. |

**Local fit uses input + expected output**, because the KV cache grows during
generation. Both axes feed the VRAM fit formula in `ollama-curate`.

**Stakes** was added during grilling and is not optional: willingness to pay is a
function of consequence, not difficulty. A commit message and a migration plan can
both be "moderate reasoning, few tool calls", but one is free to fix when wrong.
Without stakes the router can never justify the expensive model.

**No latency axis.** "I'm waiting on this" versus "run it while I get coffee" is
not derivable from the task text; the user says "fast" when they care.

## The five starting types

A task type is a **cached bundle of axis values**.

| Type | Reasoning | Agentic | Stakes | Input | Output |
| --- | --- | --- | --- | --- | --- |
| `quick` — commit messages, renames, regex, lookups, summaries | trivial | none | low | small | small |
| `doc-edit` — tightening/revising existing prose | moderate | none | low | small–med | small |
| `doc-author` — drafting new technical/functional/architectural docs | hard | none | medium | medium | **large** |
| `doc-review` — consistency across many files | hard | few | medium | **large** | small |
| `code-agentic` — multi-file edits, refactors | hard | **many** | high | large | large |

**The taxonomy is open**: new types are minted as the user meets work that does not
fit, and appended to the prefs file. No skill prose changes.

Deliberate choices to preserve:

- **Docs split three ways** because the three sit at opposite corners of the cost
  axes. `doc-author` reads little and writes a lot; `doc-review` reads a lot and
  writes little. Since output costs 5–12× input, collapsing them would make the
  router systematically wrong about one. `doc-review` is also the type most likely
  to trip the long-context penalty, and the only doc type with tool use.
- **`quick` and `doc-edit` kept separate** even though they may route identically
  today — so the future benchmark can test whether `doc-edit` needs a better model.
  Merging now would hide that.
- **`code-agentic` left broad.** "Fix a typo across three files" and "restructure
  auth" differ wildly, but guessing the split line now is how taxonomies bloat.
  The open-taxonomy rule handles it when a real case doesn't fit.

## Matching a new task

**Exemplars first, axis inference as fallback.**

1. Each type stores a few example task descriptions. A new task is matched
   textually against them — cheap, no reasoning, short-circuits.
2. Only when nothing matches well does the skill run full axis inference. That
   work mints a new type *with its own exemplars*, so it is cheap forever after.

This matters because **the skill's own reasoning is not free** — it runs in
whatever session is active, so classifying in an Opus session spends Opus tokens.
Matching on axes alone was rejected for exactly this reason: axis inference *is*
the expensive step, so it would pay full price on every switch and the cache would
buy nothing but consistency.

Consequence: **the taxonomy gets cheaper to use the longer it is used** — the
property wanted from something meant to survive a changing workload.

Known failure mode: exemplar matching can be **confidently wrong** — a task that
reads like `doc-edit` but is a high-stakes architectural rewrite routes cheap.
Mitigation is that the skill **prints the axis line and the type it matched**, so
a wrong match is visible *before* acting on it. "That's not `doc-edit`" is the
correction.

**Tasks spanning types** (editing docs *and* refactoring code in one session):
**the more demanding type wins.** Under-provisioning costs a retry;
over-provisioning costs credits the user can see.

## Consent gate

The charting-time gate protected against slow *local* models. Local is now
offline-only, so offline is a **branch, not a decision**, and that gate has no
job. The replacement protects **credits**.

- **Per task type, remembered.** First time a type wants an expensive model, ask;
  answer once, never asked again for that type.
- **Threshold expressed as a percentage of monthly allowance**, not raw credits —
  "~13% of your month" means something, "250 credits" does not.
- **Inform-only. It never blocks.** After a yes/no it proceeds; the user decides
  whether a refactor is worth 13% of the month.
- **Re-asks when an estimate greatly exceeds the consented level.** Per-type
  consent alone has a hole: approving Opus for `code-agentic` on a 20-credit
  refactor would silently cover a 250-credit session. Same type, same consent,
  12× the spend.
- **Allowance is a cached fact with a refresh path**, like the hardware profile —
  it changes, but rarely. The *remaining* balance is a different matter: it is
  unreadable for a regular enterprise member, so never promise it.

## Escalation

**Only on the user's word. Never automatic.**

- The user says the output was inadequate; the skill steps up to a better model and
  **records the failure against that task type**.
- **A pattern of two-to-three failures shifts the type's floor** — one does not.
- Automatic escalation was ruled out firmly: it requires the model to judge its own
  failure, which is what LLMs are worst at. It would escalate on fine answers,
  accept bad ones, and spend credits either way. Failure detection is the user's
  judgement; the skill's job is to make acting on it one word.

Note the double-pay trap the charting session worried about has **largely
evaporated**. It assumed a failed *local* attempt — minutes of wall time, then the
cloud call anyway. A failed `gpt-5.6-luna` attempt costs ~3 credits and seconds,
so escalation overhead is ~10%, not 100%. "Try cheap, escalate if needed" is now a
good strategy where it was a bad one.

But the real cost of a failed cheap attempt is **the user's time reading bad
output**,
not the credits. So this is *not* "always try cheap first" — the type's default
encodes what is actually needed, and cheap-first applies only where the type says
cheap suffices.

## Provenance: `assumed` vs `measured`

Every default carries a provenance marker. The five starting types ship as
**`assumed`** — reasoned priors, not measurements — and `pick-model` says so, so
the user knows which recommendations to distrust.

Converting `assumed` → `measured` is the job of the **benchmark skill**, which is
**out of scope here** and needs its own effort. The schema must reserve
somewhere to store measured speed and quality per `(model, task type)` so the
benchmark can write into it and `pick-model` can read it.

## What a task-type record must hold

Mirrored by `preferences.json` (see `../seed/preferences.json`):

- type name and a few **exemplar task descriptions** (the matching key)
- the five **axis values**
- **default model** for online and for offline, each with `assumed` | `measured`
- **consent record**: whether an expensive model was approved, and at roughly what
  cost level (so a much larger estimate re-asks)
- **failure counter** per model, for the two-to-three-strike floor shift
- reserved slots for **measured speed/quality** per model, written by the future
  benchmark skill
