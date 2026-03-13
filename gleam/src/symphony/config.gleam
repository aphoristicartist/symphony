import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/os
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import simplifile
import symphony/errors

/// Configuration for the issue tracker (Linear or Plane).
/// Variants enforce which fields are present for each backend.
pub type TrackerConfig {
  LinearConfig(
    api_key: String,
    project_slug: String,
    active_states: List(String),
    terminal_states: List(String),
  )
  PlaneConfig(
    api_key: String,
    endpoint: String,
    workspace_slug: String,
    project_id: String,
    active_states: List(String),
    terminal_states: List(String),
  )
}

/// Configuration for polling behavior
pub type PollingConfig {
  PollingConfig(interval_ms: Int)
}

/// Configuration for workspace management
pub type WorkspaceConfig {
  WorkspaceConfig(root: String)
}

/// Configuration for workspace lifecycle hooks
pub type HooksConfig {
  HooksConfig(
    after_create: option.Option(String),
    before_run: option.Option(String),
    after_run: option.Option(String),
    before_remove: option.Option(String),
    timeout_ms: Int,
  )
}

/// Configuration for agent behavior
pub type AgentConfig {
  AgentConfig(
    kind: String,
    command: option.Option(String),
    max_concurrent_agents: Int,
    max_turns: Int,
    allowed_tools: option.Option(String),
    permission_mode: option.Option(String),
    provider: option.Option(String),
    model: option.Option(String),
    builtins: option.Option(String),
  )
}

/// Configuration for Codex integration
pub type CodexConfig {
  CodexConfig(command: String, turn_timeout_ms: Int)
}

/// Complete configuration loaded from WORKFLOW.md
pub type Config {
  Config(
    tracker: TrackerConfig,
    polling: PollingConfig,
    workspace: WorkspaceConfig,
    hooks: HooksConfig,
    agent: AgentConfig,
    codex: CodexConfig,
    prompt_template: String,
  )
}

/// Load configuration from a WORKFLOW.md file
pub fn load(path: String) -> Result(Config, errors.ConfigError) {
  use content <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { errors.MissingFile(path: path) }),
  )

  use config_dict <- result.try(parse_yaml_front_matter(content))

  use config <- result.try(build_config(config_dict))

  Ok(config)
}

/// Parse YAML front matter from WORKFLOW.md content
fn parse_yaml_front_matter(
  content: String,
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  let lines = string.split(content, "\n")

  case lines {
    ["---", ..rest] -> {
      case find_closing_delimiter(rest, []) {
        Ok(yaml_lines) -> parse_simple_yaml(yaml_lines)
        Error(e) -> Error(e)
      }
    }
    _ ->
      Error(errors.ParseError(
        details: "WORKFLOW.md must start with YAML front matter (---)",
      ))
  }
}

/// Simple YAML parser for basic key-value pairs
fn parse_simple_yaml(
  lines: List(String),
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  parse_yaml_lines(lines, dict.new(), option.None)
}

/// Parse YAML lines into a dictionary
fn parse_yaml_lines(
  lines: List(String),
  acc: Dict(String, Dynamic),
  current_section: option.Option(String),
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  case lines {
    [] -> Ok(acc)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case string.starts_with(trimmed, "#") || trimmed == "" {
        True -> parse_yaml_lines(rest, acc, current_section)
        False -> {
          case is_indented(line) {
            True -> parse_nested_line(trimmed, acc, current_section, rest)
            False -> parse_root_line(trimmed, acc, rest)
          }
        }
      }
    }
  }
}

