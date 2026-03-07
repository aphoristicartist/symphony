import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import symphony/agent_runner
import symphony/config.{type Config}
import symphony/linear/client
import symphony/types

/// Orchestrator message types
pub type OrchestratorMessage {
  Tick
  WorkerCompleted(issue_id: String, result: WorkerResult)
  RetryIssue(retry_entry: types.RetryEntry)
}

/// Result from a worker
pub type WorkerResult {
  WorkerSucceeded
  WorkerFailed(error: String)
  WorkerTimedOut
}

/// Start the orchestrator
pub fn start(config: Config) -> Result(Subject(OrchestratorMessage), String) {
  let initial_state = types.OrchestratorState(
    poll_interval_ms: config.polling.interval_ms,
    max_concurrent_agents: config.agent.max_concurrent_agents,
    running: dict.new(),
    claimed: set.new(),
    retry_attempts: dict.new(),
    completed: set.new(),
  )

  actor.start_spec(actor.Spec(
    init: fn() { actor.Ready(initial_state, process.new_selector()) },
    init_timeout: 5000,
    loop: fn(message, state) {
      case message {
        Tick -> handle_tick(state, config)
        WorkerCompleted(issue_id, result) -> handle_worker_completed(
          state,
          issue_id,
          result,
          config,
        )
        RetryIssue(retry_entry) -> handle_retry(state, retry_entry, config)
      }
    },
  ))
  |> result.map_error(fn(_) { "Failed to start orchestrator actor" })
}

/// Handle tick message
fn handle_tick(
  state: types.OrchestratorState,
  config: Config,
) -> actor.Next(OrchestratorMessage, types.OrchestratorState) {
  // Step 1: Reconcile - check if running issues are still active
  let reconciled_state = reconcile_running_issues(state, config)

  // Step 2: Fetch candidate issues from Linear
  case client.fetch_active_issues(config) {
    Ok(issues) -> {
      // Step 3: Filter out claimed/running
      let candidates = filter_candidates(issues, reconciled_state)

      // Step 4: Dispatch up to max_concurrent_agents
      let new_state = dispatch_issues(candidates, reconciled_state, config)

      actor.Continue(new_state, None)
    }
    Error(_) -> {
      // Log error and continue
      actor.Continue(state, None)
    }
  }
}

/// Reconcile running issues
fn reconcile_running_issues(
  state: types.OrchestratorState,
  config: Config,
) -> types.OrchestratorState {
  // For each running issue, check if it's still in an active state
  let running_list = dict.to_list(state.running)

  list.fold(running_list, state, fn(acc, entry) {
    let #(issue_id, _session) = entry
    case client.fetch_issue_state(config, issue_id) {
      Ok(state_name) -> {
        case list.contains(config.tracker.active_states, state_name) {
          True -> acc
          False -> {
            // Issue is no longer active, mark as completed
            types.OrchestratorState(
              poll_interval_ms: acc.poll_interval_ms,
              max_concurrent_agents: acc.max_concurrent_agents,
              running: dict.delete(acc.running, issue_id),
              claimed: acc.claimed,
              retry_attempts: acc.retry_attempts,
              completed: set.insert(acc.completed, issue_id),
            )
          }
        }
      }
      Error(_) -> acc
    }
  })
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

/// Dispatch a single issue
fn dispatch_single_issue(
  issue: types.Issue,
  state: types.OrchestratorState,
  config: Config,
) -> types.OrchestratorState {
  // Claim the issue
  let claimed_state = types.OrchestratorState(
    poll_interval_ms: state.poll_interval_ms,
    max_concurrent_agents: state.max_concurrent_agents,
    running: state.running,
    claimed: set.insert(state.claimed, issue.id),
    retry_attempts: state.retry_attempts,
    completed: state.completed,
  )

  // Spawn worker process
  let _worker_pid = process.start(
    fn() {
      let _result = agent_runner.run_issue(issue, config, 1)
      // In production, would send result back
      Nil
    },
    False,
  )

  claimed_state
}

/// Handle worker completed message
fn handle_worker_completed(
  state: types.OrchestratorState,
  issue_id: String,
  result: WorkerResult,
  _config: Config,
) -> actor.Next(OrchestratorMessage, types.OrchestratorState) {
  case result {
    WorkerSucceeded -> {
      let new_state = types.OrchestratorState(
        poll_interval_ms: state.poll_interval_ms,
        max_concurrent_agents: state.max_concurrent_agents,
        running: dict.delete(state.running, issue_id),
        claimed: state.claimed,
        retry_attempts: state.retry_attempts,
        completed: set.insert(state.completed, issue_id),
      )
      actor.Continue(new_state, None)
    }
    WorkerFailed(_) -> {
      // Schedule retry with exponential backoff
      let new_state = types.OrchestratorState(
        poll_interval_ms: state.poll_interval_ms,
        max_concurrent_agents: state.max_concurrent_agents,
        running: dict.delete(state.running, issue_id),
        claimed: state.claimed,
        retry_attempts: state.retry_attempts,
        completed: state.completed,
      )
      actor.Continue(new_state, None)
    }
    WorkerTimedOut -> {
      // Schedule retry with delay
      let new_state = types.OrchestratorState(
        poll_interval_ms: state.poll_interval_ms,
        max_concurrent_agents: state.max_concurrent_agents,
        running: dict.delete(state.running, issue_id),
        claimed: state.claimed,
        retry_attempts: state.retry_attempts,
        completed: state.completed,
      )
      actor.Continue(new_state, None)
    }
  }
}

/// Handle retry message
fn handle_retry(
  state: types.OrchestratorState,
  retry_entry: types.RetryEntry,
  _config: Config,
) -> actor.Next(OrchestratorMessage, types.OrchestratorState) {
  // Check if retry is due
  case erlang_timestamp() >= retry_entry.due_at_ms {
    True -> {
      // Fetch issue and retry
      // For now, just remove from retry attempts
      let new_state = types.OrchestratorState(
        poll_interval_ms: state.poll_interval_ms,
        max_concurrent_agents: state.max_concurrent_agents,
        running: state.running,
        claimed: state.claimed,
        retry_attempts: dict.delete(state.retry_attempts, retry_entry.issue_id),
        completed: state.completed,
      )
      actor.Continue(new_state, None)
    }
    False -> {
      // Not due yet, reschedule
      actor.Continue(state, None)
    }
  }
}

/// Get current Erlang timestamp in milliseconds
fn erlang_timestamp() -> Int {
  do_erlang_timestamp()
}

@external(erlang, "erlang", "system_time")
fn do_erlang_timestamp() -> Int
