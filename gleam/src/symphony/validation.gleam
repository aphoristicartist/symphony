import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import symphony/config.{type Config}
import symphony/errors.{
  type ValidationError, EmptyStateList, InvalidIssueIdentifier,
  InvalidSessionComponent, MissingRequiredField, NonPositiveValue,
  OverlappingState, UnsupportedValue,
}

const workspace_safe_chars = [
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p",
  "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "A", "B", "C", "D", "E", "F",
  "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V",
  "W", "X", "Y", "Z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "_",
  "-",
]

/// Check if a tracker state is currently active.
pub fn is_active_state(state: String, config: Config) -> Bool {
  let normalized = normalize_state(state)

  config.tracker.active_states
  |> list.any(fn(candidate) { normalize_state(candidate) == normalized })
}

/// Check if a tracker state is terminal.
pub fn is_terminal_state(state: String, config: Config) -> Bool {
  let normalized = normalize_state(state)

  config.tracker.terminal_states
  |> list.any(fn(candidate) { normalize_state(candidate) == normalized })
}

/// Replace non `[A-Za-z0-9._-]` characters with `_` for workspace-safe keys.
pub fn sanitize_workspace_key(identifier: String) -> String {
  identifier
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case is_workspace_safe_char(grapheme) {
      True -> grapheme
      False -> "_"
    }
  })
  |> string.concat
}

/// Validate issue identifiers used for logs and workspace naming.
pub fn validate_issue_identifier(
  identifier: String,
) -> Result(String, ValidationError) {
  let trimmed = string.trim(identifier)
  let is_valid =
    trimmed != ""
    && {
      trimmed
      |> string.to_graphemes
      |> list.all(is_workspace_safe_char)
    }

  case is_valid {
    True -> Ok(trimmed)
    False -> Error(InvalidIssueIdentifier(identifier: identifier))
  }
}

/// Predicate form of issue identifier validation.
pub fn is_valid_issue_identifier(identifier: String) -> Bool {
  case validate_issue_identifier(identifier) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Compose a session id from thread and turn identifiers.
pub fn compose_session_id(
  thread_id: String,
  turn_id: String,
) -> Result(String, ValidationError) {
  use normalized_thread_id <- result.try(require_session_component(
    "thread_id",
    thread_id,
  ))
  use normalized_turn_id <- result.try(require_session_component(
    "turn_id",
    turn_id,
  ))

  Ok(normalized_thread_id <> "-" <> normalized_turn_id)
}

/// Validate config invariants required for dispatch.
pub fn validate_config(config: Config) -> Result(Config, ValidationError) {
  use _ <- result.try(validate_tracker_kind(config.tracker.kind))
  use _ <- result.try(require_non_empty(
    "tracker.api_key",
    config.tracker.api_key,
  ))
  use _ <- result.try(validate_project_slug(config))
  use _ <- result.try(validate_state_lists(config))
  use _ <- result.try(require_non_empty("codex.command", config.codex.command))
  use _ <- result.try(validate_positive(
    "polling.interval_ms",
    config.polling.interval_ms,
  ))

  use _ <- result.try(validate_positive(
    "agent.max_concurrent_agents",
    config.agent.max_concurrent_agents,
  ))

  use _ <- result.try(validate_positive(
    "agent.max_turns",
    config.agent.max_turns,
  ))
  use _ <- result.try(validate_positive(
    "codex.turn_timeout_ms",
    config.codex.turn_timeout_ms,
  ))
  use _ <- result.try(validate_positive(
    "hooks.timeout_ms",
    config.hooks.timeout_ms,
  ))

  Ok(config)
}

fn validate_tracker_kind(kind: String) -> Result(Nil, ValidationError) {
  case normalize_state(kind) {
    "linear" -> Ok(Nil)
    _ -> Error(UnsupportedValue(field: "tracker.kind", value: kind))
  }
}

fn validate_project_slug(config: Config) -> Result(Nil, ValidationError) {
  case normalize_state(config.tracker.kind) {
    "linear" ->
      require_non_empty("tracker.project_slug", config.tracker.project_slug)

    _ -> Ok(Nil)
  }
}

fn validate_state_lists(config: Config) -> Result(Nil, ValidationError) {
  use active <- result.try(normalize_states(
    "tracker.active_states",
    config.tracker.active_states,
  ))

  use terminal <- result.try(normalize_states(
    "tracker.terminal_states",
    config.tracker.terminal_states,
  ))

  case find_overlap(active, terminal) {
    Some(overlap) -> Error(OverlappingState(state: overlap))
    None -> Ok(Nil)
  }
}

fn normalize_states(
  field: String,
  states: List(String),
) -> Result(List(String), ValidationError) {
  let normalized =
    states
    |> list.map(normalize_state)
    |> list.filter(fn(state) { state != "" })

  case normalized {
    [] -> Error(EmptyStateList(field: field))
    _ -> Ok(normalized)
  }
}

fn find_overlap(active: List(String), terminal: List(String)) -> Option(String) {
  case active |> list.find(fn(state) { list.contains(terminal, state) }) {
    Ok(state) -> Some(state)
    Error(_) -> None
  }
}

fn require_non_empty(
  field: String,
  value: String,
) -> Result(Nil, ValidationError) {
  case string.trim(value) == "" {
    True -> Error(MissingRequiredField(field: field))
    False -> Ok(Nil)
  }
}

fn validate_positive(field: String, value: Int) -> Result(Nil, ValidationError) {
  case value > 0 {
    True -> Ok(Nil)
    False -> Error(NonPositiveValue(field: field, value: value))
  }
}

/// Normalize state names for comparisons (`trim` + `lowercase`).
pub fn normalize_state(state: String) -> String {
  state
  |> string.trim
  |> string.lowercase
}

fn is_workspace_safe_char(grapheme: String) -> Bool {
  list.contains(workspace_safe_chars, grapheme)
}

fn require_session_component(
  component: String,
  value: String,
) -> Result(String, ValidationError) {
  let trimmed = string.trim(value)

  case trimmed == "" {
    True -> Error(InvalidSessionComponent(component: component, value: value))
    False -> Ok(trimmed)
  }
}
