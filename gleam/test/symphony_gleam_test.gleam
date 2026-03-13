import gleam/dict
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit
import gleeunit/should
import simplifile
import symphony/agent_runner
import symphony/claude_code/event_parser
import symphony/codex/app_server
import symphony/codex/dynamic_tool
import symphony/config
import symphony/errors
import symphony/persistence
import symphony/plane/normalizer
import symphony/plane/types as plane_types
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
    tracker_adapter: None,
    agent_adapter: None,
    agent_kind: None,
    last_cleanup_at: None,
    tick_count: 0,
    own_subject: None,
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

  let assert config.LinearConfig(project_slug: project_slug, ..) = cfg.tracker

  project_slug
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

// ============================================================================
// Error Types Tests (Plan 1.1)
// ============================================================================

pub fn error_tracker_write_error_message_test() {
  errors.tracker_error_message(errors.WriteError(
    operation: "create_comment",
    resource_id: "ISSUE-42",
    details: "permission denied",
  ))
  |> should.equal(
    "Tracker write error in create_comment for ISSUE-42: permission denied",
  )
}

pub fn error_stall_detected_message_test() {
  errors.agent_error_message(errors.StallDetected(
    issue_id: "issue-123",
    last_event_ms: Some(5000),
    stall_timeout_ms: 300_000,
    details: "no events received",
  ))
  |> should.equal(
    "Agent stall detected for issue issue-123 (last event: 5000ms ago, timeout: 300000ms): no events received",
  )
}

pub fn error_persistence_write_failed_test() {
  errors.persistence_error_message(errors.WriteFailed(
    path: "/tmp/symphony_state.json",
    details: "disk full",
  ))
  |> should.equal("State write failed for /tmp/symphony_state.json: disk full")
}

pub fn error_run_error_persistence_failure_test() {
  errors.run_error_message(
    errors.PersistenceFailure(errors.ReadFailed(
      path: "/data/state.json",
      details: "file not found",
    )),
  )
  |> should.equal("State read failed for /data/state.json: file not found")
}

// ============================================================================
// Validation New Kinds Tests (Plan 1.4)
// ============================================================================

pub fn validation_tracker_kind_linear_test() {
  validation.parse_tracker_kind("linear")
  |> should.equal(Ok(types.Linear))
}

pub fn validation_tracker_kind_plane_test() {
  validation.parse_tracker_kind("plane")
  |> should.equal(Ok(types.Plane))
}

pub fn validation_tracker_kind_unknown_test() {
  validation.parse_tracker_kind("jira")
  |> should.be_error()
}

pub fn validation_agent_kind_codex_test() {
  validation.parse_agent_kind("codex")
  |> should.equal(Ok(types.Codex))
}

pub fn validation_agent_kind_claude_code_test() {
  validation.parse_agent_kind("claude-code")
  |> should.equal(Ok(types.ClaudeCode))
}

pub fn validation_agent_kind_goose_test() {
  validation.parse_agent_kind("goose")
  |> should.equal(Ok(types.Goose))
}

pub fn validation_agent_kind_unknown_test() {
  validation.parse_agent_kind("cursor")
  |> should.be_error()
}

// ============================================================================
// Config New Fields Tests (Plan 1.2)
// ============================================================================

pub fn config_load_with_agent_kind_test() {
  let path = "/tmp/symphony_gleam_workflow_agent_kind.md"
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
    <> "agent:\n"
    <> "  kind: claude-code\n"
    <> "  max_concurrent_agents: 2\n"
    <> "  max_turns: 5\n"
    <> "  allowed_tools: Read,Edit,Bash\n"
    <> "  permission_mode: bypassPermissions\n"
    <> "codex:\n"
    <> "  command: codex app-server\n"
    <> "  turn_timeout_ms: 60000\n"
    <> "prompt_template: Work on {{ issue.identifier }}\n"
    <> "---\n"

  let assert Ok(Nil) = simplifile.write(to: path, contents: content)
  let assert Ok(cfg) = config.load(path)

  cfg.agent.kind
  |> should.equal("claude-code")

  cfg.agent.allowed_tools
  |> should.equal(Some("Read,Edit,Bash"))

  cfg.agent.permission_mode
  |> should.equal(Some("bypassPermissions"))
}

