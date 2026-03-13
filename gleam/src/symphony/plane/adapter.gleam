import gleam/list
import gleam/option.{None, Some}
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
  use #(endpoint, workspace_slug, project_id) <- result.try(
    extract_plane_config(config),
  )

  use items <- result.try(plane_client.list_issues(
    endpoint,
    config.tracker.api_key,
    workspace_slug,
    project_id,
    config.tracker.active_states,
  ))

  Ok(list.map(items, normalizer.normalize_issue))
}

fn fetch_issue_states_by_ids(
  config: Config,
  issue_ids: List(String),
) -> Result(List(types.Issue), errors.TrackerError) {
  use #(endpoint, workspace_slug, project_id) <- result.try(
    extract_plane_config(config),
  )

  let results =
    list.map(issue_ids, fn(issue_id) {
      case
        plane_client.get_issue(
          endpoint,
          config.tracker.api_key,
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
  use #(endpoint, workspace_slug, project_id) <- result.try(
    extract_plane_config(config),
  )

  plane_client.create_comment(
    endpoint,
    config.tracker.api_key,
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
  use #(endpoint, workspace_slug, project_id) <- result.try(
    extract_plane_config(config),
  )

  use state_id <- result.try(plane_client.resolve_state_id(
    endpoint,
    config.tracker.api_key,
    workspace_slug,
    project_id,
    state_name,
  ))

  plane_client.update_issue_state(
    endpoint,
    config.tracker.api_key,
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
) -> Result(#(String, String, String), errors.TrackerError) {
  use endpoint <- result.try(case config.tracker.endpoint {
    Some(ep) -> Ok(ep)
    None ->
      Error(errors.ApiError(
        operation: "plane_config",
        details: "tracker.endpoint is required for Plane adapter",
        status_code: None,
      ))
  })

  use workspace_slug <- result.try(case config.tracker.workspace_slug {
    Some(ws) -> Ok(ws)
    None ->
      Error(errors.ApiError(
        operation: "plane_config",
        details: "tracker.workspace_slug is required for Plane adapter",
        status_code: None,
      ))
  })

  use project_id <- result.try(case config.tracker.project_id {
    Some(pid) -> Ok(pid)
    None ->
      Error(errors.ApiError(
        operation: "plane_config",
        details: "tracker.project_id is required for Plane adapter",
        status_code: None,
      ))
  })

  Ok(#(endpoint, workspace_slug, project_id))
}
