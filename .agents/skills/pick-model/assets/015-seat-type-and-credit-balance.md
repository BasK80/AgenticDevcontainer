---
id: 015
title: Establish Bas's seat type and how to read the remaining AI credit pool
label: wayfinder:task
status: closed
assignee: Bas Kloet
blocked_by: []
---

## ⚠ Re-scoped 2026-08-24 (from ticket 007)

This ticket originally bundled two questions of very different difficulty.
**Un-conflated:**

1. **Seat type / monthly allowance** (Business=1900, Enterprise=3900) — a
   near-constant Bas can simply state. **This is no longer this ticket's
   concern**: `pick-model` self-serves it directly into
   `hardware.json.creditAllowance` on first need, exactly like `ollama-curate`
   self-serves hardware specs. See
   the data schema asset. This is *why*
   Write the pick-model skill is **not** blocked on
   this ticket.
2. **Reading the remaining live balance** — genuinely hard, may need admin
   rights Bas doesn't have. **This is what remains in scope here.**

## Question

**How is the remaining pool read** — the harder half, now the only thing this
ticket covers (seat type is self-served elsewhere, see above).

Credits are pooled at the billing-entity level across all licenses, so Bas's
personal usage is not the whole picture — the pool can be drained by colleagues.
Establish whether there is:
   - a REST endpoint for enterprise/org Copilot usage or billing that Bas has
     permission to call (he may not be an enterprise admin),
   - a per-user view he can always reach, or
   - only an admin-only settings page.

If only an admin page exists, say so plainly — the skill then ranks by relative
cost and cannot show remaining budget. That is an acceptable outcome; a wrong
budget number would be worse than none.

## Why it does not block the router

Ranking models by credit cost works without knowing the balance. Showing
remaining budget is a **degradable enhancement**, so
Write the pick-model skill is deliberately *not*
blocked on this. Resolve it if it is cheap; skip it if it needs admin rights Bas
does not have.

## Notes

- Overage is **not** a service cutoff — usage beyond the pool is billed at $0.01
  per credit. So "out of credits" means "now costing real money", which is
  arguably a *more* important thing for the skill to surface than a hard limit.
- Context: the credit-cost asset.
- Auth is already in place (see ticket 003); `gh` is authenticated for
  `info-support.ghe.com` via the Copilot CLI login.

## Resolution (2026-08-25)

**Correction to the note above: `gh` is not actually authenticated in this
container** (`gh auth status` → not logged in to any host; no `~/.config/gh`).
The `copilot` CLI and opencode's `github-copilot` OAuth are separate,
Copilot-scoped credentials — neither is a general GitHub REST API token, so
neither could be reused to call the billing endpoints below. Noted for
accuracy; doesn't block the answer, which came from GitHub's docs plus one
direct question to Bas.

**The pool-level balance is genuinely out of reach — as the ticket
anticipated, and now confirmed rather than assumed.** GitHub's REST billing
API (`docs.github.com/en/enterprise-cloud@latest/rest/billing/usage`) has
`GET /enterprises/{enterprise}/settings/billing/ai_credit/usage` and the
equivalent `/organizations/{org}/settings/billing/ai_credit/usage`, but both
explicitly require "administrator or billing manager of the enterprise [or
organization], or a custom role holder with fine-grained read access to
billing." **Bas confirmed he is a regular member, not an org/enterprise
admin or billing manager** — so this half is unreachable for him specifically,
not just unreachable in theory. `pick-model` cannot show remaining shared-pool
budget; it ranks by relative cost only (tickets 013/014), which the ticket
already flagged as an acceptable outcome.