fn parse_root_line(
  line: String,
  acc: Dict(String, Dynamic),
  rest: List(String),
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  case is_section_start(line) {
    True -> {
      let section = string.drop_right(line, 1) |> string.trim

      case dict.get(acc, section) {
        Ok(existing) -> {
          let decoder = dynamic.dict(dynamic.string, dynamic.dynamic)
          case decoder(existing) {
            Ok(_) -> parse_yaml_lines(rest, acc, option.Some(section))
            Error(_) ->
              Error(errors.ParseError(
                details: "Section " <> section <> " must be a mapping",
              ))
          }
        }
        Error(_) -> {
          let new_acc = dict.insert(acc, section, dynamic.from(dict.new()))
          parse_yaml_lines(rest, new_acc, option.Some(section))
        }
      }
    }
    False -> {
      use #(key, value) <- result.try(parse_key_value(line))
      let new_acc = dict.insert(acc, key, dynamic.from(value))
      parse_yaml_lines(rest, new_acc, option.None)
    }
  }
}

fn parse_nested_line(
  line: String,
  acc: Dict(String, Dynamic),
  current_section: option.Option(String),
  rest: List(String),
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  use section <- result.try(require_section(current_section))
  use parent <- result.try(get_section_dict(acc, section))
  use #(key, value) <- result.try(parse_key_value(line))

  let updated_parent = dict.insert(parent, key, dynamic.from(value))
  let new_acc = dict.insert(acc, section, dynamic.from(updated_parent))
  parse_yaml_lines(rest, new_acc, option.Some(section))
}

