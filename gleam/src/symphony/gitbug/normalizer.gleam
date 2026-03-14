import gleam/option.{None, Some}
import symphony/gitbug/client
import symphony/gitbug/types as gb_types
import symphony/types

/// Convert a GitBugIssue to the canonical Symphony Issue type.
pub fn normalize_issue(issue: gb_types.GitBugIssue) -> types.Issue {
  let description = case issue.author {
    Some(author) -> Some("Author: " <> author)
    None -> None
  }

  types.Issue(
    id: issue.id,
    identifier: issue.human_id,
    title: issue.title,
    description: description,
    priority: None,
    state: client.status_to_state(issue.status),
    branch_name: None,
    url: None,
    labels: issue.labels,
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )
}
