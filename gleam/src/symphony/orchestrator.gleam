import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
import symphony/agent
import symphony/agent_runner
import symphony/config.{type Config}
import symphony/errors
import symphony/persistence
import symphony/tracker
import symphony/types
import symphony/validation
import symphony/workspace

/// Type alias for convenience within this module.
pub type OrchestratorMessage =
  types.OrchestratorMessage

/// Type alias for convenience within this module.
pub type WorkerResult =
  types.WorkerResult

/// Maximum retry backoff in milliseconds (1 hour)
const max_retry_backoff_ms = 3_600_000

/// Number of ticks between cleanup passes
const cleanup_tick_interval = 10

/// Start the orchestrator
pub fn start(
  config: Config,
) -> Result(Subject(types.OrchestratorMessage), errors.OrchestrationError) {
  use tracker_adapter <- result.try(
    tracker.build_tracker_adapter(config)
    |> result.map_error(fn(e) {
      errors.ReconciliationFailed(
        issue_id: None,
        operation: "orchestrator.start.build_tracker_adapter",
        details: errors.run_error_message(e),
      )
    }),
  )

  use agent_adapter <- result.try(
    agent.build_agent_adapter(config)
    |> result.map_error(fn(e) {
      errors.ReconciliationFailed(
        issue_id: None,
        operation: "orchestrator.start.build_agent_adapter",
        details: errors.run_error_message(e),
      )
    }),
  )

  let agent_kind =
    validation.parse_agent_kind(config.agent.kind)
    |> result.unwrap(types.Codex)

  let initial_state =
    types.OrchestratorState(
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      running: dict.new(),
      claimed: set.new(),
      retry_attempts: dict.new(),
      completed: set.new(),
      codex_totals: types.CodexTotals(
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: 0.0,
      ),
      codex_rate_limits: None,
      tracker_adapter: Some(tracker_adapter),
      agent_adapter: Some(agent_adapter),
      agent_kind: Some(agent_kind),
      last_cleanup_at: None,
      tick_count: 0,
      own_subject: None,
    )

  actor.start_spec(
    actor.Spec(
      init: fn() { actor.Ready(initial_state, process.new_selector()) },
      init_timeout: 5000,
      loop: fn(message, state) {
        case message {
          types.Tick -> handle_tick(state, config)
          types.WorkerCompleted(issue_id, worker_result) ->
            handle_worker_completed(state, issue_id, worker_result, config)
          types.RetryIssue(retry_entry) ->
            handle_retry(state, retry_entry, config)
          types.CleanupTerminalWorkspaces -> handle_cleanup(state, config)
          types.SetOwnSubject(subject) -> handle_set_subject(state, subject)
        }
      },
    ),
  )
  |> result.map(fn(subject) {
    process.send(subject, types.SetOwnSubject(subject))
    subject
  })
  |> result.map_error(fn(_) {
    errors.ReconciliationFailed(
      issue_id: None,
      operation: "orchestrator.start",
      details: "Failed to start orchestrator actor",
    )
  })
}

/// Handle SetOwnSubject message — store our own subject for worker callbacks.
fn handle_set_subject(
  state: types.OrchestratorState,
  subject: Subject(types.OrchestratorMessage),
) -> actor.Next(types.OrchestratorMessage, types.OrchestratorState) {
  actor.Continue(
    types.OrchestratorState(..state, own_subject: Some(subject)),
    None,
  )
}

/// Handle tick message
fn handle_tick(
  state: types.OrchestratorState,
  config: Config,
) -> actor.Next(types.OrchestratorMessage, types.OrchestratorState) {
  let new_tick = state.tick_count + 1
  let ticked_state = types.OrchestratorState(..state, tick_count: new_tick)

  // Periodically trigger workspace cleanup
  let with_cleanup = case new_tick % cleanup_tick_interval == 0 {
    True -> handle_cleanup_pass(ticked_state, config)
    False -> ticked_state
  }

  // Step 1: Reconcile - check if running issues are still active
  let reconciled_state = reconcile_running_issues(with_cleanup, config)

  // Step 2: Validate dispatch config and then fetch candidates
  case validation.validate_config(config) {
    Ok(_) -> {
      case fetch_candidates(reconciled_state, config) {
        Ok(issues) -> {
          let candidates = filter_candidates(issues, reconciled_state)
          let new_state = dispatch_issues(candidates, reconciled_state, config)

          // Periodic state checkpoint every 10 ticks
          let _checkpoint = case new_tick % 10 == 0 {
            True -> persistence.save_snapshot(new_state, config.workspace.root)
            False -> Ok(Nil)
          }

          actor.Continue(new_state, None)
        }
        Error(_) -> actor.Continue(reconciled_state, None)
      }
    }
    Error(_) -> actor.Continue(reconciled_state, None)
  }
}