fn parse_key_value(
  line: String,
) -> Result(#(String, String), errors.ConfigError) {
  case string.split_once(line, ":") {
    Ok(#(key, value)) -> Ok(#(string.trim(key), string.trim(value)))
    Error(_) -> Error(errors.ParseError(details: "Invalid YAML line: " <> line))
  }
}

fn require_section(
  current_section: option.Option(String),
) -> Result(String, errors.ConfigError) {
  case current_section {
    option.Some(section) -> Ok(section)
    option.None ->
      Error(errors.ParseError(
        details: "Nested YAML value without a parent section",
      ))
  }
}

fn get_section_dict(
  acc: Dict(String, Dynamic),
  section: String,
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  case dict.get(acc, section) {
    Ok(parent_dyn) -> {
      let decoder = dynamic.dict(dynamic.string, dynamic.dynamic)
      case decoder(parent_dyn) {
        Ok(parent) -> Ok(parent)
        Error(_) ->
          Error(errors.ParseError(
            details: "Invalid nested structure for " <> section,
          ))
      }
    }
    Error(_) ->
      Error(errors.ParseError(details: "Parent section not found: " <> section))
  }
}

fn is_indented(line: String) -> Bool {
  string.starts_with(line, "  ") || string.starts_with(line, "\t")
}

fn is_section_start(line: String) -> Bool {
  string.ends_with(line, ":") && !string.contains(line, ": ")
}

/// Find the closing --- delimiter
fn find_closing_delimiter(
  lines: List(String),
  acc: List(String),
) -> Result(List(String), errors.ConfigError) {
  case lines {
    [] ->
      Error(errors.ParseError(
        details: "YAML front matter not closed (missing ---)",
      ))
    ["---", ..] -> Ok(list.reverse(acc))
    [line, ..rest] -> find_closing_delimiter(rest, [line, ..acc])
  }
}

/// Build Config from parsed YAML dictionary
fn build_config(
  dict: Dict(String, Dynamic),
) -> Result(Config, errors.ConfigError) {
  use tracker <- result.try(build_tracker_config(dict))
  use polling <- result.try(build_polling_config(dict))
  use workspace <- result.try(build_workspace_config(dict))
  use hooks <- result.try(build_hooks_config(dict))
  use agent <- result.try(build_agent_config(dict))
  use codex <- result.try(build_codex_config(dict))
  use prompt_template <- result.try(get_prompt_template(dict))

  Ok(Config(
    tracker: tracker,
    polling: polling,
    workspace: workspace,
    hooks: hooks,
    agent: agent,
    codex: codex,
    prompt_template: prompt_template,
  ))
}

/// Build tracker configuration with defaults
fn build_tracker_config(
  dict: Dict(String, Dynamic),
) -> Result(TrackerConfig, errors.ConfigError) {
  use tracker_dict <- result.try(get_dict(dict, "tracker"))

  use kind <- result.try(get_string_required(
    tracker_dict,
    "kind",
    "tracker.kind",
  ))
  use api_key <- result.try(get_string_with_env(
    tracker_dict,
    "api_key",
    "tracker.api_key",
  ))
  let active_states =
    get_string_list_with_default(tracker_dict, "active_states", [
      "Todo",
      "In Progress",
      "In Review",
    ])
  let terminal_states =
    get_string_list_with_default(tracker_dict, "terminal_states", [
      "Done",
      "Canceled",
      "Duplicate",
    ])

  case string.lowercase(string.trim(kind)) {
    "plane" ->
      build_plane_tracker_config(
        tracker_dict,
        api_key,
        active_states,
        terminal_states,
      )
    _ -> {
      let project_slug =
        get_string_with_default(tracker_dict, "project_slug", "")
      Ok(LinearConfig(
        api_key: api_key,
        project_slug: project_slug,
        active_states: active_states,
        terminal_states: terminal_states,
      ))
    }
  }
}

/// Build Plane-specific tracker configuration
fn build_plane_tracker_config(
  tracker_dict: Dict(String, Dynamic),
  api_key: String,
  active_states: List(String),
  terminal_states: List(String),
) -> Result(TrackerConfig, errors.ConfigError) {
  use endpoint <- result.try(get_string_required(
    tracker_dict,
    "endpoint",
    "tracker.endpoint",
  ))
  use workspace_slug <- result.try(get_string_required(
    tracker_dict,
    "workspace_slug",
    "tracker.workspace_slug",
  ))
  use project_id <- result.try(get_string_required(
    tracker_dict,
    "project_id",
    "tracker.project_id",
  ))
  Ok(PlaneConfig(
    api_key: api_key,
    endpoint: endpoint,
    workspace_slug: workspace_slug,
    project_id: project_id,
    active_states: active_states,
    terminal_states: terminal_states,
  ))
}

/// Build polling configuration with defaults
fn build_polling_config(
  dict: Dict(String, Dynamic),
) -> Result(PollingConfig, errors.ConfigError) {
  use polling_dict <- result.try(get_dict(dict, "polling"))

  let interval_ms = get_int_with_default(polling_dict, "interval_ms", 30_000)

  Ok(PollingConfig(interval_ms: interval_ms))
}

/// Build workspace configuration with defaults
fn build_workspace_config(
  dict: Dict(String, Dynamic),
) -> Result(WorkspaceConfig, errors.ConfigError) {
  use workspace_dict <- result.try(get_dict(dict, "workspace"))

  let root =
    get_string_with_default(workspace_dict, "root", "/tmp/symphony_workspaces")

  Ok(WorkspaceConfig(root: root))
}

/// Build workspace hook configuration with defaults
fn build_hooks_config(
  dict: Dict(String, Dynamic),
) -> Result(HooksConfig, errors.ConfigError) {
  use hooks_dict <- result.try(get_optional_dict(dict, "hooks"))

  use after_create <- result.try(get_optional_string(
    hooks_dict,
    "after_create",
    "hooks.after_create",
  ))
  use before_run <- result.try(get_optional_string(
    hooks_dict,
    "before_run",
    "hooks.before_run",
  ))
  use after_run <- result.try(get_optional_string(
    hooks_dict,
    "after_run",
    "hooks.after_run",
  ))
  use before_remove <- result.try(get_optional_string(
    hooks_dict,
    "before_remove",
    "hooks.before_remove",
  ))
  let timeout_ms = get_int_with_default(hooks_dict, "timeout_ms", 60_000)

  Ok(HooksConfig(
    after_create: after_create,
    before_run: before_run,
    after_run: after_run,
    before_remove: before_remove,
    timeout_ms: timeout_ms,
  ))
}

/// Build agent configuration with defaults
fn build_agent_config(
  dict: Dict(String, Dynamic),
) -> Result(AgentConfig, errors.ConfigError) {
  use agent_dict <- result.try(get_dict(dict, "agent"))

  let kind = get_string_with_default(agent_dict, "kind", "codex")
  use command <- result.try(get_optional_string(
    agent_dict,
    "command",
    "agent.command",
  ))
  let max_concurrent_agents =
    get_int_with_default(agent_dict, "max_concurrent_agents", 10)
  let max_turns = get_int_with_default(agent_dict, "max_turns", 20)
  use allowed_tools <- result.try(get_optional_string(
    agent_dict,
    "allowed_tools",
    "agent.allowed_tools",
  ))
  use permission_mode <- result.try(get_optional_string(
    agent_dict,
    "permission_mode",
    "agent.permission_mode",
  ))
  use provider <- result.try(get_optional_string(
    agent_dict,
    "provider",
    "agent.provider",
  ))
  use model <- result.try(get_optional_string(
    agent_dict,
    "model",
    "agent.model",
  ))
  use builtins <- result.try(get_optional_string(
    agent_dict,
    "builtins",
    "agent.builtins",
  ))

  Ok(AgentConfig(
    kind: kind,
    command: command,
    max_concurrent_agents: max_concurrent_agents,
    max_turns: max_turns,
    allowed_tools: allowed_tools,
    permission_mode: permission_mode,
    provider: provider,
    model: model,
    builtins: builtins,
  ))
}

/// Build Codex configuration with defaults
fn build_codex_config(
  dict: Dict(String, Dynamic),
) -> Result(CodexConfig, errors.ConfigError) {
  use codex_dict <- result.try(get_dict(dict, "codex"))

  let command =
    get_string_with_default(codex_dict, "command", "codex app-server")
  let turn_timeout_ms =
    get_int_with_default(codex_dict, "turn_timeout_ms", 3_600_000)

  Ok(CodexConfig(command: command, turn_timeout_ms: turn_timeout_ms))
}

/// Get prompt template (required)
fn get_prompt_template(
  dict: Dict(String, Dynamic),
) -> Result(String, errors.ConfigError) {
  get_string_required(dict, "prompt_template", "prompt_template")
}

// ============================================================================
// Helper functions for extracting values from Dynamic
// ============================================================================

/// Get a nested dictionary from a parent dictionary
fn get_dict(
  dict: Dict(String, Dynamic),
  key: String,
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      let decoder = dynamic.dict(dynamic.string, dynamic.dynamic)
      case decoder(dyn) {
        Ok(d) -> Ok(d)
        Error(_) -> Error(config_validation_type(key, "mapping"))
      }
    }
    Error(_) -> Error(config_validation_missing(key))
  }
}

