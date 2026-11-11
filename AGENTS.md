# Khoa Agent defaults

- Load and follow the `$master-worker` skill for multi-agent, delegation, parallel worker, or `/goal` requests.
- Unless the user explicitly asks for Codex-native subagents, interpret “subagents” and “workers” as **OpenCode subagents through the configured 9Router model**. Do not silently substitute the Codex-native subagent system.
- If OpenCode/9Router cannot run, explain the blocker and ask before changing the requested agent provider.
- The Codex Master owns planning, review, testing, integration, and final acceptance. OpenCode workers do not merge, push, or deploy.