/// Fetch candidate issues using the tracker adapter
fn fetch_candidates(
  state: types.OrchestratorState,
  _config: Config,
) -> Result(List(types.Issue), errors.TrackerError) {
  case state.tracker_adapter {
    Some(adapter) -> adapter.fetch_candidate_issues()
    None ->
      Error(errors.ApiError(
        operation: "fetch_candidates",
        details: "No tracker adapter configured",
        status_code: None,
      ))
  }
}

/// Reconcile running issues against current tracker state
fn reconcile_running_issues(
  state: types.OrchestratorState,
  config: Config,
) -> types.OrchestratorState {
  let running_ids = dict.keys(state.running)

  case running_ids, state.tracker_adapter {
    [], _ -> state
    _, None -> state
    ids, Some(adapter) -> {
      case adapter.fetch_issue_states_by_ids(ids) {
        Ok(issues) ->
          list.fold(issues, state, fn(acc, issue) {
            case validation.is_active_state(issue.state, config) {
              True -> acc
              False ->
                types.OrchestratorState(
                  ..acc,
                  running: dict.delete(acc.running, issue.id),
                  completed: set.insert(acc.completed, issue.id),
                )
            }
          })
        Error(_) -> state
      }
    }
  }
}

/// Filter candidate issues
fn filter_candidates(
  issues: List(types.Issue),
  state: types.OrchestratorState,
) -> List(types.Issue) {
  issues
  |> list.filter(fn(issue) {
    !set.contains(state.claimed, issue.id)
    && !dict.has_key(state.running, issue.id)
    && !set.contains(state.completed, issue.id)
    && !dict.has_key(state.retry_attempts, issue.id)
  })
}

/// Dispatch issues to workers
fn dispatch_issues(
  issues: List(types.Issue),
  state: types.OrchestratorState,
  config: Config,
) -> types.OrchestratorState {
  let available_slots = state.max_concurrent_agents - dict.size(state.running)

  issues
  |> list.take(available_slots)
  |> list.fold(state, fn(acc, issue) {
    dispatch_single_issue(issue, acc, config)
  })
}

/// Dispatch a single issue — starts a worker process that sends WorkerCompleted
/// back to the orchestrator when done.
fn dispatch_single_issue(
  issue: types.Issue,
  state: types.OrchestratorState,
  config: Config,
) -> types.OrchestratorState {
  let claimed_state =
    types.OrchestratorState(
      ..state,
      claimed: set.insert(state.claimed, issue.id),
    )

  case state.agent_adapter, state.own_subject {
    Some(adapter), Some(orch_subject) -> {
      let issue_id = issue.id
      let _worker_pid =
        process.start(
          fn() {
            let run_result = agent_runner.run_issue(issue, config, 1, adapter)
            let worker_result = case run_result {
              Ok(_) -> types.WorkerSucceeded
              Error(e) -> types.WorkerFailed(error: e)
            }
            process.send(
              orch_subject,
              types.WorkerCompleted(issue_id, worker_result),
            )
          },
          False,
        )
      claimed_state
    }
    Some(adapter), None -> {
      // No subject yet; still dispatch but can't send completion callback
      let issue_id = issue.id
      let _worker_pid =
        process.start(
          fn() {
            let _run_result = agent_runner.run_issue(issue, config, 1, adapter)
            let _ = issue_id
            Nil
          },
          False,
        )
      claimed_state
    }
    None, _ -> claimed_state
  }
}

