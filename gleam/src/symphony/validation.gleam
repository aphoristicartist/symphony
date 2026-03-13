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
import symphony/types

const workspace_safe_chars = [
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p",
  "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "A", "B", "C", "D", "E", "F",
  "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V",
  "W", "X", "Y", "Z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "_",
  "-",
]

/// Extract active_states from a TrackerConfig union variant.
fn tracker_active_states(tracker: config.TrackerConfig) -> List(String) {
  case tracker {
    config.LinearConfig(active_states: s, ..) -> s
    config.PlaneConfig(active_states: s, ..) -> s
  }
}

/// Extract terminal_states from a TrackerConfig union variant.
fn tracker_terminal_states(tracker: config.TrackerConfig) -> List(String) {
  case tracker {
    config.LinearConfig(terminal_states: s, ..) -> s
    config.PlaneConfig(terminal_states: s, ..) -> s
  }
}

/// Extract api_key from a TrackerConfig union variant.
pub fn tracker_api_key(tracker: config.TrackerConfig) -> String {
  case tracker {
    config.LinearConfig(api_key: k, ..) -> k
    config.PlaneConfig(api_key: k, ..) -> k
  }
}

/// Check if a tracker state is currently active.
pub fn is_active_state(state: String, config: Config) -> Bool {
  let normalized = normalize_state(state)

  tracker_active_states(config.tracker)
  |> list.any(fn(candidate) { normalize_state(candidate) == normalized })
}

/// Check if a tracker state is terminal.
pub fn is_terminal_state(state: String, config: Config) -> Bool {
  let normalized = normalize_state(state)

  tracker_terminal_states(config.tracker)
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
/// Validate an agent kind string.
pub fn validate_agent_kind(kind: String) -> Result(Nil, ValidationError) {
  case normalize_state(kind) {
    "codex" | "claude-code" | "goose" -> Ok(Nil)
    _ -> Error(UnsupportedValue(field: "agent.kind", value: kind))
  }
}

/// Parse an agent kind string into the typed enum.
pub fn parse_agent_kind(
  kind: String,
) -> Result(types.AgentKind, ValidationError) {
  case normalize_state(kind) {
    "codex" -> Ok(types.Codex)
    "claude-code" -> Ok(types.ClaudeCode)
    "goose" -> Ok(types.Goose)
    _ -> Error(UnsupportedValue(field: "agent.kind", value: kind))
  }
}

/// Parse a tracker kind string into the typed enum.
pub fn parse_tracker_kind(
  kind: String,
) -> Result(types.TrackerKind, ValidationError) {
  case normalize_state(kind) {
    "linear" -> Ok(types.Linear)
    "plane" -> Ok(types.Plane)
    _ -> Error(UnsupportedValue(field: "tracker.kind", value: kind))
  }
}

pub fn validate_config(config: Config) -> Result(Config, ValidationError) {
  use _ <- result.try(validate_tracker(config.tracker))
  use _ <- result.try(validate_state_lists(config))
  use _ <- result.try(validate_agent_kind(config.agent.kind))
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

fn validate_tracker(
  tracker: config.TrackerConfig,
) -> Result(Nil, ValidationError) {
  case tracker {
    config.LinearConfig(api_key: k, project_slug: slug, ..) -> {
      use _ <- result.try(require_non_empty("tracker.api_key", k))
      require_non_empty("tracker.project_slug", slug)
    }
    config.PlaneConfig(
      api_key: k,
      endpoint: ep,
      workspace_slug: ws,
      project_id: pid,
      ..,
    ) -> {
      use _ <- result.try(require_non_empty("tracker.api_key", k))
      use _ <- result.try(require_non_empty("tracker.endpoint", ep))
      use _ <- result.try(require_non_empty("tracker.workspace_slug", ws))
      require_non_empty("tracker.project_id", pid)
    }
  }
}

fn validate_state_lists(config: Config) -> Result(Nil, ValidationError) {
  use active <- result.try(normalize_states(
    "tracker.active_states",
    tracker_active_states(config.tracker),
  ))

  use terminal <- result.try(normalize_states(
    "tracker.terminal_states",
    tracker_terminal_states(config.tracker),
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
