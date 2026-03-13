# Gleam / Elixir Boundary

Symphony enforces a strict boundary between the Gleam core and the Elixir
Phoenix layer. This document describes what lives on each side and how they
communicate.

## What lives in Gleam (core runtime)

All business logic that has nothing to do with serving HTTP or rendering a UI
belongs in the Gleam implementation under `gleam/src/symphony/`:

- **Orchestration** — polling loop, reconciliation against Linear state,
  concurrency cap, `max_concurrent_agents` dispatch
- **Agent lifecycle** — per-issue workspace creation, hook execution
  (`AfterCreate`, `BeforeRun`, `AfterRun`, `BeforeRemove`), Codex session
  management, turn loop, timeout handling
- **Retry logic** — exponential backoff, `max_retry_backoff_ms`, retry-attempt
  tracking
- **Workspace management** — path-traversal protection, symlink-escape checks,
  workspace root enforcement
- **Linear tracker** — GraphQL queries, state transitions, comment posting
- **Token accounting** — Codex input/output token delta tracking, rate-limit
  snapshot, stale-event deduplication
- **Config parsing** — WORKFLOW.md YAML front matter, env var expansion
  (`$VAR_NAME`), type coercion, defaults, validation

## What lives in Elixir (Phoenix web layer)

Everything related to serving and displaying orchestrator state belongs in
`elixir/lib/`:

- **Phoenix application** — `SymphonyElixir.Application`, supervision tree,
  `Phoenix.PubSub`, `Task.Supervisor`
- **CLI entrypoint** — `SymphonyElixir.CLI` (escript, argument parsing)
- **HTTP server** — `SymphonyElixir.HttpServer`, `SymphonyElixirWeb` router,
  JSON API at `/api/v1/*`
- **LiveView dashboard** — `SymphonyElixirWeb.DashboardLive`, real-time
  observability UI
- **Terminal dashboard** — `SymphonyElixir.StatusDashboard`, ANSI status
  rendering for the terminal
- **Presenter** — `SymphonyElixirWeb.Presenter`, projections from raw snapshot
  maps to payload shapes consumed by the dashboard and API
- **PubSub bridge** — `SymphonyElixirWeb.ObservabilityPubSub`, broadcasts
  state-change notifications to LiveView subscribers
- **WorkflowStore** — caches the parsed WORKFLOW.md content for serving via
  the API

## How the boundary works

`SymphonyElixir.GleamBridge` is the single crossing point:

1. On startup it calls `symphony_gleam@config.load/1` with the WORKFLOW.md
   path to obtain a typed Gleam config value.
2. It then calls `symphony_gleam@orchestrator.start/1` with that config,
   which spawns the Gleam OTP actor and returns a Gleam `Subject`.
3. The bridge holds the Subject and forwards periodic `:tick` messages
   (and forced ticks from `request_refresh/1`) by sending `{tag, :tick}` to
   the Gleam actor's owner PID.
4. After each tick the bridge calls `ObservabilityPubSub.broadcast_update/0`
   so connected LiveView sockets re-render with the latest state.

`SymphonyElixir.Orchestrator` is now a thin GenServer that:
- Exposes `snapshot/0,2` returning a static empty-state map (the real state
  lives entirely in the Gleam actor — future work can query it via a
  `get_state` call into the Gleam subject if needed).
- Exposes `request_refresh/0,1` which delegates to `GleamBridge.tick/0`.

## Erlang module naming convention

Gleam modules compile to Erlang atoms following the pattern:

```
<app_name>@<gleam_module_path_with_slashes_replaced_by_@>
```

For the `symphony_gleam` application:

| Gleam module              | Erlang atom                          |
|---------------------------|--------------------------------------|
| `symphony/orchestrator`   | `:symphony_gleam@orchestrator`       |
| `symphony/config`         | `:symphony_gleam@config`             |
| `symphony/agent_runner`   | `:symphony_gleam@agent_runner`       |
| `symphony/workspace`      | `:symphony_gleam@workspace`          |
| `symphony/linear/client`  | `:symphony_gleam@linear@client`      |

These atoms are called directly from `GleamBridge` with standard Erlang MFA
syntax, e.g. `:symphony_gleam@orchestrator.start(config)`.
