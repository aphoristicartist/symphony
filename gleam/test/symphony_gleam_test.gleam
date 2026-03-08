import gleam/dict
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import symphony/codex/app_server
import symphony/config
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

pub fn workspace_run_hook_success_test() {
  let hook_dir = "/tmp/symphony_gleam_hook_success"
  let assert Ok(_) = simplifile.create_directory_all(hook_dir)

  workspace.run_hook("printf ok", hook_dir, 2000, errors.BeforeRun)
  |> should.equal(Ok(Nil))
}

pub fn workspace_run_hook_non_zero_exit_test() {
  let hook_dir = "/tmp/symphony_gleam_hook_fail"
  let assert Ok(_) = simplifile.create_directory_all(hook_dir)

  let assert Error(errors.HookFailed(
    hook: errors.BeforeRun,
    workspace_path: workspace_path,
    details: details,
    exit_code: Some(exit_code),
  )) =
    workspace.run_hook("echo boom && exit 7", hook_dir, 2000, errors.BeforeRun)

  workspace_path
  |> should.equal(hook_dir)

  exit_code
  |> should.equal(7)

  string.contains(details, "boom")
  |> should.equal(True)
}

pub fn workspace_run_hook_timeout_test() {
  let hook_dir = "/tmp/symphony_gleam_hook_timeout"
  let assert Ok(_) = simplifile.create_directory_all(hook_dir)

  let assert Error(errors.HookTimedOut(
    hook: errors.AfterRun,
    workspace_path: workspace_path,
    timeout_ms: timeout_ms,
    details: _details,
  )) = workspace.run_hook("while :; do :; done", hook_dir, 20, errors.AfterRun)

  workspace_path
  |> should.equal(hook_dir)

  timeout_ms
  |> should.equal(20)
}

pub fn workspace_remove_workspace_metadata_test() {
  let root = "/tmp/symphony_gleam_remove_root"
  let key = "TEST_REMOVE_OK"
  let path = root <> "/" <> key

  let assert Ok(_) = simplifile.create_directory_all(path)

  let assert Ok(cleanup) = workspace.remove_workspace(root, key, None, 1000)

  cleanup.path
  |> should.equal(path)

  cleanup.workspace_key
  |> should.equal(key)

  cleanup.removed_now
  |> should.equal(True)
}

pub fn workspace_remove_workspace_cleanup_failure_test() {
  let assert Error(errors.CleanupFailed(
    path: path,
    workspace_key: workspace_key,
    details: _details,
  )) = workspace.remove_workspace("/dev/null", "blocked", None, 1000)

  path
  |> should.equal("/dev/null/blocked")

  workspace_key
  |> should.equal("blocked")
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
    errors.ValidationFailed(error: errors.MissingRequiredField(
      field: "tracker.api_key",
    )),
  )
  |> should.equal(
    "Configuration validation failed: Missing required field: tracker.api_key",
  )
}

pub fn tracker_error_api_message_test() {
  errors.tracker_error_message(errors.ApiError(
    operation: "fetch_active_issues",
    details: "HTTP request failed",
    status_code: Some(500),
  ))
  |> should.equal(
    "Tracker API error in fetch_active_issues (status 500): HTTP request failed",
  )
}

pub fn tracker_error_not_found_message_test() {
  errors.tracker_error_message(errors.NotFound(
    resource: "issue",
    identifier: Some("ISSUE-123"),
    details: "State payload missing",
  ))
  |> should.equal(
    "Tracker resource not found: issue (ISSUE-123) - State payload missing",
  )
}

pub fn workspace_error_hook_message_test() {
  errors.workspace_error_message(errors.HookFailed(
    hook: errors.BeforeRun,
    workspace_path: "/tmp/workspace",
    details: "script exited non-zero",
    exit_code: Some(2),
  ))
  |> should.equal(
    "Workspace hook before_run failed in /tmp/workspace (exit: 2): script exited non-zero",
  )
}

pub fn workspace_error_timeout_message_test() {
  errors.workspace_error_message(errors.HookTimedOut(
    hook: errors.AfterRun,
    workspace_path: "/tmp/workspace",
    timeout_ms: 50,
    details: "no command output",
  ))
  |> should.equal(
    "Workspace hook after_run timed out in /tmp/workspace after 50ms: no command output",
  )
}

pub fn run_error_agent_message_test() {
  errors.run_error_message(
    errors.AgentFailure(errors.ProtocolError(
      event: Some("start_turn"),
      details: "invalid JSON-RPC payload",
    )),
  )
  |> should.equal(
    "Agent protocol error at start_turn: invalid JSON-RPC payload",
  )
}

