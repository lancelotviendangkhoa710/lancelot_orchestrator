# Lancelot Orchestrator

**Author:** Viên Đăng Khoa

Lancelot Orchestrator coordinates Codex as the Master, OpenCode coding workers through 9Router, and a GPT-6 Luna testing role. Workers implement bounded tasks in separate Git worktrees. The Master reviews every diff and controls integration; changes are never merged automatically into `main`.

## Requirements

- Windows PowerShell, Git, OpenCode CLI, and Codex CLI.
- 9Router running locally at `http://127.0.0.1:20128/v1` with the configured Sonnet and Opus model IDs.
- Microsoft Edge for browser checks. Docker Desktop is needed for Compose checks.

## Setup

1. Copy `.env.example` to `.env` and set `NINEROUTER_API_KEY`. Keep `.env` private; it is ignored by Git.
2. Start 9Router, then launch OpenCode from this folder with `./start-opencode.ps1`.
3. To install the orchestration guidance into a project, run:

   ```powershell
   ./Install-KhoaAgent.ps1 -TargetRepo 'D:\path\to\team-repo'
   ```

   Start a new Codex session in that project to load the installed skill.

## Coding workflow

Use `Invoke-KhoaWorker.ps1` to dispatch a bounded task. Provide a JSON contract based on [`schemas/task-contract.schema.json`](schemas/task-contract.schema.json):

```powershell
./Invoke-KhoaWorker.ps1 `
  -RepoPath 'D:\path\to\team-repo' `
  -ContractPath '.\task.json' `
  -Model 'ninerouter/claude-sonnet-4-6'
```

The runner creates a branch and worktree under ignored `runs/`, records logs and metadata, checks changed paths against `allowed_paths`, and commits in-scope changes. A scope violation or model quota failure preserves the worktree for review. To try the other configured model once after a quota error, pass `-AllowModelFallback`; fallback occurs only when the worktree has no changes. Review the result before integration.

To integrate reviewed worker results, pass their `result.json` files to `Invoke-KhoaIntegration.ps1` in dependency order and provide at least one check. Checks must throw on failure or return a failing exit code; a Boolean `False` is treated as failure. The controller verifies each result came from a contract-enforced task, that its commit still matches, and that committed paths match the recorded allowlist. It creates a separate integration branch/worktree, cherry-picks sequentially, and resets that disposable worktree to its initial SHA if integration fails. It never updates `main`.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for isolation, planning, recovery, and quality gate design. Git worktrees separate code changes but do not provide an OS security boundary. OpenCode worker configuration denies shell and MCP access; use a separate OS or container boundary for untrusted tasks.

## Testing and browser checks

The GPT-6 Luna testing instructions are in [`prompts/testing-agent.md`](prompts/testing-agent.md), with output described by [`schemas/test-report.schema.json`](schemas/test-report.schema.json). Verify the model route and available tools before relying on the testing role. Run tests against the integration worktree and report unavailable checks as blocked.

OpenCode uses Microsoft's Playwright MCP with headless Microsoft Edge, isolated browser state, and DevTools diagnostics. Codex MCP configuration is per user machine; add it once on each machine:

```powershell
codex mcp add playwright -- cmd /c npx -y @playwright/mcp@0.0.85 --headless --isolated --browser msedge --caps devtools --console-level error
```

For UI changes, exercise the real user flow, check validation and API behavior, inspect console errors, and capture diagnostics on failure. HTTP 200 alone is not a functional test.

## Docker and Supabase

`Invoke-ComposeCheck.ps1` validates Compose configuration, builds and starts services under a unique project name, waits for service health, and can poll an HTTP readiness endpoint. It preserves resources and does not remove volumes or containers.

Configure Supabase MCP only in repositories that use Supabase. For Edge Function changes, test on an explicitly designated non-production Supabase project: deploy the affected function there, invoke its remote endpoint, and record assertions and logs. Do not use the production project as a test target.

## Smoke test

Run the worker dispatch, scope enforcement, permission, report, and quota fallback smoke checks with:

```powershell
./tests/worker-smoke.ps1
```
