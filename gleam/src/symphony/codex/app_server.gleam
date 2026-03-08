import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import symphony/errors
import symphony/types

/// Codex process handle
pub type CodexProcess {
  CodexProcess(
    pid: process.Pid,
    stdin: process.Subject(String),
    stdout: process.Subject(String),
  )
}

/// JSON-RPC request
type JsonRpcRequest =
  JsonRpcMessage(Dynamic)

/// JSON-RPC message
type JsonRpcMessage(a) {
  JsonRpcMessage(
    jsonrpc: String,
    method: Option(String),
    params: Option(a),
    id: Option(Int),
    result: Option(a),
    error: Option(Dynamic),
  )
}

/// Token usage snapshot from Codex payloads.
pub type TokenSnapshot {
  TokenSnapshot(input_tokens: Int, output_tokens: Int, total_tokens: Int)
}

/// Codex event types
pub type CodexEvent {
  TurnStarted(turn_id: String)
  TurnUpdate(turn_id: String, content: String)
  TurnComplete(
    turn_id: String,
    usage: TokenSnapshot,
    rate_limits: Option(types.CodexRateLimits),
  )
  TokenUsageUpdated(
    usage: TokenSnapshot,
    rate_limits: Option(types.CodexRateLimits),
  )
  ThreadStarted(thread_id: String)
  ThreadComplete(thread_id: String)
  RateLimitUpdated(rate_limits: types.CodexRateLimits)
  UnknownEvent(method: String)
  MalformedEvent(details: String)
  ProcessError(message: String)
}

/// Zero-valued token snapshot used as an accounting baseline.
pub fn zero_token_snapshot() -> TokenSnapshot {
  TokenSnapshot(input_tokens: 0, output_tokens: 0, total_tokens: 0)
}

/// Start a Codex thread by spawning the app-server process
pub fn start_thread(
  command: String,
  cwd: String,
) -> Result(CodexProcess, errors.AgentError) {
  do_start_codex(command, cwd)
  |> result.map_error(fn(details) {
    errors.LaunchFailed(command: command, workspace_path: cwd, details: details)
  })
}

/// Start Codex via Erlang FFI
@external(erlang, "symphony_codex_ffi", "start_codex")
fn do_start_codex(command: String, cwd: String) -> Result(CodexProcess, String)

/// Start a turn in the Codex thread
pub fn start_turn(
  process: CodexProcess,
  prompt: String,
) -> Result(Nil, errors.AgentError) {
  let request =
    JsonRpcMessage(
      jsonrpc: "2.0",
      method: Some("turn.start"),
      params: Some(
        dynamic.from(dict.from_list([#("prompt", dynamic.from(prompt))])),
      ),
      id: Some(1),
      result: None,
      error: None,
    )

  send_request(process, request)
}

/// Send a JSON-RPC request
fn send_request(
  process: CodexProcess,
  request: JsonRpcRequest,
) -> Result(Nil, errors.AgentError) {
  let json_str = encode_request(request)
  do_send_to_process(process, json_str)
  |> result.map_error(fn(details) {
    errors.ProtocolError(event: Some("send_request"), details: details)
  })
}

/// Send data to Codex process via FFI
@external(erlang, "symphony_codex_ffi", "send_to_process")
fn do_send_to_process(
  process: CodexProcess,
  data: String,
) -> Result(Nil, String)

/// Stream events from the Codex process
pub fn stream_events(
  process: CodexProcess,
  handler: fn(CodexEvent) -> Nil,
) -> Nil {
  stream_loop(process, handler)
}

/// Stream loop
fn stream_loop(process: CodexProcess, handler: fn(CodexEvent) -> Nil) -> Nil {
  case read_event(process) {
    Ok(event) -> {
      handler(event)
      case event {
        ThreadComplete(_) -> Nil
        ProcessError(_) -> Nil
        _ -> stream_loop(process, handler)
      }
    }
    Error(error) -> {
      handler(ProcessError(message: errors.agent_error_message(error)))
      Nil
    }
  }
}

/// Read a single event from the process
fn read_event(process: CodexProcess) -> Result(CodexEvent, errors.AgentError) {
  case do_read_event(process) {
    Ok(event_str) -> Ok(decode_event_line(event_str))
    Error(details) ->
      Error(errors.ProtocolError(event: Some("read_event"), details: details))
  }
}

/// Read event via FFI
@external(erlang, "symphony_codex_ffi", "read_event")
fn do_read_event(process: CodexProcess) -> Result(String, String)

/// Decode one app-server event payload into a typed event branch.
pub fn decode_event_line(json_str: String) -> CodexEvent {
  case json.decode(json_str, dynamic.dynamic) {
    Ok(dyn) -> parse_event_dynamic(dyn)
    Error(_) -> MalformedEvent(details: "invalid JSON payload")
  }
}

/// Apply one codex event into orchestrator token/rate-limit metrics.
pub fn apply_event_accounting(
  state: types.OrchestratorState,
  last_snapshot: TokenSnapshot,
  event: CodexEvent,
) -> #(types.OrchestratorState, TokenSnapshot) {
  let next_rate_limits = case rate_limits_from_event(event) {
    Some(rate_limits) -> Some(rate_limits)
    None -> state.codex_rate_limits
  }

  case token_snapshot_from_event(event) {
    Some(next_snapshot) -> {
      let #(next_totals, reported_snapshot) =
        accumulate_totals(state.codex_totals, last_snapshot, next_snapshot)

      #(
        replace_codex_metrics(state, next_totals, next_rate_limits),
        reported_snapshot,
      )
    }
    None -> #(
      replace_codex_metrics(state, state.codex_totals, next_rate_limits),
      last_snapshot,
    )
  }
}

