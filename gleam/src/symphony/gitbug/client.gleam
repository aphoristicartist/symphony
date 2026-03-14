import gleam/dynamic
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import symphony/errors
import symphony/gitbug/types as gb_types

/// List all issues using `git bug ls --format json`.
pub fn list_issues(
  repo_dir: String,
) -> Result(List(gb_types.GitBugIssue), errors.TrackerError) {
  list_issues_timeout(repo_dir, 30_000)
}

/// List all issues with a configurable timeout (ms).
pub fn list_issues_timeout(
  repo_dir: String,
  timeout_ms: Int,
) -> Result(List(gb_types.GitBugIssue), errors.TrackerError) {
  case run_git_bug_timeout(repo_dir, ["ls", "--format", "json"], timeout_ms) {
    Ok(output) -> decode_issues(output)
    Error(msg) -> Error(shell_error("gitbug.list_issues", msg))
  }
}

/// Get a single issue by ID using `git bug show --format json <id>`.
pub fn get_issue(
  repo_dir: String,
  id: String,
) -> Result(gb_types.GitBugIssue, errors.TrackerError) {
  get_issue_timeout(repo_dir, id, 30_000)
}

/// Get a single issue with a configurable timeout (ms).
pub fn get_issue_timeout(
  repo_dir: String,
  id: String,
  timeout_ms: Int,
) -> Result(gb_types.GitBugIssue, errors.TrackerError) {
  case run_git_bug_timeout(repo_dir, ["show", "--format", "json", id], timeout_ms) {
    Ok(output) -> {
      use issues <- result.try(decode_issues(output))
      case issues {
        [issue, ..] -> Ok(issue)
        [] ->
          Error(errors.NotFound(
            resource: "gitbug_issue",
            identifier: Some(id),
            details: "No issue found with id: " <> id,
          ))
      }
    }
    Error(msg) -> Error(shell_error("gitbug.get_issue", msg))
  }
}

/// Change issue status using `git bug status open <id>` or `git bug status close <id>`.
/// git-bug only supports open/closed natively; Symphony maps states to these.
pub fn set_status(
  repo_dir: String,
  id: String,
  status: String,
) -> Result(Nil, errors.TrackerError) {
  let subcommand = case string.lowercase(status) {
    "open" -> "open"
    _ -> "close"
  }
  case run_git_bug(repo_dir, ["status", subcommand, id]) {
    Ok(_) -> Ok(Nil)
    Error(msg) ->
      Error(errors.WriteError(
        operation: "gitbug.set_status",
        resource_id: id,
        details: msg,
      ))
  }
}

/// Add a comment using `git bug comment add <id> -m <body>`.
pub fn add_comment(
  repo_dir: String,
  id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  case run_git_bug(repo_dir, ["comment", "add", id, "-m", body]) {
    Ok(_) -> Ok(Nil)
    Error(msg) ->
      Error(errors.WriteError(
        operation: "gitbug.add_comment",
        resource_id: id,
        details: msg,
      ))
  }
}

// ---------------------------------------------------------------------------
// Shell runner
// ---------------------------------------------------------------------------

/// Run `git bug <args>` in the given repo directory with a configurable timeout.
pub fn run_git_bug_timeout(
  repo_dir: String,
  args: List(String),
  timeout_ms: Int,
) -> Result(String, String) {
  do_run_command_timeout("git", ["bug", ..args], repo_dir, timeout_ms)
}

/// Run `git bug <args>` in the given repo directory (default 30s timeout).
fn run_git_bug(repo_dir: String, args: List(String)) -> Result(String, String) {
  do_run_command_timeout("git", ["bug", ..args], repo_dir, 30_000)
}

@external(erlang, "symphony_shell_ffi", "run_command_in_dir_timeout")
fn do_run_command_timeout(
  cmd: String,
  args: List(String),
  dir: String,
  timeout_ms: Int,
) -> Result(String, String)

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

/// git bug ls --format json outputs a JSON array of issue objects.
fn decode_issues(
  json_str: String,
) -> Result(List(gb_types.GitBugIssue), errors.TrackerError) {
  case json.decode(json_str, dynamic.list(decode_issue)) {
    Ok(issues) -> Ok(issues)
    Error(_) ->
      Error(errors.ApiError(
        operation: "gitbug.decode_issues",
        details: "Failed to decode git-bug JSON: "
          <> string.slice(json_str, 0, 200),
        status_code: None,
      ))
  }
}

fn decode_issue(
  dyn: dynamic.Dynamic,
) -> Result(gb_types.GitBugIssue, List(dynamic.DecodeError)) {
  use id <- result.try(dynamic.field("id", dynamic.string)(dyn))
  use human_id <- result.try(dynamic.field("humanId", dynamic.string)(dyn))
  use title <- result.try(dynamic.field("title", dynamic.string)(dyn))
  use status <- result.try(dynamic.field("status", dynamic.string)(dyn))

  let labels = case dynamic.field("labels", dynamic.list(dynamic.string))(dyn) {
    Ok(l) -> l
    Error(_) -> []
  }

  let author = decode_author(dyn)

  let created_at = case dynamic.field("createdAt", dynamic.string)(dyn) {
    Ok(t) -> Some(t)
    Error(_) -> None
  }

  let comments = case dynamic.field("comments", dynamic.int)(dyn) {
    Ok(n) -> n
    Error(_) -> 0
  }

  Ok(gb_types.GitBugIssue(
    id: id,
    human_id: human_id,
    title: title,
    status: status,
    labels: labels,
    author: author,
    created_at: created_at,
    comments: comments,
  ))
}

fn decode_author(dyn: dynamic.Dynamic) -> Option(String) {
  case dynamic.field("author", dynamic.dynamic)(dyn) {
    Ok(author_dyn) ->
      case dynamic.field("name", dynamic.string)(author_dyn) {
        Ok(name) -> Some(name)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

/// Map git-bug status to Symphony state string.
/// git-bug uses "open" / "closed".
pub fn status_to_state(status: String) -> String {
  case string.lowercase(status) {
    "open" -> "open"
    "closed" -> "closed"
    other -> other
  }
}

/// Map a Symphony terminal-state transition to git-bug's open/close model.
/// Any terminal state → "close"; otherwise → "open".
pub fn state_to_git_bug_status(
  state: String,
  terminal_states: List(String),
) -> String {
  case list.contains(terminal_states, state) {
    True -> "close"
    False -> "open"
  }
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

/// Convert a shell error message to a TrackerError.
/// Detects "command not found" / "not found" patterns and returns a helpful
/// installation hint instead of a raw shell error.
fn shell_error(operation: String, msg: String) -> errors.TrackerError {
  let lower = string.lowercase(msg)
  let is_not_found =
    string.contains(lower, "command not found")
    || string.contains(lower, "not found in path")
    || string.contains(lower, "no such file or directory")
    || string.contains(lower, "executable file not found")
  case is_not_found {
    True ->
      errors.ApiError(
        operation: operation,
        details: "git-bug not found in PATH. Install with: go install github.com/MichaelMure/git-bug@latest",
        status_code: None,
      )
    False ->
      errors.ApiError(operation: operation, details: msg, status_code: None)
  }
}
