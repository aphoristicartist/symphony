import gleam/option.{None, Some}
import symphony/local/types as local_types
import symphony/types

/// Convert a LocalIssue to the canonical Symphony Issue type.
pub fn normalize_issue(
  local: local_types.LocalIssue,
  issues_dir: String,
) -> types.Issue {
  types.Issue(
    id: local.id,
    identifier: local.id,
    title: local.title,
    description: local.description,
    priority: local.priority,
    state: local.state,
    branch_name: None,
    url: Some("file://" <> issues_dir <> "/" <> local.id <> ".yaml"),
    labels: local.labels,
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )
}