pub fn token_snapshot_from_event(event: CodexEvent) -> Option(TokenSnapshot) {
  case event {
    TurnComplete(_, usage, _) -> Some(usage)
    TokenUsageUpdated(usage, _) -> Some(usage)
    _ -> None
  }
}

pub fn rate_limits_from_event(
  event: CodexEvent,
) -> Option(types.CodexRateLimits) {
  case event {
    TurnComplete(_, _, Some(rate_limits)) -> Some(rate_limits)
    TokenUsageUpdated(_, Some(rate_limits)) -> Some(rate_limits)
    RateLimitUpdated(rate_limits) -> Some(rate_limits)
    _ -> None
  }
}

fn parse_event_dynamic(dyn: dynamic.Dynamic) -> CodexEvent {
  case get_optional_string_field(dyn, "method") {
    Some(method) -> parse_event_method(method, dyn)
    None -> MalformedEvent(details: "event missing method field")
  }
}

fn parse_event_method(method: String, dyn: dynamic.Dynamic) -> CodexEvent {
  case normalize_method(method) {
    "turn.started" -> parse_turn_started(dyn)
    "turn.update" -> parse_turn_update(dyn)
    "turn.complete" -> parse_turn_complete(dyn)
    "turn.completed" -> parse_turn_complete(dyn)
    "thread.started" -> parse_thread_started(dyn)
    "thread.complete" -> parse_thread_complete(dyn)
    "thread.tokenusage.updated" -> parse_token_usage_updated(dyn)
    normalized -> {
      case
        string.contains(normalized, "rate")
        && string.contains(normalized, "limit")
      {
        True -> parse_rate_limit_updated(method, dyn)
        False -> UnknownEvent(method: method)
      }
    }
  }
}

fn parse_turn_started(dyn: dynamic.Dynamic) -> CodexEvent {
  case get_required_params_string_field(dyn, "turn_id") {
    Ok(turn_id) -> TurnStarted(turn_id: turn_id)
    Error(details) -> MalformedEvent(details: details)
  }
}

fn parse_turn_update(dyn: dynamic.Dynamic) -> CodexEvent {
  case get_params(dyn) {
    Ok(params) ->
      case
        get_required_string_field(params, "turn_id"),
        get_required_string_field(params, "content")
      {
        Ok(turn_id), Ok(content) ->
          TurnUpdate(turn_id: turn_id, content: content)
        Error(details), _ -> MalformedEvent(details: details)
        _, Error(details) -> MalformedEvent(details: details)
      }
    Error(details) -> MalformedEvent(details: details)
  }
}

