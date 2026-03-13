import gleam/dynamic
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import symphony/errors
import symphony/plane/types as plane_types

/// Base URL builder for Plane API v1
pub fn api_url(
  endpoint: String,
  workspace_slug: String,
  project_id: String,
) -> String {
  let base = case string.ends_with(endpoint, "/") {
    True -> string.drop_right(endpoint, 1)
    False -> endpoint
  }
  base <> "/api/v1/workspaces/" <> workspace_slug <> "/projects/" <> project_id
}

/// Build the issues list URL, optionally appending a cursor query parameter.
pub fn build_issues_url(
  endpoint: String,
  workspace_slug: String,
  project_id: String,
  cursor: option.Option(String),
) -> String {
  let base = api_url(endpoint, workspace_slug, project_id)
  let base_url = base <> "/issues/"
  case cursor {
    None -> base_url
    Some(c) -> base_url <> "?cursor=" <> c
  }
}

/// Decode the `next` cursor value from a paginated response body.
/// Returns `None` when the `next` field is absent or null.
pub fn decode_next_cursor(body: String) -> option.Option(String) {
  let decoder = dynamic.field("next", dynamic.optional(dynamic.string))
  case json.decode(body, decoder) {
    Ok(Some(url)) if url != "" && url != "null" -> Some(url)
    _ -> None
  }
}

/// List issues filtered by state names, fetching all pages via cursor pagination.
pub fn list_issues(
  endpoint: String,
  api_key: String,
  workspace_slug: String,
  project_id: String,
  state_names: List(String),
) -> Result(List(plane_types.PlaneWorkItem), errors.TrackerError) {
  use all_items <- result.try(
    fetch_all_pages(endpoint, api_key, workspace_slug, project_id, None, []),
  )

  // Filter client-side by state name
  let filtered = case state_names {
    [] -> all_items
    _ ->
      list.filter(all_items, fn(item) {
        list.contains(state_names, item.state_detail.name)
      })
  }

  Ok(filtered)
}

/// Recursively fetch all pages of issues using cursor-based pagination.
pub fn fetch_all_pages(
  endpoint: String,
  api_key: String,
  workspace_slug: String,
  project_id: String,
  cursor: option.Option(String),
  acc: List(plane_types.PlaneWorkItem),
) -> Result(List(plane_types.PlaneWorkItem), errors.TrackerError) {
  let url = build_issues_url(endpoint, workspace_slug, project_id, cursor)
  use body <- result.try(send_get(url, api_key, "list_issues"))

  use items <- result.try(
    json.decode(body, dynamic.field("results", dynamic.list(decode_work_item)))
    |> result.map_error(fn(_) {
      errors.ApiError(
        operation: "list_issues",
        details: "Failed to decode issues response",
        status_code: None,
      )
    }),
  )

  let all = list.append(acc, items)
  let next_cursor = decode_next_cursor(body)

  case next_cursor {
    None -> Ok(all)
    Some(_) ->
      fetch_all_pages(
        endpoint,
        api_key,
        workspace_slug,
        project_id,
        next_cursor,
        all,
      )
  }
}

/// Get a single issue by ID
pub fn get_issue(
  endpoint: String,
  api_key: String,
  workspace_slug: String,
  project_id: String,
  issue_id: String,
) -> Result(plane_types.PlaneWorkItem, errors.TrackerError) {
  let base = api_url(endpoint, workspace_slug, project_id)
  let url = base <> "/issues/" <> issue_id <> "/"

  use response <- result.try(send_get(url, api_key, "get_issue"))

  json.decode(response, decode_work_item)
  |> result.map_error(fn(_) {
    errors.ApiError(
      operation: "get_issue",
      details: "Failed to decode issue response",
      status_code: None,
    )
  })
}

