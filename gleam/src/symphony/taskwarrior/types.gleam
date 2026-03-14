import gleam/option.{type Option}

/// A Taskwarrior task as returned by `task export`.
pub type TaskwarriorTask {
  TaskwarriorTask(
    uuid: String,
    id: Int,
    description: String,
    status: String,
    project: Option(String),
    priority: Option(String),
    tags: List(String),
    annotations: List(String),
    entry: Option(String),
    modified: Option(String),
  )
}
