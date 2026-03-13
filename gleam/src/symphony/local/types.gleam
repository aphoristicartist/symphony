import gleam/option.{type Option}

/// Issue as stored in a local YAML file.
pub type LocalIssue {
  LocalIssue(
    id: String,
    title: String,
    description: Option(String),
    state: String,
    priority: Option(Int),
    labels: List(String),
  )
}
