# LancelotForge hardening plan

This plan tracks the gap between the 2026-11-11 audit (2.6/10 at commit
`9e980fe`) and a defensible 9.5/10. A passing smoke test alone cannot close
the goal. Every gate needs executable evidence from the current revision.

## Gate 1: Worker safety

- Run each worker under an OS or container boundary with only its worktree
  writable. The worker must not read the main checkout, sibling worktrees,
  host home, `.env`, SSH material, or controller state.
- Supply only scoped, short-lived credentials. Redact credentials from logs.
- Enforce task timeout and process-tree cancellation; persist `starting`,
  `running`, and terminal states before and after external actions.
- Reject out-of-scope changes, symlink escapes, unexpected binary/secret files,
  and stale or tampered task metadata before accepting a worker commit.
- Verify with isolated negative tests that attempted reads/writes outside the
  sandbox fail and that timeout/crash artifacts remain recoverable.

## Gate 2: Orchestration and integration

- Persist task DAG, dependency and resource locks, run ID, base/commit SHA,
  process/container identity, and integration decisions in controller state.
- Dispatch only DAG-ready tasks. Serialize overlapping paths, interfaces,
  database, Docker service, and fixed-port use.
- Verify worker ancestry, scope, source state, and review decision. Integrate
  one accepted result at a time under a repository lock.
- Run repository-owned required checks, including interface/API tests when
  relevant; caller-supplied trivial checks do not constitute acceptance.
- Verify conflict and failing-check rollback in disposable integration trees.

## Gate 3: Test and operational evidence

- Keep deterministic unit, integration, negative, and restart tests in CI.
- Exercise a real OpenCode worker with denied tools, a Docker workload with
  isolated data, and a browser flow when the target project needs one.
- Record elapsed time, token/cost estimates, retries, conflicts, and check
  outcomes. Compare single-worker and parallel runs on the same tasks.
- Update architecture/status documentation from observed implementation and
  test evidence. Do not call a planned control implemented.

## Acceptance rule

Re-audit the ten weighted categories from the original audit. A 9.5/10 claim
requires current evidence for every safety-critical gate above and repeatable
failure-scenario tests. Missing evidence counts as incomplete, even if the
implementation appears plausible.
