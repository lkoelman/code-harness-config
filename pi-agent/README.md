
# Installation

```bash
# copy settings file
mv ~/.pi/agent/settings.{json,old.json}
cp code-harness-config/pi-agent/settings.json ~/.pi/agent/settings.json

# link agent definitions
ln -s ~/.pi/agents/agents code-harness-config/pi-agent/agents
```

# Skills

See https://pi.dev/docs/latest/skills#locations

The bundled [settings.json](settings.json) configures pi-agent to use skills from the claude and codex harness. So if you install codex skills from this repository, they will be available in pi-agent.

# Agent Definitions

Agent definitions for the [pi-subagents package](https://pi.dev/packages/pi-subagents). Agents definitions must conform to markdown format in https://github.com/nicobailon/pi-subagents/tree/main/agents

Useful sources for agent definitions:
- [Codex CLI Plan Mode](https://github.com/openai/codex/blob/main/codex-rs/collaboration-mode-templates/templates/plan.md)

Usage:
- see https://github.com/nicobailon/pi-subagents/tree/main#common-workflows and https://github.com/nicobailon/pi-subagents/tree/main#direct-commands
- e.g. prompt `use <agent-name> to do X`
- e.g. `/run <agent> [task-description]`