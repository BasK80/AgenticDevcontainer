# Future (possible) improvements
This document is a braindump of ideas for improvements that I get when using this container or get as feedback from other users. I've roughly sorted the ideas into maintainability, usability and security improvements.

## Maintainability
### Clean up the post-create & post-install logic for the development container
The current post-create.sh, post-install.sh and devcontainer.json have overlaping logic that was organically created to fix certain issues during development of this container. This needs some TLC to make this much more consistent and streamlined.

### ~~Remove the logic of the 'fw' tool~~ ✅ Done
~~Remove the fw tool, it's logic is already better provided by the web ui in the control container. Make the logic provided by the fw tool more easily available on the firewall container itself and update the description in the README on how to work without the control container to use this new tooling in the firewall container.~~

`tools/fw` has been removed. A native `fw` script now lives directly on the firewall container (`/usr/local/bin/fw`) and supports `allow`, `deny`, `list`, `blocks`, and `log`. README and USAGE both document `docker exec "$FW" fw <command>` as the management interface.

## Usability
### More fine-grained .devcontainer mount
The .devcontainer directory is fully mounted read-only, so you cannot make any changes to the setup from within the agentic development container, that would become active after a rebuild. This is an important security feature, but it is a bit too broad, since most of the files in .devcontainer/development pose no security risk at all if they are edited by a user or agent and that would make life a lot easier. 

### Support for copilot cli
The current version of this solution is fully focussed on claude code, but I would like to extend this with support to copilot cli out of the box as well. The scripts that switch between backend llm providers should support set up the environment for both claude and copilot cli where possible and if a provider can only be used with either claude or copilot, then the switch script should state this clearly. 

### Support for opencode
Same story as for the copilot cli, but with opencode.

### Support for GitHub copilot SDK
The current setup works with an anthropic account, LLM's in Azure foundry or an Anthropic API key to either Anthropic itself or a third-party LLM gateway. In many organisations the preferred way to use LLM's is through GitHub copilot, so having out-of-the-box support for the copilot SDK would be a big improvement. 

### Skill/tool guide
I do not want to preload this image with skills or tools, since they are too volatile and would add a lot of maintenance overhead. It would be helpful however to add a guide on where to find good (Info Support) skills and tools and how to use them in the development container.

### Better 'boot' experience
When you currently open the container you have to manually open a terminal after the container has fully booted. This is counter-intuitive and should happen automatically.

### Add useful default linux tools
Right now I know I'm missing the 'ping' tool, but there are probably more tools that should be part of the base image. Since you have no root permissions within the development container, you can't simply install them as needed. Maybe also add a short section to the README on how to add new tools like this. 

### Firewall-aware AI tools
When an AI tool tries to reach a domain that is blocked by the firewall, it currently receives a generic network error. The tool has no way to distinguish "this domain doesn't exist" from "this domain is blocked by a firewall". As a result, the tool may retry, suggest workarounds, or report a confusing error to the user instead of simply saying "this domain is not on the allowlist — add it via the control UI or the firewall container". Ideally the tools would be made aware that they are running behind a firewall, so they can give the user a clear and actionable message. Possible approaches: set a system prompt addition that explains the network topology and how to request allowlist changes, configure a custom Squid error page that includes allowlist instructions (visible when the tool follows a redirect or renders HTML), or provide a small wrapper/hook that intercepts CONNECT-denied responses and prepends a human-readable explanation before surfacing the error to the model.

## Security
### Better control over the firewall allowlist.default
The current allowlist is too large. I would like to have be able to enable certain features in the devcontainer that describe how it will be used, for example if we need npm packages, or access to Azure. This should correspond to the corresponding domains being added to the default allowlist. Note: this feature should be further refined when being implemented, since the devcontainer.json might not be the best place for this. I can imagine that it would be extremely nice to be able to configure this from the control webui, either permanently or temporarily (like with individual domains), but in that case we would need a corresponding fallback in the firewall container itself.

### Run an automated test pentest from within the container
The goal of this solution is to have a secure environment where a rogue agent cannot harm anything outside of the container. I would like to test this by having an agent team try to find ways to bypass this security from within the container.
