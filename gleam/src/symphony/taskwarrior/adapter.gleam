import gleam/list
import gleam/option.{None}
import gleam/result
import symphony/config
import symphony/errors
import symphony/taskwarrior/client
import symphony/taskwarrior/normalizer
import symphony/types
import symphony/validation

/// Construct a TrackerAdapter backed by Taskwarrior.
/// Accepts the TaskwarriorConfig variant of TrackerConfig.
pub fn build(cfg: config.TrackerConfig) -> types.TrackerAdapter {
  types.TrackerAdapter(
    fetch_candidate_issues: fn() { fetch_candidate_issues(cfg) },
    fetch_issue_states_by_ids: fn(ids) { fetch_issue_states_by_ids(cfg, ids) },
    create_comment: fn(id, body) { create_comment(id, body) },
    update_issue_state: fn(id, state_name) {
      update_issue_state(cfg, id, state_name)
    },
  )
}

fn project(cfg: config.TrackerConfig) -> option.Option(String) {
  case cfg {
    config.TaskwarriorConfig(project: p, ..) -> p
    _ -> None
  }
}

fn active_states(cfg: config.TrackerConfig) -> List(String) {
  case cfg {
    config.TaskwarriorConfig(active_states: s, ..) -> s
    _ -> []
  }
}

fn terminal_states(cfg: config.TrackerConfig) -> List(String) {
  case cfg {
    config.TaskwarriorConfig(terminal_states: s, ..) -> s
    _ -> []
  }
}

fn fetch_candidate_issues(
  cfg: config.TrackerConfig,
) -> Result(List(types.Issue), errors.TrackerError) {
  let states = active_states(cfg)
  use tasks <- result.try(client.list_tasks(project(cfg)))
  tasks
  |> list.filter(fn(t) {
    validation.is_active_state_list(client.status_to_state(t.status), states)
  })
  |> list.map(normalizer.normalize_task)
  |> Ok
}

fn fetch_issue_states_by_ids(
  cfg: config.TrackerConfig,
  issue_ids: List(String),
) -> Result(List(types.Issue), errors.TrackerError) {
  let _ = cfg
  list.try_map(issue_ids, fn(uuid) {
    use task <- result.try(client.get_task(uuid))
    Ok(normalizer.normalize_task(task))
  })
}

fn create_comment(
  issue_id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  client.annotate_task(issue_id, body)
}

fn update_issue_state(
  cfg: config.TrackerConfig,
  issue_id: String,
  state_name: String,
) -> Result(Nil, errors.TrackerError) {
  // Map Symphony state name → Taskwarrior status.
  // If the state is terminal → completed; otherwise → pending.
  let term = terminal_states(cfg)
  let tw_status = case list.contains(term, state_name) {
    True -> "completed"
    False -> "pending"
  }
  client.set_task_status(issue_id, tw_status)
}
