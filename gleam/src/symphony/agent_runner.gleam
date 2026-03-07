import gleam/erlang/process
import gleam/int
import gleam/option
import gleam/result
import symphony/codex/app_server.{type CodexEvent, type CodexProcess}
import symphony/config.{type Config}
import symphony/template
import symphony/types.{type Issue, type RunAttemptPhase}
import symphony/workspace

/// Run an issue through the agent
pub fn run_issue(issue: Issue, config: Config, attempt: Int) -> Result(RunAttemptPhase, String) {
  // Step 1: Ensure workspace
  use workspace_path <- result.try(
    ensure_issue_workspace(issue, config)
    |> result.map_error(fn(_) { "Failed to create workspace" }),
  )

  // Step 2: Run before_run hook if configured
  use _ <- result.try(
    run_before_hook(config, workspace_path)
    |> result.map_error(fn(e) { "before_run hook failed: " <> e }),
  )

  // Step 3: Build prompt from template
  use prompt <- result.try(
    build_prompt(issue, config, attempt)
    |> result.map_error(fn(e) { "Failed to build prompt: " <> e }),
  )

  // Step 4: Start Codex thread
  use codex_process <- result.try(
    start_codex_thread(config, workspace_path)
    |> result.map_error(fn(e) { "Failed to start Codex: " <> e }),
  )

  // Step 5: Run turns until complete or max turns reached
  let result = run_turns(codex_process, prompt, config, issue, 0)

  // Step 6: Run after_run hook
  let _ = run_after_hook(config, workspace_path)

  // Step 7: Stop Codex process
  app_server.stop_thread(codex_process)

  result
}

/// Ensure workspace exists for an issue
fn ensure_issue_workspace(issue: Issue, config: Config) -> Result(String, Nil) {
  let key = workspace.workspace_key(issue.identifier)
  workspace.ensure_workspace(config.workspace.root, key)
}

/// Run before_run hook
fn run_before_hook(config: Config, workspace_path: String) -> Result(Nil, String) {
  // For now, no hooks configured
  // In production, this would read from config
  Ok(Nil)
}

/// Run after_run hook
fn run_after_hook(config: Config, workspace_path: String) -> Result(Nil, String) {
  // For now, no hooks configured
  // In production, this would read from config
  Ok(Nil)
}

/// Build prompt from template
fn build_prompt(issue: Issue, config: Config, attempt: Int) -> Result(String, String) {
  let context = template.context_from_issue(issue, attempt)
  template.render(config.prompt_template, context)
}

/// Start Codex thread
fn start_codex_thread(config: Config, workspace_path: String) -> Result(CodexProcess, String) {
  app_server.start_thread(config.codex.command, workspace_path)
}

/// Run turns until completion or max turns
fn run_turns(
  codex_process: CodexProcess,
  prompt: String,
  config: Config,
  issue: Issue,
  turn_count: Int,
) -> Result(RunAttemptPhase, String) {
  // Check if max turns reached
  case turn_count >= config.agent.max_turns {
    True -> Ok(types.TimedOut)
    False -> {
      // Start a turn
      use _ <- result.try(
        app_server.start_turn(codex_process, prompt)
        |> result.map_error(fn(e) { "Failed to start turn: " <> e }),
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
) -> Result(RunAttemptPhase, String) {
  let result = process.new_subject()

  app_server.stream_events(codex_process, fn(event) {
    case event {
      app_server.TurnComplete(..) -> {
        // Check if issue is still in active state
        case check_issue_state(issue, config) {
          Ok(True) -> {
            // Issue still active, continue with next turn
            let _ = process.send(result, Ok(types.StreamingTurn))
          }
          Ok(False) -> {
            // Issue completed, we're done
            let _ = process.send(result, Ok(types.Succeeded))
          }
          Error(e) -> {
            let _ = process.send(result, Error(e))
          }
        }
      }
      app_server.ThreadComplete(..) -> {
        let _ = process.send(result, Ok(types.Succeeded))
      }
      app_server.Error(message) -> {
        let _ = process.send(result, Error(message))
      }
      _ -> Nil
    }
  })

  // Wait for result with timeout
  case process.receive(result, config.codex.turn_timeout_ms) {
    Ok(phase) -> {
      case phase {
        types.StreamingTurn -> {
          // Continue with next turn
          run_turns(codex_process, "", config, issue, turn_count + 1)
        }
        _ -> Ok(phase)
      }
    }
    Error(process.Timeout) -> Ok(types.TimedOut)
    Error(_) -> Error("Failed to receive turn result")
  }
}

/// Check if issue is still in an active state
fn check_issue_state(issue: Issue, config: Config) -> Result(Bool, String) {
  // For now, assume issue is still active
  // In production, this would query Linear to check current state
  Ok(list.contains(config.tracker.active_states, issue.state))
}

/// Get the current phase
pub fn current_phase() -> RunAttemptPhase {
  types.InitializingSession
}
