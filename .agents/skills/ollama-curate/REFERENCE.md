# ollama-curate — method reference

Everything here is *method* — how to decide. The *facts* it operates on
(hardware specs, model architecture fields, measured fit/throughput numbers)
live in the data directory (see § Configuration) and must be read live, never
recited. If a number below looks like a model name or a byte count, that's an
example from a past run, not something to trust without re-reading the file.

## Configuration

Two things are environment-specific and must be resolved before anything
else, not assumed from a past run or another machine:

- **Data directory** — where `hardware.json`/`models.json`/`preferences.json`
  live. Default: `$MODEL_PICKER_DATA_DIR`, falling back to
  `/workspace/.model-picker` if unset (this repo's choice, driven by its own
  bind-mount setup — not a universal default). If neither exists yet, this is
  a first run: seed it from `../pick-model/seed/*.json` if that folder is
  present (treat every seeded fact as stale until re-confirmed), otherwise
  create the directory and the two files this skill owns (`hardware.json`,
  `models.json`) fresh, per § Hardware refresh.
- **Ollama endpoint** — see § Ollama endpoint discovery immediately below.

Every other section refers to "the data directory" and "the ollama
endpoint" — resolve them once per session and reuse, don't re-resolve per
step.

## Ollama endpoint discovery

Don't hardcode a host or port — where ollama listens depends entirely on how
it's installed relative to wherever this skill is running:

1. **`$OLLAMA_HOST`**, if set — ollama's own standard env var. It may be a
   bare `host:port` (no scheme); prefix `http://` if so.
2. Otherwise probe, in order, and use whichever answers `GET /api/tags`:
   `http://localhost:11434` → `http://127.0.0.1:11434` →
   `http://host.docker.internal:11434` (the last one only makes sense if
   *this skill* is running inside a container and ollama is on the host —
   it will fail to resolve elsewhere, which is fine, just move to the next).
3. Cache the resolved URL in `hardware.json`'s `ollamaEndpoint` key
   (`{ "url": "...", "resolvedVia": "env" | "probe:<which>", "lastConfirmed": "..." }`
   — this skill owns this key, same as `hardware`). Re-resolve if a cached
   endpoint stops answering rather than assuming ollama is gone entirely.

## File ownership (read the data-directory conventions first)

- `hardware.json`: this skill owns the `hardware` and `ollamaEndpoint` keys.
  The `creditAllowance` key belongs to `pick-model` — don't touch it.
- `models.json`: this skill owns every `ollama/*` entry and the top-level
  `ollamaKvCacheAssumptions` block. `github-copilot/*` entries belong to
  `pick-model` — don't touch them.
- `preferences.json`: not this skill's file at all. Never read-for-decisions,
  never write.
- **Write convention:** read-modify-write, merge only the keys you own. This
  is a single-user, sequential-tool-call tool — no locking, no concurrent
  writers to guard against.
- Every fact you write gets a `lastMeasured`/`lastConfirmed` date and, where
  the schema has it, a provenance marker (`measured` vs `assumed` vs
  `metadata_x1.02_unfitted` etc.) — staleness must always be visible, never
  silent.

## Hardware refresh (first run, or explicitly asked)

Ask the user directly — if this skill is running somewhere that can't probe
the GPU itself (inside a container, no vendor tooling installed, etc.),
`nvidia-smi`-style probing won't be meaningful, so don't try and don't guess:

- GPU vendor, total VRAM (or "unified memory" — see the caveat below)
- System RAM size and type
- CPU model/core count

Write these under `hardware.json`'s `hardware` key with
`source: "asked"` and today's date. **Usable VRAM is not the same as total
VRAM** — reserve ~1.5–2 GB for driver/CUDA/desktop-compositor overhead unless
you have a measured `usableVramGiB` already cached; if not, predict
conservatively (total minus ~2 GB) until a real measurement corrects it (see
Tiering formula below — the measured ceiling from `/api/ps` is ground truth,
a spec-based guess is a starting point only). Re-ask only when the user says
the hardware changed, or a fit prediction is repeatedly wrong by more than a
couple percent (a sign the cached usable-VRAM figure has drifted — something
else is now sharing the GPU, or it changed).

**This whole formula assumes a discrete GPU with its own fixed VRAM pool,
separate from system RAM.** That's true for NVIDIA/AMD discrete cards, but
**not** for unified-memory hardware (e.g. Apple Silicon), where there's no
separate "VRAM ceiling" to compute against — the constraint is total system
memory shared with everything else running. If the user reports unified
memory, say so plainly and don't force the tiering formula onto it; the fast
vs. slow distinction still applies conceptually (does it run at interactive
speed or not?) but the sizing math below doesn't transfer without rework.

