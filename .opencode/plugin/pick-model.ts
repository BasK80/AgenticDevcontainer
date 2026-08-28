// pick-model actuation plugin — the mechanical half of the pick-model skill.
//
// Why a plugin at all: a prose skill running shell commands cannot address
// the running opencode server (no discoverable port, no lock file, no
// OPENCODE_SERVER_URL — see .agents/skills/pick-model/assets/002-opencode-model-switching.md).
// A plugin gets `client` for free via PluginInput, so the actual switch has
// to live here.
//
// Why a tool, not a slash command: the ticket that specified this
// ("Registers a /pick-model slash command via PluginInput's client/serverUrl")
// turned out to be inconsistent with the real API surface once the actual
// SDK types were read — slash-command registration
// (api.command.register / api.keymap.registerLayer) only exists on the TUI
// plugin shape (TuiPluginApi), which is a different, undocumented export
// convention from the server Plugin shape that actually carries `client`.
// Exposing this as a tool instead uses only the documented, stable
// server-plugin API, and lets the pick-model skill call it directly in the
// same turn it decides a model — no separate manual slash-command step, no
// stale-file handoff.
//
// Why validation reads `client.config.providers()`, NOT `GET /api/model` —
// verified live against opencode 1.18.21 with real github-copilot credit
// spend, not assumed from docs or the .d.ts files:
//   - `GET /api/model` (the endpoint ticket 002's research and this ticket's
//     original plan both pointed at) reliably omits `github-copilot`
//     entirely on this version — confirmed on multiple freshly-started
//     servers, before AND after a real, successful completion through
//     `github-copilot/gpt-5.6-luna` on that exact same server process. Only
//     `opencode`(zen) and `ollama` ever appeared. This is not an auth or
//     activation-order issue — the provider is fully configured and usable
//     (the CLI's `-m github-copilot/...` and the raw switch endpoint both
//     work), `/api/model` just doesn't list it.
//   - `GET /config/providers` (exposed on the v1 client as
//     `client.config.providers()`) reliably lists all 25 github-copilot
//     models, including on a fresh server with zero prior activity. This is
//     the correct validation source; `/api/model` is not, at least for this
//     provider on this opencode version.
//   - Validating against the wrong source is worse than not validating at
//     all: it silently blocks every legitimate github-copilot switch while
//     looking like it "did the right thing." A dedicated round-trip test
//     with real credits (see ticket 011's resolution) is what caught this —
//     the earlier, ollama-only test could not have, because ollama happens
//     to appear correctly in both endpoints.
//
// Why `client._client.post`, not a typed `client.*` method, for the switch
// itself — also verified live: `PluginInput.client` is the v1 SDK client,
// which has no `session.switchModel` (that only exists on the newer
// `/api/*` routes). Plain `fetch(serverUrl + "/api/...")` fails every time
// with a generic "Unable to connect" from inside a tool call, even though
// the identical URL is reachable by `curl` from a shell at the same moment
// (a real self-connection limitation; an ordinary external fetch, e.g. to
// ollama, works fine from the same call). `client._client` is the generic,
// untyped transport the typed `client.*` methods are themselves built on
// (`_client` is TS-`protected`, not private — reachable at runtime since JS
// doesn't enforce that); it reaches `/api/*` routes without hitting the
// self-connection issue — confirmed with a real `204` that actually
// switched the session's model.
import { tool } from "@opencode-ai/plugin";

export const PickModelPlugin = async ({ client }) => {
  return {
    tool: {
      pickmodel_switch: tool({
        description:
          "Switch the current opencode session to a specific model. " +
          "Use this after pick-model's own reasoning has already chosen a " +
          "provider/model — this tool only performs the mechanical switch " +
          "and validates the model actually exists first (the raw " +
          "session-model API returns 204 and stores a bogus model/provider " +
          "silently, per ticket 002's finding).",
        args: {
          providerID: tool.schema
            .string()
            .describe("e.g. 'github-copilot' or 'ollama'"),
          id: tool.schema
            .string()
            .describe("model id, e.g. 'gpt-5.6-luna' or 'qwen2.5:7b'"),
          variant: tool.schema
            .string()
            .optional()
            .describe(
              "reasoning-effort variant if the provider supports one " +
                "(e.g. 'low'..'max'); omit for the provider default",
            ),
        },
        async execute({ providerID, id, variant }, context) {
          const { data: providersData, error: providersError } =
            await client.config.providers();
          if (providersError || !providersData) {
            return {
              output:
                "Could not fetch the live provider/model catalogue to " +
                `validate against: ${JSON.stringify(providersError)}. Not ` +
                "switching — the session-model API stores a bogus model " +
                "silently, so validation is not optional.",
            };
          }

          const provider = (providersData.providers ?? []).find(
            (p) => p.id === providerID,
          );
          if (!provider || !(id in (provider.models ?? {}))) {
            return {
              output:
                `No model '${id}' under provider '${providerID}' in the ` +
                "live catalogue — not switching. Check the id/providerID " +
                "(e.g. run pick-model's matching step again, or list " +
                "available models) rather than retrying the same call.",
            };
          }

          const switchResult = await client._client.post({
            url: `/api/session/${context.sessionID}/model`,
            body: { model: { providerID, id, variant } },
          });
          if (switchResult.error) {
            return {
              output: `Switch failed: ${JSON.stringify(switchResult.error)}`,
            };
          }

          return {
            output:
              `Switched this session to ${providerID}/${id}` +
              (variant ? ` (variant: ${variant})` : "") +
              ". Subsequent turns use this model.",
          };
        },
      }),
    },
  };
};

export default PickModelPlugin;
