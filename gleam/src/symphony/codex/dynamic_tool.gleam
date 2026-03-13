import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/result
import gleam/string
import symphony/config.{type Config}

/// A tool call received from Codex during a session.
pub type ToolCall {
  ToolCall(name: String, arguments: Dict(String, Dynamic))
}

/// The result of executing a tool call.
pub type ToolResult {
  ToolResult(output: String, success: Bool)
}

/// Execute a tool call and return the result.
/// Dispatches to the appropriate handler based on the tool name.
pub fn execute(tool_call: ToolCall, config: Config) -> ToolResult {
  case tool_call.name {
    "linear_graphql" -> execute_linear_graphql(tool_call.arguments, config)
    "plane_api" -> execute_plane_api(tool_call.arguments, config)
    other ->
      ToolResult(
        output: encode_error(
          "Unsupported dynamic tool: "
          <> other
          <> ". Supported tools: linear_graphql, plane_api",
        ),
        success: False,
      )
  }
}

/// Execute the linear_graphql tool - sends a GraphQL query to Linear API.
///
/// Arguments:
///   - query (String, required): The GraphQL query or mutation to execute.
///   - variables (optional): A JSON object of GraphQL variables.
fn execute_linear_graphql(
  arguments: Dict(String, Dynamic),
  config: Config,
) -> ToolResult {
  // Extract and validate the query argument
  let query_result = case dict.get(arguments, "query") {
    Ok(query_dyn) ->
      case dynamic.string(query_dyn) {
        Ok(query) ->
          case string.trim(query) {
            "" -> Error("linear_graphql requires a non-empty `query` string.")
            trimmed -> Ok(trimmed)
          }
        Error(_) -> Error("linear_graphql `query` must be a string.")
      }
    Error(_) -> Error("linear_graphql requires a non-empty `query` string.")
  }

  case query_result {
    Error(message) -> ToolResult(output: encode_error(message), success: False)
    Ok(query) -> {
      // Extract optional variables
      let variables = case dict.get(arguments, "variables") {
        Ok(vars_dyn) ->
          case dynamic.string(vars_dyn) {
            Ok(s) ->
              case string.trim(s) {
                "" -> "{}"
                _ -> s
              }
            Error(_) ->
              // It might be a dict/object, encode it back to JSON
              dynamic_to_json_string(vars_dyn)
          }
        Error(_) -> "{}"
      }

      // Build the request body
      // Variables is already a JSON string, so we construct the body manually
      // to avoid double-encoding it.
      let query_json = json.string(query) |> json.to_string
      let body =
        "{\"query\":" <> query_json <> ",\"variables\":" <> variables <> "}"

      // Build and send the HTTP request
      let req =
        request.new()
        |> request.set_method(http.Post)
        |> request.set_scheme(http.Https)
        |> request.set_host("api.linear.app")
        |> request.set_path("/graphql")
        |> request.prepend_header(
          "Authorization",
          "Bearer " <> tracker_api_key(config),
        )
        |> request.prepend_header("Content-Type", "application/json")
        |> request.set_body(body)

      case httpc.send(req) {
        Ok(response) ->
          case response.status >= 200 && response.status < 300 {
            True -> ToolResult(output: response.body, success: True)
            False ->
              ToolResult(
                output: encode_error(
                  "Linear GraphQL request failed with HTTP "
                  <> string.inspect(response.status)
                  <> ": "
                  <> response.body,
                ),
                success: False,
              )
          }
        Error(reason) ->
          ToolResult(
            output: encode_error(
              "Linear GraphQL request failed: " <> string.inspect(reason),
            ),
            success: False,
          )
      }
    }
  }
}

