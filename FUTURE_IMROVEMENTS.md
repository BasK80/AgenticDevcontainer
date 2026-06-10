# Future (possible) improvements
This document is a braindump of ideas for improvements that I get when using this container or get as feedback from other users. I've roughly sorted the ideas into maintainability, usability and security improvements.

## Maintainability
### Clean up the post-create & post-install logic for the development container
The current post-create.sh, post-install.sh and devcontainer.json have overlaping logic that was organically created to fix certain issues during development of this container. This needs some TLC to make this much more consistent and streamlined.

### Find a better place for the 'fw' tool
Currently the 'tools' folder only contains the fw tool, which is only useful on the host machine. Since the entire directory is mounted to the /workspace directory of the development container however, you now have a tool within that container that has no use there at all.  

## Usability
### More fine-grained .devcontainer mount
The .devcontainer directory is fully mounted read-only, so you cannot make any changes to the setup from within the agentic development container, that would become active after a rebuild. This is an important security feature, but it is a bit too broad, since most of the files in .devcontainer/development pose no security risk at all if they are edited by a user or agent and that would make life a lot easier. 

### Support for other agentic frameworks
The current version of this solution is fully focussed on claude code, but I would like to extend this with support for frameworks like opencode out of the box as well.

### Support for GitHub copilot SDK
The current setup works with an anthropic account, LLM's in Azure foundry or an Anthropic API key to either Anthropic itself or a third-party LLM gateway. In many organisations the preferred way to use LLM's is through GitHub copilot, so having out-of-the-box support for the copilot SDK would be a big improvement. 

### Skill/tool guide
I do not want to preload this image with skills or tools, since they are too volatile and would add a lot of maintenance overhead. It would be helpful however to add a guide on where to find good (Info Support) skills and tools and how to use them in the development container.

### Better 'boot' experience
When you currently open the container you have to manually open a terminal after the container has fully booted. This is counter-intuitive and should happen automatically.

### Add useful default linux tools
Right now I know I'm missing the 'ping' tool, but there are probably more tools that should be part of the base image. Since you have no root permissions within the development container, you can't simply install them as needed. Maybe also add a short section to the README on how to add new tools like this. 

## Security
### Run an automated test pentest from within the container
The goal of this solution is to have a secure environment where a rogue agent cannot harm anything outside of the container. I would like to test this by having an agent team try to find ways to bypass this security from within the container.