/// Handle worker completed message
fn handle_worker_completed(
  state: types.OrchestratorState,
  issue_id: String,
  worker_result: types.WorkerResult,
  _config: Config,
) -> actor.Next(types.OrchestratorMessage, types.OrchestratorState) {
  case worker_result {
    types.WorkerSucceeded -> {
      let new_state =
        types.OrchestratorState(
          ..state,
          running: dict.delete(state.running, issue_id),
          claimed: set.delete(state.claimed, issue_id),
          completed: set.insert(state.completed, issue_id),
        )
      actor.Continue(new_state, None)
    }
    types.WorkerFailed(error) -> {
      let attempt =
        dict.get(state.retry_attempts, issue_id)
        |> result.map(fn(e) { e.attempt })
        |> result.unwrap(1)
      let identifier =
        dict.get(state.running, issue_id)
        |> result.map(fn(e) { e.issue_identifier })
        |> result.unwrap(issue_id)
      let new_state =
        schedule_retry(
          state,
          issue_id,
          identifier,
          attempt + 1,
          errors.run_error_message(error),
        )
      actor.Continue(new_state, None)
    }
    types.WorkerTimedOut -> {
      let attempt =
        dict.get(state.retry_attempts, issue_id)
        |> result.map(fn(e) { e.attempt })
        |> result.unwrap(1)
      let identifier =
        dict.get(state.running, issue_id)
        |> result.map(fn(e) { e.issue_identifier })
        |> result.unwrap(issue_id)
      let new_state =
        schedule_retry(
          state,
          issue_id,
          identifier,
          attempt + 1,
          "worker timed out",
        )
      actor.Continue(new_state, None)
    }
  }
}

/// Schedule a retry with exponential backoff
fn schedule_retry(
  state: types.OrchestratorState,
  issue_id: String,
  identifier: String,
  attempt: Int,
  error_msg: String,
) -> types.OrchestratorState {
  let backoff_ms = calculate_backoff(attempt, max_retry_backoff_ms)
  let due_at = erlang_timestamp() + backoff_ms
  let entry =
    types.RetryEntry(
      issue_id: issue_id,
      identifier: identifier,
      attempt: attempt,
      due_at_ms: due_at,
      timer_handle: None,
      error: Some(error_msg),
    )
  types.OrchestratorState(
    ..state,
    running: dict.delete(state.running, issue_id),
    claimed: set.delete(state.claimed, issue_id),
    retry_attempts: dict.insert(state.retry_attempts, issue_id, entry),
  )
}

/// Exponential backoff: 1000 * 2^attempt, capped at max_ms
fn calculate_backoff(attempt: Int, max_ms: Int) -> Int {
  let base = 1000
  let shifted = bitwise_shift_left(base, attempt)
  int.min(shifted, max_ms)
}

/// Handle retry message
fn handle_retry(
  state: types.OrchestratorState,
  retry_entry: types.RetryEntry,
  _config: Config,
) -> actor.Next(types.OrchestratorMessage, types.OrchestratorState) {
  case erlang_timestamp() >= retry_entry.due_at_ms {
    True -> {
      // Remove from retry queue and dispatch on next tick
      let new_state =
        types.OrchestratorState(
          ..state,
          retry_attempts: dict.delete(
            state.retry_attempts,
            retry_entry.issue_id,
          ),
        )
      actor.Continue(new_state, None)
    }
    False -> actor.Continue(state, None)
  }
}

/// Handle CleanupTerminalWorkspaces message
fn handle_cleanup(
  state: types.OrchestratorState,
  config: Config,
) -> actor.Next(types.OrchestratorMessage, types.OrchestratorState) {
  let new_state = handle_cleanup_pass(state, config)
  actor.Continue(new_state, None)
}

/// Run a cleanup pass over completed issue workspaces
fn handle_cleanup_pass(
  state: types.OrchestratorState,
  config: Config,
) -> types.OrchestratorState {
  set.to_list(state.completed)
  |> list.each(fn(issue_id) {
    let key = validation.sanitize_workspace_key(issue_id)
    let _ =
      workspace.remove_workspace(
        config.workspace.root,
        key,
        config.hooks.before_remove,
        config.hooks.timeout_ms,
      )
    Nil
  })
  types.OrchestratorState(..state, last_cleanup_at: Some(erlang_timestamp()))
}

/// Get current Erlang timestamp in milliseconds
fn erlang_timestamp() -> Int {
  do_erlang_timestamp()
}

@external(erlang, "symphony_workflow_store_ffi", "system_time_ms")
fn do_erlang_timestamp() -> Int

/// Left-shift an integer (for exponential backoff calculation)
@external(erlang, "erlang", "bsl")
fn bitwise_shift_left(value: Int, shift: Int) -> Int
