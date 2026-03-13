import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import symphony/errors

/// Handle to a running Claude Code subprocess.
pub type ClaudeCodeProcess {
  ClaudeCodeProcess(port: Dynamic, session_id: Option(String))
}

/// Spawn `claude` with streaming JSON output.
///
/// Builds the argument list from the given options and starts the process
/// in the specified working directory.
pub fn start(
  command: String,
  prompt: String,
  cwd: String,
  allowed_tools: Option(String),
  permission_mode: Option(String),
) -> Result(ClaudeCodeProcess, errors.AgentError) {
  let base_args = ["-p", prompt, "--output-format", "stream-json"]

  let tools_args = case allowed_tools {
    Some(tools) -> ["--allowedTools", tools]
    None -> []
  }

  let permission_args = case permission_mode {
    Some(mode) -> ["--permission-mode", mode]
    None -> []
  }

  let args = list.concat([base_args, tools_args, permission_args])

  start_with_args(command, args, cwd)
}

/// Resume a previous Claude Code session.
///
/// Uses `--resume <session_id>` to continue an existing session with a
/// new prompt.
pub fn resume(
  command: String,
  session_id: String,
  prompt: String,
  cwd: String,
) -> Result(ClaudeCodeProcess, errors.AgentError) {
  let args = [
    "--resume", session_id, "-p", prompt, "--output-format", "stream-json",
  ]

  case start_with_args(command, args, cwd) {
    Ok(process) ->
      Ok(ClaudeCodeProcess(..process, session_id: Some(session_id)))
    Error(err) -> Error(err)
  }
}

/// Read the next newline-delimited event line from the process stdout.
pub fn read_event(
  process: ClaudeCodeProcess,
) -> Result(String, errors.AgentError) {
  case do_read_line(process.port) {
    Ok(line) -> Ok(line)
    Error(details) ->
      Error(errors.ProtocolError(event: Some("read_event"), details: details))
  }
}

/// Stop the Claude Code subprocess.
pub fn stop(process: ClaudeCodeProcess) -> Nil {
  do_stop(process.port)
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Start the subprocess with a pre-built argument list.
fn start_with_args(
  command: String,
  args: List(String),
  cwd: String,
) -> Result(ClaudeCodeProcess, errors.AgentError) {
  case do_start_claude(args, cwd) {
    Ok(port) -> Ok(ClaudeCodeProcess(port: port, session_id: None))
    Error(details) ->
      Error(errors.LaunchFailed(
        command: command,
        workspace_path: cwd,
        details: details,
      ))
  }
}

// ---------------------------------------------------------------------------
// Erlang FFI bindings
// ---------------------------------------------------------------------------

@external(erlang, "symphony_claude_code_ffi", "start_claude")
fn do_start_claude(args: List(String), cwd: String) -> Result(Dynamic, String)

@external(erlang, "symphony_claude_code_ffi", "read_line")
fn do_read_line(port: Dynamic) -> Result(String, String)

@external(erlang, "symphony_claude_code_ffi", "stop_process")
fn do_stop(port: Dynamic) -> Nil
