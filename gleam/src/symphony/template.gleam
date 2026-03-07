import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/regex
import gleam/result
import gleam/string
import symphony/types.{type Issue}

/// Render a template string with variable substitution
/// Supports: {{ variable }}, {{ nested.field }}, {{ object.property }}
pub fn render(template: String, context: RenderContext) -> Result(String, String) {
  // Find all {{ ... }} patterns
  let assert Ok(var_pattern) = regex.from_string("\\{\\{\\s*([^}]+?)\\s*\\}\\}")

  regex.replace(var_pattern, template, fn(match) {
    let var_name = match
    |> string.trim
    |> string.replace("{{ ", "")
    |> string.replace(" }}", "")
    |> string.replace("{{", "")
    |> string.replace("}}", "")
    |> string.trim

    case resolve_variable(var_name, context) {
      Ok(value) -> value
      Error(_) -> "{{ UNDEFINED: " <> var_name <> " }}"
    }
  })
  |> Ok
}

/// Context for template rendering
pub type RenderContext {
  RenderContext(
    issue: Issue,
    attempt: Int,
    extra: Dict(String, String),
  )
}

/// Resolve a variable name to its value
fn resolve_variable(name: String, context: RenderContext) -> Result(String, String) {
  let parts = string.split(name, ".")
  
  case parts {
    ["issue"] -> Ok(format_issue(context.issue))
    ["issue", field] -> resolve_issue_field(field, context.issue)
    ["attempt"] -> Ok(int.to_string(context.attempt))
    [key] -> {
      case dict.get(context.extra, key) {
        Ok(value) -> Ok(value)
        Error(_) -> Error("Undefined variable: " <> key)
      }
    }
    [namespace, ..rest] -> {
      // Try to resolve nested path
      case namespace {
        "issue" -> resolve_nested_issue_field(rest, context.issue)
        _ -> Error("Unknown namespace: " <> namespace)
      }
    }
    _ -> Error("Invalid variable path: " <> name)
  }
}

/// Resolve an issue field
fn resolve_issue_field(field: String, issue: Issue) -> Result(String, String) {
  case field {
    "id" -> Ok(issue.id)
    "identifier" -> Ok(issue.identifier)
    "title" -> Ok(issue.title)
    "description" -> Ok(option.unwrap(issue.description, ""))
    "state" -> Ok(issue.state)
    "priority" -> Ok(option.unwrap(option.map(issue.priority, int.to_string), ""))
    "branch_name" -> Ok(option.unwrap(issue.branch_name, ""))
    "url" -> Ok(option.unwrap(issue.url, ""))
    "labels" -> Ok(string.join(issue.labels, ", "))
    "created_at" -> Ok(option.unwrap(option.map(issue.created_at, int.to_string), ""))
    "updated_at" -> Ok(option.unwrap(option.map(issue.updated_at, int.to_string), ""))
    _ -> Error("Unknown issue field: " <> field)
  }
}

/// Resolve nested issue field
fn resolve_nested_issue_field(path: List(String), issue: Issue) -> Result(String, String) {
  case path {
    [] -> Ok(format_issue(issue))
    [field] -> resolve_issue_field(field, issue)
    [field, ..rest] -> {
      // For now, we don't support deeper nesting
      Error("Nested field access not supported: " <> string.join([field, ..rest], "."))
    }
  }
}

/// Format an entire issue as a string
fn format_issue(issue: Issue) -> String {
  "Issue("
    <> issue.identifier
    <> ": "
    <> issue.title
    <> ")"
}

/// Create a render context from an issue
pub fn context_from_issue(issue: Issue, attempt: Int) -> RenderContext {
  RenderContext(issue: issue, attempt: attempt, extra: dict.new())
}

/// Add extra variables to the context
pub fn with_extra(context: RenderContext, key: String, value: String) -> RenderContext {
  RenderContext(
    issue: context.issue,
    attempt: context.attempt,
    extra: dict.insert(context.extra, key, value),
  )
}
