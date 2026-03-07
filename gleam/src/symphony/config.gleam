import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/os
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import symphony/errors

/// Configuration for the issue tracker (Linear)
pub type TrackerConfig {
  TrackerConfig(
    kind: String,
    api_key: String,
    project_slug: String,
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

/// Configuration for agent behavior
pub type AgentConfig {
  AgentConfig(
    max_concurrent_agents: Int,
    max_turns: Int,
  )
}

/// Configuration for Codex integration
pub type CodexConfig {
  CodexConfig(
    command: String,
    turn_timeout_ms: Int,
  )
}

/// Complete configuration loaded from WORKFLOW.md
pub type Config {
  Config(
    tracker: TrackerConfig,
    polling: PollingConfig,
    workspace: WorkspaceConfig,
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

  use config_dict <- result.try(
    parse_yaml_front_matter(content)
    |> result.map_error(fn(e) { errors.ParseError(details: e) }),
  )

  use config <- result.try(
    build_config(config_dict)
    |> result.map_error(fn(e) { errors.ParseError(details: e) }),
  )

  Ok(config)
}

/// Parse YAML front matter from WORKFLOW.md content
fn parse_yaml_front_matter(content: String) -> Result(Dict(String, Dynamic), String) {
  let lines = string.split(content, "\n")

  case lines {
    ["---", ..rest] -> {
      case find_closing_delimiter(rest, []) {
        Ok(yaml_lines) -> {
          parse_simple_yaml(yaml_lines)
          |> result.map_error(fn(e) { "YAML parse error: " <> e })
        }
        Error(e) -> Error(e)
      }
    }
    _ -> Error("WORKFLOW.md must start with YAML front matter (---)")
  }
}

/// Simple YAML parser for basic key-value pairs
fn parse_simple_yaml(lines: List(String)) -> Result(Dict(String, Dynamic), String) {
  parse_yaml_lines(lines, dict.new())
}

/// Parse YAML lines into a dictionary
fn parse_yaml_lines(
  lines: List(String),
  acc: Dict(String, Dynamic),
) -> Result(Dict(String, Dynamic), String) {
  case lines {
    [] -> Ok(acc)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case string.starts_with(trimmed, "#") || trimmed == "" {
        True -> parse_yaml_lines(rest, acc)
        False -> {
          case parse_yaml_line(trimmed) {
            Ok(KeyValue(key, value)) -> {
              let new_acc = dict.insert(acc, key, dynamic.from(value))
              parse_yaml_lines(rest, new_acc)
            }
            Ok(SectionStart(name)) -> {
              // Create nested dict for section
              case dict.get(acc, name) {
                Ok(_) -> parse_yaml_lines(rest, acc)
                Error(_) -> {
                  let new_acc = dict.insert(
                    acc,
                    name,
                    dynamic.from(dict.new()),
                  )
                  parse_yaml_lines(rest, new_acc)
                }
              }
            }
            Ok(NestedKeyValue(parent, key, value)) -> {
              case dict.get(acc, parent) {
                Ok(parent_dyn) -> {
                  let decoder = dynamic.dict(dynamic.string, dynamic.dynamic)
                  case decoder(parent_dyn) {
                    Ok(parent_dict) -> {
                      let new_parent = dict.insert(
                        parent_dict,
                        key,
                        dynamic.from(value),
                      )
                      let new_acc = dict.insert(acc, parent, dynamic.from(new_parent))
                      parse_yaml_lines(rest, new_acc)
                    }
                    Error(_) -> Error("Invalid nested structure for " <> parent)
                  }
                }
                Error(_) -> Error("Parent section not found: " <> parent)
              }
            }
            Error(e) -> Error(e)
          }
        }
      }
    }
  }
}

/// Types of YAML lines we can parse
type YamlLine {
  KeyValue(String, String)
  SectionStart(String)
  NestedKeyValue(String, String, String)
}

/// Parse a single YAML line
fn parse_yaml_line(line: String) -> Result(YamlLine, String) {
  // Check for nested key-value (with leading spaces)
  case string.starts_with(line, "  ") || string.starts_with(line, "\t") {
    True -> {
      // This is a nested line - we'll handle this in the parent context
      // For now, just treat as error since we need parent context
      Error("Nested values require parent context")
    }
    False -> {
      // Check for section start (ends with :)
      case string.ends_with(line, ":") && !string.contains(line, ": ") {
        True -> {
          let name = string.drop_right(line, 1) |> string.trim
          Ok(SectionStart(name))
        }
        False -> {
          // Check for key-value pair
          case string.split_once(line, ":") {
            Ok(#(key, value)) -> {
              let trimmed_key = string.trim(key)
              let trimmed_value = string.trim(value)
              Ok(KeyValue(trimmed_key, trimmed_value))
            }
            Error(_) -> Error("Invalid YAML line: " <> line)
          }
        }
      }
    }
  }
}

/// Find the closing --- delimiter
fn find_closing_delimiter(
  lines: List(String),
  acc: List(String),
) -> Result(List(String), String) {
  case lines {
    [] -> Error("YAML front matter not closed (missing ---)")
    ["---", .._] -> Ok(list.reverse(acc))
    [line, ..rest] -> find_closing_delimiter(rest, [line, ..acc])
  }
}

/// Build Config from parsed YAML dictionary
fn build_config(dict: Dict(String, Dynamic)) -> Result(Config, String) {
  use tracker <- result.try(build_tracker_config(dict))
  use polling <- result.try(build_polling_config(dict))
  use workspace <- result.try(build_workspace_config(dict))
  use agent <- result.try(build_agent_config(dict))
  use codex <- result.try(build_codex_config(dict))
  use prompt_template <- result.try(get_prompt_template(dict))

  Ok(Config(
    tracker: tracker,
    polling: polling,
    workspace: workspace,
    agent: agent,
    codex: codex,
    prompt_template: prompt_template,
  ))
}

/// Build tracker configuration with defaults
fn build_tracker_config(
  dict: Dict(String, Dynamic),
) -> Result(TrackerConfig, String) {
  use tracker_dict <- result.try(get_dict(dict, "tracker"))

  use kind <- result.try(get_string_required(tracker_dict, "kind", "tracker.kind"))
  use api_key <- result.try(
    get_string_with_env(tracker_dict, "api_key", "tracker.api_key"),
  )
  use project_slug <- result.try(
    get_string_required(tracker_dict, "project_slug", "tracker.project_slug"),
  )
  let active_states = get_string_list_with_default(
    tracker_dict,
    "active_states",
    ["Todo", "In Progress", "In Review"],
  )
  let terminal_states = get_string_list_with_default(
    tracker_dict,
    "terminal_states",
    ["Done", "Canceled", "Duplicate"],
  )

  Ok(TrackerConfig(
    kind: kind,
    api_key: api_key,
    project_slug: project_slug,
    active_states: active_states,
    terminal_states: terminal_states,
  ))
}

/// Build polling configuration with defaults
fn build_polling_config(
  dict: Dict(String, Dynamic),
) -> Result(PollingConfig, String) {
  use polling_dict <- result.try(get_dict(dict, "polling"))

  let interval_ms = get_int_with_default(polling_dict, "interval_ms", 30000)

  Ok(PollingConfig(interval_ms: interval_ms))
}

/// Build workspace configuration with defaults
fn build_workspace_config(
  dict: Dict(String, Dynamic),
) -> Result(WorkspaceConfig, String) {
  use workspace_dict <- result.try(get_dict(dict, "workspace"))

  let root = get_string_with_default(
    workspace_dict,
    "root",
    "/tmp/symphony_workspaces",
  )

  Ok(WorkspaceConfig(root: root))
}

/// Build agent configuration with defaults
fn build_agent_config(dict: Dict(String, Dynamic)) -> Result(AgentConfig, String) {
  use agent_dict <- result.try(get_dict(dict, "agent"))

  let max_concurrent_agents = get_int_with_default(
    agent_dict,
    "max_concurrent_agents",
    10,
  )
  let max_turns = get_int_with_default(agent_dict, "max_turns", 20)

  Ok(AgentConfig(
    max_concurrent_agents: max_concurrent_agents,
    max_turns: max_turns,
  ))
}

/// Build Codex configuration with defaults
fn build_codex_config(dict: Dict(String, Dynamic)) -> Result(CodexConfig, String) {
  use codex_dict <- result.try(get_dict(dict, "codex"))

  let command = get_string_with_default(codex_dict, "command", "codex app-server")
  let turn_timeout_ms = get_int_with_default(codex_dict, "turn_timeout_ms", 3600000)

  Ok(CodexConfig(command: command, turn_timeout_ms: turn_timeout_ms))
}

/// Get prompt template (required)
fn get_prompt_template(dict: Dict(String, Dynamic)) -> Result(String, String) {
  get_string_required(dict, "prompt_template", "prompt_template")
}

// ============================================================================
// Helper functions for extracting values from Dynamic
// ============================================================================

/// Get a nested dictionary from a parent dictionary
fn get_dict(
  dict: Dict(String, Dynamic),
  key: String,
) -> Result(Dict(String, Dynamic), String) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      let decoder = dynamic.dict(dynamic.string, dynamic.dynamic)
      case decoder(dyn) {
        Ok(d) -> Ok(d)
        Error(_) -> Error(key <> " must be a mapping")
      }
    }
    Error(_) -> Error("Missing required key: " <> key)
  }
}

