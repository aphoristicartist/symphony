import gleam/dynamic
import gleam/list
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
        process_handle: types.CodexProcess(inner: dynamic.from(process)),
      ))
    Error(err) -> Error(err)
  }
}

/// Run a single turn: send the prompt, collect all events, fold into a TurnResult.
fn run_turn(
  session: types.AgentSession,
  prompt: String,
) -> Result(types.TurnResult, errors.AgentError) {
  case session.process_handle {
    types.CodexProcess(inner: inner) -> {
      let process: app_server.CodexProcess = dynamic.unsafe_coerce(inner)
      case app_server.start_turn(process, prompt) {
        Ok(Nil) -> {
          let result =
            app_server.collect_events(process)
            |> list.fold(initial_turn_result(), fold_event)
          Ok(result)
        }
        Error(err) -> Error(err)
      }
    }
    _ ->
      Error(errors.ProtocolError(
        event: None,
        details: "Expected CodexProcess handle in session.process_handle",
      ))
  }
}

/// Stop the Codex session by terminating the underlying process.
fn stop_session(session: types.AgentSession) -> Result(Nil, errors.AgentError) {
  case session.process_handle {
    types.CodexProcess(inner: inner) -> {
      let process: app_server.CodexProcess = dynamic.unsafe_coerce(inner)
      app_server.stop_thread(process)
      Ok(Nil)
    }
    _ -> Ok(Nil)
  }
}

fn initial_turn_result() -> types.TurnResult {
  types.TurnResult(
    status: types.TurnSucceeded,
    token_usage: None,
    session_id: None,
    output: None,
  )
}

fn fold_event(
  acc: types.TurnResult,
  event: app_server.CodexEvent,
) -> types.TurnResult {
  case event {
    app_server.TurnStarted(_turn_id) -> acc

    app_server.TurnUpdate(_turn_id, content) -> {
      let new_output = case acc.output {
        Some(existing) -> Some(existing <> content)
        None -> Some(content)
      }
      types.TurnResult(..acc, output: new_output)
    }

    app_server.TurnComplete(_turn_id, usage, _rate_limits) ->
      types.TurnResult(..acc, token_usage: Some(convert_token_snapshot(usage)))

    app_server.TokenUsageUpdated(usage, _rate_limits) ->
      types.TurnResult(..acc, token_usage: Some(convert_token_snapshot(usage)))

    app_server.ThreadStarted(_thread_id) -> acc

    app_server.ThreadComplete(_thread_id) -> acc

    app_server.RateLimitUpdated(_rate_limits) -> acc

    app_server.UnknownEvent(_method) -> acc

    app_server.MalformedEvent(details) ->
      types.TurnResult(
        ..acc,
        status: types.TurnFailed(reason: "Malformed event: " <> details),
      )

    app_server.ProcessError(message) ->
      types.TurnResult(
        ..acc,
        status: types.TurnFailed(reason: "Process error: " <> message),
      )
  }
}

fn convert_token_snapshot(
  snapshot: app_server.TokenSnapshot,
) -> types.TokenSnapshot {
  types.TokenSnapshot(
    input_tokens: snapshot.input_tokens,
    output_tokens: snapshot.output_tokens,
    total_tokens: snapshot.total_tokens,
  )
}
