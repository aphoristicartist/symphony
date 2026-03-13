import gleam/dynamic
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/option
import gleam/result
import symphony/config.{type Config}
import symphony/errors
import symphony/types.{type BlockerRef, type Issue, BlockerRef, Issue}

/// Linear GraphQL API endpoint
const linear_api_url = "https://api.linear.app/graphql"

/// Extract Linear-specific fields from TrackerConfig.
fn linear_fields(config: Config) -> #(String, String) {
  case config.tracker {
    config.LinearConfig(api_key: k, project_slug: slug, ..) -> #(k, slug)
    config.PlaneConfig(api_key: k, ..) -> #(k, "")
    config.LocalConfig(..) -> #("", "")
  }
}

/// Fetch active issues from Linear
pub fn fetch_active_issues(
  config: Config,
) -> Result(List(Issue), errors.TrackerError) {
  let #(api_key, project_slug) = linear_fields(config)
  let query = build_active_issues_query(project_slug)
  let req = build_graphql_request(api_key, query)

  use response <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) {
      errors.ApiError(
        operation: "fetch_active_issues",
        details: "HTTP request failed",
        status_code: option.None,
      )
    }),
  )

  use body <- result.try(parse_graphql_response(response))
  extract_issues_from_response(body)
}

/// Fetch the state of a specific issue
pub fn fetch_issue_state(
  config: Config,
  issue_id: String,
) -> Result(String, errors.TrackerError) {
  let #(api_key, _) = linear_fields(config)
  let query = build_issue_state_query(issue_id)
  let req = build_graphql_request(api_key, query)

  use response <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) {
      errors.ApiError(
        operation: "fetch_issue_state",
        details: "HTTP request failed",
        status_code: option.None,
      )
    }),
  )

  use body <- result.try(parse_graphql_response(response))
  extract_state_from_response(body, issue_id)
}

/// Build GraphQL query for active issues
fn build_active_issues_query(project_slug: String) -> String {
  "query { issues(filter: { project: { identifier: { eq: \""
  <> project_slug
  <> "\" } } }) { nodes { id identifier title description state { name } priority branchName url labels { nodes { name } } blockedBy { nodes { id identifier state { name } } } createdAt updatedAt } } }"
}

/// Build GraphQL query for issue state
fn build_issue_state_query(issue_id: String) -> String {
  "query { issue(id: \"" <> issue_id <> "\") { state { name } } }"
}