pub fn config_load_plane_tracker_fields_test() {
  let path = "/tmp/symphony_gleam_workflow_plane.md"
  let content =
    "---\n"
    <> "tracker:\n"
    <> "  kind: plane\n"
    <> "  api_key: plane-key\n"
    <> "  endpoint: http://localhost:8080\n"
    <> "  workspace_slug: my-workspace\n"
    <> "  project_id: abc-123\n"
    <> "  project_slug: PROJ\n"
    <> "polling:\n"
    <> "  interval_ms: 5000\n"
    <> "workspace:\n"
    <> "  root: /tmp/symphony_ws\n"
    <> "agent:\n"
    <> "  kind: codex\n"
    <> "  max_concurrent_agents: 1\n"
    <> "  max_turns: 3\n"
    <> "codex:\n"
    <> "  command: codex app-server\n"
    <> "  turn_timeout_ms: 30000\n"
    <> "prompt_template: Fix {{ issue.identifier }}\n"
    <> "---\n"

  let assert Ok(Nil) = simplifile.write(to: path, contents: content)
  let assert Ok(cfg) = config.load(path)

  let assert config.PlaneConfig(
    endpoint: endpoint,
    workspace_slug: workspace_slug,
    project_id: project_id,
    ..,
  ) = cfg.tracker

  endpoint
  |> should.equal("http://localhost:8080")

  workspace_slug
  |> should.equal("my-workspace")

  project_id
  |> should.equal("abc-123")
}

// ============================================================================
// Plane Normalizer Tests (Plan 3.2)
// ============================================================================

pub fn plane_normalizer_build_identifier_test() {
  normalizer.build_identifier("PROJ", 42)
  |> should.equal("PROJ-42")
}

pub fn plane_normalizer_priority_urgent_test() {
  normalizer.normalize_priority(Some("urgent"))
  |> should.equal(Some(1))
}

pub fn plane_normalizer_priority_high_test() {
  normalizer.normalize_priority(Some("high"))
  |> should.equal(Some(2))
}

pub fn plane_normalizer_priority_none_test() {
  normalizer.normalize_priority(None)
  |> should.equal(Some(0))
}

pub fn plane_normalizer_normalize_issue_test() {
  let item =
    plane_types.PlaneWorkItem(
      id: "uuid-1",
      sequence_id: 7,
      project_identifier: "FEAT",
      name: "My feature",
      description_html: Some("<p>desc</p>"),
      priority: Some("high"),
      state_detail: plane_types.PlaneStateDetail(
        id: "state-uuid",
        name: "In Progress",
        group: "started",
      ),
      created_at: "2024-01-01T00:00:00Z",
      updated_at: "2024-01-02T00:00:00Z",
      label_details: [plane_types.PlaneLabel(id: "l1", name: "backend")],
    )

  let issue = normalizer.normalize_issue(item)

  issue.identifier
  |> should.equal("FEAT-7")

  issue.state
  |> should.equal("In Progress")

  issue.priority
  |> should.equal(Some(2))

  issue.labels
  |> should.equal(["backend"])
}

// ============================================================================
// Claude Code Event Parser Tests (Plan 2.3)
// ============================================================================

pub fn claude_code_parse_init_event_test() {
  let payload = "{\"type\":\"init\",\"session_id\":\"sess-abc-123\"}"

  let assert event_parser.InitEvent(session_id: sid) =
    event_parser.parse_event(payload)

  sid
  |> should.equal("sess-abc-123")
}

pub fn claude_code_parse_text_delta_test() {
  let payload = "{\"type\":\"text\",\"content\":\"Hello!\"}"

  let assert event_parser.TextDelta(content: content) =
    event_parser.parse_event(payload)

  content
  |> should.equal("Hello!")
}