fn parse_turn_complete(dyn: dynamic.Dynamic) -> CodexEvent {
  case get_params(dyn) {
    Ok(params) ->
      case get_required_string_field(params, "turn_id") {
        Ok(turn_id) -> {
          let usage = find_token_snapshot(dyn)
          let rate_limits = find_rate_limits(dyn)

          case usage {
            Some(snapshot) ->
              TurnComplete(
                turn_id: turn_id,
                usage: snapshot,
                rate_limits: rate_limits,
              )
            None ->
              MalformedEvent(
                details: "turn.complete missing token usage fields",
              )
          }
        }
        Error(details) -> MalformedEvent(details: details)
      }
    Error(details) -> MalformedEvent(details: details)
  }
}

fn parse_token_usage_updated(dyn: dynamic.Dynamic) -> CodexEvent {
  let usage = find_token_snapshot(dyn)
  let rate_limits = find_rate_limits(dyn)

  case usage {
    Some(snapshot) ->
      TokenUsageUpdated(usage: snapshot, rate_limits: rate_limits)
    None -> MalformedEvent(details: "token usage update missing token fields")
  }
}

fn parse_thread_started(dyn: dynamic.Dynamic) -> CodexEvent {
  case get_required_params_string_field(dyn, "thread_id") {
    Ok(thread_id) -> ThreadStarted(thread_id: thread_id)
    Error(details) -> MalformedEvent(details: details)
  }
}

fn parse_thread_complete(dyn: dynamic.Dynamic) -> CodexEvent {
  case get_required_params_string_field(dyn, "thread_id") {
    Ok(thread_id) -> ThreadComplete(thread_id: thread_id)
    Error(details) -> MalformedEvent(details: details)
  }
}

fn parse_rate_limit_updated(method: String, dyn: dynamic.Dynamic) -> CodexEvent {
  case find_rate_limits(dyn) {
    Some(rate_limits) -> RateLimitUpdated(rate_limits: rate_limits)
    None -> UnknownEvent(method: method)
  }
}

fn find_token_snapshot(dyn: dynamic.Dynamic) -> Option(TokenSnapshot) {
  find_token_snapshot_with_depth(dyn, 6)
}

fn find_token_snapshot_with_depth(
  dyn: dynamic.Dynamic,
  depth: Int,
) -> Option(TokenSnapshot) {
  case depth <= 0 {
    True -> None
    False -> {
      case token_snapshot_from_fields(dyn) {
        Some(snapshot) -> Some(snapshot)
        None -> {
          case dynamic.dict(dynamic.string, dynamic.dynamic)(dyn) {
            Ok(entries) ->
              entries
              |> dict.to_list
              |> list.map(fn(item) {
                let #(_key, value) = item
                value
              })
              |> find_snapshot_in_list(depth - 1)
            Error(_) -> {
              case dynamic.list(dynamic.dynamic)(dyn) {
                Ok(values) -> find_snapshot_in_list(values, depth - 1)
                Error(_) -> None
              }
            }
          }
        }
      }
    }
  }
}

fn find_snapshot_in_list(
  values: List(dynamic.Dynamic),
  depth: Int,
) -> Option(TokenSnapshot) {
  case values {
    [] -> None
    [value, ..rest] -> {
      case find_token_snapshot_with_depth(value, depth) {
        Some(snapshot) -> Some(snapshot)
        None -> find_snapshot_in_list(rest, depth)
      }
    }
  }
}

fn token_snapshot_from_fields(dyn: dynamic.Dynamic) -> Option(TokenSnapshot) {
  let input_tokens =
    first_int_field(dyn, [
      "input_tokens",
      "prompt_tokens",
      "inputTokens",
      "promptTokens",
      "input",
    ])
  let output_tokens =
    first_int_field(dyn, [
      "output_tokens",
      "completion_tokens",
      "outputTokens",
      "completionTokens",
      "output",
      "completion",
    ])
  let total_tokens =
    first_int_field(dyn, ["total_tokens", "totalTokens", "total"])

  case any_some([input_tokens, output_tokens, total_tokens]) {
    True -> {
      let input = option_default_int(input_tokens, 0)
      let output = option_default_int(output_tokens, 0)
      let total = option_default_int(total_tokens, input + output)

      Some(TokenSnapshot(
        input_tokens: input,
        output_tokens: output,
        total_tokens: total,
      ))
    }
    False -> None
  }
}

