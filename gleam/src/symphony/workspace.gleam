import gleam/option
import gleam/result
import gleam/string
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
      Ok(types.Workspace(
        path: path,
        workspace_key: key,
        created_now: created_now,
      ))

    Error(_) ->
      Error(errors.CreationFailed(
        path: path,
        workspace_key: key,
        details: "failed to create workspace directory",
      ))
  }
}

/// Run a hook script in the specified directory
pub fn run_hook(
  script: String,
  cwd: String,
  timeout_ms: Int,
  hook: errors.WorkspaceHook,
) -> Result(Nil, errors.WorkspaceError) {
  case string.trim(script) == "" {
    True -> Ok(Nil)
    False -> run_command(script, cwd, timeout_ms, hook)
  }
}

/// Run a hook script when configured.
pub fn run_optional_hook(
  script: option.Option(String),
  cwd: String,
  timeout_ms: Int,
  hook: errors.WorkspaceHook,
) -> Result(Nil, errors.WorkspaceError) {
  case script {
    option.Some(command) -> run_hook(command, cwd, timeout_ms, hook)
    option.None -> Ok(Nil)
  }
}

/// Run a command with timeout-aware Erlang FFI.
fn run_command(
  script: String,
  workspace_path: String,
  timeout_ms: Int,
  hook: errors.WorkspaceHook,
) -> Result(Nil, errors.WorkspaceError) {
  case do_run_command(script, workspace_path, timeout_ms) {
    Ok(#(0, _output)) -> Ok(Nil)
    Ok(#(status, output)) ->
      Error(errors.HookFailed(
        hook: hook,
        workspace_path: workspace_path,
        details: normalize_hook_details(output),
        exit_code: option.Some(status),
      ))
    Error(#("timeout", output)) ->
      Error(errors.HookTimedOut(
        hook: hook,
        workspace_path: workspace_path,
        timeout_ms: timeout_ms,
        details: normalize_hook_details(output),
      ))
    Error(#(_kind, details)) ->
      Error(errors.HookFailed(
        hook: hook,
        workspace_path: workspace_path,
        details: normalize_hook_details(details),
        exit_code: option.None,
      ))
  }
}

@external(erlang, "symphony_workspace_ffi", "run_command")
fn do_run_command(
  script: String,
  workspace_path: String,
  timeout_ms: Int,
) -> Result(#(Int, String), #(String, String))

/// Remove a workspace directory and return cleanup metadata.
pub fn remove_workspace(
  root: String,
  key: String,
  before_remove_hook: option.Option(String),
  hook_timeout_ms: Int,
) -> Result(types.WorkspaceCleanup, errors.WorkspaceError) {
  let path = root <> "/" <> key
  let removed_now = workspace_exists(root, key)

  use _ <- result.try(run_optional_hook(
    before_remove_hook,
    path,
    hook_timeout_ms,
    errors.BeforeRemove,
  ))

  case simplifile.delete(path) {
    Ok(_) ->
      Ok(types.WorkspaceCleanup(
        path: path,
        workspace_key: key,
        removed_now: removed_now,
      ))
    Error(_) ->
      Error(errors.CleanupFailed(
        path: path,
        workspace_key: key,
        details: "failed to remove workspace directory",
      ))
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

fn normalize_hook_details(details: String) -> String {
  case string.trim(details) {
    "" -> "no command output"
    trimmed -> trimmed
  }
}