pub fn claude_code_parse_usage_event_test() {
  let payload = "{\"type\":\"usage\",\"input_tokens\":150,\"output_tokens\":42}"

  let assert event_parser.UsageEvent(input_tokens: input, output_tokens: output) =
    event_parser.parse_event(payload)

  input
  |> should.equal(150)

  output
  |> should.equal(42)
}

pub fn claude_code_parse_result_event_test() {
  let payload =
    "{\"type\":\"result\",\"output\":\"Done!\",\"session_id\":\"sess-xyz\"}"

  let assert event_parser.ResultEvent(output: output, session_id: sid) =
    event_parser.parse_event(payload)

  output
  |> should.equal("Done!")

  sid
  |> should.equal("sess-xyz")
}

pub fn claude_code_is_terminal_result_event_test() {
  event_parser.is_terminal_event(event_parser.ResultEvent(
    output: "done",
    session_id: "s",
  ))
  |> should.equal(True)
}

pub fn claude_code_is_not_terminal_text_delta_test() {
  event_parser.is_terminal_event(event_parser.TextDelta(content: "hi"))
  |> should.equal(False)
}

pub fn claude_code_token_usage_from_usage_event_test() {
  event_parser.token_usage(event_parser.UsageEvent(
    input_tokens: 10,
    output_tokens: 5,
  ))
  |> should.equal(Some(#(10, 5)))
}

pub fn claude_code_session_id_empty_string_is_none_test() {
  event_parser.session_id(event_parser.InitEvent(session_id: ""))
  |> should.equal(None)
}

// ============================================================================
// Dynamic Tool Tests (Plan 1.4)
// ============================================================================

pub fn dynamic_tool_unsupported_tool_test() {
  let tool_call =
    dynamic_tool.ToolCall(name: "unknown_tool", arguments: dict.new())

  let cfg = make_test_config()
  let result = dynamic_tool.execute(tool_call, cfg)

  result.success
  |> should.equal(False)

  string.contains(result.output, "Unsupported")
  |> should.equal(True)
}

// ============================================================================
// Persistence Tests (Plan 1.7)
// ============================================================================

pub fn persistence_encode_decode_roundtrip_test() {
  let state = make_state_with_data()
  let json_str = persistence.encode_state(state)

  let assert Ok(restored) = persistence.decode_state(json_str)

  restored.tick_count
  |> should.equal(42)

  set.contains(restored.completed, "issue-1")
  |> should.equal(True)

  restored.codex_totals.input_tokens
  |> should.equal(100)
}

pub fn persistence_decode_empty_json_uses_defaults_test() {
  let assert Ok(state) = persistence.decode_state("{}")

  state.tick_count
  |> should.equal(0)

  set.is_empty(state.completed)
  |> should.equal(True)
}

pub fn persistence_decode_invalid_json_returns_error_test() {
  persistence.decode_state("not json")
  |> should.be_error()
}

pub fn persistence_save_and_load_roundtrip_test() {
  let dir = "/tmp/symphony_gleam_persistence_test"
  let assert Ok(_) = simplifile.create_directory_all(dir)

  let state = make_state_with_data()
  let assert Ok(Nil) = persistence.save_snapshot(state, dir)

  let assert Ok(loaded) = persistence.load_snapshot(dir)

  loaded.tick_count
  |> should.equal(42)

  set.contains(loaded.completed, "issue-1")
  |> should.equal(True)
}

pub fn persistence_load_missing_file_returns_empty_state_test() {
  let dir = "/tmp/symphony_gleam_persistence_never_written"

  let assert Ok(state) = persistence.load_snapshot(dir)

  state.tick_count
  |> should.equal(0)
}

// ============================================================================
// Types: New Fields Tests
// ============================================================================

pub fn types_agent_kind_variants_test() {
  types.Codex
  |> should.equal(types.Codex)

  types.ClaudeCode
  |> should.equal(types.ClaudeCode)

  types.Goose
  |> should.equal(types.Goose)
}

pub fn types_turn_result_with_usage_test() {
  let result =
    types.TurnResult(
      status: types.TurnSucceeded,
      token_usage: Some(types.TokenSnapshot(
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15,
      )),
      session_id: Some("sess-1"),
      output: Some("task complete"),
    )

  result.status
  |> should.equal(types.TurnSucceeded)

  result.session_id
  |> should.equal(Some("sess-1"))
}

pub fn types_orchestrator_state_new_fields_test() {
  let state = empty_orchestrator_state()

  state.tick_count
  |> should.equal(0)

  state.tracker_adapter
  |> should.equal(None)

  state.last_cleanup_at
  |> should.equal(None)
}

// ============================================================================
// Additional Test Helpers
// ============================================================================

fn make_test_config() -> config.Config {
  config.Config(
    tracker: config.LinearConfig(
      api_key: "test-key",
      project_slug: "TEST",
      active_states: ["Todo", "In Progress"],
      terminal_states: ["Done"],
    ),
    polling: config.PollingConfig(interval_ms: 5000),
    workspace: config.WorkspaceConfig(root: "/tmp/test"),
    hooks: config.HooksConfig(
      after_create: None,
      before_run: None,
      after_run: None,
      before_remove: None,
      timeout_ms: 5000,
    ),
    agent: config.AgentConfig(
      kind: "codex",
      command: None,
      max_concurrent_agents: 1,
      max_turns: 5,
      allowed_tools: None,
      permission_mode: None,
      provider: None,
      model: None,
      builtins: None,
    ),
    codex: config.CodexConfig(
      command: "codex app-server",
      turn_timeout_ms: 60_000,
    ),
    prompt_template: "Work on {{ issue.identifier }}",
  )
}

fn make_state_with_data() -> types.OrchestratorState {
  types.OrchestratorState(
    poll_interval_ms: 5000,
    max_concurrent_agents: 2,
    running: dict.new(),
    claimed: set.new(),
    retry_attempts: dict.new(),
    completed: set.from_list(["issue-1", "issue-2"]),
    codex_totals: types.CodexTotals(
      input_tokens: 100,
      output_tokens: 50,
      total_tokens: 150,
      seconds_running: 10.0,
    ),
    codex_rate_limits: None,
    tracker_adapter: None,
    agent_adapter: None,
    agent_kind: Some(types.Codex),
    last_cleanup_at: None,
    tick_count: 42,
    own_subject: None,
  )
}

// ============================================================================
// Integration Tests — mock tracker + mock agent
// ============================================================================

fn make_test_issue() -> types.Issue {
  types.Issue(
    id: "test-issue-1",
    identifier: "TEST-1",
    title: "Integration test issue",
    description: None,
    state: "In Progress",
    priority: None,
    branch_name: None,
    url: None,
    labels: [],
    blocked_by: [],
    created_at: None,
    updated_at: None,
  )
}

/// Mock agent adapter that immediately succeeds with one turn
fn mock_agent_adapter_succeed() -> types.AgentAdapter {
  types.AgentAdapter(
    start_session: fn(_cfg) {
      Ok(types.AgentSession(
        session_id: Some("mock-session"),
        agent_kind: types.Codex,
        process_handle: types.NoProcess,
      ))
    },
    run_turn: fn(_session, _prompt) {
      Ok(types.TurnResult(
        status: types.TurnSucceeded,
        token_usage: None,
        session_id: Some("mock-session"),
        output: Some("Task completed"),
      ))
    },
    stop_session: fn(_session) { Ok(Nil) },
  )
}

/// Mock agent adapter that fails on run_turn
fn mock_agent_adapter_fail() -> types.AgentAdapter {
  types.AgentAdapter(
    start_session: fn(_cfg) {
      Ok(types.AgentSession(
        session_id: Some("mock-fail-session"),
        agent_kind: types.Codex,
        process_handle: types.NoProcess,
      ))
    },
    run_turn: fn(_session, _prompt) {
      Error(errors.ProtocolError(
        event: Some("run_turn"),
        details: "Mock failure",
      ))
    },
    stop_session: fn(_session) { Ok(Nil) },
  )
}

/// Agent runner integration test: mock agent that succeeds one turn.
/// After TurnSucceeded the runner re-fetches issue state; since the tracker
/// returns an empty list (issue not found), it conservatively stays active and
/// increments the turn counter until max_turns is hit.
pub fn agent_runner_mock_succeed_one_turn_test() {
  let issue = make_test_issue()
  // max_turns = 1 so the runner exits after the first successful turn
  let config =
    config.Config(
      ..make_test_config(),
      agent: config.AgentConfig(
        kind: "codex",
        command: None,
        max_concurrent_agents: 1,
        max_turns: 1,
        allowed_tools: None,
        permission_mode: None,
        provider: None,
        model: None,
        builtins: None,
      ),
    )

  let result =
    agent_runner.run_issue(issue, config, 1, mock_agent_adapter_succeed())

  // With max_turns = 1 and a single TurnSucceeded, the runner hits TimedOut
  // (one successful turn exhausts the budget of 1).
  case result {
    Ok(_) -> should.equal(True, True)
    Error(_) -> should.fail()
  }
}

/// Agent runner integration test: mock agent that fails on run_turn returns Failed.
pub fn agent_runner_mock_fail_turn_test() {
  let issue = make_test_issue()
  let config = make_test_config()

  let result =
    agent_runner.run_issue(issue, config, 1, mock_agent_adapter_fail())

  result
  |> should.be_error()
}

/// Agent runner integration test: TurnCancelled immediately returns CanceledByReconciliation.
pub fn agent_runner_mock_cancel_turn_test() {
  let issue = make_test_issue()
  let config = make_test_config()

  let cancelled_adapter =
    types.AgentAdapter(
      start_session: fn(_cfg) {
        Ok(types.AgentSession(
          session_id: None,
          agent_kind: types.Codex,
          process_handle: types.NoProcess,
        ))
      },
      run_turn: fn(_session, _prompt) {
        Ok(types.TurnResult(
          status: types.TurnCancelled,
          token_usage: None,
          session_id: None,
          output: None,
        ))
      },
      stop_session: fn(_session) { Ok(Nil) },
    )

  let assert Ok(phase) =
    agent_runner.run_issue(issue, config, 1, cancelled_adapter)

  phase
  |> should.equal(types.CanceledByReconciliation)
}

/// TrackerConfig union: verify LinearConfig variant is created and matched correctly.
pub fn tracker_config_linear_variant_test() {
  let tracker =
    config.LinearConfig(
      api_key: "key",
      project_slug: "PROJ",
      active_states: ["Todo"],
      terminal_states: ["Done"],
    )

  let config.LinearConfig(api_key: api_key, ..) = tracker

  api_key
  |> should.equal("key")
}

/// TrackerConfig union: verify PlaneConfig variant is created and matched correctly.
pub fn tracker_config_plane_variant_test() {
  let tracker =
    config.PlaneConfig(
      api_key: "plane-key",
      endpoint: "https://plane.example.com",
      workspace_slug: "my-ws",
      project_id: "proj-uuid",
      active_states: ["In Progress"],
      terminal_states: ["Done"],
    )

  let config.PlaneConfig(endpoint: ep, ..) = tracker

  ep
  |> should.equal("https://plane.example.com")
}

/// Validation: is_active_state works with LinearConfig union.
pub fn validation_is_active_state_linear_config_test() {
  let config = make_test_config()

  validation.is_active_state("In Progress", config)
  |> should.equal(True)

  validation.is_active_state("Done", config)
  |> should.equal(False)
}

/// Validation: is_terminal_state works with LinearConfig union.
pub fn validation_is_terminal_state_linear_config_test() {
  let config = make_test_config()

  validation.is_terminal_state("Done", config)
  |> should.equal(True)

  validation.is_terminal_state("In Progress", config)
  |> should.equal(False)
}
