import gleam/int
import gleam/option.{None, Some}
import symphony/taskwarrior/client
import symphony/taskwarrior/types as tw_types
import symphony/types

/// Convert a TaskwarriorTask to the canonical Symphony Issue type.
/// The `entry` and `modified` fields are ISO strings; Symphony's Issue uses
/// Option(Int) Unix ms, so we leave timestamps as None.
pub fn normalize_task(task: tw_types.TaskwarriorTask) -> types.Issue {
  let _ = task.entry
  let _ = task.modified
  let description = case task.project {
    Some(p) -> Some("Project: " <> p)
    None -> None
  }

  types.Issue(
    id: task.uuid,
    identifier: "TW-" <> int.to_string(task.id),
    title: task.description,
    description: description,
    priority: client.priority_to_int(task.priority),
    state: client.status_to_state(task.status),
    branch_name: None,
    url: None,
    labels: task.tags,
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )
}
