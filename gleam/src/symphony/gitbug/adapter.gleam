import gleam/list
import gleam/result
import symphony/config
import symphony/errors
import symphony/gitbug/client
import symphony/gitbug/normalizer
import symphony/types
import symphony/validation

/// Construct a TrackerAdapter backed by git-bug.
/// Accepts the GitBugConfig variant of TrackerConfig.
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

fn repo_dir(cfg: config.TrackerConfig) -> String {
  case cfg {
    config.GitBugConfig(repo_dir: d, ..) -> d
    _ -> "."
  }
}

fn active_states(cfg: config.TrackerConfig) -> List(String) {
  case cfg {
    config.GitBugConfig(active_states: s, ..) -> s
    _ -> []
  }
}

fn terminal_states(cfg: config.TrackerConfig) -> List(String) {
  case cfg {
    config.GitBugConfig(terminal_states: s, ..) -> s
    _ -> []
  }
}

fn command_timeout_ms(cfg: config.TrackerConfig) -> Int {
  case cfg {
    config.GitBugConfig(command_timeout_ms: t, ..) -> t
    _ -> 30_000
  }
}

fn fetch_candidate_issues(
  cfg: config.TrackerConfig,
) -> Result(List(types.Issue), errors.TrackerError) {
  let states = active_states(cfg)
  let timeout = command_timeout_ms(cfg)
  use issues <- result.try(client.list_issues_timeout(repo_dir(cfg), timeout))
  issues
  |> list.filter(fn(i) {
    validation.is_active_state_list(client.status_to_state(i.status), states)
  })
  |> list.map(normalizer.normalize_issue)
  |> Ok
}

fn fetch_issue_states_by_ids(
  cfg: config.TrackerConfig,
  issue_ids: List(String),
) -> Result(List(types.Issue), errors.TrackerError) {
  let dir = repo_dir(cfg)
  let timeout = command_timeout_ms(cfg)
  list.try_map(issue_ids, fn(id) {
    use issue <- result.try(client.get_issue_timeout(dir, id, timeout))
    Ok(normalizer.normalize_issue(issue))
  })
}

fn create_comment(
  cfg: config.TrackerConfig,
  issue_id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  client.add_comment(repo_dir(cfg), issue_id, body)
}

fn update_issue_state(
  cfg: config.TrackerConfig,
  issue_id: String,
  state_name: String,
) -> Result(Nil, errors.TrackerError) {
  let term = terminal_states(cfg)
  let git_bug_status = client.state_to_git_bug_status(state_name, term)
  client.set_status(repo_dir(cfg), issue_id, git_bug_status)
}
