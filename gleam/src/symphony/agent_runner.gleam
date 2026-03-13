import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import symphony/config.{type Config}
import symphony/errors
import symphony/template
import symphony/tracker
import symphony/types.{type Issue, type RunAttemptPhase}
import symphony/validation
import symphony/workspace

/// Run an issue through the agent using the given adapter.
pub fn run_issue(
  issue: Issue,
  config: Config,
  attempt: Int,
  agent_adapter: types.AgentAdapter,
) -> Result(RunAttemptPhase, errors.RunError) {
  // Step 1: Ensure workspace
  use ws <- result.try(
    ensure_issue_workspace(issue, config)
    |> result.map_error(fn(e) { errors.WorkspaceFailure(e) }),
  )

  // Step 2: Run after_create hook for newly created workspace
  use _ <- result.try(run_after_create_hook(config, ws))

  // Step 3: Run before_run hook if configured
  use _ <- result.try(run_before_hook(config, ws.path))

  // Step 4: Build prompt from template
  use prompt <- result.try(build_prompt(issue, config, attempt))

  // Step 5: Build session config and start session
  let session_config =
    types.AgentSessionConfig(
      command: option.unwrap(
        config.agent.command,
        default_command_for_kind(config.agent.kind),
      ),
      workspace_path: ws.path,
      issue_identifier: issue.identifier,
      agent_kind: agent_kind_from_string(config.agent.kind),
      max_turns: config.agent.max_turns,
      turn_timeout_ms: config.codex.turn_timeout_ms,
      allowed_tools: config.agent.allowed_tools,
      permission_mode: config.agent.permission_mode,
      resume_session_id: None,
    )

  use session <- result.try(
    agent_adapter.start_session(session_config)
    |> result.map_error(fn(e) { errors.AgentFailure(e) }),
  )

  // Step 6: Run turns until complete or max turns reached
  let turn_result = run_turns(agent_adapter, session, prompt, config, issue, 0)

  // Step 7: Run after_run hook
  let _ = run_after_hook(config, ws.path)

  // Step 8: Stop session (best effort)
  let _ = agent_adapter.stop_session(session)

  turn_result
}

/// Ensure workspace exists for an issue
fn ensure_issue_workspace(
  issue: Issue,
  config: Config,
) -> Result(types.Workspace, errors.WorkspaceError) {
  let key = workspace.workspace_key(issue.identifier)
  workspace.ensure_workspace(config.workspace.root, key)
}

/// Run before_run hook
fn run_before_hook(
  config: Config,
  workspace_path: String,
) -> Result(Nil, errors.RunError) {
  workspace.run_optional_hook(
    config.hooks.before_run,
    workspace_path,
    config.hooks.timeout_ms,
    errors.BeforeRun,
  )
  |> result.map_error(fn(e) { errors.WorkspaceFailure(e) })
}

/// Run after_run hook
fn run_after_hook(
  config: Config,
  workspace_path: String,
) -> Result(Nil, errors.RunError) {
  workspace.run_optional_hook(
    config.hooks.after_run,
    workspace_path,
    config.hooks.timeout_ms,
    errors.AfterRun,
  )
  |> result.map_error(fn(e) { errors.WorkspaceFailure(e) })
}

/// Run after_create hook only when a workspace directory is newly created
fn run_after_create_hook(
  config: Config,
  ws: types.Workspace,
) -> Result(Nil, errors.RunError) {
  case ws.created_now {
    True ->
      workspace.run_optional_hook(
        config.hooks.after_create,
        ws.path,
        config.hooks.timeout_ms,
        errors.AfterCreate,
      )
    False -> Ok(Nil)
  }
  |> result.map_error(fn(e) { errors.WorkspaceFailure(e) })
}

