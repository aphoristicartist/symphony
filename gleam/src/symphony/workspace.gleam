import simplifile
import symphony/errors
import symphony/types
import symphony/validation

/// Generate a workspace key from an issue identifier
/// Sanitizes to [A-Za-z0-9._-]
pub fn workspace_key(identifier: String) -> String {
  validation.sanitize_workspace_key(identifier)
}

/// Ensure a workspace directory exists
/// Returns typed workspace metadata including creation status.
pub fn ensure_workspace(
  root: String,
  key: String,
) -> Result(types.Workspace, errors.WorkspaceError) {
  let path = root <> "/" <> key
  let created_now = case simplifile.verify_is_directory(path) {
    Ok(True) -> False
    _ -> True
  }

  case simplifile.create_directory_all(path) {
    Ok(_) ->
      Ok(types.Workspace(path: path, workspace_key: key, created_now: created_now))

    Error(_) ->
      Error(
        errors.CreationFailed(
          path: path,
          workspace_key: key,
          details: "failed to create workspace directory",
        ),
      )
  }
}

/// Run a hook script in the specified directory
pub fn run_hook(
  script: String,
  cwd: String,
  timeout_ms: Int,
) -> Result(Nil, String) {
  case script == "" {
    True -> Ok(Nil)
    False -> {
      // Execute the script using Erlang :os.cmd
      let cmd = "cd " <> cwd <> " && " <> script <> " 2>&1"
      let result = run_command(cmd, timeout_ms)

      case result {
        Ok(_output) -> Ok(Nil)
        Error(e) -> Error(e)
      }
    }
  }
}

/// Run a command with timeout using Erlang FFI
fn run_command(cmd: String, _timeout_ms: Int) -> Result(String, String) {
  // For now, use a simple synchronous execution
  // In production, this would use proper timeout handling
  do_run_command(cmd)
}

@external(erlang, "symphony_workspace_ffi", "run_command")
fn do_run_command(cmd: String) -> Result(String, String)

/// Remove a workspace directory
pub fn remove_workspace(root: String, key: String) -> Result(Nil, Nil) {
  let path = root <> "/" <> key

  case simplifile.delete(path) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

/// Check if a workspace exists
pub fn workspace_exists(root: String, key: String) -> Bool {
  let path = root <> "/" <> key

  case simplifile.verify_is_directory(path) {
    Ok(True) -> True
    _ -> False
  }
}
