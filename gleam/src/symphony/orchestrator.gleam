import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import symphony/agent_runner
import symphony/config.{type Config}
import symphony/linear/client
import symphony/types.{
  type Issue, type LiveSession, type OrchestratorState, type RetryEntry,
}

/// Orchestrator message types
pub type OrchestratorMessage {
  Tick
  WorkerCompleted(issue_id: String, result: WorkerResult)
  RetryIssue(retry_entry: RetryEntry)
}

/// Result from a worker
pub type WorkerResult {
  WorkerSucceeded
  WorkerFailed(error: String)
  WorkerTimedOut
}

/// Start the orchestrator
pub fn start(config: Config) -> Result(actor.Subject(OrchestratorMessage), String) {
  let initial_state = OrchestratorState(
    poll_interval_ms: config.polling.interval_ms,
    max_concurrent_agents: config.agent.max_concurrent_agents,
    running: dict.new(),
    claimed: set.new(),
    retry_attempts: dict.new(),
    completed: set.new(),
  )

  actor.start_spec(actor.Spec(
    init: fn() { actor.Ready(initial_state) },
    init_timeout_ms: 5000,
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
  state: OrchestratorState,
  config: Config,
) -> actor.Loop(OrchestratorMessage) {
  // Step 1: Reconcile - check if running issues are still active
  let reconciled_state = reconcile_running_issues(state, config)

  // Step 2: Fetch candidate issues from Linear
  case client.fetch_active_issues(config) {
    Ok(issues) -> {
      // Step 3: Filter out claimed/running
      let candidates = filter_candidates(issues, reconciled_state)

      // Step 4: Dispatch up to max_concurrent_agents
      let new_state = dispatch_issues(candidates, reconciled_state, config)

      // Schedule next tick
      let _ = process.send_after(
        process.subject_owner(self()),
        state.poll_interval_ms,
        Tick,
      )

      actor.Continue(new_state)
    }
    Error(e) -> {
      // Log error and continue
      let _ = process.send_after(
        process.subject_owner(self()),
        state.poll_interval_ms,
        Tick,
      )
      actor.Continue(state)
    }
  }
}

/// Reconcile running issues
fn reconcile_running_issues(
  state: OrchestratorState,
  config: Config,
) -> OrchestratorState {
  // For each running issue, check if it's still in an active state
  let running_list = dict.to_list(state.running)

  list.fold(running_list, state, fn(acc, entry) {
    let #(issue_id, session) = entry
    case client.fetch_issue_state(config, issue_id) {
      Ok(state_name) -> {
        case list.contains(config.tracker.active_states, state_name) {
          True -> acc
          False -> {
            // Issue is no longer active, mark as completed
            OrchestratorState(
              ..acc,
              running: dict.delete(acc.running, issue_id),
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
  issues: List(Issue),
  state: OrchestratorState,
) -> List(Issue) {
  issues
  |> list.filter(fn(issue) {
    !set.contains(state.claimed, issue.id)
    && !dict.has_key(state.running, issue.id)
    && !set.contains(state.completed, issue.id)
  })
}

/// Dispatch issues to workers
fn dispatch_issues(
  issues: List(Issue),
  state: OrchestratorState,
  config: Config,
) -> OrchestratorState {
  let available_slots = state.max_concurrent_agents - dict.size(state.running)

  issues
  |> list.take(available_slots)
  |> list.fold(state, fn(acc, issue) {
    dispatch_single_issue(issue, acc, config)
  })
}

/// Dispatch a single issue
fn dispatch_single_issue(
  issue: Issue,
  state: OrchestratorState,
  config: Config,
) -> OrchestratorState {
  // Claim the issue
  let claimed_state = OrchestratorState(
    ..state,
    claimed: set.insert(state.claimed, issue.id),
  )

  // Spawn worker process
  let self_subject = self()
  let _worker_pid = process.start(
    fn() {
      let result = agent_runner.run_issue(issue, config, 1)
      let worker_result = case result {
        Ok(types.Succeeded) -> WorkerSucceeded
        Ok(types.Failed) -> WorkerFailed(error: "Agent failed")
        Ok(types.TimedOut) -> WorkerTimedOut
        Ok(_) -> WorkerFailed(error: "Unexpected phase")
        Error(e) -> WorkerFailed(error: e)
      }
      let _ = process.send(self_subject, WorkerCompleted(issue.id, worker_result))
    },
    False,
  )

  claimed_state
}

/// Handle worker completed message
fn handle_worker_completed(
  state: OrchestratorState,
  issue_id: String,
  result: WorkerResult,
  config: Config,
) -> actor.Loop(OrchestratorMessage) {
  case result {
    WorkerSucceeded -> {
      let new_state = OrchestratorState(
        ..state,
        running: dict.delete(state.running, issue_id),
        completed: set.insert(state.completed, issue_id),
      )
      actor.Continue(new_state)
    }
    WorkerFailed(error) -> {
      // Schedule retry with exponential backoff
      let retry_entry = RetryEntry(
        issue_id: issue_id,
        identifier: "ISSUE", // Would get from state
        attempt: 1,
        due_at_ms: erlang_timestamp() + 1000,
        error: Some(error),
      )

      let _ = process.send_after(
        process.subject_owner(self()),
        1000,
        RetryIssue(retry_entry),
      )

      let new_state = OrchestratorState(
        ..state,
        running: dict.delete(state.running, issue_id),
        retry_attempts: dict.insert(state.retry_attempts, issue_id, retry_entry),
      )
      actor.Continue(new_state)
    }
    WorkerTimedOut -> {
      // Schedule retry with delay
      let retry_entry = RetryEntry(
        issue_id: issue_id,
        identifier: "ISSUE",
        attempt: 1,
        due_at_ms: erlang_timestamp() + 1000,
        error: Some("Timed out"),
      )

      let _ = process.send_after(
        process.subject_owner(self()),
        1000,
        RetryIssue(retry_entry),
      )

      let new_state = OrchestratorState(
        ..state,
        running: dict.delete(state.running, issue_id),
        retry_attempts: dict.insert(state.retry_attempts, issue_id, retry_entry),
      )
      actor.Continue(new_state)
    }
  }
}

/// Handle retry message
fn handle_retry(
  state: OrchestratorState,
  retry_entry: RetryEntry,
  config: Config,
) -> actor.Loop(OrchestratorMessage) {
  // Check if retry is due
  case erlang_timestamp() >= retry_entry.due_at_ms {
    True -> {
      // Fetch issue and retry
      // For now, just remove from retry attempts
      let new_state = OrchestratorState(
        ..state,
        retry_attempts: dict.delete(state.retry_attempts, retry_entry.issue_id),
      )
      actor.Continue(new_state)
    }
    False -> {
      // Not due yet, reschedule
      let delay = retry_entry.due_at_ms - erlang_timestamp()
      let _ = process.send_after(
        process.subject_owner(self()),
        delay,
        RetryIssue(retry_entry),
      )
      actor.Continue(state)
    }
  }
}

/// Get current Erlang timestamp in milliseconds
fn erlang_timestamp() -> Int {
  do_erlang_timestamp()
}

@external(erlang, "erlang", "system_time")
fn do_erlang_timestamp() -> Int

/// Get the orchestrator's subject
fn self() -> actor.Subject(OrchestratorMessage) {
  do_self()
}

@external(erlang, "erlang", "self")
fn do_self() -> actor.Subject(OrchestratorMessage)