/// Execute the plane_api tool - sends a REST request to Plane API.
///
/// Arguments:
///   - method (String: GET/POST/PATCH/DELETE)
///   - path (String): API path appended to the tracker endpoint
///   - body (optional String): Request body for POST/PATCH
fn execute_plane_api(
  arguments: Dict(String, Dynamic),
  config: Config,
) -> ToolResult {
  // Extract method
  let method_result = case dict.get(arguments, "method") {
    Ok(method_dyn) ->
      case dynamic.string(method_dyn) {
        Ok(method_str) -> parse_http_method(string.uppercase(method_str))
        Error(_) -> Error("plane_api `method` must be a string.")
      }
    Error(_) ->
      Error("plane_api requires a `method` argument (GET/POST/PATCH/DELETE).")
  }

  // Extract path
  let path_result = case dict.get(arguments, "path") {
    Ok(path_dyn) ->
      case dynamic.string(path_dyn) {
        Ok(path) ->
          case string.trim(path) {
            "" -> Error("plane_api requires a non-empty `path` string.")
            trimmed -> Ok(trimmed)
          }
        Error(_) -> Error("plane_api `path` must be a string.")
      }
    Error(_) -> Error("plane_api requires a `path` argument.")
  }

  // Extract optional body
  let body_str = case dict.get(arguments, "body") {
    Ok(body_dyn) ->
      case dynamic.string(body_dyn) {
        Ok(b) -> b
        Error(_) -> ""
      }
    Error(_) -> ""
  }

  case method_result, path_result {
    Error(msg), _ -> ToolResult(output: encode_error(msg), success: False)
    _, Error(msg) -> ToolResult(output: encode_error(msg), success: False)
    Ok(method), Ok(path) -> {
      // Get the tracker endpoint, defaulting if not set
      let endpoint = case config.tracker {
        config.PlaneConfig(endpoint: ep, ..) -> ep
        config.LinearConfig(..) | config.LocalConfig(..) ->
          "https://api.plane.so"
      }

      // Build the full URL by parsing the endpoint
      let req_result =
        request.to(endpoint <> path)
        |> result.map(fn(req) {
          req
          |> request.set_method(method)
          |> request.prepend_header("X-API-Key", tracker_api_key(config))
          |> request.prepend_header("Content-Type", "application/json")
          |> request.set_body(body_str)
        })

      case req_result {
        Ok(req) ->
          case httpc.send(req) {
            Ok(response) ->
              case response.status >= 200 && response.status < 300 {
                True -> ToolResult(output: response.body, success: True)
                False ->
                  ToolResult(
                    output: encode_error(
                      "Plane API request failed with HTTP "
                      <> string.inspect(response.status)
                      <> ": "
                      <> response.body,
                    ),
                    success: False,
                  )
              }
            Error(reason) ->
              ToolResult(
                output: encode_error(
                  "Plane API request failed: " <> string.inspect(reason),
                ),
                success: False,
              )
          }
        Error(_) ->
          ToolResult(
            output: encode_error(
              "Failed to construct request URL from endpoint: "
              <> endpoint
              <> path,
            ),
            success: False,
          )
      }
    }
  }
}

/// Extract the API key from the TrackerConfig union.
fn tracker_api_key(config: Config) -> String {
  case config.tracker {
    config.LinearConfig(api_key: k, ..) -> k
    config.PlaneConfig(api_key: k, ..) -> k
    config.LocalConfig(..) -> ""
  }
}

/// Parse an HTTP method string into the gleam/http Method type.
fn parse_http_method(method: String) -> Result(http.Method, String) {
  case method {
    "GET" -> Ok(http.Get)
    "POST" -> Ok(http.Post)
    "PATCH" -> Ok(http.Patch)
    "DELETE" -> Ok(http.Delete)
    "PUT" -> Ok(http.Put)
    other ->
      Error(
        "Unsupported HTTP method: "
        <> other
        <> ". Supported: GET, POST, PATCH, DELETE, PUT",
      )
  }
}

/// Encode an error message as a JSON string for tool output.
fn encode_error(message: String) -> String {
  json.object([#("error", json.object([#("message", json.string(message))]))])
  |> json.to_string
}

/// Convert a Dynamic value to a JSON string representation.
/// Falls back to "{}" if the value cannot be meaningfully serialized.
fn dynamic_to_json_string(dyn: Dynamic) -> String {
  case dynamic.string(dyn) {
    Ok(s) -> s
    Error(_) ->
      case dynamic.int(dyn) {
        Ok(i) -> string.inspect(i)
        Error(_) ->
          case dynamic.float(dyn) {
            Ok(f) -> string.inspect(f)
            Error(_) ->
              case dynamic.bool(dyn) {
                Ok(b) ->
                  case b {
                    True -> "true"
                    False -> "false"
                  }
                Error(_) -> "{}"
              }
          }
      }
  }
}
