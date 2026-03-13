import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import symphony/plane/types as plane_types
import symphony/types

/// Normalize a Plane work item to a Symphony Issue
pub fn normalize_issue(item: plane_types.PlaneWorkItem) -> types.Issue {
  let identifier = build_identifier(item.project_identifier, item.sequence_id)
  types.Issue(
    id: item.id,
    identifier: identifier,
    title: item.name,
    description: item.description_html,
    priority: normalize_priority(item.priority),
    state: item.state_detail.name,
    branch_name: None,
    url: None,
    labels: list.map(item.label_details, fn(label) { label.name }),
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )
}

/// Normalize priority string to int (urgent=1, high=2, medium=3, low=4, none=0)
pub fn normalize_priority(priority: Option(String)) -> Option(Int) {
  case priority {
    None -> Some(0)
    Some(p) -> {
      case string.lowercase(p) {
        "urgent" -> Some(1)
        "high" -> Some(2)
        "medium" -> Some(3)
        "low" -> Some(4)
        "none" -> Some(0)
        _ -> Some(0)
      }
    }
  }
}

/// Build an identifier from project prefix and sequence ID (e.g., "PROJ-42")
pub fn build_identifier(project_identifier: String, sequence_id: Int) -> String {
  project_identifier <> "-" <> int.to_string(sequence_id)
}
