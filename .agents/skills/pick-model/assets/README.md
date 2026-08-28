# pick-model — bundled research assets

These four documents are the *why* behind the method in `../REFERENCE.md`.
They were produced in the `ModelSwitcher` spin-off repo (a `wayfinder`-tracked
investigation) and are copied here verbatim so the skill is self-contained in
this template — no dependency on that repo's `.wayfinder/` tracker.

| File | What it establishes |
| --- | --- |
| `005-taxonomy-and-routing.md` | The task taxonomy and the routing policy `pick-model` implements. Read this first. |
| `002-opencode-model-switching.md` | How opencode can switch its own model mid-session — the basis for the `pickmodel_switch` plugin. |
| `006-offline-detection.md` | How to tell a firewall block apart from genuine loss of network, so local fallback only fires when it should. |
| `015-seat-type-and-credit-balance.md` | Why the remaining credit balance cannot be read programmatically here, and what the skill asks for instead. |

Cross-references that pointed at documents outside this set were flattened to
plain text when copied, so no link here dangles. Dates and figures inside are
snapshots from the original investigation — trust `../seed/*.json` and live
re-verification over anything stated in prose.