## Tiering formula

For a model to be **fast tier** (fully GPU-resident, low latency), the whole
KV cache + weights must stay under the usable VRAM ceiling for the context
length you actually intend to use.

```
head_dim            = <arch>.embedding_length / <arch>.attention.head_count
kv_bytes_per_token   = 2 × block_count × head_count_kv × head_dim × bytes_per_elem
                       (2 = K and V; bytes_per_elem = 2 for ollama's f16 default KV)
total_bytes(ctx)     = BASE + SLOPE × ctx
SLOPE                = kv_bytes_per_token × 1.02        ← +2% correction, empirically needed
BASE                 = weights + fixed buffers          ← must be measured per model, not guessed
fully GPU-resident  ⟺ total_bytes(ctx) ≤ usable_VRAM
```

`ctx` = input + expected output tokens (KV cache grows during generation, not
just at prefill). **Never trust a model's advertised context length** — the
usable figure on a given card is frequently smaller, sometimes by design
margins as tight as ~1%.

**Get the architecture fields from `POST /api/show` → `.model_info`**, keyed
`<arch>.block_count`, `<arch>.attention.head_count`,
`<arch>.attention.head_count_kv`, `<arch>.embedding_length`. `key_length`/
`value_length` are typically absent — always derive `head_dim` from
`embedding_length / head_count`, don't assume a fixed value across families.
For MoE architectures the same fields apply for the attention/KV math — MoE
changes the *feed-forward* compute path (see Slow-tier evaluation below), not
the attention/KV sizing above.

**Fitting `BASE`/`SLOPE` for a new model**: run two generations at different
`num_ctx` values (comfortably below where you expect it to spill), read
`size`/`size_vram` from `/api/ps` during each, unload with `keep_alive: 0`
between probes. Two non-spilled points fit `BASE` and confirm `SLOPE` exactly
(linear in `ctx`); metadata alone over/under-predicts `SLOPE` by a couple of
percent (family-dependent — verify, don't assume the correction is universal).
A model whose *every* probe already spills has no valid `BASE`/`SLOPE` fit —
fall back to a weights-only comparison against the VRAM budget: if the raw
weight size alone doesn't clear the ceiling, no context length will ever work
and there's no need to chase a KV-level fit.

**Correct predictions with measurement, always.** After any real run, compare
predicted vs actual `size_vram`/`size` from `/api/ps` and write the corrected
verdict back (`slopeSource: "measured"` once two clean points exist). Treat a
single spill as evidence the ceiling might have moved (something else is
using the GPU right now), not proof the model can never fit — but don't
special-case it either; just re-measure.

## Slow-tier evaluation (CPU/RAM-bound, deliberate)

A model that doesn't clear the fast-tier bar isn't automatically worthless —
it may be worth keeping as a **deliberate, accept-minutes tier** for task
types the fast tier can't serve at all (large-input review, long agentic
loops), *if* it's actually usable at that speed. Decide this by measurement,
never by parameter count alone:

1. **Measure real decode tok/s**, not VRAM-residency percentage. Generate a
   realistic-length response (a few hundred tokens is enough to get a stable
   average) and compute `eval_count / (eval_duration / 1e9)` from
   `/api/generate`'s response. Do this both at the model's natural
   (ollama-chosen) GPU/CPU split and forced fully-CPU (`num_gpu: 0`) — if
   they're close, GPU offload isn't buying anything for this model and
   shouldn't factor into the recommendation.
2. **MoE architectures decode faster than their disk size suggests** —
   decode cost tracks *active* parameters per token
   (`expert_used_count × expert_feed_forward_length`-ish work), not total
   resident weights. A large MoE tag can be a *better* slow-tier candidate
   than a smaller dense model with more total parameters resident — check
   `model_info`'s `expert_count`/`expert_used_count` fields and don't
   dismiss a model on disk size alone before checking whether it's MoE.
3. **Compare against a usability floor, not a bare tok/s number.** A turn of
   realistic output length (roughly 500–1000 tokens — one review verdict, one
   agentic tool-call turn) should complete in **under ~2 minutes** to count
   as "usable as an emergency fallback." (This threshold is a judgment call,
   not a hard fact — revisit it if the user's tolerance turns out different
   in practice.) A candidate that misses this at realistic context lengths is
   not worth a slot, no matter how much more capable it looks on paper.
