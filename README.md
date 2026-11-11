# Khoa Agent

Codex is the Master. It plans and delegates bounded coding tasks to OpenCode CLI, which uses the configured 9Router model. Codex reviews every Worker diff and runs the target repository's quality gates before integration.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the production isolation, task planning, merge control, and recovery requirements. Those controls are design requirements; the current launcher does not implement them yet.

## Setup

1. Install OpenCode CLI and Git on the machine that runs Codex.
2. Start 9Router and confirm the worker model IDs are available at `/v1/models`.
3. Copy `.env.example` to `.env` and add `NINEROUTER_API_KEY`.
4. Keep `.env` local. The folder ignores it and stores worker logs under ignored `runs/`.
5. Launch OpenCode from this folder with `./start-opencode.ps1` to check or switch models.

To carry the Codex defaults into another Git repo, run this installer:

```powershell
./Install-KhoaAgent.ps1 -TargetRepo 'D:\path\to\team-repo'
```

It copies the repo skill and appends a marked Khoa Agent section to the target `AGENTS.md`; it refuses to overwrite an existing skill or duplicate a managed section. Start a new Codex session from the target repo so it loads the instructions and skill. OpenCode worker runs point explicitly to this package's `opencode.jsonc` and `.env`, so the endpoint config does not need to be copied into every repo. Keep this `Khoa_agent` package in a stable shared location for the team.

The project config defines `ninerouter/claude-sonnet-4-6` and `ninerouter/claude-opus-4-6-thinking`. Select with `/models` in the TUI, or pass a model ID to the worker script.

## Delegate one task

From this folder, run:

```powershell
./Invoke-KhoaWorker.ps1 `
  -RepoPath 'D:\path\to\target-repo' `
  -Task 'Implement the bounded task and report changed files and checks.' `
  -Model 'ninerouter/claude-sonnet-4-6'