**But there is a third option the ticket didn't anticipate: a per-user
endpoint, confirmed reachable with no special role — via a live check, not
just doc-reading.** `GET /users/{username}/settings/billing/ai_credit/usage`
exists (`docs.github.com/en/rest/billing/usage`; "Gets a report of AI credit
usage for a user," data for the past 24 months, filterable by
year/month/day/model/product) — but the doc page's rendered text does **not**
state a permission requirement for it one way or the other (checked twice,
carefully, quoting verbatim; no "Fine-grained access tokens" box came through
in the fetched content, unlike the org/enterprise versions which explicitly
say "administrator or billing manager"). A June 2026 changelog adding an
`ai_credits_used` field looked like corroboration at first but turned out to
be a **different, still admin-gated API** (`copilot/metrics/reports/users-*`,
explicitly "available to enterprise administrators and organization owners")
— a red herring, not evidence for this endpoint. So doc-reading alone left
this genuinely ambiguous.

**Resolved empirically instead, per the ticket's own suggested fallback:**
asked Bas directly whether the GitHub web UI shows him any AI-credit-usage
numbers for himself. **It does** — he can see his own usage as a regular
member, no admin/billing access needed. That's a live, first-hand
confirmation that per-user consumption is genuinely self-serve for him,
independent of whatever the API's undocumented permission model turns out to
require. (`docs.github.com/en/billing/reference/billing-reports` separately
describes a web-only "detailed usage report," up to 31 days, broken down by
date/model/token-type — likely what Bas saw; whether the REST endpoint above
returns the identical data was not tested with a live API call, since no
properly-scoped GitHub token was available in this container — `gh` is not
authenticated here and the Copilot-CLI/opencode tokens are scoped to Copilot
chat, not the general REST API.)

**Answer to the ticket's question:** no readable "remaining pool" exists for
a regular member — confirmed both by the docs' explicit admin/billing-manager
requirement and by Bas's own role. A readable "my own recent consumption"
does exist, confirmed live via the web UI (the REST endpoint's own permission
model is undocumented in the fetched page text, so treat the API route as
*probably* self-serve, not proven at the API layer specifically).
`pick-model` should treat personal usage as an **optional, degradable
enhancement** — useful context ("you've used ~X credits recently"), not a
substitute for the pool balance the ticket originally asked about. Wiring it
up would need `gh auth login` (or another properly-scoped token) done live,
plus a real call to confirm the API matches the UI — neither was attempted
here since it's out of this ticket's scope (establishing *whether* a signal
exists, not building the skill that reads it) — flagged for
Write the pick-model skill to pick up or skip.

**Sources:** `docs.github.com/en/enterprise-cloud@latest/rest/billing/usage`,
`docs.github.com/en/rest/billing/usage`, `docs.github.com/en/billing/reference/billing-reports`,
[GitHub changelog: AI credits consumed per user now in the Copilot usage
metrics API](https://github.blog/changelog/2026-06-19-ai-credits-consumed-per-user-now-in-the-copilot-usage-metrics-api/)
(fetched directly once Bas allowlisted `github.blog` mid-session — confirms
the *metrics* API's per-user `ai_credits_used` field is enterprise-admin/org-owner-gated,
a different API from the billing endpoint above, not corroboration for it).
Plus one direct, live confirmation from Bas about his own web-UI access.
Captured 2026-08-25 — this is dated billing-API surface that changed as
recently as June 2026; re-check before trusting past a few weeks stale.

## Update (2026-08-25, from ticket 012's live verification)

Independently reconfirmed the "no programmatic remaining-balance check"
finding above, from the API side rather than the docs side: with a real,
working `github-copilot` OAuth token (confirmed working against
`GET /user`), `GET /users/BasKL/settings/billing/ai_credit/usage` (and the
`/usage`, `/usage/summary` variants) on `api.info-support.ghe.com` all
returned a clean `404` — distinct in character from a real scope-permission
`403` (compare `/user/orgs`'s explicit "need read:org scope" response on
the same token). Reads as "not implemented on this GHE Data Residency
tenant," not "blocked by scope." Also surfaced, separately, that the
*allowance* half this ticket deliberately left to `pick-model`'s self-serve
(seat type → `monthlyCredits`) has its own gap: it doesn't hold when credits
are pooled across multiple licenses, which is Bas's actual situation
(15,000 pooled, not the single-seat 3,900) — corrected in `hardware.json`,
detail in ticket 012.
