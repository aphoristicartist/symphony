import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Codex process handle
pub type CodexProcess {
  CodexProcess(
    pid: process.Pid,
    stdin: process.Subject(String),
    stdout: process.Subject(String),
  )
}

/// JSON-RPC request
type JsonRpcRequest =
  JsonRpcMessage(Dynamic)

/// JSON-RPC response
type JsonRpcResponse =
  JsonRpcMessage(Dynamic)

/// JSON-RPC message
type JsonRpcMessage(a) {
  JsonRpcMessage(
    jsonrpc: String,
    method: Option(String),
    params: Option(a),
    id: Option(Int),
    result: Option(a),
    error: Option(JsonRpcError),
  )
}

/// JSON-RPC error
type JsonRpcError {
  JsonRpcError(code: Int, message: String, data: Option(Dynamic))
}

/// Codex event types
pub type CodexEvent {
  TurnStarted(turn_id: String)
  TurnUpdate(turn_id: String, content: String)
  TurnComplete(turn_id: String, input_tokens: Int, output_tokens: Int)
  ThreadStarted(thread_id: String)
  ThreadComplete(thread_id: String)
  Error(message: String)
}

/// Start a Codex thread by spawning the app-server process
pub fn start_thread(command: String, cwd: String) -> Result(CodexProcess, String) {
  // For this implementation, we'll use Erlang ports to communicate with the subprocess
  do_start_codex(command, cwd)
}

/// Start Codex via Erlang FFI
@external(erlang, "symphony_codex_ffi", "start_codex")
fn do_start_codex(command: String, cwd: String) -> Result(CodexProcess, String)

