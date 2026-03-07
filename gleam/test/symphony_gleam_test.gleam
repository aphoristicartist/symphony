import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import symphony/errors
import symphony/template
import symphony/types
import symphony/validation
import symphony/workspace

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Workspace Tests
// ============================================================================

pub fn workspace_key_sanitizes_special_chars_test() {
  workspace.workspace_key("TEST-123_abc")
  |> should.equal("TEST-123_abc")
}

pub fn workspace_key_replaces_unsafe_chars_test() {
  workspace.workspace_key("test issue #123!")
  |> should.equal("test_issue__123_")
}

pub fn workspace_key_preserves_alphanumeric_test() {
  workspace.workspace_key("ABC123def456")
  |> should.equal("ABC123def456")
}

pub fn workspace_key_preserves_underscores_test() {
  workspace.workspace_key("test_issue_name")
  |> should.equal("test_issue_name")
}

pub fn workspace_key_preserves_dashes_test() {
  workspace.workspace_key("test-issue-name")
  |> should.equal("test-issue-name")
}

pub fn workspace_key_preserves_dots_test() {
  workspace.workspace_key("v1.2.3")
  |> should.equal("v1.2.3")
}

// ============================================================================
// Validation Tests
// ============================================================================

pub fn validation_sanitize_workspace_key_test() {
  validation.sanitize_workspace_key("test issue #123!")
  |> should.equal("test_issue__123_")
}

pub fn validation_issue_identifier_test() {
  validation.is_valid_issue_identifier("ABC-123")
  |> should.equal(True)

  validation.is_valid_issue_identifier("bad identifier")
  |> should.equal(False)
}

pub fn validation_normalize_state_test() {
  validation.normalize_state("  In Progress  ")
  |> should.equal("in progress")
}

pub fn validation_compose_session_id_test() {
  validation.compose_session_id("thread-1", "turn-2")
  |> should.equal(Ok("thread-1-turn-2"))
}

pub fn config_error_missing_file_message_test() {
  errors.config_error_message(errors.MissingFile(path: "/tmp/WORKFLOW.md"))
  |> should.equal("Configuration file not found: /tmp/WORKFLOW.md")
}

pub fn config_error_validation_message_test() {
  errors.config_error_message(
    errors.ValidationFailed(
      error: errors.MissingRequiredField(field: "tracker.api_key"),
    ),
  )
  |> should.equal(
    "Configuration validation failed: Missing required field: tracker.api_key",
  )
}

pub fn tracker_error_api_message_test() {
  errors.tracker_error_message(
    errors.ApiError(
      operation: "fetch_active_issues",
      details: "HTTP request failed",
      status_code: Some(500),
    ),
  )
  |> should.equal(
    "Tracker API error in fetch_active_issues (status 500): HTTP request failed",
  )
}

pub fn tracker_error_not_found_message_test() {
  errors.tracker_error_message(
    errors.NotFound(
      resource: "issue",
      identifier: Some("ISSUE-123"),
      details: "State payload missing",
    ),
  )
  |> should.equal(
    "Tracker resource not found: issue (ISSUE-123) - State payload missing",
  )
}

// ============================================================================
// Template Tests
// ============================================================================

pub fn template_renders_issue_identifier_test() {
  let issue = types.Issue(
    id: "123",
    identifier: "TEST-1",
    title: "Test Issue",
    description: None,
    state: "Todo",
    priority: Some(1),
    branch_name: None,
    url: None,
    labels: [],
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )

  let context = template.context_from_issue(issue, 1)

  template.render("Issue: {{ issue.identifier }}", context)
  |> should.equal(Ok("Issue: TEST-1"))
}

pub fn template_renders_issue_title_test() {
  let issue = types.Issue(
    id: "123",
    identifier: "TEST-1",
    title: "Test Issue",
    description: None,
    state: "Todo",
    priority: Some(1),
    branch_name: None,
    url: None,
    labels: [],
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )

  let context = template.context_from_issue(issue, 1)

  template.render("Title: {{ issue.title }}", context)
  |> should.equal(Ok("Title: Test Issue"))
}

pub fn template_renders_attempt_test() {
  let issue = types.Issue(
    id: "123",
    identifier: "TEST-1",
    title: "Test Issue",
    description: None,
    state: "Todo",
    priority: Some(1),
    branch_name: None,
    url: None,
    labels: [],
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )

  let context = template.context_from_issue(issue, 3)

  template.render("Attempt: {{ attempt }}", context)
  |> should.equal(Ok("Attempt: 3"))
}

pub fn template_renders_multiple_variables_test() {
  let issue = types.Issue(
    id: "123",
    identifier: "TEST-1",
    title: "Test Issue",
    description: None,
    state: "Todo",
    priority: Some(1),
    branch_name: None,
    url: None,
    labels: [],
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )

  let context = template.context_from_issue(issue, 2)

  template.render(
    "{{ issue.identifier }}: {{ issue.title }} (attempt {{ attempt }})",
    context,
  )
  |> should.equal(Ok("TEST-1: Test Issue (attempt 2)"))
}

pub fn template_handles_unknown_variable_test() {
  let issue = types.Issue(
    id: "123",
    identifier: "TEST-1",
    title: "Test Issue",
    description: None,
    state: "Todo",
    priority: Some(1),
    branch_name: None,
    url: None,
    labels: [],
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )

  let context = template.context_from_issue(issue, 1)

  template.render("Unknown: {{ unknown_var }}", context)
  |> should.equal(Ok("Unknown: {{ UNDEFINED: unknown_var }}"))
}

// ============================================================================
// State Transition Tests
// ============================================================================

pub fn orchestration_state_unclaimed_exists_test() {
  let _ = types.Unclaimed
  should.equal(1, 1)
}

pub fn orchestration_state_claimed_exists_test() {
  let _ = types.Claimed
  should.equal(1, 1)
}

pub fn orchestration_state_running_exists_test() {
  let _ = types.Running
  should.equal(1, 1)
}

pub fn orchestration_state_retry_queued_exists_test() {
  let _ = types.RetryQueued
  should.equal(1, 1)
}

pub fn orchestration_state_released_exists_test() {
  let _ = types.Released
  should.equal(1, 1)
}

pub fn run_attempt_phase_succeeded_exists_test() {
  let _ = types.Succeeded
  should.equal(1, 1)
}

pub fn run_attempt_phase_failed_exists_test() {
  let _ = types.Failed
  should.equal(1, 1)
}

pub fn run_attempt_phase_timed_out_exists_test() {
  let _ = types.TimedOut
  should.equal(1, 1)
}

// ============================================================================
// Issue Type Tests
// ============================================================================

pub fn issue_can_be_created_with_all_fields_test() {
  let issue = types.Issue(
    id: "123",
    identifier: "TEST-1",
    title: "Test Issue",
    description: Some("Description"),
    state: "Todo",
    priority: Some(1),
    branch_name: Some("feature/test"),
    url: Some("https://example.com"),
    labels: ["bug", "urgent"],
    blocked_by: [],
    created_at: Some(1234567890),
    updated_at: Some(1234567900),
  )

  issue.identifier
  |> should.equal("TEST-1")
}

pub fn issue_can_be_created_with_minimal_fields_test() {
  let issue = types.Issue(
    id: "123",
    identifier: "TEST-1",
    title: "Test Issue",
    description: None,
    state: "Todo",
    priority: None,
    branch_name: None,
    url: None,
    labels: [],
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )

  issue.identifier
  |> should.equal("TEST-1")
}
