import gleam/dynamic
import gleam/option.{None, Some}
import symphony/claude_code/event_parser
import symphony/claude_code/subprocess
import symphony/errors
import symphony/types

/// Build an AgentAdapter that delegates to the Claude Code CLI subprocess.
pub fn build() -> types.AgentAdapter {
  types.AgentAdapter(
    start_session: start_session,
    run_turn: run_turn,
    stop_session: stop_session,
  )
}

/// Start a Claude Code session by spawning the CLI process and reading
/// events until an InitEvent provides the session ID.
fn start_session(
  config: types.AgentSessionConfig,
) -> Result(types.AgentSession, errors.AgentError) {
  let start_result = case config.resume_session_id {
    Some(session_id) ->
      subprocess.resume(config.command, session_id, "", config.workspace_path)
    None ->
      subprocess.start(
        config.command,
        "",
        config.workspace_path,
        config.allowed_tools,
        config.permission_mode,
      )
  }

  case start_result {
    Ok(process) -> {
      let session = wait_for_init(process)
      session
    }
    Error(err) -> Error(err)
  }
}

/// Read events until we see an InitEvent, then wrap the process handle
/// into an AgentSession.
fn wait_for_init(
  process: subprocess.ClaudeCodeProcess,
) -> Result(types.AgentSession, errors.AgentError) {
  case subprocess.read_event(process) {
    Ok(line) -> {
      let event = event_parser.parse_event(line)
      case event {
        event_parser.InitEvent(session_id) ->
          Ok(types.AgentSession(
            session_id: Some(session_id),
            agent_kind: types.ClaudeCode,
            process_handle: types.ClaudeCodeProcess(inner: dynamic.from(
              subprocess.ClaudeCodeProcess(
                ..process,
                session_id: Some(session_id),
              ),
            )),
          ))
        event_parser.ErrorEvent(message) ->
          Error(errors.ProtocolError(
            event: Some("init"),
            details: "Error during init: " <> message,
          ))
        _ ->
          // Skip non-init events (e.g. system messages) and keep reading
          wait_for_init(process)
      }
    }
    Error(err) -> Error(err)
  }
}

/// Run a single turn: send the prompt via a fresh subprocess invocation
/// (or the existing one), read events until a terminal event, and collect
/// the result including text output and token usage.
fn run_turn(
  session: types.AgentSession,
  prompt: String,
) -> Result(types.TurnResult, errors.AgentError) {
  let process: subprocess.ClaudeCodeProcess =
    dynamic.unsafe_coerce(extract_inner(session.process_handle))

  // For Claude Code, each turn is a separate invocation. If we have a
  // session_id, resume; otherwise start fresh.
  let turn_result = case session.session_id {
    Some(session_id) ->
      subprocess.resume("claude", session_id, prompt, get_cwd(process))
    None -> subprocess.start("claude", prompt, get_cwd(process), None, None)
  }

  case turn_result {
    Ok(turn_process) -> {
      let result = collect_turn_events(turn_process)
      Ok(result)
    }
    Error(err) -> Error(err)
  }
}

/// Read events in a loop until a ResultEvent or ErrorEvent, accumulating
/// text output and extracting token usage.
fn collect_turn_events(
  process: subprocess.ClaudeCodeProcess,
) -> types.TurnResult {
  collect_turn_loop(process, "", None, None)
}

fn collect_turn_loop(
  process: subprocess.ClaudeCodeProcess,
  accumulated_text: String,
  token_usage: option.Option(types.TokenSnapshot),
  session_id: option.Option(String),
) -> types.TurnResult {
  case subprocess.read_event(process) {
    Ok(line) -> {
      let event = event_parser.parse_event(line)
      case event {
        event_parser.ResultEvent(output, sid) -> {
          let final_output = case accumulated_text {
            "" -> output
            _ -> accumulated_text <> output
          }
          let final_session_id = case sid {
            "" -> session_id
            _ -> Some(sid)
          }
          types.TurnResult(
            status: types.TurnSucceeded,
            token_usage: token_usage,
            session_id: final_session_id,
            output: Some(final_output),
          )
        }

        event_parser.ErrorEvent(message) ->
          types.TurnResult(
            status: types.TurnFailed(reason: message),
            token_usage: token_usage,
            session_id: session_id,
            output: case accumulated_text {
              "" -> None
              text -> Some(text)
            },
          )

        event_parser.TextDelta(content) ->
          collect_turn_loop(
            process,
            accumulated_text <> content,
            token_usage,
            session_id,
          )

        event_parser.UsageEvent(input_tokens, output_tokens) -> {
          let snapshot =
            types.TokenSnapshot(
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              total_tokens: input_tokens + output_tokens,
            )
          collect_turn_loop(
            process,
            accumulated_text,
            Some(snapshot),
            session_id,
          )
        }

        event_parser.InitEvent(sid) ->
          collect_turn_loop(process, accumulated_text, token_usage, Some(sid))

        _ ->
          // ToolUse, ToolResult, SystemEvent, UnknownEvent: skip
          collect_turn_loop(process, accumulated_text, token_usage, session_id)
      }
    }

    Error(_err) ->
      // Process ended unexpectedly
      types.TurnResult(
        status: types.TurnFailed(reason: "Process ended unexpectedly"),
        token_usage: token_usage,
        session_id: session_id,
        output: case accumulated_text {
          "" -> None
          text -> Some(text)
        },
      )
  }
}

/// Stop the Claude Code session by terminating the underlying process.
fn stop_session(session: types.AgentSession) -> Result(Nil, errors.AgentError) {
  let process: subprocess.ClaudeCodeProcess =
    dynamic.unsafe_coerce(extract_inner(session.process_handle))
  subprocess.stop(process)
  Ok(Nil)
}

/// Extract the inner Dynamic from a typed process handle.
fn extract_inner(handle: types.AgentProcessHandle) -> dynamic.Dynamic {
  case handle {
    types.ClaudeCodeProcess(inner: inner) -> inner
    types.CodexProcess(inner: inner) -> inner
    types.GooseProcess(inner: inner) -> inner
    types.NoProcess -> dynamic.from(Nil)
  }
}

/// Extract the working directory from the process. Since ClaudeCodeProcess
/// doesn't store cwd, we use a default. In practice the workspace_path
/// from the session config is used at start time.
fn get_cwd(_process: subprocess.ClaudeCodeProcess) -> String {
  "."
}
