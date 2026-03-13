import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import symphony/errors
import symphony/local/types as local_types

/// List all .yaml files in the issues directory and decode them.
/// Skips unreadable or unparseable files rather than failing the whole list.
pub fn list_issues(
  issues_dir: String,
) -> Result(List(local_types.LocalIssue), errors.TrackerError) {
  use filenames <- result.try(
    simplifile.read_directory(issues_dir)
    |> result.map_error(fn(_) {
      errors.ApiError(
        operation: "list_issues",
        details: "Failed to read issues directory: " <> issues_dir,
        status_code: None,
      )
    }),
  )

  let yaml_files =
    filenames
    |> list.filter(fn(name) { string.ends_with(name, ".yaml") })

  let issues =
    yaml_files
    |> list.filter_map(fn(filename) {
      let full_path = issues_dir <> "/" <> filename
      case simplifile.read(full_path) {
        Ok(content) ->
          case parse_issue_yaml(content) {
            Ok(issue) -> Ok(issue)
            Error(_) -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    })

  Ok(issues)
}

/// Read a single issue file by ID. Searches for <issues_dir>/<id>.yaml
pub fn get_issue(
  issues_dir: String,
  id: String,
) -> Result(local_types.LocalIssue, errors.TrackerError) {
  let clean_id = strip_yaml_suffix(id)
  let path = issues_dir <> "/" <> clean_id <> ".yaml"

  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) {
      errors.NotFound(
        resource: "local_issue",
        identifier: Some(id),
        details: "Issue file not found: " <> path,
      )
    }),
  )

  parse_issue_yaml(content)
  |> result.map_error(fn(details) {
    errors.ApiError(operation: "get_issue", details: details, status_code: None)
  })
}

/// Update the state field in an issue file.
pub fn set_issue_state(
  issues_dir: String,
  id: String,
  new_state: String,
) -> Result(Nil, errors.TrackerError) {
  let clean_id = strip_yaml_suffix(id)
  let path = issues_dir <> "/" <> clean_id <> ".yaml"

  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) {
      errors.NotFound(
        resource: "local_issue",
        identifier: Some(id),
        details: "Issue file not found: " <> path,
      )
    }),
  )

  let lines = string.split(content, "\n")
  let updated_lines =
    list.map(lines, fn(line) {
      let trimmed = string.trim(line)
      case string.starts_with(trimmed, "state:") {
        True -> "state: " <> new_state
        False -> line
      }
    })
  let updated_content = string.join(updated_lines, "\n")

  simplifile.write(path, updated_content)
  |> result.map_error(fn(_) {
    errors.WriteError(
      operation: "set_issue_state",
      resource_id: id,
      details: "Failed to write issue file: " <> path,
    )
  })
}

/// Append a comment block to the end of an issue file.
pub fn append_comment(
  issues_dir: String,
  id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  let clean_id = strip_yaml_suffix(id)
  let path = issues_dir <> "/" <> clean_id <> ".yaml"

  let comment_block = "\n# Comment\n" <> body <> "\n"

  simplifile.append(path, comment_block)
  |> result.map_error(fn(_) {
    errors.WriteError(
      operation: "append_comment",
      resource_id: id,
      details: "Failed to append comment to issue file: " <> path,
    )
  })
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Strip a .yaml suffix from an ID string if present.
fn strip_yaml_suffix(id: String) -> String {
  case string.ends_with(id, ".yaml") {
    True -> string.drop_right(id, 5)
    False -> id
  }
}

/// Parse a LocalIssue from YAML content.
/// Supports simple flat key: value pairs and a list for labels.
fn parse_issue_yaml(content: String) -> Result(local_types.LocalIssue, String) {
  let pairs = parse_flat_yaml(content)

  use id <- result.try(case list.key_find(pairs, "id") {
    Ok(v) -> Ok(v)
    Error(_) -> Error("Missing required field: id")
  })

  use title <- result.try(case list.key_find(pairs, "title") {
    Ok(v) -> Ok(v)
    Error(_) -> Error("Missing required field: title")
  })

  use state <- result.try(case list.key_find(pairs, "state") {
    Ok(v) -> Ok(v)
    Error(_) -> Error("Missing required field: state")
  })

  let description = case list.key_find(pairs, "description") {
    Ok(v) if v != "" -> Some(v)
    _ -> parse_block_scalar(content, "description")
  }

  let priority = case list.key_find(pairs, "priority") {
    Ok(v) ->
      case int.parse(v) {
        Ok(i) -> Some(i)
        Error(_) -> None
      }
    Error(_) -> None
  }

  let labels = parse_list_field(content, "labels")

  Ok(local_types.LocalIssue(
    id: id,
    title: title,
    description: description,
    state: state,
    priority: priority,
    labels: labels,
  ))
}

/// Parse flat key: value pairs from YAML content (non-indented, non-list lines).
fn parse_flat_yaml(content: String) -> List(#(String, String)) {
  content
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    let trimmed = string.trim(line)
    case
      string.starts_with(trimmed, "#")
      || trimmed == ""
      || string.starts_with(trimmed, "- ")
      || string.starts_with(line, "  ")
      || string.starts_with(line, "\t")
    {
      True -> Error(Nil)
      False ->
        case string.split_once(trimmed, ":") {
          Ok(#(key, value)) -> Ok(#(string.trim(key), string.trim(value)))
          Error(_) -> Error(Nil)
        }
    }
  })
}

/// Parse a YAML block scalar (lines after `key: |`) into a single string.
/// Returns None if the field is not present or has no block content.
fn parse_block_scalar(content: String, key: String) -> Option(String) {
  let lines = string.split(content, "\n")
  case find_block_scalar_start(lines, key) {
    None -> None
    Some(rest) -> {
      let block_lines =
        rest
        |> list.take_while(fn(line) {
          string.starts_with(line, "  ") || string.starts_with(line, "\t")
        })
        |> list.map(fn(line) {
          case string.starts_with(line, "  ") {
            True -> string.drop_left(line, 2)
            False -> string.drop_left(line, 1)
          }
        })
      case block_lines {
        [] -> None
        _ -> Some(string.join(block_lines, "\n"))
      }
    }
  }
}

/// Find the lines after a `key: |` block scalar marker.
fn find_block_scalar_start(
  lines: List(String),
  key: String,
) -> Option(List(String)) {
  case lines {
    [] -> None
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      let marker = key <> ": |"
      case trimmed == marker {
        True -> Some(rest)
        False -> find_block_scalar_start(rest, key)
      }
    }
  }
}

/// Parse a YAML list field (lines after `key:` that start with `- `).
fn parse_list_field(content: String, key: String) -> List(String) {
  let lines = string.split(content, "\n")
  case find_list_start(lines, key) {
    None -> []
    Some(rest) -> {
      rest
      |> list.take_while(fn(line) {
        let trimmed = string.trim(line)
        string.starts_with(trimmed, "- ")
      })
      |> list.filter_map(fn(line) {
        let trimmed = string.trim(line)
        case string.starts_with(trimmed, "- ") {
          True -> Ok(string.drop_left(trimmed, 2))
          False -> Error(Nil)
        }
      })
    }
  }
}

/// Find lines after a list key marker (`key:` on its own line).
fn find_list_start(lines: List(String), key: String) -> Option(List(String)) {
  case lines {
    [] -> None
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed == key <> ":" {
        True -> Some(rest)
        False -> find_list_start(rest, key)
      }
    }
  }
}
