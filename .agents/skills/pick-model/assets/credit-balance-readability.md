# Reading the remaining AI credit balance — what is and isn't available

Established **2026-08-25** against GitHub Enterprise Cloud / GHE, from the
billing API docs plus a live check with a real token. This is the finding
behind `pick-model`'s decision to rank models by *relative* cost and never
promise a remaining-budget figure.

Two questions of very different difficulty are easy to conflate here, so keep
them apart:

1. **Seat type / monthly allowance** — a near-constant the user can simply
   state. `pick-model` self-serves this into
   `hardware.json.creditAllowance` on first need, the same way `ollama-curate`
   self-serves hardware specs. Not hard, not covered further here.
2. **The remaining live balance** — genuinely hard, and the subject of this
   document.

## The pool-level balance is out of reach for a regular member

Credits are pooled at the billing-entity level across all licenses, so any one
person's usage is not the whole picture — the pool can be drained by
colleagues.

GitHub's REST billing API
(`docs.github.com/en/enterprise-cloud@latest/rest/billing/usage`) exposes
`GET /enterprises/{enterprise}/settings/billing/ai_credit/usage` and the
equivalent `/organizations/{org}/settings/billing/ai_credit/usage`, but both
explicitly require "administrator or billing manager of the enterprise [or
organization], or a custom role holder with fine-grained read access to
billing."

**Confirmed against a regular member account** — not an org/enterprise admin
or billing manager — so this is unreachable in practice, not just in theory.

> A wrong budget number would be worse than none. Where the balance can't be
> read, say so plainly and rank by relative cost instead.

## A per-user endpoint exists, but is unproven at the API layer

`GET /users/{username}/settings/billing/ai_credit/usage` exists
(`docs.github.com/en/rest/billing/usage`; "Gets a report of AI credit usage for
a user," data for the past 24 months, filterable by
year/month/day/model/product). The doc page's rendered text does **not** state
a permission requirement either way — checked twice, verbatim; no
"Fine-grained access tokens" box came through in the fetched content, unlike
the org/enterprise versions which explicitly say "administrator or billing
manager."

A June 2026 changelog adding an `ai_credits_used` field looked like
corroboration but is a **different, still admin-gated API**
(`copilot/metrics/reports/users-*`, explicitly "available to enterprise
administrators and organization owners") — a red herring.

**Resolved empirically instead.** A regular member confirmed the GitHub web UI
does show them their own AI-credit-usage numbers, with no admin or billing
access. `docs.github.com/en/billing/reference/billing-reports` separately
describes a web-only "detailed usage report" (up to 31 days, broken down by
date/model/token-type) — likely what was seen. Whether the REST endpoint
returns the identical data was not tested, because no properly-scoped GitHub
token was available: `gh` is not authenticated in this container, and the
Copilot CLI / opencode `github-copilot` OAuth credentials are Copilot-scoped,
not general REST API tokens.

## On GHE Data Residency, the endpoint isn't there at all

Independently reconfirmed from the API side. With a real, working
`github-copilot` OAuth token (verified against `GET /user`),
`GET /users/{username}/settings/billing/ai_credit/usage` — and the `/usage`
and `/usage/summary` variants — on the enterprise's
`api.<tenant>.ghe.com` host all returned a clean **`404`**. That is distinct in
character from a real scope-permission `403` (compare `/user/orgs`, which
returns an explicit "need read:org scope" on the same token). Reads as "not
implemented on this GHE Data Residency tenant," not "blocked by scope."

## What this means for `pick-model`

- **No remaining-pool figure.** Rank by relative cost and express thresholds as
  a percentage of the cached `monthlyCredits`, never as remaining budget.
- **Personal usage is an optional, degradable enhancement** — useful context
  ("you've used ~X credits recently"), not a substitute for the pool balance.
  Wiring it up needs `gh auth login` (or another properly-scoped token) plus a
  live call to confirm the API matches the UI. Skip it if that isn't cheap.
- **The seat-type self-serve has its own gap:** "seat type → `monthlyCredits`"
  does not hold when credits are pooled across multiple licenses. The account
  this skill's seed data came from has 15,000 pooled credits, not the
  single-seat Enterprise 3,900. Ask for the actual pooled figure; don't derive
  it from seat type alone.
- **Overage is not a cutoff.** Usage beyond the pool bills at $0.01 per credit,
  so "out of credits" means "now costing real money" — arguably more important
  to surface than a hard limit would be.

**Sources:** `docs.github.com/en/enterprise-cloud@latest/rest/billing/usage`,
`docs.github.com/en/rest/billing/usage`,
`docs.github.com/en/billing/reference/billing-reports`,
[GitHub changelog: AI credits consumed per user now in the Copilot usage
metrics API](https://github.blog/changelog/2026-06-19-ai-credits-consumed-per-user-now-in-the-copilot-usage-metrics-api/).

Captured 2026-08-25. This is dated billing-API surface that changed as recently
as June 2026 — re-check before trusting it more than a few weeks stale.
