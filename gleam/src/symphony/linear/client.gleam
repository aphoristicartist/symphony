import gleam/dict
import gleam/dynamic
import gleam/http.{type Request}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import symphony/config.{type Config}
import symphony/types.{type BlockerRef, type Issue}

/// Linear GraphQL API endpoint
const linear_api_url = "https://api.linear.app/graphql"

/// Fetch active issues from Linear
pub fn fetch_active_issues(config: Config) -> Result(List(Issue), String) {
  let query = build_active_issues_query(config.tracker.project_slug)
  let req = build_graphql_request(config.tracker.api_key, query)

  use response <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )

  use body <- result.try(parse_graphql_response(response))
  extract_issues_from_response(body)
}

/// Fetch the state of a specific issue
pub fn fetch_issue_state(
  config: Config,
  issue_id: String,
) -> Result(String, String) {
  let query = build_issue_state_query(issue_id)
  let req = build_graphql_request(config.tracker.api_key, query)

  use response <- result.try(
    httpc.send(req)
    |> result.map_error(fn(_) { "HTTP request failed" }),
  )

  use body <- result.try(parse_graphql_response(response))
  extract_state_from_response(body)
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
fn parse_graphql_response(response: Response(String)) -> Result(dynamic.Dynamic, String) {
  case response.status {
    200 -> {
      json.decode(response.body, dynamic.dynamic)
      |> result.map_error(fn(_) { "Failed to parse JSON response" })
    }
    _ -> Error("HTTP error: " <> int.to_string(response.status))
  }
}

/// Extract issues from GraphQL response
fn extract_issues_from_response(body: dynamic.Dynamic) -> Result(List(Issue), String) {
  // Navigate the response structure: data.issues.nodes
  let decoder = dynamic.field(
    "data",
    dynamic.field(
      "issues",
      dynamic.field("nodes", dynamic.list(decode_issue)),
    ),
  )

  case decoder(body) {
    Ok(issues) -> Ok(issues)
    Error(_) -> Error("Failed to decode issues from response")
  }
}

/// Extract state from GraphQL response
fn extract_state_from_response(body: dynamic.Dynamic) -> Result(String, String) {
  let decoder = dynamic.field(
    "data",
    dynamic.field(
      "issue",
      dynamic.field("state", dynamic.field("name", dynamic.string)),
    ),
  )

  case decoder(body) {
    Ok(state) -> Ok(state)
    Error(_) -> Error("Failed to decode issue state from response")
  }
}

/// Decode an Issue from dynamic
fn decode_issue(dyn: dynamic.Dynamic) -> Result(Issue, List(dynamic.DecodeError)) {
  use id <- dynamic.field("id", dynamic.string)(dyn)
  use identifier <- dynamic.field("identifier", dynamic.string)(dyn)
  use title <- dynamic.field("title", dynamic.string)(dyn)
  use description <- dynamic.optional_field(
    "description",
    dynamic.optional(dynamic.string),
  )(dyn)
  use state <- dynamic.field(
    "state",
    dynamic.field("name", dynamic.string),
  )(dyn)
  use priority <- dynamic.optional_field(
    "priority",
    dynamic.optional(dynamic.int),
  )(dyn)
  use branch_name <- dynamic.optional_field(
    "branchName",
    dynamic.optional(dynamic.string),
  )(dyn)
  use url <- dynamic.optional_field("url", dynamic.optional(dynamic.string))(dyn)
  use labels <- dynamic.field(
    "labels",
    dynamic.field("nodes", dynamic.list(dynamic.field("name", dynamic.string))),
  )(dyn)
  use blocked_by <- dynamic.field(
    "blockedBy",
    dynamic.field("nodes", dynamic.list(decode_blocker_ref)),
  )(dyn)
  use created_at <- dynamic.optional_field(
    "createdAt",
    dynamic.optional(dynamic.int),
  )(dyn)
  use updated_at <- dynamic.optional_field(
    "updatedAt",
    dynamic.optional(dynamic.int),
  )(dyn)

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
  use id <- dynamic.optional_field("id", dynamic.optional(dynamic.string))(dyn)
  use identifier <- dynamic.optional_field(
    "identifier",
    dynamic.optional(dynamic.string),
  )(dyn)
  use state <- dynamic.field(
    "state",
    dynamic.optional(dynamic.field("name", dynamic.string)),
  )(dyn)

  Ok(BlockerRef(
    id: id |> option.flatten,
    identifier: identifier |> option.flatten,
    state: state |> option.flatten,
  ))
}
