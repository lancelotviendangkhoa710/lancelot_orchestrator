# Master–Worker safety and integration design

This document defines the production direction for Codex → OpenCode → 9Router. It distinguishes host-enforced controls from model instructions.

## Current implementation status

- The current launcher creates a task branch and Git worktree, captures OpenCode output, validates changed paths for JSON Task Contracts, and commits only in-scope results. A worktree is a version-control workspace, **not a security sandbox**.
- The launcher currently uses a detached worktree and does not implement task DAG scheduling, path locks, a merge controller, crash recovery, or container isolation.
- The worker prompt asks the model not to touch unrelated paths or perform dangerous actions. Those are instructions, not enforcement.
- Docker CLI is installed in the inspected environment, but the daemon did not respond during inspection. Container isolation has not been exercised.

Do not enable unattended workers against valuable project data until the isolation and integration gates below are implemented and tested.

## Isolation layers

| Control | Enforced boundary | Limitation |
|---|---|---|
| Prompt/task allowlist/OpenCode agent rules | Model guidance and tool policy when configured | Not a security boundary; shell may bypass prompt intent. |
| Git worktree + branch | Separate checkout, diff, and branch history | No filesystem, process, credential, network, Docker, database, or host isolation. |
| Windows ACL/restricted account | Limits access to files/resources not granted to that account | Does not isolate the kernel; inherited grants and shared resources matter. |
| Windows Sandbox | Hypervisor-backed disposable Windows VM; mapped folders can be read-only or writable | One instance at a time, networking defaults on unless disabled, state disappears on close. Not suited to parallel worker pools. [Microsoft](https://learn.microsoft.com/en-us/windows/security/threat-protection/windows-sandbox/windows-sandbox-overview) |
| Docker Desktop Linux container | Container process/filesystem namespace in Docker's Linux VM; host files require explicit mounts | Writable bind mounts can be changed/deleted. Network egress is not automatically allowlisted. Never mount the Docker socket. [Bind mounts](https://docs.docker.com/engine/storage/bind-mounts/), [Desktop FAQ](https://docs.docker.com/faqs/platform/) |

### Recommended worker sandbox

Run one unprivileged Linux container per Worker on Docker Desktop, with only that Worker's source snapshot/worktree mounted writable. Do not mount the main checkout, home directory, SSH directory, global `.env`, Docker socket, or sibling workspaces. Use a read-only container root where compatible, bounded temp storage, CPU/memory/PID/time limits, no privileged mode, no extra capabilities, and a non-root user.

Give the process only a short-lived 9Router key restricted to required models. Never pass upstream credentials. Restrict egress to 9Router and explicitly required package mirrors using host firewall or an approved network proxy; Docker Desktop has no built-in internet allowlist. Do not expose 9Router to the LAN solely for container access. Use an ephemeral database/schema, unique ports, and mocks by default; never expose production data or services.

This provides actual filesystem/process isolation relative to the host, subject to VM and mount configuration. The mounted worker tree remains intentionally writable. Keep a host-side Git object/snapshot so a task can be discarded without touching another Worker.

If container egress and mounts cannot be configured and verified, use a dedicated VM/runner. Do not label prompt-only controls or worktrees a sandbox.

## Planning, conflicts, and concurrency

Before spawning Workers, Codex builds a task DAG. Each task declares ID, dependencies, allowed path globs, outputs, acceptance criteria, checks, model, timeout, retry policy, and shared resources (database, port, service, credentials).

- Run only DAG-ready tasks. Serialize tasks that consume prior output or touch the same module, interface, or schema.
- Canonicalize path globs and acquire write locks. Reject or queue tasks with overlapping write scopes. Broad globs and generated files conflict by default.
- Limit to two concurrent Workers until resource and quality data justifies more. Add locks for databases, ports, Docker services, and external test accounts.
- Path overlap finds likely file conflicts only. Master review and post-integration tests must catch semantic conflicts in interfaces, schemas, and behavior.
- Skip delegation when the change is small enough that coordination costs more than it saves.

Lifecycle: `planned → queued → starting → running → completed | failed | timed_out | cancelled → review → accepted | rejected → integrated → cleaned`. Persist each transition before the next side effect.

Use bounded timeouts. Retry only clearly transient startup/provider failures, at most once without review. If a worker may have changed files or external state, inspect logs, commit, and resource state before retrying. Cancellation terminates the process/container group, records the outcome, and preserves artifacts.

## Merge Controller

The controller alone mutates the shared Integration Branch. Workers cannot push to it and receive no write credentials for it.

1. Start a task branch from a recorded base SHA inside the isolated worker environment.
2. Worker commits its task branch. Record task ID, base/final SHA, branch, changed paths, logs, exit state, model, usage, and test report.
3. Validate changed paths against the task allowlist. Reject unexpected files, escaping symlinks, secrets, oversized artifacts, and unexpected binaries.
4. Codex Master reviews the diff and evidence. Optional read-only reviewers may report findings; they cannot approve or merge alone.
5. Acquire a repository integration lock. Merge one accepted task at a time into a disposable Integration Branch using `--no-commit --no-ff`.
6. Run format/lint, type checks, unit and integration tests, and relevant builds. Review interfaces, migrations, generated files, and shared behavior.
7. On textual conflict, stop and return the task for rework; never auto-resolve semantic conflicts. On failed gates, abort or reset only the disposable Integration Branch to its recorded pre-merge SHA while holding the lock. Preserve worker branch and logs.
8. Once the selected set passes together, require explicit user approval before moving it to `main`. Never auto-push or deploy.
9. After integration is verified and no Worker follow-up is needed, clean only if the changes are committed and preserved in Integration Branch. Keep logs/metadata by retention policy. Never delete uncommitted output.

Git detects textual conflicts, not semantic ones. Passing tests cannot prove semantic compatibility; Master review remains required.

## Reliability and recovery

Keep an append-only task manifest (SQLite or atomic JSON) in controller-owned state outside worker mounts. Record task ID, DAG dependencies, path/resource locks, run ID, base/final SHAs, branch/worktree/container IDs, timestamps, process/container exit, timeout/cancel state, log paths, checks, retries, and integration state.

After restart, reconcile persisted state against `git worktree list`, refs, container labels, and process/container status before resuming. Never infer success from a missing process or an LLM message. Missing commit/diff becomes `needs_recovery`, not `accepted`.

Use a log per Worker; redact credentials before persistence. Preserve structured progress and a concise final report. A cleanup sweeper may remove only expired artifacts proven clean, integrated, and unreferenced; dirty or ambiguous artifacts require review. Never retry side effects blindly.

Shared Docker daemons, databases, ports, credentials, and external services need explicit locks or per-worker instances. Prefer isolated ephemeral services; otherwise serialize access.

## Context and token budget

Codex Master receives summaries, changed paths, compact diff summaries, test outcomes, and review findings; it loads full diffs for review/integration. Workers receive repository instructions, task-specific context, acceptance criteria, and relevant checks, not full chat history. Use Sonnet for bounded implementation and Opus for ambiguous/high-risk reasoning when justified. Keep worker count and retries low because each duplicates context and cost.

## Rollout gates

1. Keep single-worker manual review first.
2. Verify container mounts by attempting writes to sibling workspaces, main checkout, home/SSH, and protected files; all must fail.
3. Verify no Docker socket, production credentials, database, or network access is available.
4. Inject timeout, crash, router failure, out-of-scope diff, dirty cleanup, textual conflict, and failing test. Confirm artifacts remain recoverable and Integration Branch returns to its recorded SHA.
5. Enable two-worker DAG execution only after those checks; measure conflict rate, runtime, token use, and test failures before increasing concurrency.