// ============================================================================
// Codex Protocol and Accounting Tests
// ============================================================================

pub fn codex_decode_turn_complete_event_test() {
  let payload =
    "{\"method\":\"turn/completed\",\"params\":{\"turn_id\":\"turn-1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"total_tokens\":14}},\"rate_limits\":{\"request_limit\":100,\"request_remaining\":90,\"token_limit\":1000,\"token_remaining\":850}}"

  let assert app_server.TurnComplete(
    turn_id: turn_id,
    usage: usage,
    rate_limits: Some(rate_limits),
  ) = app_server.decode_event_line(payload)

  turn_id
  |> should.equal("turn-1")

  usage.total_tokens
  |> should.equal(14)

  rate_limits.request_remaining
  |> should.equal(Some(90))
}

pub fn codex_decode_token_usage_nested_event_test() {
  let payload =
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"tokenUsage\":{\"total\":{\"inputTokens\":21,\"outputTokens\":9,\"totalTokens\":30}}}}"

  let assert app_server.TokenUsageUpdated(usage: usage, rate_limits: None) =
    app_server.decode_event_line(payload)

  usage.input_tokens
  |> should.equal(21)

  usage.output_tokens
  |> should.equal(9)

  usage.total_tokens
  |> should.equal(30)
}

pub fn codex_decode_unknown_event_test() {
  app_server.decode_event_line("{\"method\":\"mystery/event\"}")
  |> should.equal(app_server.UnknownEvent(method: "mystery/event"))
}

pub fn codex_decode_malformed_event_test() {
  app_server.decode_event_line("{\"params\":{\"turn_id\":\"x\"}}")
  |> should.equal(app_server.MalformedEvent(
    details: "event missing method field",
  ))
}

pub fn codex_accounting_applies_deterministic_deltas_test() {
  let state0 = empty_orchestrator_state()
  let baseline = app_server.zero_token_snapshot()

  let first_event =
    app_server.TurnComplete(
      turn_id: "turn-1",
      usage: app_server.TokenSnapshot(
        input_tokens: 10,
        output_tokens: 4,
        total_tokens: 14,
      ),
      rate_limits: None,
    )

  let #(state1, snapshot1) =
    app_server.apply_event_accounting(state0, baseline, first_event)

  state1.codex_totals.total_tokens
  |> should.equal(14)

  snapshot1.total_tokens
  |> should.equal(14)

  let rate_limits =
    types.CodexRateLimits(
      request_limit: Some(100),
      request_remaining: Some(80),
      request_reset_at_ms: None,
      token_limit: Some(1000),
      token_remaining: Some(700),
      token_reset_at_ms: None,
    )

  let second_event =
    app_server.TokenUsageUpdated(
      usage: app_server.TokenSnapshot(
        input_tokens: 12,
        output_tokens: 6,
        total_tokens: 18,
      ),
      rate_limits: Some(rate_limits),
    )

  let #(state2, snapshot2) =
    app_server.apply_event_accounting(state1, snapshot1, second_event)

  state2.codex_totals.input_tokens
  |> should.equal(12)

  state2.codex_totals.output_tokens
  |> should.equal(6)

  state2.codex_totals.total_tokens
  |> should.equal(18)

  state2.codex_rate_limits
  |> should.equal(Some(rate_limits))

  let stale_event =
    app_server.TokenUsageUpdated(
      usage: app_server.TokenSnapshot(
        input_tokens: 11,
        output_tokens: 5,
        total_tokens: 16,
      ),
      rate_limits: None,
    )

  let #(state3, snapshot3) =
    app_server.apply_event_accounting(state2, snapshot2, stale_event)

  state3.codex_totals.input_tokens
  |> should.equal(12)

  state3.codex_totals.output_tokens
  |> should.equal(6)

  state3.codex_totals.total_tokens
  |> should.equal(18)

  snapshot3.total_tokens
  |> should.equal(18)
}

fn empty_orchestrator_state() -> types.OrchestratorState {
  types.OrchestratorState(
    poll_interval_ms: 1000,
    max_concurrent_agents: 1,
    running: dict.new(),
    claimed: set.new(),
    retry_attempts: dict.new(),
    completed: set.new(),
    codex_totals: types.CodexTotals(
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      seconds_running: 0.0,
    ),
    codex_rate_limits: None,
  )
}

// ============================================================================
// Config Loading Tests
// ============================================================================

