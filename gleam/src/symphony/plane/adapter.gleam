import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import symphony/config.{type Config}
import symphony/errors
import symphony/plane/client as plane_client
import symphony/plane/normalizer
import symphony/types

/// Construct a TrackerAdapter backed by the Plane REST API.
pub fn build() -> types.TrackerAdapter {
  types.TrackerAdapter(
    fetch_candidate_issues: fetch_candidate_issues,
    fetch_issue_states_by_ids: fetch_issue_states_by_ids,
    create_comment: create_comment,
    update_issue_state: update_issue_state,
  )
}

/// Fetch candidate issues from Plane, filtered by active states.
pub fn fetch_candidate_issues(
  config_dyn: dynamic.Dynamic,
) -> Result(List(types.Issue), errors.TrackerError) {
  let config: Config = dynamic.unsafe_coerce(config_dyn)

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

/// Fetch current state for a list of issue IDs (for reconciliation).
pub fn fetch_issue_states_by_ids(
  config_dyn: dynamic.Dynamic,
  issue_ids: List(String),
) -> Result(List(types.Issue), errors.TrackerError) {
  let config: Config = dynamic.unsafe_coerce(config_dyn)

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

/// Post a comment on a Plane issue.
pub fn create_comment(
  config_dyn: dynamic.Dynamic,
  issue_id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  let config: Config = dynamic.unsafe_coerce(config_dyn)

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

/// Transition a Plane issue to a new state by name.
pub fn update_issue_state(
  config_dyn: dynamic.Dynamic,
  issue_id: String,
  state_name: String,
) -> Result(Nil, errors.TrackerError) {
  let config: Config = dynamic.unsafe_coerce(config_dyn)

  use #(endpoint, workspace_slug, project_id) <- result.try(
    extract_plane_config(config),
  )

  // Resolve state name to UUID
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
