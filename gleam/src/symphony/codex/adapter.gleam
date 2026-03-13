import gleam/dynamic
import gleam/option.{None, Some}
import symphony/codex/app_server
import symphony/errors
import symphony/types

/// Build an AgentAdapter that delegates to the Codex app-server.
pub fn build() -> types.AgentAdapter {
  types.AgentAdapter(
    start_session: start_session,
    run_turn: run_turn,
    stop_session: stop_session,
  )
}

/// Start a Codex session by spawning the app-server process.
fn start_session(
  config: types.AgentSessionConfig,
) -> Result(types.AgentSession, errors.AgentError) {
  case app_server.start_thread(config.command, config.workspace_path) {
    Ok(process) ->
      Ok(types.AgentSession(
        session_id: None,
        agent_kind: types.Codex,
        process_handle: dynamic.from(process),
      ))
    Error(err) -> Error(err)
  }
}

/// Run a single turn: send the prompt, stream events, and collect the result.
fn run_turn(
  session: types.AgentSession,
  prompt: String,
) -> Result(types.TurnResult, errors.AgentError) {
  let process: app_server.CodexProcess =
    dynamic.unsafe_coerce(session.process_handle)

  case app_server.start_turn(process, prompt) {
    Ok(Nil) -> {
      let result = collect_turn_events(process)
      Ok(result)
    }
    Error(err) -> Error(err)
  }
}

/// Stop the Codex session by terminating the underlying process.
fn stop_session(session: types.AgentSession) -> Result(Nil, errors.AgentError) {
  let process: app_server.CodexProcess =
    dynamic.unsafe_coerce(session.process_handle)

  app_server.stop_thread(process)
  Ok(Nil)
}

/// Stream all events for a turn and fold them into a TurnResult.
fn collect_turn_events(process: app_server.CodexProcess) -> types.TurnResult {
  // Mutable-style accumulation via recursive streaming is not ergonomic here,
  // so we use a reference cell pattern: stream_events calls the handler for
  // each event and we fold state through the handler using an Erlang process
  // dictionary or similar. Since Gleam lacks mutable state, we instead do a
  // synchronous fold by reading events one at a time.
  //
  // However, app_server.stream_events is the public API and it handles the
  // read loop internally. We use it with a stateless handler that captures
  // the final state via process dictionary FFI.
  //
  // For simplicity, we collect into a result ref using Erlang process dict.
  let result_ref = make_result_ref()

  app_server.stream_events(process, fn(event) {
    update_result_ref(result_ref, event)
    Nil
  })

  read_result_ref(result_ref)
}

/// Opaque reference to accumulated turn result state.
type ResultRef =
  dynamic.Dynamic

/// Create a fresh result accumulator in the process dictionary.
fn make_result_ref() -> ResultRef {
  let initial =
    types.TurnResult(
      status: types.TurnSucceeded,
      token_usage: None,
      session_id: None,
      output: None,
    )
  let ref = dynamic.from(initial)
  do_put_result_ref(ref)
  ref
}

/// Update the accumulated result based on a Codex event.
fn update_result_ref(ref: ResultRef, event: app_server.CodexEvent) -> Nil {
  let current: types.TurnResult = dynamic.unsafe_coerce(do_get_result_ref(ref))

  let updated = case event {
    app_server.TurnStarted(_turn_id) -> current

    app_server.TurnUpdate(_turn_id, content) -> {
      let new_output = case current.output {
        Some(existing) -> Some(existing <> content)
        None -> Some(content)
      }
      types.TurnResult(..current, output: new_output)
    }

    app_server.TurnComplete(_turn_id, usage, _rate_limits) -> {
      let token_usage = convert_token_snapshot(usage)
      types.TurnResult(..current, token_usage: Some(token_usage))
    }

    app_server.TokenUsageUpdated(usage, _rate_limits) -> {
      let token_usage = convert_token_snapshot(usage)
      types.TurnResult(..current, token_usage: Some(token_usage))
    }

    app_server.ThreadStarted(_thread_id) -> current

    app_server.ThreadComplete(_thread_id) -> current

    app_server.RateLimitUpdated(_rate_limits) -> current

    app_server.UnknownEvent(_method) -> current

    app_server.MalformedEvent(details) ->
      types.TurnResult(
        ..current,
        status: types.TurnFailed(reason: "Malformed event: " <> details),
      )

    app_server.ProcessError(message) ->
      types.TurnResult(
        ..current,
        status: types.TurnFailed(reason: "Process error: " <> message),
      )
  }

  do_put_result_ref(dynamic.from(updated))
  Nil
}

/// Read the final accumulated result.
fn read_result_ref(ref: ResultRef) -> types.TurnResult {
  let stored = do_get_result_ref(ref)
  dynamic.unsafe_coerce(stored)
}

/// Convert a codex-specific TokenSnapshot to the generic types.TokenSnapshot.
fn convert_token_snapshot(
  snapshot: app_server.TokenSnapshot,
) -> types.TokenSnapshot {
  types.TokenSnapshot(
    input_tokens: snapshot.input_tokens,
    output_tokens: snapshot.output_tokens,
    total_tokens: snapshot.total_tokens,
  )
}

// Process dictionary helpers for stateful event accumulation.
// These use a single well-known key to store/retrieve the TurnResult.

fn do_put_result_ref(value: dynamic.Dynamic) -> Nil {
  do_erlang_put("$codex_adapter_result", value)
  Nil
}

fn do_get_result_ref(_ref: dynamic.Dynamic) -> dynamic.Dynamic {
  do_erlang_get("$codex_adapter_result")
}

@external(erlang, "symphony_codex_adapter_ffi", "put_process_dict")
fn do_erlang_put(key: String, value: dynamic.Dynamic) -> dynamic.Dynamic

@external(erlang, "symphony_codex_adapter_ffi", "get_process_dict")
fn do_erlang_get(key: String) -> dynamic.Dynamic
