import gleam/dynamic
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import symphony/errors
import symphony/taskwarrior/types as tw_types

/// Export all tasks as JSON using `task export`.
/// Optionally filter by a project name.
pub fn list_tasks(
  project: Option(String),
) -> Result(List(tw_types.TaskwarriorTask), errors.TrackerError) {
  let filter = case project {
    Some(p) -> "project:" <> p
    None -> ""
  }
  let args = case filter {
    "" -> ["export"]
    f -> [f, "export"]
  }
  case run_task(args) {
    Ok(output) -> decode_tasks(output)
    Error(msg) ->
      Error(errors.ApiError(
        operation: "taskwarrior.list_tasks",
        details: msg,
        status_code: None,
      ))
  }
}

/// Export a single task by UUID.
pub fn get_task(
  uuid: String,
) -> Result(tw_types.TaskwarriorTask, errors.TrackerError) {
  case run_task([uuid, "export"]) {
    Ok(output) -> {
      use tasks <- result.try(decode_tasks(output))
      case tasks {
        [task, ..] -> Ok(task)
        [] ->
          Error(errors.NotFound(
            resource: "taskwarrior_task",
            identifier: Some(uuid),
            details: "No task found with uuid: " <> uuid,
          ))
      }
    }
    Error(msg) ->
      Error(errors.ApiError(
        operation: "taskwarrior.get_task",
        details: msg,
        status_code: None,
      ))
  }
}

/// Modify a task's status using `task <uuid> modify status:<new_status>`.
/// Valid statuses: pending, completed, deleted, waiting, recurring.
pub fn set_task_status(
  uuid: String,
  status: String,
) -> Result(Nil, errors.TrackerError) {
  case run_task([uuid, "modify", "status:" <> status]) {
    Ok(_) -> Ok(Nil)
    Error(msg) ->
      Error(errors.WriteError(
        operation: "taskwarrior.set_task_status",
        resource_id: uuid,
        details: msg,
      ))
  }
}

/// Add an annotation (comment) to a task using `task <uuid> annotate <text>`.
pub fn annotate_task(
  uuid: String,
  text: String,
) -> Result(Nil, errors.TrackerError) {
  case run_task([uuid, "annotate", text]) {
    Ok(_) -> Ok(Nil)
    Error(msg) ->
      Error(errors.WriteError(
        operation: "taskwarrior.annotate_task",
        resource_id: uuid,
        details: msg,
      ))
  }
}

// ---------------------------------------------------------------------------
// Shell runner
// ---------------------------------------------------------------------------

/// Run `task <args>` and return stdout, or an error string.
fn run_task(args: List(String)) -> Result(String, String) {
  do_run_command("task", args)
}

@external(erlang, "symphony_shell_ffi", "run_command")
fn do_run_command(cmd: String, args: List(String)) -> Result(String, String)

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

fn decode_tasks(
  json_str: String,
) -> Result(List(tw_types.TaskwarriorTask), errors.TrackerError) {
  case json.decode(json_str, dynamic.list(decode_task)) {
    Ok(tasks) -> Ok(tasks)
    Error(_) ->
      Error(errors.ApiError(
        operation: "taskwarrior.decode_tasks",
        details: "Failed to decode task JSON: "
          <> string.slice(json_str, 0, 200),
        status_code: None,
      ))
  }
}

fn decode_task(
  dyn: dynamic.Dynamic,
) -> Result(tw_types.TaskwarriorTask, List(dynamic.DecodeError)) {
  use uuid <- result.try(dynamic.field("uuid", dynamic.string)(dyn))
  use id <- result.try(dynamic.field("id", dynamic.int)(dyn))
  use description <- result.try(dynamic.field("description", dynamic.string)(dyn))
  use status <- result.try(dynamic.field("status", dynamic.string)(dyn))

  let project = case dynamic.field("project", dynamic.string)(dyn) {
    Ok(p) -> Some(p)
    Error(_) -> None
  }

  let priority = case dynamic.field("priority", dynamic.string)(dyn) {
    Ok(p) -> Some(p)
    Error(_) -> None
  }

  let tags = case dynamic.field("tags", dynamic.list(dynamic.string))(dyn) {
    Ok(t) -> t
    Error(_) -> []
  }

  let annotations = decode_annotations(dyn)

  let entry = case dynamic.field("entry", dynamic.string)(dyn) {
    Ok(e) -> Some(e)
    Error(_) -> None
  }

  let modified = case dynamic.field("modified", dynamic.string)(dyn) {
    Ok(m) -> Some(m)
    Error(_) -> None
  }

  Ok(tw_types.TaskwarriorTask(
    uuid: uuid,
    id: id,
    description: description,
    status: status,
    project: project,
    priority: priority,
    tags: tags,
    annotations: annotations,
    entry: entry,
    modified: modified,
  ))
}

/// Taskwarrior annotations are `[{entry, description}]` objects.
fn decode_annotations(dyn: dynamic.Dynamic) -> List(String) {
  case
    dynamic.field(
      "annotations",
      dynamic.list(fn(a) {
        dynamic.field("description", dynamic.string)(a)
      }),
    )(dyn)
  {
    Ok(descs) -> descs
    Error(_) -> []
  }
}

/// Map a Taskwarrior status string to a Symphony-facing state name.
/// pending → status as-is (Symphony config drives active/terminal logic).
pub fn status_to_state(status: String) -> String {
  status
}

/// Map a priority letter to an integer (H=1, M=2, L=3, none=0).
pub fn priority_to_int(priority: Option(String)) -> Option(Int) {
  case priority {
    Some("H") -> Some(1)
    Some("M") -> Some(2)
    Some("L") -> Some(3)
    Some(other) ->
      case int.parse(other) {
        Ok(n) -> Some(n)
        Error(_) -> None
      }
    None -> None
  }
}
