import gleam/dynamic
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import symphony/config.{type Config}
import symphony/errors
import symphony/linear/client
import symphony/types

/// Construct a TrackerAdapter backed by the Linear GraphQL API.
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
  client.fetch_active_issues(config)
}

fn fetch_issue_states_by_ids(
  config: Config,
  issue_ids: List(String),
) -> Result(List(types.Issue), errors.TrackerError) {
  let results =
    list.map(issue_ids, fn(issue_id) {
      case client.fetch_issue_state(config, issue_id) {
        Ok(state_name) ->
          Ok(types.Issue(
            id: issue_id,
            identifier: issue_id,
            title: "",
            description: None,
            state: state_name,
            priority: None,
            branch_name: None,
            url: None,
            labels: [],
            blocked_by: [],
            created_at: None,
            updated_at: None,
          ))
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
  let api_key = linear_api_key(config)
  let query =
    "mutation { commentCreate(input: { issueId: \""
    <> issue_id
    <> "\", body: "
    <> json.to_string(json.string(body))
    <> " }) { success } }"

  execute_graphql_mutation(api_key, query, "create_comment")
}

fn update_issue_state(
  config: Config,
  issue_id: String,
  state_name: String,
) -> Result(Nil, errors.TrackerError) {
  use state_id <- result.try(resolve_state_id(config, issue_id, state_name))
  let api_key = linear_api_key(config)

  let query =
    "mutation { issueUpdate(id: \""
    <> issue_id
    <> "\", input: { stateId: \""
    <> state_id
    <> "\" }) { success } }"

  execute_graphql_mutation(api_key, query, "update_issue_state")
}

/// Extract the Linear API key from config.tracker (must be LinearConfig).
fn linear_api_key(config: Config) -> String {
  case config.tracker {
    config.LinearConfig(api_key: k, ..) -> k
    config.PlaneConfig(api_key: k, ..) -> k
  }
}

/// Resolve a state name to a Linear state ID by querying the issue's team.
fn resolve_state_id(
  config: Config,
  issue_id: String,
  state_name: String,
) -> Result(String, errors.TrackerError) {
  let query =
    "query { issue(id: \""
    <> issue_id
    <> "\") { team { states { nodes { id name } } } } }"

  let body = json.object([#("query", json.string(query))]) |> json.to_string

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("https://api.linear.app/graphql")
    |> request.prepend_header(
      "Authorization",
      "Bearer " <> linear_api_key(config),
    )
    |> request.prepend_header("Content-Type", "application/json")
    |> request.set_body(body)

  case httpc.send(req) {
    Ok(response) -> {
      case response.status {
        200 -> {
          case json.decode(response.body, dynamic.dynamic) {
            Ok(dyn) -> find_state_id_in_response(dyn, state_name)
            Error(_) ->
              Error(errors.ApiError(
                operation: "resolve_state_id",
                details: "Failed to parse response",
                status_code: Some(200),
              ))
          }
        }
        status ->
          Error(errors.ApiError(
            operation: "resolve_state_id",
            details: "HTTP error",
            status_code: Some(status),
          ))
      }
    }
    Error(_) ->
      Error(errors.ApiError(
        operation: "resolve_state_id",
        details: "HTTP request failed",
        status_code: None,
      ))
  }
}

/// Find a state ID by name in the team states response.
fn find_state_id_in_response(
  dyn: dynamic.Dynamic,
  target_name: String,
) -> Result(String, errors.TrackerError) {
  let decoder =
    dynamic.field(
      "data",
      dynamic.field(
        "issue",
        dynamic.field(
          "team",
          dynamic.field(
            "states",
            dynamic.field(
              "nodes",
              dynamic.list(fn(state) {
                let id_decoder = dynamic.field("id", dynamic.string)
                let name_decoder = dynamic.field("name", dynamic.string)
                case id_decoder(state), name_decoder(state) {
                  Ok(id), Ok(name) -> Ok(#(id, name))
                  _, _ -> Error([])
                }
              }),
            ),
          ),
        ),
      ),
    )

  case decoder(dyn) {
    Ok(states) -> {
      case
        list.find(states, fn(pair) {
          let #(_, name) = pair
          name == target_name
        })
      {
        Ok(#(id, _)) -> Ok(id)
        Error(_) ->
          Error(errors.NotFound(
            resource: "workflow_state",
            identifier: Some(target_name),
            details: "State not found in team",
          ))
      }
    }
    Error(_) ->
      Error(errors.ApiError(
        operation: "resolve_state_id",
        details: "Failed to decode team states",
        status_code: None,
      ))
  }
}

/// Execute a GraphQL mutation and check for success.
fn execute_graphql_mutation(
  api_key: String,
  query: String,
  operation: String,
) -> Result(Nil, errors.TrackerError) {
  let body = json.object([#("query", json.string(query))]) |> json.to_string

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host("https://api.linear.app/graphql")
    |> request.prepend_header("Authorization", "Bearer " <> api_key)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.set_body(body)

  case httpc.send(req) {
    Ok(response) -> {
      case response.status {
        200 -> Ok(Nil)
        429 ->
          Error(errors.RateLimit(
            retry_after_ms: None,
            scope: None,
            details: "Linear API rate limited during " <> operation,
          ))
        status ->
          Error(errors.ApiError(
            operation: operation,
            details: "HTTP error",
            status_code: Some(status),
          ))
      }
    }
    Error(_) ->
      Error(errors.ApiError(
        operation: operation,
        details: "HTTP request failed",
        status_code: None,
      ))
  }
}