4. **Check RAM headroom, not just VRAM.** Weights that spill from VRAM run
   from system RAM — total footprint (weights + KV, computed the same way as
   the fast-tier formula above) needs to fit comfortably alongside a normal
   desktop session, with real headroom to spare, not just barely.
5. **This is a capability claim, not a quality one.** No local eval/benchmark
   is in scope here (that's a separate, larger effort) — a slow-tier pick
   should ship marked `assumed` for quality, `measured` for its throughput
   numbers. Don't conflate the two.

## Coverage gaps

Task types typically split into: quick/small edits, larger document
authoring, large-input document review, and agentic (many tool-call
round-trip) work — plus, orthogonally, whether a task needs tool-calling at
all. (Adjust this list to whatever task taxonomy the user's `preferences.json`
actually defines — this is a description of the shape, not a fixed list to
hardcode.) For each installed model, check:

- **Tool-calling capability** — required for any agentic use, check the
  model's declared capability (`/api/show` → `capabilities`/`tools`), never
  assume it from the family name.
- **Fast-tier context ceiling vs realistic task sizes** — a model fully
  GPU-resident only to a few thousand tokens covers small edits fine but not
  a real multi-file review; say so plainly rather than implying broader
  coverage than the ceiling supports.
- **Whether a slow tier exists for what the fast tier can't cover** — if nothing
  clears the slow-tier bar above, state plainly which task types simply
  cannot be served offline right now, rather than silently degrading to a
  bad match.

Report gaps as: *task type → served? by which tier → ceiling or floor that
limits it.* Don't editorialize beyond what the measured facts support.

## Recommending changes

**Pulls:** state the size before recommending, and **never pull without an
explicit go-ahead** — a multi-GB download is a real cost to flag, not a
silent action. Prefer a candidate that's architecturally distinct from what's
already installed (a same-architecture model at a different quant, or a
"coder-specialized" variant of an already-installed generalist, rarely earns
a second disk slot — check whether the manifest-reported weight bytes are
suspiciously close to an already-installed model's, which usually means
same-architecture-different-branding, not a real capability gain).

**Drops:** a model is a drop candidate when it clears neither the fast-tier
bar (doesn't fit VRAM at any useful context) nor the slow-tier bar (measured
decode throughput below the usability floor, or redundant with an
already-installed model that's equal or better on the same axis). State the
disk reclaimed. Don't recommend dropping a model that's the *only* thing
currently covering some task type, even a poorly-fitting one, without also
proposing a replacement — surfacing an unserved gap is better than silently
removing a fallback.

**Never add a second model in the same tier without a demonstrated gap** —
same architecture family, same size class, "might be better" is not a
reason; a measured or sourced advantage is.

## Refreshing

- Installed-model report (checklist steps 2–4): **no network needed** beyond
  the resolved ollama endpoint itself, which isn't the internet.
- Catalogue scan (looking for *new* candidates to fill a gap): hits
  `https://ollama.com/library` and `https://registry.ollama.ai/v2/...`
  manifests — real network calls, only on an explicit refresh, never recited
  from memory (the catalogue moves monthly; families you remember may be
  gone, and families that don't exist in memory may now be the best fit).
- The registry's manifest JSON gives you weight-blob **byte sizes** cheaply
  (no download). It does **not** give you `block_count`/`head_count`/etc. —
  that lives in the GGUF header inside the blob itself, which requires
  following a redirect to an object-storage host that may be blocked by your
  network's egress policy (corporate proxy, container firewall, etc.). If
  that redirect is blocked, say so plainly (it's a network-policy decision to
  fix outside this skill, not something to work around from here) rather
  than guessing the architecture fields.
- If a candidate's manifest-reported weight size matches an already-profiled
  model's to within a few dozen bytes, that's a strong signal they share the
  same architecture and parameter count (continued-pretraining variants do
  this) — the already-measured `fitFormula` can be inherited without a new
  probe, but say so explicitly rather than passing it off as independently
  measured.
- **If `OLLAMA_FLASH_ATTENTION` or `OLLAMA_KV_CACHE_TYPE` may have changed on
  the host** (ask the user — this skill can't reliably read host env vars if
  it's running somewhere other than the ollama host itself), check the
  cached `ollamaKvCacheAssumptions` fingerprint in `models.json` against what
  they report. A mismatch invalidates every ollama model's `slopeSource` back
  to `metadata_x1.02_unfitted` until re-measured — update the fingerprint and
  every affected entry together, don't leave them inconsistent.
