import gleam/dict
import gleam/dynamic
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import simplifile
import symphony/errors
import symphony/types

/// Default snapshot filename written under the workspace root.
pub const snapshot_filename = "symphony_state.json"

/// Save orchestrator state to a JSON snapshot file.
pub fn save_snapshot(
  state: types.OrchestratorState,
  directory: String,
) -> Result(Nil, errors.PersistenceError) {
  let path = directory <> "/" <> snapshot_filename
  let json_str = encode_state(state)
  simplifile.write(to: path, contents: json_str)
  |> result.map_error(fn(_) {
    errors.WriteFailed(path: path, details: "failed to write state snapshot")
  })
}

/// Load orchestrator state from a JSON snapshot file.
/// Returns a fresh empty state if the file does not exist.
pub fn load_snapshot(
  directory: String,
) -> Result(types.OrchestratorState, errors.PersistenceError) {
  let path = directory <> "/" <> snapshot_filename
  case simplifile.read(path) {
    Ok(json_str) -> decode_state(json_str)
    Error(_) ->
      // File missing — return a fresh state (not an error)
      Ok(empty_state())
  }
}

/// Encode orchestrator state to a JSON string.
/// Only persists stable fields; running dict (ephemeral PIDs) is excluded.
pub fn encode_state(state: types.OrchestratorState) -> String {
  let completed_list =
    state.completed
    |> set.to_list
    |> list.map(json.string)

  let claimed_list =
    state.claimed
    |> set.to_list
    |> list.map(json.string)

  let retry_list =
    state.retry_attempts
    |> dict.to_list
    |> list.map(fn(pair) {
      let #(_id, entry) = pair
      encode_retry_entry(entry)
    })

  let totals = state.codex_totals

  json.object([
    #("completed", json.array(completed_list, fn(x) { x })),
    #("claimed", json.array(claimed_list, fn(x) { x })),
    #("retry_attempts", json.array(retry_list, fn(x) { x })),
    #("tick_count", json.int(state.tick_count)),
    #(
      "codex_totals",
      json.object([
        #("input_tokens", json.int(totals.input_tokens)),
        #("output_tokens", json.int(totals.output_tokens)),
        #("total_tokens", json.int(totals.total_tokens)),
      ]),
    ),
  ])
  |> json.to_string
}

/// Decode state from a JSON string.
pub fn decode_state(
  json_str: String,
) -> Result(types.OrchestratorState, errors.PersistenceError) {
  case json.decode(json_str, dynamic.dynamic) {
    Error(_) ->
      Error(errors.DeserializationFailed(
        path: snapshot_filename,
        details: "invalid JSON",
      ))
    Ok(dyn) -> {
      let completed = decode_string_set(dyn, "completed")
      let claimed = decode_string_set(dyn, "claimed")
      let retry_attempts = decode_retry_attempts(dyn)
      let tick_count = decode_int_field(dyn, "tick_count", 0)
      let codex_totals = decode_codex_totals(dyn)

      Ok(types.OrchestratorState(
        poll_interval_ms: 30_000,
        max_concurrent_agents: 10,
        running: dict.new(),
        claimed: claimed,
        retry_attempts: retry_attempts,
        completed: completed,
        codex_totals: codex_totals,
        codex_rate_limits: None,
        tracker_adapter: None,
        agent_adapter: None,
        agent_kind: None,
        last_cleanup_at: None,
        tick_count: tick_count,
      ))
    }
  }
}

// ============================================================================
// Encoding helpers
// ============================================================================

fn encode_retry_entry(entry: types.RetryEntry) -> json.Json {
  let error_field = case entry.error {
    Some(msg) -> [#("error", json.string(msg))]
    None -> []
  }
  json.object(
    list.concat([
      [
        #("issue_id", json.string(entry.issue_id)),
        #("identifier", json.string(entry.identifier)),
        #("attempt", json.int(entry.attempt)),
        #("due_at_ms", json.int(entry.due_at_ms)),
      ],
      error_field,
    ]),
  )
}

// ============================================================================
// Decoding helpers
// ============================================================================

fn decode_string_set(dyn: dynamic.Dynamic, field: String) -> set.Set(String) {
  case dynamic.field(field, dynamic.list(dynamic.string))(dyn) {
    Ok(items) -> set.from_list(items)
    Error(_) -> set.new()
  }
}

fn decode_retry_attempts(
  dyn: dynamic.Dynamic,
) -> dict.Dict(String, types.RetryEntry) {
  case dynamic.field("retry_attempts", dynamic.list(decode_retry_entry))(dyn) {
    Ok(entries) ->
      entries
      |> list.map(fn(e) { #(e.issue_id, e) })
      |> dict.from_list
    Error(_) -> dict.new()
  }
}

fn decode_retry_entry(
  dyn: dynamic.Dynamic,
) -> Result(types.RetryEntry, List(dynamic.DecodeError)) {
  use issue_id <- result.try(dynamic.field("issue_id", dynamic.string)(dyn))
  use identifier <- result.try(dynamic.field("identifier", dynamic.string)(dyn))
  use attempt <- result.try(dynamic.field("attempt", dynamic.int)(dyn))
  use due_at_ms <- result.try(dynamic.field("due_at_ms", dynamic.int)(dyn))
  let error_msg = case dynamic.field("error", dynamic.string)(dyn) {
    Ok(msg) -> Some(msg)
    Error(_) -> None
  }
  Ok(types.RetryEntry(
    issue_id: issue_id,
    identifier: identifier,
    attempt: attempt,
    due_at_ms: due_at_ms,
    timer_handle: None,
    error: error_msg,
  ))
}

fn decode_int_field(dyn: dynamic.Dynamic, field: String, default: Int) -> Int {
  case dynamic.field(field, dynamic.int)(dyn) {
    Ok(v) -> v
    Error(_) -> {
      case dynamic.field(field, dynamic.string)(dyn) {
        Ok(s) -> int.parse(s) |> result.unwrap(default)
        Error(_) -> default
      }
    }
  }
}

fn decode_codex_totals(dyn: dynamic.Dynamic) -> types.CodexTotals {
  case dynamic.field("codex_totals", dynamic.dynamic)(dyn) {
    Ok(totals_dyn) ->
      types.CodexTotals(
        input_tokens: decode_int_field(totals_dyn, "input_tokens", 0),
        output_tokens: decode_int_field(totals_dyn, "output_tokens", 0),
        total_tokens: decode_int_field(totals_dyn, "total_tokens", 0),
        seconds_running: 0.0,
      )
    Error(_) ->
      types.CodexTotals(
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: 0.0,
      )
  }
}

fn empty_state() -> types.OrchestratorState {
  types.OrchestratorState(
    poll_interval_ms: 30_000,
    max_concurrent_agents: 10,
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
    tracker_adapter: None,
    agent_adapter: None,
    agent_kind: None,
    last_cleanup_at: None,
    tick_count: 0,
  )
}