/// Get an optional nested dictionary from a parent dictionary
fn get_optional_dict(
  dict: Dict(String, Dynamic),
  key: String,
) -> Result(Dict(String, Dynamic), errors.ConfigError) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      let decoder = dynamic.dict(dynamic.string, dynamic.dynamic)
      case decoder(dyn) {
        Ok(d) -> Ok(d)
        Error(_) -> Error(config_validation_type(key, "mapping"))
      }
    }
    Error(_) -> Ok(dict.new())
  }
}

/// Get a required string value
fn get_string_required(
  dict: Dict(String, Dynamic),
  key: String,
  path: String,
) -> Result(String, errors.ConfigError) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case dynamic.string(dyn) {
        Ok(s) -> expand_env_vars(s)
        Error(_) -> Error(config_validation_type(path, "string"))
      }
    }
    Error(_) -> Error(config_validation_missing(path))
  }
}

/// Get a string value with environment variable expansion
fn get_string_with_env(
  dict: Dict(String, Dynamic),
  key: String,
  path: String,
) -> Result(String, errors.ConfigError) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case dynamic.string(dyn) {
        Ok(s) -> expand_env_vars(s)
        Error(_) -> Error(config_validation_type(path, "string"))
      }
    }
    Error(_) -> Error(config_validation_missing(path))
  }
}

