import gleam/option.{type Option}

/// A git-bug issue as returned by `git bug ls --format json`.
pub type GitBugIssue {
  GitBugIssue(
    id: String,
    human_id: String,
    title: String,
    status: String,
    labels: List(String),
    author: Option(String),
    created_at: Option(String),
    comments: Int,
  )
}
