import gleam/int
import gleam/option.{type Option}

/// Validation failures for typed config checks.
pub type ValidationError {
  MissingRequiredField(field: String)
  UnsupportedValue(field: String, value: String)
  EmptyStateList(field: String)
  OverlappingState(state: String)
  NonPositiveValue(field: String, value: Int)
  InvalidIssueIdentifier(identifier: String)
  InvalidSessionComponent(component: String, value: String)
}

/// Configuration loading and validation failures.
pub type ConfigError {
  MissingFile(path: String)
  ParseError(details: String)
  ValidationFailed(error: ValidationError)
}

/// Workspace hook identity.
pub type WorkspaceHook {
  AfterCreate
  BeforeRun
  AfterRun
  BeforeRemove
}

/// Workspace setup and lifecycle failures.
pub type WorkspaceError {
  CreationFailed(path: String, workspace_key: String, details: String)
  HookFailed(
    hook: WorkspaceHook,
    workspace_path: String,
    details: String,
    exit_code: Option(Int),
  )
  CleanupFailed(path: String, workspace_key: String, details: String)
}

/// Tracker integration failures.
pub type TrackerError {
  ApiError(operation: String, details: String, status_code: Option(Int))
  RateLimit(retry_after_ms: Option(Int), scope: Option(String), details: String)
  NotFound(resource: String, identifier: Option(String), details: String)
}

/// Agent execution failures.
pub type AgentError {
  LaunchFailed(command: String, workspace_path: String, details: String)
  Timeout(operation: String, timeout_ms: Int, details: String)
  ProtocolError(event: Option(String), details: String)
}

/// Orchestrator coordination failures.
pub type OrchestrationError {
  DispatchFailed(
    issue_id: String,
    issue_identifier: Option(String),
    attempt: Option(Int),
    details: String,
  )
  ReconciliationFailed(
    issue_id: Option(String),
    operation: String,
    details: String,
  )
}

/// Unified runtime failure surface.
pub type RunError {
  ConfigFailure(ConfigError)
  WorkspaceFailure(WorkspaceError)
  TrackerFailure(TrackerError)
  AgentFailure(AgentError)
  OrchestrationFailure(OrchestrationError)
}

/// Deterministic human-readable message for validation failures.
pub fn validation_error_message(error: ValidationError) -> String {
  case error {
    MissingRequiredField(field) -> "Missing required field: " <> field
    UnsupportedValue(field, value) ->
      "Unsupported value for " <> field <> ": " <> value
    EmptyStateList(field) -> "State list must not be empty: " <> field
    OverlappingState(state) ->
      "State cannot be both active and terminal: " <> state
    NonPositiveValue(field, value) ->
      "Expected positive value for " <> field <> ", got: "
      <> int.to_string(value)
    InvalidIssueIdentifier(identifier) ->
      "Invalid issue identifier: " <> identifier
    InvalidSessionComponent(component, value) ->
      "Invalid session component " <> component <> ": " <> value
  }
}

/// Deterministic human-readable message for config failures.
pub fn config_error_message(error: ConfigError) -> String {
  case error {
    MissingFile(path) -> "Configuration file not found: " <> path
    ParseError(details) -> "Configuration parse error: " <> details
    ValidationFailed(error) ->
      "Configuration validation failed: " <> validation_error_message(error)
  }
}