```

The script creates a task branch and Git worktree under `runs/`, starts one OpenCode run, and saves its output and metadata there. It leaves the worktree intact for review. For new tasks, pass `-ContractPath` pointing to a JSON Task Contract matching `schemas/task-contract.schema.json`. The controller checks changed paths against `allowed_paths` and commits only in-scope work; an out-of-scope edit is retained for review and marked `scope_failed`. The worker gets a generated OpenCode config without MCP servers and with shell and external-directory tool calls denied. This tool policy is not an OS sandbox; only use `-AutoApprove` within a separately verified isolation boundary.

The integration gate is `Invoke-KhoaIntegration.ps1`: pass reviewed worker `result.json` paths in dependency order. It verifies the worker commits and shared base, creates a separate integration branch/worktree, cherry-picks sequentially, and runs explicit checks. It records logs and stops on a conflict or failed check. The Master must review each worker before supplying its result to this script. It does not update main.

The testing role is specified in `prompts/testing-agent.md` and its output schema is `schemas/test-report.schema.json`. GPT-6 Luna responded successfully through the local Codex CLI with `-m gpt-6-luna --sandbox read-only`. That probe confirms model routing, not Docker or browser tool access. Docker Engine was unavailable during inspection, and Codex's current MCP list had no Playwright server. Automated Luna test dispatch and report validation are not yet implemented; the integration script's explicit checks are the available gate until they are. Keep Master review before integration and manual acceptance after it.

## Team workflow

Use the `$master-worker` Codex skill in this folder. When the user asks for subagents without specifying a provider, OpenCode subagents through 9Router are the default; Codex-native subagents are used only when explicitly requested. Codex decomposes the request and delegates implementation tasks through `Invoke-KhoaWorker.ps1`. Each coding task gets a separate worktree. Avoid parallel tasks that edit the same files or depend on each other's unmerged changes.

Before accepting a Worker result, Codex must:

1. Inspect the Worker's report and full diff.
2. Check scope, secrets, dependencies, and architecture conventions.
3. Run the target repo's documented lint, type, unit, and integration checks as applicable.
4. Fix or redelegate bounded issues; cap correction rounds at two.
5. Integrate accepted changes deliberately and rerun relevant checks.

LLM review supplements automated checks; it does not replace them. If tests are unavailable or fail, report that instead of marking the task verified.

## Task contract

Give each Worker a specific goal, allowed paths, acceptance criteria, and checks. A Worker report should include status, summary, changed files, tests run and results, known risks, and the worktree path. Codex owns final acceptance.

## Security notes

- `.env` contains the local router key; do not share or commit it.
- Workers need only the router API key, not upstream provider credentials.
- A Git worktree isolates changes, not OS permissions. Run Workers with least privilege and an appropriate OS/container boundary for untrusted repositories.
- Keep task scope and concurrency small; inspect commands and diffs before integration.
- The worker script defaults to approval-aware execution. `-AutoApprove` explicitly opts into unattended tool execution.

## Docker Compose checks

`Invoke-ComposeCheck.ps1` checks Docker Engine, selects the only standard Compose file at the repository root (or accepts explicit `-ComposeFile`), validates the file, builds and starts services under a unique Compose project name, waits for health, and optionally polls a real HTTP URL and expected response text. It captures `ps` and relevant logs on failures. It never runs `down`, `rm`, `prune`, or volume deletion. External volumes/networks and bind mounts outside the worker repo are refused by default.

```powershell
./Invoke-ComposeCheck.ps1 -RepoPath 'D:\path\to\repo' -ReadyUrl 'http://127.0.0.1:3000/health' -ExpectedText 'ok'
```

Use service `healthcheck` definitions in Compose. Readiness uses condition polling, not a fixed startup sleep. Review Compose first: fixed host ports can conflict, and application environment variables can still point at a shared database.

## Browser checks

OpenCode config includes Microsoft's Playwright MCP pinned to `@playwright/mcp@0.0.85`, headless Microsoft Edge, isolated browser state, and DevTools for console/network diagnostics. Start OpenCode from this folder and check `/mcp` if it did not connect. First run may need network access to fetch the package.

For UI work, require a functional E2E flow: navigate, interact, submit forms, assert the expected state and validation, inspect failed API requests and console errors, and check a mobile viewport when layout changes. Capture a screenshot and relevant diagnostics on failure. HTTP 200 alone is insufficient. Prefer checked-in `@playwright/test` for repeatable CI gates; MCP interaction complements those tests. Playwright MCP is not a security boundary.

## Supabase MCP and Edge Function checks

Supabase is opt-in per target repository. Do not add its MCP server to this package's shared/default MCP set. Configure it only in a repository that uses Supabase, scope the remote MCP URL to that project's `project_ref`, and use read-only mode for inspection tasks. Keep OAuth credentials and CLI access out of committed files.

For Edge Function changes, combine static/unit checks with a deployed Edge smoke/E2E check when the target repo has an explicitly configured non-production Supabase test project. Deploy only the affected function to that test project, invoke its real Edge URL with test inputs, and assert status, response body, and relevant side effects. Collect function logs on failure. Never infer that local `functions serve` proves the deployed Edge behavior.

The Edge test target must be explicit and verifiably non-production (for example, a dedicated project ref or branch); do not rely on whichever project happens to be linked in the CLI. Do not deploy to production or change remote secrets, schema, or data as part of a test. If no safe Edge target is configured, report that remote Edge verification is blocked and run the available local checks instead. The user's preference is to test on Edge when such a test target is configured; it does not authorize production deployment or destructive remote changes.

The Playwright MCP definition is packaged in opencode.jsonc, so OpenCode workers use Microsoft Edge wherever this package is launched. Codex stores MCP connections in the user's global Codex configuration; it is not copied automatically when this folder moves. On another machine, add it once with:

```powershell
codex mcp add playwright -- cmd /c npx -y @playwright/mcp@0.0.85 --headless --isolated --browser msedge --caps devtools --console-level error
```

Install Microsoft Edge on that machine. The MCP package is fetched by npx when first used.
