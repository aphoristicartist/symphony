import gleam/int
import gleam/option.{None, Some, type Option}

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

/// Deterministic human-readable message for tracker failures.
pub fn tracker_error_message(error: TrackerError) -> String {
  case error {
    ApiError(operation, details, status_code) -> {
      case status_code {
        Some(code) ->
          "Tracker API error in "
          <> operation
          <> " (status "
          <> int.to_string(code)
          <> "): "
          <> details
        None -> "Tracker API error in " <> operation <> ": " <> details
      }
    }
    RateLimit(retry_after_ms, scope, details) -> {
      let retry_text = case retry_after_ms {
        Some(ms) -> int.to_string(ms) <> "ms"
        None -> "unknown"
      }
      let scope_text = case scope {
        Some(scope_name) -> scope_name
        None -> "unspecified"
      }

      "Tracker rate limited (scope: "
      <> scope_text
      <> ", retry_after: "
      <> retry_text
      <> "): "
      <> details
    }
    NotFound(resource, identifier, details) -> {
      case identifier {
        Some(value) ->
          "Tracker resource not found: "
          <> resource
          <> " ("
          <> value
          <> ") - "
          <> details
        None -> "Tracker resource not found: " <> resource <> " - " <> details
      }
    }
  }
}

/// Deterministic human-readable message for workspace failures.
pub fn workspace_error_message(error: WorkspaceError) -> String {
  case error {
    CreationFailed(path, workspace_key, details) ->
      "Workspace creation failed for "
      <> workspace_key
      <> " at "
      <> path
      <> ": "
      <> details
    HookFailed(hook, workspace_path, details, exit_code) -> {
      let code_text = case exit_code {
        Some(code) -> int.to_string(code)
        None -> "unknown"
      }

      "Workspace hook "
      <> workspace_hook_name(hook)
      <> " failed in "
      <> workspace_path
      <> " (exit: "
      <> code_text
      <> "): "
      <> details
    }
    CleanupFailed(path, workspace_key, details) ->
      "Workspace cleanup failed for "
      <> workspace_key
      <> " at "
      <> path
      <> ": "
      <> details
  }
}

/// Deterministic human-readable message for agent failures.
pub fn agent_error_message(error: AgentError) -> String {
  case error {
    LaunchFailed(command, workspace_path, details) ->
      "Agent launch failed for command `"
      <> command
      <> "` in "
      <> workspace_path
      <> ": "
      <> details
    Timeout(operation, timeout_ms, details) ->
      "Agent timeout during "
      <> operation
      <> " after "
      <> int.to_string(timeout_ms)
      <> "ms: "
      <> details
    ProtocolError(event, details) -> {
      case event {
        Some(event_name) -> "Agent protocol error at " <> event_name <> ": " <> details
        None -> "Agent protocol error: " <> details
      }
    }
  }
}

/// Deterministic human-readable message for orchestration failures.
pub fn orchestration_error_message(error: OrchestrationError) -> String {
  case error {
    DispatchFailed(issue_id, issue_identifier, attempt, details) -> {
      let identifier_text = case issue_identifier {
        Some(value) -> value
        None -> "unknown"
      }
      let attempt_text = case attempt {
        Some(value) -> int.to_string(value)
        None -> "unknown"
      }

      "Dispatch failed for issue "
      <> issue_id
      <> " (identifier: "
      <> identifier_text
      <> ", attempt: "
      <> attempt_text
      <> "): "
      <> details
    }
    ReconciliationFailed(issue_id, operation, details) -> {
      let issue_text = case issue_id {
        Some(value) -> value
        None -> "unknown"
      }

      "Reconciliation failed for issue "
      <> issue_text
      <> " during "
      <> operation
      <> ": "
      <> details
    }
  }
}

/// Deterministic human-readable message for runtime failures.
pub fn run_error_message(error: RunError) -> String {
  case error {
    ConfigFailure(error) -> config_error_message(error)
    WorkspaceFailure(error) -> workspace_error_message(error)
    TrackerFailure(error) -> tracker_error_message(error)
    AgentFailure(error) -> agent_error_message(error)
    OrchestrationFailure(error) -> orchestration_error_message(error)
  }
}

fn workspace_hook_name(hook: WorkspaceHook) -> String {
  case hook {
    AfterCreate -> "after_create"
    BeforeRun -> "before_run"
    AfterRun -> "after_run"
    BeforeRemove -> "before_remove"
  }
}