/// Get an optional string value
fn get_optional_string(
  dict: Dict(String, Dynamic),
  key: String,
  path: String,
) -> Result(option.Option(String), errors.ConfigError) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case dynamic.string(dyn) {
        Ok(s) ->
          expand_env_vars(s)
          |> result.map(fn(value) { option.Some(value) })
        Error(_) -> Error(config_validation_type(path, "string"))
      }
    }
    Error(_) -> Ok(option.None)
  }
}

/// Get a string value with a default
fn get_string_with_default(
  dict: Dict(String, Dynamic),
  key: String,
  default: String,
) -> String {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case dynamic.string(dyn) {
        Ok(s) -> expand_env_vars_or_default(s, default)
        Error(_) -> default
      }
    }
    Error(_) -> default
  }
}

/// Get an integer value with a default
fn get_int_with_default(
  dict: Dict(String, Dynamic),
  key: String,
  default: Int,
) -> Int {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case dynamic.int(dyn) {
        Ok(i) -> i
        Error(_) -> {
          // Try parsing from string
          case dynamic.string(dyn) {
            Ok(s) -> {
              case int.parse(s) {
                Ok(i) -> i
                Error(_) -> default
              }
            }
            Error(_) -> default
          }
        }
      }
    }
    Error(_) -> default
  }
}

/// Get a list of strings with a default
fn get_string_list_with_default(
  dict: Dict(String, Dynamic),
  key: String,
  default: List(String),
) -> List(String) {
  let decoder = dynamic.list(dynamic.string)
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case decoder(dyn) {
        Ok(items) -> items
        Error(_) -> default
      }
    }
    Error(_) -> default
  }
}

/// Expand environment variables in a string ($VAR_NAME)
fn expand_env_vars(s: String) -> Result(String, errors.ConfigError) {
  case string.split(s, "$") {
    [] -> Ok(s)
    [first] -> Ok(first)
    [first, ..rest] -> {
      use expanded <- result.try(list.try_fold(rest, first, expand_single_var))
      Ok(expanded)
    }
  }
}

/// Expand a single variable reference
fn expand_single_var(
  acc: String,
  part: String,
) -> Result(String, errors.ConfigError) {
  // Find the variable name (alphanumeric and underscore)
  let var_name_end = find_var_name_end(part, 0)
  let var_name = string.slice(part, 0, var_name_end)
  let rest = string.drop_left(part, var_name_end)

  case var_name {
    "" -> Ok(acc <> "$" <> part)
    _ -> {
      case os.get_env(var_name) {
        Ok(value) -> Ok(acc <> value <> rest)
        Error(_) -> Error(config_validation_missing("env." <> var_name))
      }
    }
  }
}

/// Find the end of a variable name
fn find_var_name_end(s: String, pos: Int) -> Int {
  case string.pop_grapheme(string.drop_left(s, pos)) {
    Ok(#(grapheme, _)) -> {
      case is_var_name_char(grapheme) {
        True -> find_var_name_end(s, pos + 1)
        False -> pos
      }
    }
    Error(_) -> pos
  }
}

/// Check if a character is valid in a variable name
fn is_var_name_char(grapheme: String) -> Bool {
  let lowercase = [
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
  ]
  let uppercase = [
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
  ]
  let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

  grapheme == "_"
  || list.contains(lowercase, grapheme)
  || list.contains(uppercase, grapheme)
  || list.contains(digits, grapheme)
}

/// Expand env vars or return default if any var is missing
fn expand_env_vars_or_default(s: String, default: String) -> String {
  case expand_env_vars(s) {
    Ok(expanded) -> expanded
    Error(_) -> default
  }
}

fn config_validation_missing(field: String) -> errors.ConfigError {
  errors.ValidationFailed(error: errors.MissingRequiredField(field: field))
}

fn config_validation_type(field: String, expected: String) -> errors.ConfigError {
  errors.ValidationFailed(error: errors.UnsupportedValue(
    field: field,
    value: expected,
  ))
}