/// Create a comment (activity) on an issue
pub fn create_comment(
  endpoint: String,
  api_key: String,
  workspace_slug: String,
  project_id: String,
  issue_id: String,
  body: String,
) -> Result(Nil, errors.TrackerError) {
  let base = api_url(endpoint, workspace_slug, project_id)
  let url = base <> "/issues/" <> issue_id <> "/activities/"

  let payload =
    json.object([#("comment_html", json.string("<p>" <> body <> "</p>"))])
    |> json.to_string

  use _response <- result.try(send_post(url, api_key, payload, "create_comment"))
  Ok(Nil)
}

/// Update an issue's state by PATCH
pub fn update_issue_state(
  endpoint: String,
  api_key: String,
  workspace_slug: String,
  project_id: String,
  issue_id: String,
  state_id: String,
) -> Result(Nil, errors.TrackerError) {
  let base = api_url(endpoint, workspace_slug, project_id)
  let url = base <> "/issues/" <> issue_id <> "/"

  let payload =
    json.object([#("state", json.string(state_id))])
    |> json.to_string

  use _response <- result.try(send_patch(
    url,
    api_key,
    payload,
    "update_issue_state",
  ))
  Ok(Nil)
}

/// Resolve a state name to UUID by listing project states
pub fn resolve_state_id(
  endpoint: String,
  api_key: String,
  workspace_slug: String,
  project_id: String,
  state_name: String,
) -> Result(String, errors.TrackerError) {
  let base = api_url(endpoint, workspace_slug, project_id)
  let url = base <> "/states/"

  use response <- result.try(send_get(url, api_key, "resolve_state_id"))

  use states <- result.try(
    json.decode(
      response,
      dynamic.field(
        "results",
        dynamic.list(fn(dyn) {
          use id <- result.try(dynamic.field("id", dynamic.string)(dyn))
          use name <- result.try(dynamic.field("name", dynamic.string)(dyn))
          Ok(#(id, name))
        }),
      ),
    )
    |> result.map_error(fn(_) {
      errors.ApiError(
        operation: "resolve_state_id",
        details: "Failed to decode states response",
        status_code: None,
      )
    }),
  )

  case list.find(states, fn(pair) { pair.1 == state_name }) {
    Ok(#(id, _)) -> Ok(id)
    Error(_) ->
      Error(errors.NotFound(
        resource: "workflow_state",
        identifier: Some(state_name),
        details: "State not found in project",
      ))
  }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

fn send_get(
  url: String,
  api_key: String,
  operation: String,
) -> Result(String, errors.TrackerError) {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_host(url)
    |> request.prepend_header("X-API-Key", api_key)
    |> request.prepend_header("Content-Type", "application/json")

  case httpc.send(req) {
    Ok(response) -> handle_response(response, operation)
    Error(_) ->
      Error(errors.ApiError(
        operation: operation,
        details: "HTTP request failed",
        status_code: None,
      ))
  }
}

fn send_post(
  url: String,
  api_key: String,
  body: String,
  operation: String,
) -> Result(String, errors.TrackerError) {
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_host(url)
    |> request.prepend_header("X-API-Key", api_key)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.set_body(body)

  case httpc.send(req) {
    Ok(response) -> handle_response(response, operation)
    Error(_) ->
      Error(errors.ApiError(
        operation: operation,
        details: "HTTP request failed",
        status_code: None,
      ))
  }
}

fn send_patch(
  url: String,
  api_key: String,
  body: String,
  operation: String,
) -> Result(String, errors.TrackerError) {
  let req =
    request.new()
    |> request.set_method(http.Patch)
    |> request.set_host(url)
    |> request.prepend_header("X-API-Key", api_key)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.set_body(body)

  case httpc.send(req) {
    Ok(response) -> handle_response(response, operation)
    Error(_) ->
      Error(errors.ApiError(
        operation: operation,
        details: "HTTP request failed",
        status_code: None,
      ))
  }
}

fn handle_response(
  response: Response(String),
  operation: String,
) -> Result(String, errors.TrackerError) {
  case response.status {
    200 | 201 -> Ok(response.body)
    204 -> Ok("")
    429 -> {
      let retry_after_ms = parse_retry_after_ms(response)
      Error(errors.RateLimit(
        retry_after_ms: retry_after_ms,
        scope: None,
        details: "Plane API rate limited during " <> operation,
      ))
    }
    404 ->
      Error(errors.NotFound(
        resource: operation,
        identifier: None,
        details: "Plane API returned 404",
      ))
    status ->
      Error(errors.ApiError(
        operation: operation,
        details: "HTTP error: " <> int.to_string(status),
        status_code: Some(status),
      ))
  }
}

/// Extract the Retry-After header value and convert seconds to milliseconds.
/// Returns None if the header is absent or not a valid integer.
fn parse_retry_after_ms(response: Response(String)) -> option.Option(Int) {
  case list.key_find(response.headers, "retry-after") {
    Ok(value) ->
      case int.parse(string.trim(value)) {
        Ok(seconds) -> Some(seconds * 1000)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

// ---------------------------------------------------------------------------
// Decoders
// ---------------------------------------------------------------------------

fn decode_work_item(
  dyn: dynamic.Dynamic,
) -> Result(plane_types.PlaneWorkItem, List(dynamic.DecodeError)) {
  use id <- result.try(dynamic.field("id", dynamic.string)(dyn))
  use sequence_id <- result.try(dynamic.field("sequence_id", dynamic.int)(dyn))
  use project_identifier <- result.try(dynamic.field(
    "project_detail",
    dynamic.field("identifier", dynamic.string),
  )(dyn))
  use name <- result.try(dynamic.field("name", dynamic.string)(dyn))
  use description_html <- result.try(dynamic.optional_field(
    "description_html",
    dynamic.optional(dynamic.string),
  )(dyn))
  use priority <- result.try(dynamic.optional_field(
    "priority",
    dynamic.optional(dynamic.string),
  )(dyn))
  use state_detail <- result.try(decode_state_detail(dyn))
  use created_at <- result.try(dynamic.field("created_at", dynamic.string)(dyn))
  use updated_at <- result.try(dynamic.field("updated_at", dynamic.string)(dyn))
  use label_details <- result.try(
    dynamic.field("label_detail", dynamic.list(decode_label))(dyn)
    |> result.or(Ok([])),
  )

  Ok(plane_types.PlaneWorkItem(
    id: id,
    sequence_id: sequence_id,
    project_identifier: project_identifier,
    name: name,
    description_html: option.flatten(description_html),
    priority: option.flatten(priority),
    state_detail: state_detail,
    created_at: created_at,
    updated_at: updated_at,
    label_details: label_details,
  ))
}

fn decode_state_detail(
  dyn: dynamic.Dynamic,
) -> Result(plane_types.PlaneStateDetail, List(dynamic.DecodeError)) {
  let decoder =
    dynamic.field("state_detail", fn(sd) {
      use id <- result.try(dynamic.field("id", dynamic.string)(sd))
      use name <- result.try(dynamic.field("name", dynamic.string)(sd))
      use group <- result.try(dynamic.field("group", dynamic.string)(sd))
      Ok(plane_types.PlaneStateDetail(id: id, name: name, group: group))
    })
  decoder(dyn)
}

fn decode_label(
  dyn: dynamic.Dynamic,
) -> Result(plane_types.PlaneLabel, List(dynamic.DecodeError)) {
  use id <- result.try(dynamic.field("id", dynamic.string)(dyn))
  use name <- result.try(dynamic.field("name", dynamic.string)(dyn))
  Ok(plane_types.PlaneLabel(id: id, name: name))
}
