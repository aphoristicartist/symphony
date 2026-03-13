import gleam/dynamic
import gleam/json
import gleam/option.{type Option, None, Some}

/// Events emitted by `claude -p <prompt> --output-format stream-json`.
/// Each line of stdout is a newline-delimited JSON object with a `type` field.
pub type ClaudeCodeEvent {
  InitEvent(session_id: String)
  TextDelta(content: String)
  ToolUse(tool_name: String, tool_input: String)
  ToolResult(output: String)
  SystemEvent(event_type: String, message: String)
  UsageEvent(input_tokens: Int, output_tokens: Int)
  ResultEvent(output: String, session_id: String)
  ErrorEvent(message: String)
  UnknownEvent(raw: String)
}

/// Parse a single line of streaming JSON output into a typed event.
pub fn parse_event(json_str: String) -> ClaudeCodeEvent {
  case json.decode(json_str, dynamic.dynamic) {
    Ok(dyn) -> decode_event(dyn, json_str)
    Error(_) -> ErrorEvent(message: "Malformed JSON: " <> json_str)
  }
}

/// Extract the `type` field and dispatch to the appropriate decoder.
fn decode_event(dyn: dynamic.Dynamic, raw: String) -> ClaudeCodeEvent {
  case get_string_field(dyn, "type") {
    Some("init") -> decode_init_event(dyn)
    Some("text") -> decode_text_delta(dyn)
    Some("tool_use") -> decode_tool_use(dyn)
    Some("tool_result") -> decode_tool_result(dyn)
    Some("system") -> decode_system_event(dyn)
    Some("usage") -> decode_usage_event(dyn)
    Some("result") -> decode_result_event(dyn)
    Some("error") -> decode_error_event(dyn)
    Some(_) -> UnknownEvent(raw: raw)
    None -> UnknownEvent(raw: raw)
  }
}

fn decode_init_event(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let session_id =
    get_string_field(dyn, "session_id")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "sessionId")
      |> option.unwrap("")
    })
  InitEvent(session_id: session_id)
}

fn decode_text_delta(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let content =
    get_string_field(dyn, "content")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "text")
      |> option.unwrap("")
    })
  TextDelta(content: content)
}

fn decode_tool_use(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let tool_name =
    get_string_field(dyn, "tool_name")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "toolName")
      |> option.lazy_unwrap(fn() {
        get_string_field(dyn, "name")
        |> option.unwrap("")
      })
    })
  let tool_input =
    get_string_field(dyn, "tool_input")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "toolInput")
      |> option.lazy_unwrap(fn() {
        get_string_field(dyn, "input")
        |> option.unwrap("")
      })
    })
  ToolUse(tool_name: tool_name, tool_input: tool_input)
}

fn decode_tool_result(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let output =
    get_string_field(dyn, "output")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "content")
      |> option.unwrap("")
    })
  ToolResult(output: output)
}

fn decode_system_event(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let event_type =
    get_string_field(dyn, "event")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "subtype")
      |> option.unwrap("unknown")
    })
  let message =
    get_string_field(dyn, "message")
    |> option.unwrap("")
  SystemEvent(event_type: event_type, message: message)
}

fn decode_usage_event(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let input_tokens =
    get_int_field(dyn, "input_tokens")
    |> option.lazy_unwrap(fn() {
      get_int_field(dyn, "inputTokens")
      |> option.unwrap(0)
    })
  let output_tokens =
    get_int_field(dyn, "output_tokens")
    |> option.lazy_unwrap(fn() {
      get_int_field(dyn, "outputTokens")
      |> option.unwrap(0)
    })
  UsageEvent(input_tokens: input_tokens, output_tokens: output_tokens)
}

fn decode_result_event(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let output =
    get_string_field(dyn, "output")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "result")
      |> option.unwrap("")
    })
  let session_id =
    get_string_field(dyn, "session_id")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "sessionId")
      |> option.unwrap("")
    })
  ResultEvent(output: output, session_id: session_id)
}

fn decode_error_event(dyn: dynamic.Dynamic) -> ClaudeCodeEvent {
  let message =
    get_string_field(dyn, "message")
    |> option.lazy_unwrap(fn() {
      get_string_field(dyn, "error")
      |> option.unwrap("Unknown error")
    })
  ErrorEvent(message: message)
}

/// Safely extract an optional string field from a dynamic value.
fn get_string_field(dyn: dynamic.Dynamic, field: String) -> Option(String) {
  case dynamic.field(field, dynamic.string)(dyn) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Safely extract an optional int field from a dynamic value.
fn get_int_field(dyn: dynamic.Dynamic, field: String) -> Option(Int) {
  case dynamic.field(field, dynamic.int)(dyn) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Check whether a parsed event signals the end of a turn.
pub fn is_terminal_event(event: ClaudeCodeEvent) -> Bool {
  case event {
    ResultEvent(_, _) -> True
    ErrorEvent(_) -> True
    _ -> False
  }
}

/// Extract token usage from a UsageEvent, if present.
pub fn token_usage(event: ClaudeCodeEvent) -> Option(#(Int, Int)) {
  case event {
    UsageEvent(input_tokens, output_tokens) ->
      Some(#(input_tokens, output_tokens))
    _ -> None
  }
}

/// Extract session ID from events that carry one.
pub fn session_id(event: ClaudeCodeEvent) -> Option(String) {
  case event {
    InitEvent(sid) ->
      case sid {
        "" -> None
        _ -> Some(sid)
      }
    ResultEvent(_, sid) ->
      case sid {
        "" -> None
        _ -> Some(sid)
      }
    _ -> None
  }
}
