# opencode model switching — verified live

Tested **2026-08-24** against opencode **1.18.21** (SDK 1.18.18), by running
`opencode serve --port 47821` locally and exercising the HTTP API. Asset of
[Determine whether opencode can switch its own model mid-session](002-opencode-model-switching.md).

No model prompts were sent, so **no credits were spent**. The probe session was
deleted and the server stopped afterwards.

## Answer: yes, mid-session switching is fully supported

```
POST /api/session/{sessionID}/model
Content-Type: application/json

{"model": {"providerID": "github-copilot", "id": "gpt-5.6-luna", "variant": "high"}}
→ 204 No Content
```

The spec's own words: *"Switch session model — **Switch the model used by
subsequent provider turns**."* Verified by reading the session back:

```json
{"id":"gpt-5.6-luna","providerID":"github-copilot","variant":"default"}
```

`ModelRef` is a **structured object**, not a `provider/model` string:

```ts
type ModelRef = { id: string; providerID: string; variant?: string }
```

Note the CLI's `-m provider/model` string form (used by
`tools/test-opencode-providers.sh`) is a *different* surface. The API takes fields.

**`variant` works and persists** — set `claude-sonnet-5` with `variant: "high"`,
read back as `"high"`. Omitting it yields `"default"`. This is the
reasoning-effort lever from the credit-cost work,
now confirmed as directly settable per session.

## ⚠ The API does not validate that the model exists

This is the finding that most affects the implementation.

| Request | Result |
| --- | --- |
| `{"model":{"providerID":"github-copilot","id":"gpt-5.6-luna"}}` | 204, stored |
| `{"model":{"providerID":"github-copilot","id":"no-such-model-xyz"}}` | **204, stored** |
| `{"model":{"providerID":"nope","id":"nope"}}` | **204, stored** |
| `{}` (missing `model`) | 400 `InvalidRequestError: Missing key at ["model"]` |

Body *shape* is validated; model *existence* is not. A bogus switch succeeds
silently and the session is left pointing at a model that only fails at the next
prompt — by which time the cause is far from the symptom.

**So `pick-model` must validate against `GET /api/model` before switching.** A
204 is not evidence the model is real.

## Relevant routes

| Route | Method | Use |
| --- | --- | --- |
| `/api/session/{sessionID}/model` | POST | **switch the model** |
| `/api/session/active` | GET | *"foreground Session drains currently owned by this OpenCode process"* — discover the live session |
| `/api/model` | GET | full model catalogue for authenticated providers |
| `/api/session/{sessionID}` | GET | read back `model`, `cost`, `tokens` |
| `/config`, `/global/config` | GET, **PATCH** | config is patchable over HTTP — no file editing needed |
| `/api/skill`, `/skill` | GET | skills listing (read-only) |
| `/tui/open-models` | POST | opens the interactive picker — the fallback if a direct switch is unwanted |
| `/doc` | GET | the full OpenAPI spec (478 KB), authoritative |

**`GET /api/model` returns per entry:** `api, capabilities, cost, family,
headers, id, limit, name, options, providerID, release_date, status, variants` —
the same shape as `opencode models --verbose`, **including `cost`**. So the server
API can supply the catalogue directly, and parsing CLI text output is unnecessary
when a server is reachable.

## The real constraint: how does the caller reach the server?

Switching is easy; *addressing* the server is the actual design question.

- **A plugin gets it for free.** `PluginInput` provides `serverUrl: URL` and a
  typed `client`, plus `project`, `directory`, `worktree` and a Bun shell `$`.
- **A plugin can register a slash command.** The TUI command type includes
  `slash?: { name: string; aliases?: string[] }` with an `onSelect` handler — so
  `/pick-model` can be a real slash command with full client access. (The v1
  `api.command` shape is deprecated in favour of
  `api.keymap.registerLayer({ commands, bindings })`.)
- **A prose skill running shell commands cannot easily find the server.** There is
  **no `OPENCODE_SERVER_URL` env var** (only `OPENCODE_SERVER_USERNAME` /
  `OPENCODE_SERVER_PASSWORD` for auth, and `OPENCODE_PID`), **no port or lock
  file** anywhere under `~/.local/share/opencode`, and `--port` defaults to `0`
  (random). `opencode.db` holds session tables but no server address.

**Therefore the opencode half of `pick-model` should be a plugin, not a prose
skill** — that is the only path that gets `serverUrl` and a client without
guesswork. Recorded against
Decide how skills are packaged, which owns
the packaging decision.

## Question 2 from the ticket, answered differently than asked

The ticket asked whether writing `opencode.json` takes effect on the next message
or only in a fresh session. **The question is now moot** and I did not test it:
config is patchable via `PATCH /config`, and the model is settable directly per
session, so file-editing is the wrong mechanism either way.

Worth noting for provider wiring:
`~/.config/opencode/opencode.json` is still `{"provider": {}}` even after Bas's
successful Copilot login — **the credential lives in `auth.json` and providers are
discovered from it**, so a provider stanza is not required for Copilot to work.
That materially reduces the `llm-switch.sh` collision risk, since there may be
nothing in `provider` worth protecting.

## Incidental findings for other tickets

Extracted from the binary's env-var table (`strings`) and the OpenAPI spec:

- **`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`** — opencode **natively reads Claude
  Code skills**. There are also `OPENCODE_DISABLE_EXTERNAL_SKILLS`,
  `OPENCODE_SKILL_DESCRIPTION`, `OPENCODE_DISABLE_CLAUDE_CODE`, and a `/api/skill`
  route. Strong evidence for
  Decide how skills are packaged: a single
  Claude-Code-format skill may be read by opencode directly.
- **`OPENCODE_DISABLE_MODELS_FETCH`, `OPENCODE_MODELS_PATH`,
  `OPENCODE_MODELS_URL`** — control over where the model catalogue comes from,
  including a local path. Directly useful for
  [offline detection](006-offline-detection.md) and the offline-first
  invariant: the catalogue can be pinned locally rather than fetched.
- **The server is unsecured by default** — it warns
  `OPENCODE_SERVER_PASSWORD is not set; server is unsecured`. Anything that starts
  a long-lived server in this container should set it.

## Reproduction

```sh
opencode serve --port 47821 --hostname 127.0.0.1 &
B=http://127.0.0.1:47821
SID=$(curl -s -X POST $B/api/session -H 'content-type: application/json' \
        -d '{"title":"probe"}' | jq -r .id)
curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/api/session/$SID/model \
  -H 'content-type: application/json' \
  -d '{"model":{"providerID":"github-copilot","id":"gpt-5.6-luna"}}'   # → 204
curl -s $B/api/session/$SID | jq .data.model
curl -s -X DELETE $B/api/session/$SID
```
