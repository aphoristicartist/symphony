import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/regex
import gleam/string
import symphony/errors
import symphony/types.{type Issue}

/// Render a template string with variable substitution
/// Supports: {{ variable }}, {{ nested.field }}, {{ object.property }}
pub fn render(
  template: String,
  context: RenderContext,
) -> Result(String, errors.ValidationError) {
  // Find all {{ ... }} patterns
  let assert Ok(var_pattern) = regex.from_string("\\{\\{\\s*([^}]+?)\\s*\\}\\}")

  let matches = regex.scan(with: var_pattern, content: template)

  // Replace each match
  list.fold(matches, template, fn(acc, match) {
    case match {
      regex.Match(content: full_match, submatches: [Some(var_name)]) -> {
        case resolve_variable(var_name, context) {
          Ok(value) -> string.replace(acc, full_match, value)
          Error(_) ->
            string.replace(
              acc,
              full_match,
              "{{ UNDEFINED: " <> var_name <> " }}",
            )
        }
      }
      _ -> acc
    }
  })
  |> Ok
}

/// Context for template rendering
pub type RenderContext {
  RenderContext(issue: Issue, attempt: Int, extra: Dict(String, String))
}

/// Resolve a variable name to its value
fn resolve_variable(
  name: String,
  context: RenderContext,
) -> Result(String, errors.ValidationError) {
  let parts = string.split(name, ".")

  case parts {
    ["issue"] -> Ok(format_issue(context.issue))
    ["issue", field] -> resolve_issue_field(field, context.issue)
    ["attempt"] -> Ok(int.to_string(context.attempt))
    [key] -> {
      case dict.get(context.extra, key) {
        Ok(value) -> Ok(value)
        Error(_) ->
          Error(errors.MissingRequiredField(field: "template.extra." <> key))
      }
    }
    [namespace, ..rest] -> {
      // Try to resolve nested path
      case namespace {
        "issue" -> resolve_nested_issue_field(rest, context.issue)
        _ ->
          Error(errors.UnsupportedValue(
            field: "template.namespace",
            value: namespace,
          ))
      }
    }
    _ -> Error(errors.UnsupportedValue(field: "template.variable", value: name))
  }
}

/// Resolve an issue field
fn resolve_issue_field(
  field: String,
  issue: Issue,
) -> Result(String, errors.ValidationError) {
  case field {
    "id" -> Ok(issue.id)
    "identifier" -> Ok(issue.identifier)
    "title" -> Ok(issue.title)
    "description" -> Ok(option.unwrap(issue.description, ""))
    "state" -> Ok(issue.state)
    "priority" ->
      Ok(option.unwrap(option.map(issue.priority, int.to_string), ""))
    "branch_name" -> Ok(option.unwrap(issue.branch_name, ""))
    "url" -> Ok(option.unwrap(issue.url, ""))
    "labels" -> Ok(string.join(issue.labels, ", "))
    "created_at" ->
      Ok(option.unwrap(option.map(issue.created_at, int.to_string), ""))
    "updated_at" ->
      Ok(option.unwrap(option.map(issue.updated_at, int.to_string), ""))
    _ ->
      Error(errors.UnsupportedValue(field: "template.issue.field", value: field))
  }
}

/// Resolve nested issue field
fn resolve_nested_issue_field(
  path: List(String),
  issue: Issue,
) -> Result(String, errors.ValidationError) {
  case path {
    [] -> Ok(format_issue(issue))
    [field] -> resolve_issue_field(field, issue)
    [field, ..rest] -> {
      // For now, we don't support deeper nesting
      Error(errors.UnsupportedValue(
        field: "template.issue.path",
        value: string.join([field, ..rest], "."),
      ))
    }
  }
}

/// Format an entire issue as a string
fn format_issue(issue: Issue) -> String {
  "Issue(" <> issue.identifier <> ": " <> issue.title <> ")"
}

/// Create a render context from an issue
pub fn context_from_issue(issue: Issue, attempt: Int) -> RenderContext {
  RenderContext(issue: issue, attempt: attempt, extra: dict.new())
}

/// Add extra variables to the context
pub fn with_extra(
  context: RenderContext,
  key: String,
  value: String,
) -> RenderContext {
  RenderContext(
    issue: context.issue,
    attempt: context.attempt,
    extra: dict.insert(context.extra, key, value),
  )
}