fn find_rate_limits(dyn: dynamic.Dynamic) -> Option(types.CodexRateLimits) {
  find_rate_limits_with_depth(dyn, 6)
}

fn find_rate_limits_with_depth(
  dyn: dynamic.Dynamic,
  depth: Int,
) -> Option(types.CodexRateLimits) {
  case depth <= 0 {
    True -> None
    False -> {
      case rate_limits_from_fields(dyn) {
        Some(rate_limits) -> Some(rate_limits)
        None -> {
          case dynamic.dict(dynamic.string, dynamic.dynamic)(dyn) {
            Ok(entries) ->
              entries
              |> dict.to_list
              |> list.map(fn(item) {
                let #(_key, value) = item
                value
              })
              |> find_rate_limits_in_list(depth - 1)
            Error(_) -> {
              case dynamic.list(dynamic.dynamic)(dyn) {
                Ok(values) -> find_rate_limits_in_list(values, depth - 1)
                Error(_) -> None
              }
            }
          }
        }
      }
    }
  }
}

fn find_rate_limits_in_list(
  values: List(dynamic.Dynamic),
  depth: Int,
) -> Option(types.CodexRateLimits) {
  case values {
    [] -> None
    [value, ..rest] -> {
      case find_rate_limits_with_depth(value, depth) {
        Some(rate_limits) -> Some(rate_limits)
        None -> find_rate_limits_in_list(rest, depth)
      }
    }
  }
}

fn rate_limits_from_fields(
  dyn: dynamic.Dynamic,
) -> Option(types.CodexRateLimits) {
  let request_limit = first_int_field(dyn, ["request_limit", "requestLimit"])
  let request_remaining =
    first_int_field(dyn, ["request_remaining", "requestRemaining"])
  let request_reset_at_ms =
    first_int_field(dyn, [
      "request_reset_at_ms",
      "requestResetAtMs",
      "request_reset_at",
    ])
  let token_limit = first_int_field(dyn, ["token_limit", "tokenLimit"])
  let token_remaining =
    first_int_field(dyn, ["token_remaining", "tokenRemaining"])
  let token_reset_at_ms =
    first_int_field(dyn, [
      "token_reset_at_ms",
      "tokenResetAtMs",
      "token_reset_at",
    ])

  let values = [
    request_limit,
    request_remaining,
    request_reset_at_ms,
    token_limit,
    token_remaining,
    token_reset_at_ms,
  ]

  case any_some(values) {
    True ->
      Some(types.CodexRateLimits(
        request_limit: request_limit,
        request_remaining: request_remaining,
        request_reset_at_ms: request_reset_at_ms,
        token_limit: token_limit,
        token_remaining: token_remaining,
        token_reset_at_ms: token_reset_at_ms,
      ))
    False -> None
  }
}

fn first_int_field(dyn: dynamic.Dynamic, fields: List(String)) -> Option(Int) {
  case fields {
    [] -> None
    [field, ..rest] -> {
      case get_optional_int_field(dyn, field) {
        Some(value) -> Some(value)
        None -> first_int_field(dyn, rest)
      }
    }
  }
}

fn get_required_params_string_field(
  dyn: dynamic.Dynamic,
  field: String,
) -> Result(String, String) {
  use params <- result.try(get_params(dyn))
  get_required_string_field(params, field)
}

fn get_params(dyn: dynamic.Dynamic) -> Result(dynamic.Dynamic, String) {
  dynamic.field("params", dynamic.dynamic)(dyn)
  |> result.map_error(fn(_) { "missing params payload" })
}

fn get_required_string_field(
  dyn: dynamic.Dynamic,
  field: String,
) -> Result(String, String) {
  dynamic.field(field, dynamic.string)(dyn)
  |> result.map_error(fn(_) { "missing required field: " <> field })
}

