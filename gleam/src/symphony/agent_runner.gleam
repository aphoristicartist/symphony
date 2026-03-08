import gleam/erlang/process
import gleam/option
import gleam/result
import symphony/codex/app_server.{type CodexProcess}
import symphony/config.{type Config}
import symphony/errors
import symphony/template
import symphony/types.{type Issue, type RunAttemptPhase}
import symphony/validation
import symphony/workspace

/// Run an issue through the agent
pub fn run_issue(
  issue: Issue,
  config: Config,
  attempt: Int,
) -> Result(RunAttemptPhase, errors.RunError) {
  // Step 1: Ensure workspace
  use workspace <- result.try(
    ensure_issue_workspace(issue, config)
    |> result.map_error(fn(error) { errors.WorkspaceFailure(error) }),
  )

  // Step 2: Run after_create hook for newly created workspace
  use _ <- result.try(run_after_create_hook(config, workspace))

  // Step 3: Run before_run hook if configured
  use _ <- result.try(run_before_hook(config, workspace.path))

  // Step 4: Build prompt from template
  use prompt <- result.try(build_prompt(issue, config, attempt))

  // Step 5: Start Codex thread
  use codex_process <- result.try(start_codex_thread(config, workspace.path))

  // Step 6: Run turns until complete or max turns reached
  let result = run_turns(codex_process, prompt, config, issue, 0)

  // Step 7: Run after_run hook
  let _ = run_after_hook(config, workspace.path)

  // Step 8: Stop Codex process
  app_server.stop_thread(codex_process)

  result
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
  |> result.map_error(fn(error) { errors.WorkspaceFailure(error) })
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
  |> result.map_error(fn(error) { errors.WorkspaceFailure(error) })
}

/// Run after_create hook only when a workspace directory is newly created
fn run_after_create_hook(
  config: Config,
  issue_workspace: types.Workspace,
) -> Result(Nil, errors.RunError) {
  case issue_workspace.created_now {
    True ->
      workspace.run_optional_hook(
        config.hooks.after_create,
        issue_workspace.path,
        config.hooks.timeout_ms,
        errors.AfterCreate,
      )
    False -> Ok(Nil)
  }
  |> result.map_error(fn(error) { errors.WorkspaceFailure(error) })
}

/// Build prompt from template
fn build_prompt(
  issue: Issue,
  config: Config,
  attempt: Int,
) -> Result(String, errors.RunError) {
  let context = template.context_from_issue(issue, attempt)
  template.render(config.prompt_template, context)
  |> result.map_error(fn(error) {
    errors.AgentFailure(errors.ProtocolError(
      event: option.Some("prompt_template"),
      details: errors.validation_error_message(error),
    ))
  })
}

/// Start Codex thread
fn start_codex_thread(
  config: Config,
  workspace_path: String,
) -> Result(CodexProcess, errors.RunError) {
  app_server.start_thread(config.codex.command, workspace_path)
  |> result.map_error(fn(error) { errors.AgentFailure(error) })
}

/// Run turns until completion or max turns
fn run_turns(
  codex_process: CodexProcess,
  prompt: String,
  config: Config,
  issue: Issue,
  turn_count: Int,
) -> Result(RunAttemptPhase, errors.RunError) {
  // Check if max turns reached
  case turn_count >= config.agent.max_turns {
    True -> Ok(types.TimedOut)
    False -> {
      // Start a turn
      use _ <- result.try(
        app_server.start_turn(codex_process, prompt)
        |> result.map_error(fn(error) { errors.AgentFailure(error) }),
      )

      // Stream events and track completion
      stream_turn_events(codex_process, config, issue, turn_count)
    }
  }
}

/// Stream events for a single turn
fn stream_turn_events(
  codex_process: CodexProcess,
  config: Config,
  issue: Issue,
  turn_count: Int,
) -> Result(RunAttemptPhase, errors.RunError) {
  let result = process.new_subject()

  app_server.stream_events(codex_process, fn(event) {
    case event {
      app_server.TurnComplete(..) -> {
        // Check if issue is still in active state
        case check_issue_state(issue, config) {
          True -> {
            // Issue still active, continue with next turn
            let _ = process.send(result, Ok(types.StreamingTurn))
          }
          False -> {
            // Issue completed, we're done
            let _ = process.send(result, Ok(types.Succeeded))
          }
        }
      }
      app_server.ThreadComplete(..) -> {
        let _ = process.send(result, Ok(types.Succeeded))
      }
      app_server.ProcessError(message) -> {
        let _ =
          process.send(
            result,
            Error(
              errors.AgentFailure(errors.ProtocolError(
                event: option.Some("process_event"),
                details: message,
              )),
            ),
          )
      }
      _ -> Nil
    }
  })

  // Wait for result with timeout
  case process.receive(result, config.codex.turn_timeout_ms) {
    Ok(phase_result) -> {
      case phase_result {
        Ok(types.StreamingTurn) -> {
          // Continue with next turn
          run_turns(codex_process, "", config, issue, turn_count + 1)
        }
        _ -> phase_result
      }
    }
    Error(_) -> Ok(types.TimedOut)
  }
}

/// Check if issue is still in an active state
fn check_issue_state(issue: Issue, config: Config) -> Bool {
  validation.is_active_state(issue.state, config)
}

/// Get the current phase
pub fn current_phase() -> RunAttemptPhase {
  types.InitializingSession
}
