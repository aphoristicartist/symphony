import gleam/list
import gleam/result
import symphony/config
import symphony/errors
import symphony/local/client
import symphony/local/normalizer
import symphony/types
import symphony/validation

/// Construct a TrackerAdapter backed by local YAML issue files.
/// Accepts the LocalConfig variant of TrackerConfig.
pub fn build(cfg: config.TrackerConfig) -> types.TrackerAdapter {
  types.TrackerAdapter(
    fetch_candidate_issues: fn() { fetch_candidate_issues(cfg) },
    fetch_issue_states_by_ids: fn(ids) { fetch_issue_states_by_ids(cfg, ids) },
    create_comment: fn(id, body) { create_comment(cfg, id, body) },
    update_issue_state: fn(id, state_name) {
      update_issue_state(cfg, id, state_name)
    },
  )
}

fn issues_dir(cfg: config.TrackerConfig) -> String {
  case cfg {
    config.LocalConfig(issues_dir: dir, ..) -> dir
    _ -> ""
  }
}

fn active_states(cfg: config.TrackerConfig) -> List(String) {
  case cfg {
    config.LocalConfig(active_states: states, ..) -> states
    _ -> []
  }
}

fn fetch_candidate_issues(
  cfg: config.TrackerConfig,
) -> Result(List(types.Issue), errors.TrackerError) {
  let dir = issues_dir(cfg)
  let states = active_states(cfg)

  use local_issues <- result.try(client.list_issues(dir))
  local_issues
  |> list.filter(fn(i) { validation.is_active_state_list(i.state, states) })
  |> list.map(fn(i) { normalizer.normalize_issue(i, dir) })
  |> Ok
}

fn fetch_issue_states_by_ids(
  cfg: config.TrackerConfig,
  issue_ids: List(String),
) -> Result(List(types.Issue), errors.TrackerError) {
  let dir = issues_dir(cfg)

  let results =
    list.map(issue_ids, fn(issue_id) {
      client.get_issue(dir, issue_id)
      |> result.map(fn(issue) { normalizer.normalize_issue(issue, dir) })
    })

  list.try_map(results, fn(r) { r })
}

fn create_comment(
  cfg: config.TrackerConfig,
  issue_id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  client.append_comment(issues_dir(cfg), issue_id, body)
}

fn update_issue_state(
  cfg: config.TrackerConfig,
  issue_id: String,
  state_name: String,
) -> Result(Nil, errors.TrackerError) {
  client.set_issue_state(issues_dir(cfg), issue_id, state_name)
}