pub fn config_load_valid_nested_yaml_test() {
  let path = "/tmp/symphony_gleam_workflow_valid.md"
  let content =
    "---\n"
    <> "tracker:\n"
    <> "  kind: linear\n"
    <> "  api_key: test-key\n"
    <> "  project_slug: CORE\n"
    <> "polling:\n"
    <> "  interval_ms: 1500\n"
    <> "workspace:\n"
    <> "  root: /tmp/symphony_ws\n"
    <> "agent:\n"
    <> "  max_concurrent_agents: 3\n"
    <> "  max_turns: 9\n"
    <> "codex:\n"
    <> "  command: codex app-server\n"
    <> "  turn_timeout_ms: 120000\n"
    <> "prompt_template: Please implement {{ issue.identifier }}\n"
    <> "---\n"
    <> "Prompt body is ignored by current loader\n"

  let assert Ok(Nil) = simplifile.write(to: path, contents: content)
  let assert Ok(cfg) = config.load(path)

  cfg.tracker.kind
  |> should.equal("linear")

  cfg.tracker.project_slug
  |> should.equal("CORE")

  cfg.workspace.root
  |> should.equal("/tmp/symphony_ws")

  cfg.hooks.timeout_ms
  |> should.equal(60_000)
}

pub fn config_load_nested_without_section_errors_test() {
  let path = "/tmp/symphony_gleam_workflow_bad_nested.md"
  let content =
    "---\n" <> "  kind: linear\n" <> "prompt_template: hi\n" <> "---\n"

  let assert Ok(Nil) = simplifile.write(to: path, contents: content)

  config.load(path)
  |> should.equal(
    Error(errors.ParseError(
      details: "Nested YAML value without a parent section",
    )),
  )
}

pub fn config_load_missing_tracker_api_key_test() {
  let path = "/tmp/symphony_gleam_workflow_missing_key.md"
  let content =
    "---\n"
    <> "tracker:\n"
    <> "  kind: linear\n"
    <> "  project_slug: CORE\n"
    <> "polling:\n"
    <> "  interval_ms: 1000\n"
    <> "workspace:\n"
    <> "  root: /tmp/symphony_ws\n"
    <> "agent:\n"
    <> "  max_concurrent_agents: 1\n"
    <> "  max_turns: 2\n"
    <> "codex:\n"
    <> "  command: codex app-server\n"
    <> "  turn_timeout_ms: 10000\n"
    <> "prompt_template: hi\n"
    <> "---\n"

  let assert Ok(Nil) = simplifile.write(to: path, contents: content)

  config.load(path)
  |> should.equal(
    Error(
      errors.ValidationFailed(error: errors.MissingRequiredField(
        field: "tracker.api_key",
      )),
    ),
  )
}

pub fn config_load_hooks_config_test() {
  let path = "/tmp/symphony_gleam_workflow_hooks.md"
  let content =
    "---\n"
    <> "tracker:\n"
    <> "  kind: linear\n"
    <> "  api_key: test-key\n"
    <> "  project_slug: CORE\n"
    <> "polling:\n"
    <> "  interval_ms: 1000\n"
    <> "workspace:\n"
    <> "  root: /tmp/symphony_ws\n"
    <> "hooks:\n"
    <> "  before_run: echo before\n"
    <> "  after_run: echo after\n"
    <> "  timeout_ms: 2500\n"
    <> "agent:\n"
    <> "  max_concurrent_agents: 1\n"
    <> "  max_turns: 2\n"
    <> "codex:\n"
    <> "  command: codex app-server\n"
    <> "  turn_timeout_ms: 10000\n"
    <> "prompt_template: hi\n"
    <> "---\n"

  let assert Ok(Nil) = simplifile.write(to: path, contents: content)
  let assert Ok(cfg) = config.load(path)

  cfg.hooks.before_run
  |> should.equal(Some("echo before"))

  cfg.hooks.after_run
  |> should.equal(Some("echo after"))

  cfg.hooks.timeout_ms
  |> should.equal(2500)
}

// ============================================================================
// Template Tests
// ============================================================================

pub fn template_renders_issue_identifier_test() {
  let issue =
    types.Issue(
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
  let issue =
    types.Issue(
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
  let issue =
    types.Issue(
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
  let issue =
    types.Issue(
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
  let issue =
    types.Issue(
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
  let issue =
    types.Issue(
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
      created_at: Some(1_234_567_890),
      updated_at: Some(1_234_567_900),
    )

  issue.identifier
  |> should.equal("TEST-1")
}

pub fn issue_can_be_created_with_minimal_fields_test() {
  let issue =
    types.Issue(
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