/// Build prompt from template
fn build_prompt(
  issue: Issue,
  config: Config,
  attempt: Int,
) -> Result(String, errors.RunError) {
  let context = template.context_from_issue(issue, attempt)
  template.render(config.prompt_template, context)
  |> result.map_error(fn(e) {
    errors.AgentFailure(errors.ProtocolError(
      event: Some("prompt_template"),
      details: errors.validation_error_message(e),
    ))
  })
}

/// Run a single turn, wrapping it with a stall timeout if configured.
/// If `timeout_ms` is zero or negative the call is made directly without spawning
/// a separate process. Otherwise a fresh process runs the turn and we wait at
/// most `timeout_ms` milliseconds; if no reply arrives we return StallDetected.
fn run_turn_with_timeout(
  adapter: types.AgentAdapter,
  session: types.AgentSession,
  prompt: String,
  timeout_ms: Int,
  issue_id: String,
) -> Result(types.TurnResult, errors.AgentError) {
  case timeout_ms <= 0 {
    True -> adapter.run_turn(session, prompt)
    False -> {
      let reply_subject = process.new_subject()
      let _pid =
        process.start(
          fn() {
            let result = adapter.run_turn(session, prompt)
            process.send(reply_subject, result)
          },
          False,
        )
      case process.receive(reply_subject, timeout_ms) {
        Ok(result) -> result
        Error(Nil) ->
          Error(errors.StallDetected(
            issue_id: issue_id,
            last_event_ms: None,
            stall_timeout_ms: timeout_ms,
            details: "turn timed out after "
              <> int.to_string(timeout_ms)
              <> "ms",
          ))
      }
    }
  }
}

/// Run turns until completion or max turns reached
fn run_turns(
  adapter: types.AgentAdapter,
  session: types.AgentSession,
  prompt: String,
  config: Config,
  issue: Issue,
  turn_count: Int,
) -> Result(RunAttemptPhase, errors.RunError) {
  case turn_count >= config.agent.max_turns {
    True -> Ok(types.TimedOut)
    False -> {
      use turn_result <- result.try(
        run_turn_with_timeout(
          adapter,
          session,
          prompt,
          config.codex.turn_timeout_ms,
          issue.id,
        )
        |> result.map_error(fn(e) { errors.AgentFailure(e) }),
      )
      case turn_result.status {
        types.TurnSucceeded -> {
          case refetch_issue_active(issue, config) {
            True ->
              // Issue still active, continue with next turn (empty prompt for continuation)
              run_turns(adapter, session, "", config, issue, turn_count + 1)
            False -> Ok(types.Succeeded)
          }
        }
        types.TurnFailed(_reason) -> Ok(types.Failed)
        types.TurnCancelled -> Ok(types.CanceledByReconciliation)
      }
    }
  }
}

/// Re-fetch the issue state from the tracker and check whether it is still active.
/// Falls back to True (keep running) on any fetch error to avoid spurious cancellations.
fn refetch_issue_active(issue: Issue, config: Config) -> Bool {
  case tracker.build_tracker_adapter(config) {
    Error(_) -> True
    Ok(adapter) -> {
      case adapter.fetch_issue_states_by_ids([issue.id]) {
        Error(_) -> True
        Ok(issues) -> {
          case list.find(issues, fn(i) { i.id == issue.id }) {
            Error(_) ->
              // Issue not found in response — assume still active
              True
            Ok(refreshed) -> validation.is_active_state(refreshed.state, config)
          }
        }
      }
    }
  }
}

/// Get the default command for an agent kind
fn default_command_for_kind(kind: String) -> String {
  case kind {
    "codex" -> "codex app-server"
    "claude-code" -> "claude"
    "goose" -> "goose"
    _ -> "codex app-server"
  }
}

/// Parse an agent kind string to the typed enum
fn agent_kind_from_string(kind: String) -> types.AgentKind {
  case kind {
    "claude-code" -> types.ClaudeCode
    "goose" -> types.Goose
    _ -> types.Codex
  }
}

/// Get the current phase (kept for compatibility)
pub fn current_phase() -> RunAttemptPhase {
  types.InitializingSession
}