fn get_optional_string_field(
  dyn: dynamic.Dynamic,
  field: String,
) -> Option(String) {
  case dynamic.field(field, dynamic.string)(dyn) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn get_optional_int_field(dyn: dynamic.Dynamic, field: String) -> Option(Int) {
  case dynamic.field(field, dynamic.int)(dyn) {
    Ok(value) -> Some(value)
    Error(_) -> {
      case dynamic.field(field, dynamic.string)(dyn) {
        Ok(value) -> {
          case int.parse(string.trim(value)) {
            Ok(parsed) -> Some(parsed)
            Error(_) -> None
          }
        }
        Error(_) -> None
      }
    }
  }
}

fn normalize_method(method: String) -> String {
  method
  |> string.lowercase
  |> string.replace("/", ".")
}

fn any_some(values: List(Option(a))) -> Bool {
  values
  |> list.any(fn(value) {
    case value {
      Some(_) -> True
      None -> False
    }
  })
}

fn option_default_int(value: Option(Int), fallback: Int) -> Int {
  case value {
    Some(actual) -> actual
    None -> fallback
  }
}

fn accumulate_totals(
  totals: types.CodexTotals,
  last_snapshot: TokenSnapshot,
  next_snapshot: TokenSnapshot,
) -> #(types.CodexTotals, TokenSnapshot) {
  let input_delta =
    non_negative_delta(next_snapshot.input_tokens, last_snapshot.input_tokens)
  let output_delta =
    non_negative_delta(next_snapshot.output_tokens, last_snapshot.output_tokens)
  let total_delta =
    non_negative_delta(next_snapshot.total_tokens, last_snapshot.total_tokens)

  let next_totals =
    types.CodexTotals(
      input_tokens: totals.input_tokens + input_delta,
      output_tokens: totals.output_tokens + output_delta,
      total_tokens: totals.total_tokens + total_delta,
      seconds_running: totals.seconds_running,
    )

  let reported_snapshot =
    TokenSnapshot(
      input_tokens: max_int(
        last_snapshot.input_tokens,
        next_snapshot.input_tokens,
      ),
      output_tokens: max_int(
        last_snapshot.output_tokens,
        next_snapshot.output_tokens,
      ),
      total_tokens: max_int(
        last_snapshot.total_tokens,
        next_snapshot.total_tokens,
      ),
    )

  #(next_totals, reported_snapshot)
}

fn non_negative_delta(next_value: Int, previous_value: Int) -> Int {
  case next_value - previous_value {
    value if value > 0 -> value
    _ -> 0
  }
}

fn max_int(left: Int, right: Int) -> Int {
  case left >= right {
    True -> left
    False -> right
  }
}

fn replace_codex_metrics(
  state: types.OrchestratorState,
  codex_totals: types.CodexTotals,
  codex_rate_limits: Option(types.CodexRateLimits),
) -> types.OrchestratorState {
  types.OrchestratorState(
    poll_interval_ms: state.poll_interval_ms,
    max_concurrent_agents: state.max_concurrent_agents,
    running: state.running,
    claimed: state.claimed,
    retry_attempts: state.retry_attempts,
    completed: state.completed,
    codex_totals: codex_totals,
    codex_rate_limits: codex_rate_limits,
  )
}

/// Encode a JSON-RPC request
fn encode_request(request: JsonRpcRequest) -> String {
  let base_fields = [
    #("jsonrpc", json.string(request.jsonrpc)),
  ]

  let method_fields = case request.method {
    Some(method) -> [#("method", json.string(method))]
    None -> []
  }

  let params_fields = case request.params {
    Some(params) -> [#("params", dynamic_to_json(params))]
    None -> []
  }

  let id_fields = case request.id {
    Some(id) -> [#("id", json.int(id))]
    None -> []
  }

  let all_fields =
    list.concat([base_fields, method_fields, params_fields, id_fields])

  json.object(all_fields) |> json.to_string
}

/// Convert dynamic to JSON (simplified)
fn dynamic_to_json(dyn: Dynamic) -> json.Json {
  case dynamic.string(dyn) {
    Ok(s) -> json.string(s)
    Error(_) -> json.null()
  }
}

/// Stop the Codex process
pub fn stop_thread(process: CodexProcess) -> Nil {
  do_stop_codex(process)
}

/// Stop Codex via FFI
@external(erlang, "symphony_codex_ffi", "stop_codex")
fn do_stop_codex(process: CodexProcess) -> Nil