/// Build a GraphQL HTTP request
fn build_graphql_request(api_key: String, query: String) -> Request(String) {
  let body = json.object([#("query", json.string(query))]) |> json.to_string

  request.new()
  |> request.set_method(http.Post)
  |> request.set_host(linear_api_url)
  |> request.prepend_header("Authorization", "Bearer " <> api_key)
  |> request.prepend_header("Content-Type", "application/json")
  |> request.set_body(body)
}

/// Parse GraphQL response
fn parse_graphql_response(
  response: Response(String),
) -> Result(dynamic.Dynamic, errors.TrackerError) {
  case response.status {
    200 -> {
      json.decode(response.body, dynamic.dynamic)
      |> result.map_error(fn(_) {
        errors.ApiError(
          operation: "parse_graphql_response",
          details: "Failed to parse JSON response",
          status_code: option.Some(200),
        )
      })
    }
    429 -> {
      Error(errors.RateLimit(
        retry_after_ms: option.None,
        scope: option.None,
        details: "Linear API returned HTTP 429",
      ))
    }
    _ -> {
      Error(errors.ApiError(
        operation: "graphql_request",
        details: "HTTP error: " <> int.to_string(response.status),
        status_code: option.Some(response.status),
      ))
    }
  }
}

/// Extract issues from GraphQL response
fn extract_issues_from_response(
  body: dynamic.Dynamic,
) -> Result(List(Issue), errors.TrackerError) {
  // Navigate the response structure: data.issues.nodes
  let decoder =
    dynamic.field(
      "data",
      dynamic.field(
        "issues",
        dynamic.field("nodes", dynamic.list(decode_issue)),
      ),
    )

  case decoder(body) {
    Ok(issues) -> Ok(issues)
    Error(_) ->
      Error(errors.ApiError(
        operation: "decode_active_issues",
        details: "Failed to decode issues from response",
        status_code: option.None,
      ))
  }
}

/// Extract state from GraphQL response
fn extract_state_from_response(
  body: dynamic.Dynamic,
  issue_id: String,
) -> Result(String, errors.TrackerError) {
  let decoder =
    dynamic.field(
      "data",
      dynamic.field(
        "issue",
        dynamic.field("state", dynamic.field("name", dynamic.string)),
      ),
    )

  case decoder(body) {
    Ok(state) -> Ok(state)
    Error(_) ->
      Error(errors.NotFound(
        resource: "issue",
        identifier: option.Some(issue_id),
        details: "Failed to decode issue state from response",
      ))
  }
}

/// Decode an Issue from dynamic
fn decode_issue(
  dyn: dynamic.Dynamic,
) -> Result(Issue, List(dynamic.DecodeError)) {
  let id_decoder = dynamic.field("id", dynamic.string)
  let identifier_decoder = dynamic.field("identifier", dynamic.string)
  let title_decoder = dynamic.field("title", dynamic.string)
  let description_decoder =
    dynamic.optional_field("description", dynamic.optional(dynamic.string))
  let state_decoder =
    dynamic.field("state", dynamic.field("name", dynamic.string))
  let priority_decoder =
    dynamic.optional_field("priority", dynamic.optional(dynamic.int))
  let branch_name_decoder =
    dynamic.optional_field("branchName", dynamic.optional(dynamic.string))
  let url_decoder =
    dynamic.optional_field("url", dynamic.optional(dynamic.string))
  let labels_decoder =
    dynamic.field(
      "labels",
      dynamic.field(
        "nodes",
        dynamic.list(dynamic.field("name", dynamic.string)),
      ),
    )
  let blocked_by_decoder =
    dynamic.field(
      "blockedBy",
      dynamic.field("nodes", dynamic.list(decode_blocker_ref)),
    )
  let created_at_decoder =
    dynamic.optional_field("createdAt", dynamic.optional(dynamic.int))
  let updated_at_decoder =
    dynamic.optional_field("updatedAt", dynamic.optional(dynamic.int))

  use id <- result.try(id_decoder(dyn))
  use identifier <- result.try(identifier_decoder(dyn))
  use title <- result.try(title_decoder(dyn))
  use description <- result.try(description_decoder(dyn))
  use state <- result.try(state_decoder(dyn))
  use priority <- result.try(priority_decoder(dyn))
  use branch_name <- result.try(branch_name_decoder(dyn))
  use url <- result.try(url_decoder(dyn))
  use labels <- result.try(labels_decoder(dyn))
  use blocked_by <- result.try(blocked_by_decoder(dyn))
  use created_at <- result.try(created_at_decoder(dyn))
  use updated_at <- result.try(updated_at_decoder(dyn))

  Ok(Issue(
    id: id,
    identifier: identifier,
    title: title,
    description: description |> option.flatten,
    state: state,
    priority: priority |> option.flatten,
    branch_name: branch_name |> option.flatten,
    url: url |> option.flatten,
    labels: labels,
    blocked_by: blocked_by,
    created_at: created_at |> option.flatten,
    updated_at: updated_at |> option.flatten,
  ))
}

/// Decode a BlockerRef from dynamic
fn decode_blocker_ref(
  dyn: dynamic.Dynamic,
) -> Result(BlockerRef, List(dynamic.DecodeError)) {
  let id_decoder = dynamic.optional_field("id", dynamic.string)
  let identifier_decoder = dynamic.optional_field("identifier", dynamic.string)
  let state_decoder =
    dynamic.field(
      "state",
      dynamic.optional(dynamic.field("name", dynamic.string)),
    )

  use id <- result.try(id_decoder(dyn))
  use identifier <- result.try(identifier_decoder(dyn))
  use state <- result.try(state_decoder(dyn))

  Ok(BlockerRef(id: id, identifier: identifier, state: state))
}
