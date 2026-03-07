import gleam/dict
import gleam/list
import gleam/string
import simplifile

/// Generate a workspace key from an issue identifier
/// Sanitizes to [A-Za-z0-9._-]
pub fn workspace_key(identifier: String) -> String {
  identifier
  |> string.to_graphemes
  |> list.map(sanitize_char)
  |> string.concat
}

/// Sanitize a single character for workspace key
fn sanitize_char(grapheme: String) -> String {
  case is_safe_char(grapheme) {
    True -> grapheme
    False -> "_"
  }
}

/// Check if a character is safe for workspace key
fn is_safe_char(grapheme: String) -> Bool {
  let safe_chars = [
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "A", "B", "C", "D",
    "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S",
    "T", "U", "V", "W", "X", "Y", "Z", "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ".", "_", "-",
  ]
  list.contains(safe_chars, grapheme)
}

/// Ensure a workspace directory exists
/// Returns the full path to the workspace
pub fn ensure_workspace(root: String, key: String) -> Result(String, Nil) {
  let path = root <> "/" <> key

  case simplifile.create_directory_all(path) {
    Ok(_) -> Ok(path)
    Error(_) -> Error(Nil)
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
fn run_command(cmd: String, timeout_ms: Int) -> Result(String, String) {
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