/// Start a turn in the Codex thread
pub fn start_turn(process: CodexProcess, prompt: String) -> Result(Nil, String) {
  let request = JsonRpcMessage(
    jsonrpc: "2.0",
    method: Some("turn.start"),
    params: Some(dynamic.from(dict.from_list([#("prompt", dynamic.from(prompt))]))),
    id: Some(1),
    result: None,
    error: None,
  )
  
  send_request(process, request)
}

/// Send a JSON-RPC request
fn send_request(process: CodexProcess, request: JsonRpcRequest) -> Result(Nil, String) {
  let json_str = encode_request(request)
  do_send_to_process(process, json_str)
}

/// Send data to Codex process via FFI
@external(erlang, "symphony_codex_ffi", "send_to_process")
fn do_send_to_process(process: CodexProcess, data: String) -> Result(Nil, String)

/// Stream events from the Codex process
pub fn stream_events(
  process: CodexProcess,
  handler: fn(CodexEvent) -> Nil,
) -> Nil {
  // Continuously read from stdout and parse events
  stream_loop(process, handler)
}

/// Stream loop
fn stream_loop(process: CodexProcess, handler: fn(CodexEvent) -> Nil) -> Nil {
  case read_event(process) {
    Ok(event) -> {
      handler(event)
      case event {
        ThreadComplete(_) -> Nil
        Error(_) -> Nil
        _ -> stream_loop(process, handler)
      }
    }
    Error(_) -> Nil
  }
}

/// Read a single event from the process
fn read_event(process: CodexProcess) -> Result(CodexEvent, String) {
  case do_read_event(process) {
    Ok(event_str) -> parse_event(event_str)
    Error(e) -> Error(e)
  }
}

/// Read event via FFI
@external(erlang, "symphony_codex_ffi", "read_event")
fn do_read_event(process: CodexProcess) -> Result(String, String)

/// Parse a Codex event from JSON
fn parse_event(json_str: String) -> Result(CodexEvent, String) {
  case json.decode(json_str, dynamic.dynamic) {
    Ok(dyn) -> {
      case dynamic.field("method", dynamic.optional(dynamic.string))(dyn) {
        Ok(Some("turn.started")) -> {
          case dynamic.field("params", dynamic.optional(dynamic.dynamic))(dyn) {
            Ok(Some(params)) -> {
              case dynamic.field("turn_id", dynamic.string)(params) {
                Ok(turn_id) -> Ok(TurnStarted(turn_id: turn_id))
                Error(_) -> Error("Invalid turn.started event")
              }
            }
            _ -> Error("Missing params in turn.started")
          }
        }
        Ok(Some("turn.update")) -> {
          case dynamic.field("params", dynamic.optional(dynamic.dynamic))(dyn) {
            Ok(Some(params)) -> {
              use turn_id <- result.try(
                dynamic.field("turn_id", dynamic.string)(params)
                |> result.map_error(fn(_) { "Missing turn_id" }),
              )
              use content <- result.try(
                dynamic.field("content", dynamic.string)(params)
                |> result.map_error(fn(_) { "Missing content" }),
              )
              Ok(TurnUpdate(turn_id: turn_id, content: content))
            }
            _ -> Error("Missing params in turn.update")
          }
        }
        Ok(Some("turn.complete")) -> {
          case dynamic.field("params", dynamic.optional(dynamic.dynamic))(dyn) {
            Ok(Some(params)) -> {
              use turn_id <- result.try(
                dynamic.field("turn_id", dynamic.string)(params)
                |> result.map_error(fn(_) { "Missing turn_id" }),
              )
              use input_tokens <- result.try(
                dynamic.field("input_tokens", dynamic.int)(params)
                |> result.map_error(fn(_) { "Missing input_tokens" }),
              )
              use output_tokens <- result.try(
                dynamic.field("output_tokens", dynamic.int)(params)
                |> result.map_error(fn(_) { "Missing output_tokens" }),
              )
              Ok(TurnComplete(
                turn_id: turn_id,
                input_tokens: input_tokens,
                output_tokens: output_tokens,
              ))
            }
            _ -> Error("Missing params in turn.complete")
          }
        }
        Ok(Some("thread.started")) -> {
          case dynamic.field("params", dynamic.optional(dynamic.dynamic))(dyn) {
            Ok(Some(params)) -> {
              case dynamic.field("thread_id", dynamic.string)(params) {
                Ok(thread_id) -> Ok(ThreadStarted(thread_id: thread_id))
                Error(_) -> Error("Invalid thread.started event")
              }
            }
            _ -> Error("Missing params in thread.started")
          }
        }
        Ok(Some("thread.complete")) -> {
          case dynamic.field("params", dynamic.optional(dynamic.dynamic))(dyn) {
            Ok(Some(params)) -> {
              case dynamic.field("thread_id", dynamic.string)(params) {
                Ok(thread_id) -> Ok(ThreadComplete(thread_id: thread_id))
                Error(_) -> Error("Invalid thread.complete event")
              }
            }
            _ -> Error("Missing params in thread.complete")
          }
        }
        Ok(Some(_)) -> Error("Unknown event method")
        Ok(None) -> Error("Event missing method field")
        Error(_) -> Error("Failed to parse event method")
      }
    }
    Error(_) -> Error("Failed to decode event JSON")
  }
}

/// Encode a JSON-RPC request
fn encode_request(request: JsonRpcRequest) -> String {
  let base_fields = [
    #("jsonrpc", json.string(request.jsonrpc)),
  ]
  
  let method_fields = case request.method {
    Some(method) -> [#("method", json.string(method))]
    None -> []
  }
  
  let params_fields = case request.params {
    Some(params) -> [#("params", json.preprocessed(dynamic_to_json(params)))]
    None -> []
  }
  
  let id_fields = case request.id {
    Some(id) -> [#("id", json.int(id))]
    None -> []
  }
  
  let all_fields = list.concat([base_fields, method_fields, params_fields, id_fields])
  
  json.object(all_fields) |> json.to_string
}

/// Convert dynamic to JSON (simplified)
fn dynamic_to_json(dyn: Dynamic) -> json.Json {
  // This is a simplified conversion
  // In production, we'd handle all cases properly
  json.preprocessed(dyn)
}

/// Stop the Codex process
pub fn stop_thread(process: CodexProcess) -> Nil {
  do_stop_codex(process)
}

/// Stop Codex via FFI
@external(erlang, "symphony_codex_ffi", "stop_codex")
fn do_stop_codex(process: CodexProcess) -> Nil
