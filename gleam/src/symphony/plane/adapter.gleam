import gleam/list
import gleam/option.{None}
import gleam/result
import symphony/config.{type Config}
import symphony/errors
import symphony/plane/client as plane_client
import symphony/plane/normalizer
import symphony/types

/// Construct a TrackerAdapter backed by the Plane REST API.
/// The config is closed over at build time; no Dynamic passing needed.
pub fn build(config: Config) -> types.TrackerAdapter {
  types.TrackerAdapter(
    fetch_candidate_issues: fn() { fetch_candidate_issues(config) },
    fetch_issue_states_by_ids: fn(ids) {
      fetch_issue_states_by_ids(config, ids)
    },
    create_comment: fn(issue_id, body) {
      create_comment(config, issue_id, body)
    },
    update_issue_state: fn(issue_id, state_name) {
      update_issue_state(config, issue_id, state_name)
    },
  )
}

fn fetch_candidate_issues(
  config: Config,
) -> Result(List(types.Issue), errors.TrackerError) {
  use #(api_key, endpoint, workspace_slug, project_id, active_states) <- result.try(
    extract_plane_config(config),
  )

  use items <- result.try(plane_client.list_issues(
    endpoint,
    api_key,
    workspace_slug,
    project_id,
    active_states,
  ))

  Ok(list.map(items, normalizer.normalize_issue))
}

fn fetch_issue_states_by_ids(
  config: Config,
  issue_ids: List(String),
) -> Result(List(types.Issue), errors.TrackerError) {
  use #(api_key, endpoint, workspace_slug, project_id, _active_states) <- result.try(
    extract_plane_config(config),
  )

  let results =
    list.map(issue_ids, fn(issue_id) {
      case
        plane_client.get_issue(
          endpoint,
          api_key,
          workspace_slug,
          project_id,
          issue_id,
        )
      {
        Ok(item) -> Ok(normalizer.normalize_issue(item))
        Error(e) -> Error(e)
      }
    })

  list.try_map(results, fn(r) { r })
}

fn create_comment(
  config: Config,
  issue_id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  use #(api_key, endpoint, workspace_slug, project_id, _active_states) <- result.try(
    extract_plane_config(config),
  )

  plane_client.create_comment(
    endpoint,
    api_key,
    workspace_slug,
    project_id,
    issue_id,
    body,
  )
}

fn update_issue_state(
  config: Config,
  issue_id: String,
  state_name: String,
) -> Result(Nil, errors.TrackerError) {
  use #(api_key, endpoint, workspace_slug, project_id, _active_states) <- result.try(
    extract_plane_config(config),
  )

  use state_id <- result.try(plane_client.resolve_state_id(
    endpoint,
    api_key,
    workspace_slug,
    project_id,
    state_name,
  ))

  plane_client.update_issue_state(
    endpoint,
    api_key,
    workspace_slug,
    project_id,
    issue_id,
    state_id,
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract required Plane-specific config fields.
fn extract_plane_config(
  config: Config,
) -> Result(
  #(String, String, String, String, List(String)),
  errors.TrackerError,
) {
  case config.tracker {
    config.PlaneConfig(
      api_key: api_key,
      endpoint: endpoint,
      workspace_slug: workspace_slug,
      project_id: project_id,
      active_states: active_states,
      ..,
    ) -> Ok(#(api_key, endpoint, workspace_slug, project_id, active_states))
    config.LinearConfig(..)
    | config.LocalConfig(..)
    | config.TaskwarriorConfig(..)
    | config.GitBugConfig(..) ->
      Error(errors.ApiError(
        operation: "plane_config",
        details: "Plane adapter requires PlaneConfig tracker configuration",
        status_code: None,
      ))
  }
}
