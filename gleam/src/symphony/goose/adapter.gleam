import gleam/dynamic
import gleam/option.{type Option, None, Some}
import symphony/errors
import symphony/goose/subprocess
import symphony/types

/// Internal state stored in the AgentSession process_handle for Goose sessions.
type GooseSessionState {
  GooseSessionState(
    command: String,
    cwd: String,
    provider: Option(String),
    model: Option(String),
    builtins: Option(String),
    max_turns: Int,
    timeout_ms: Int,
  )
}

/// Build an AgentAdapter that delegates to the Goose CLI subprocess.
pub fn build() -> types.AgentAdapter {
  types.AgentAdapter(
    start_session: start_session,
    run_turn: run_turn,
    stop_session: stop_session,
  )
}

/// Start a Goose session. Goose is stateless (fire-and-forget CLI), so we just
/// store the configuration in the session handle for use during run_turn.
fn start_session(
  config: types.AgentSessionConfig,
) -> Result(types.AgentSession, errors.AgentError) {
  let state =
    GooseSessionState(
      command: config.command,
      cwd: config.workspace_path,
      provider: None,
      model: None,
      builtins: config.allowed_tools,
      max_turns: config.max_turns,
      timeout_ms: config.turn_timeout_ms,
    )

  Ok(types.AgentSession(
    session_id: None,
    agent_kind: types.Goose,
    process_handle: types.GooseProcess(inner: dynamic.from(state)),
  ))
}

/// Run a single turn by invoking the Goose CLI subprocess with the prompt.
/// Maps exit code 0 to TurnSucceeded, non-zero to TurnFailed.
fn run_turn(
  session: types.AgentSession,
  prompt: String,
) -> Result(types.TurnResult, errors.AgentError) {
  let inner = case session.process_handle {
    types.GooseProcess(inner: i) -> i
    _ -> dynamic.from(Nil)
  }
  let state: GooseSessionState = dynamic.unsafe_coerce(inner)

  case
    subprocess.run(
      state.command,
      prompt,
      state.cwd,
      state.provider,
      state.model,
      state.builtins,
      state.max_turns,
      state.timeout_ms,
    )
  {
    Ok(result) -> {
      let status = case result.exit_code {
        0 -> types.TurnSucceeded
        code ->
          types.TurnFailed(
            reason: "goose exited with code " <> int_to_string(code),
          )
      }

      Ok(types.TurnResult(
        status: status,
        token_usage: None,
        session_id: None,
        output: Some(result.stdout),
      ))
    }

    Error(err) -> Error(err)
  }
}

/// Stop a Goose session. No-op since Goose is stateless.
fn stop_session(_session: types.AgentSession) -> Result(Nil, errors.AgentError) {
  Ok(Nil)
}

fn int_to_string(n: Int) -> String {
  case n < 0 {
    True -> "-" <> do_int_to_string(-n)
    False -> do_int_to_string(n)
  }
}

fn do_int_to_string(n: Int) -> String {
  case n < 10 {
    True -> digit_to_string(n)
    False -> do_int_to_string(n / 10) <> digit_to_string(n % 10)
  }
}

fn digit_to_string(d: Int) -> String {
  case d {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    _ -> "9"
  }
}
