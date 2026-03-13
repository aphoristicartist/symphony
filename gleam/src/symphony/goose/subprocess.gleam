import gleam/int
import gleam/option.{type Option, None, Some}
import symphony/errors

/// Result of running a Goose subprocess to completion.
pub type GooseResult {
  GooseResult(exit_code: Int, stdout: String, stderr: String)
}

/// Run goose as a subprocess and wait for completion.
/// Command: goose run -t <instruction> --with-builtin <builtins> --no-session
/// Environment vars set: GOOSE_PROVIDER, GOOSE_MODEL, GOOSE_MODE=auto, GOOSE_MAX_TURNS
pub fn run(
  command: String,
  instruction: String,
  cwd: String,
  provider: Option(String),
  model: Option(String),
  builtins: Option(String),
  max_turns: Int,
  timeout_ms: Int,
) -> Result(GooseResult, errors.AgentError) {
  let base_args = ["run", "-t", instruction, "--no-session"]

  let args = case builtins {
    Some(b) -> list_append(base_args, ["--with-builtin", b])
    None -> base_args
  }

  let base_env = [
    #("GOOSE_MODE", "auto"),
    #("GOOSE_MAX_TURNS", int.to_string(max_turns)),
  ]

  let env = case provider {
    Some(p) -> list_append(base_env, [#("GOOSE_PROVIDER", p)])
    None -> base_env
  }

  let env = case model {
    Some(m) -> list_append(env, [#("GOOSE_MODEL", m)])
    None -> env
  }

  case do_run_goose(command, args, cwd, env, timeout_ms) {
    Ok(#(exit_code, stdout, stderr)) ->
      Ok(GooseResult(exit_code: exit_code, stdout: stdout, stderr: stderr))
    Error(reason) ->
      Error(errors.LaunchFailed(
        command: command,
        workspace_path: cwd,
        details: reason,
      ))
  }
}

fn list_append(base: List(a), extra: List(a)) -> List(a) {
  case base {
    [] -> extra
    [first, ..rest] -> [first, ..list_append(rest, extra)]
  }
}

@external(erlang, "symphony_goose_ffi", "run_goose")
fn do_run_goose(
  command: String,
  args: List(String),
  cwd: String,
  env: List(#(String, String)),
  timeout_ms: Int,
) -> Result(#(Int, String, String), String)