/// Get a required string value
fn get_string_required(
  dict: Dict(String, Dynamic),
  key: String,
  path: String,
) -> Result(String, String) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case dynamic.string(dyn) {
        Ok(s) -> expand_env_vars(s)
        Error(_) -> Error(path <> " must be a string")
      }
    }
    Error(_) -> Error("Missing required key: " <> path)
  }
}

/// Get a string value with environment variable expansion
fn get_string_with_env(
  dict: Dict(String, Dynamic),
  key: String,
  path: String,
) -> Result(String, String) {
  case dict.get(dict, key) {
    Ok(dyn) -> {
      case dynamic.string(dyn) {
        Ok(s) -> expand_env_vars(s)
        Error(_) -> Error(path <> " must be a string")
      }
    }
    Error(_) -> Error("Missing required key: " <> path)
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
fn get_int_with_default(dict: Dict(String, Dynamic), key: String, default: Int) -> Int {
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
fn expand_env_vars(s: String) -> Result(String, String) {
  case string.split(s, "$") {
    [] -> Ok(s)
    [first] -> Ok(first)
    [first, ..rest] -> {
      use expanded <- result.try(
        list.try_fold(rest, first, expand_single_var),
      )
      Ok(expanded)
    }
  }
}

/// Expand a single variable reference
fn expand_single_var(acc: String, part: String) -> Result(String, String) {
  // Find the variable name (alphanumeric and underscore)
  let var_name_end = find_var_name_end(part, 0)
  let var_name = string.slice(part, 0, var_name_end)
  let rest = string.drop_left(part, var_name_end)

  case var_name {
    "" -> Ok(acc <> "$" <> part)
    _ -> {
      case os.get_env(var_name) {
        Ok(value) -> Ok(acc <> value <> rest)
        Error(_) -> Error("Environment variable not found: " <> var_name)
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
