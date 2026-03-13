import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import gleam/set.{type Set}
import symphony/errors.{type RunError}

// ============================================================================
// Agent Abstraction Types
// ============================================================================

/// Supported coding agent backends.
pub type AgentKind {
  Codex
  ClaudeCode
  Goose
}

/// Status of a completed turn.
pub type TurnStatus {
  TurnSucceeded
  TurnFailed(reason: String)
  TurnCancelled
}

/// Result from a single agent turn.
pub type TurnResult {
  TurnResult(
    status: TurnStatus,
    token_usage: Option(TokenSnapshot),
    session_id: Option(String),
    output: Option(String),
  )
}

/// Snapshot of token usage from an agent event.
pub type TokenSnapshot {
  TokenSnapshot(input_tokens: Int, output_tokens: Int, total_tokens: Int)
}

/// Configuration for starting an agent session.
pub type AgentSessionConfig {
  AgentSessionConfig(
    command: String,
    workspace_path: String,
    issue_identifier: String,
    agent_kind: AgentKind,
    max_turns: Int,
    turn_timeout_ms: Int,
    allowed_tools: Option(String),
    permission_mode: Option(String),
    resume_session_id: Option(String),
  )
}

/// Typed process handle for each supported agent backend.
/// Each variant is created and consumed only by its own adapter.
/// The inner Dynamic field still requires a coerce inside each adapter,
/// but the tag ensures mismatches are detected rather than silently corrupted.
pub type AgentProcessHandle {
  /// Codex: carries the CodexProcess as Dynamic
  CodexProcess(inner: Dynamic)
  /// Claude Code: carries the ClaudeCodeProcess as Dynamic
  ClaudeCodeProcess(inner: Dynamic)
  /// Goose: carries the GooseSessionState as Dynamic
  GooseProcess(inner: Dynamic)
  /// No active process
  NoProcess
}

/// Handle to a running agent session.
pub type AgentSession {
  AgentSession(
    session_id: Option(String),
    agent_kind: AgentKind,
    process_handle: AgentProcessHandle,
  )
}

/// Record-of-functions adapter for coding agent backends.
pub type AgentAdapter {
  AgentAdapter(
    start_session: fn(AgentSessionConfig) ->
      Result(AgentSession, errors.AgentError),
    run_turn: fn(AgentSession, String) -> Result(TurnResult, errors.AgentError),
    stop_session: fn(AgentSession) -> Result(Nil, errors.AgentError),
  )
}

// ============================================================================
// Tracker Abstraction Types
// ============================================================================

/// Supported issue tracker backends.
pub type TrackerKind {
  Linear
  Plane
}

/// Record-of-functions adapter for issue tracker backends.
pub type TrackerAdapter {
  TrackerAdapter(
    fetch_candidate_issues: fn() -> Result(List(Issue), errors.TrackerError),
    fetch_issue_states_by_ids: fn(List(String)) ->
      Result(List(Issue), errors.TrackerError),
    create_comment: fn(String, String) -> Result(Nil, errors.TrackerError),
    update_issue_state: fn(String, String) -> Result(Nil, errors.TrackerError),
  )
}

/// Normalized issue record used by orchestration and prompt rendering.
pub type Issue {
  Issue(
    id: String,
    identifier: String,
    title: String,
    description: Option(String),
    priority: Option(Int),
    state: String,
    branch_name: Option(String),
    url: Option(String),
    labels: List(String),
    blocked_by: List(BlockerRef),
    created_at: Option(Int),
    updated_at: Option(Int),
  )
}

/// Reference to a blocking issue for dependency-aware dispatch decisions.
pub type BlockerRef {
  BlockerRef(
    id: Option(String),
    identifier: Option(String),
    state: Option(String),
  )
}

/// State of an issue in the orchestration lifecycle.
pub type OrchestrationState {
  Unclaimed
  Claimed
  Running
  RetryQueued
  Released
}

/// Phase of a single run attempt for an issue.
pub type RunAttemptPhase {
  PreparingWorkspace
  BuildingPrompt
  LaunchingAgentProcess
  InitializingSession
  StreamingTurn
  Finishing
  Succeeded
  Failed
  TimedOut
  Stalled
  CanceledByReconciliation
}

/// Filesystem workspace assigned to one issue identifier.
pub type Workspace {
  Workspace(path: String, workspace_key: String, created_now: Bool)
}

/// Result metadata for workspace cleanup attempts.
pub type WorkspaceCleanup {
  WorkspaceCleanup(path: String, workspace_key: String, removed_now: Bool)
}

/// One execution attempt for one issue.
pub type RunAttempt {
  RunAttempt(
    issue_id: String,
    issue_identifier: String,
    attempt: Option(Int),
    workspace_path: String,
    started_at: Int,
    status: RunAttemptPhase,
    error: Option(RunError),
  )
}

/// Optional workspace lifecycle hooks.
pub type ServiceHooks {
  ServiceHooks(
    after_create: Option(String),
    before_run: Option(String),
    after_run: Option(String),
    before_remove: Option(String),
    timeout_ms: Int,
  )
}

/// Typed service config view derived from workflow config.
pub type ServiceConfig {
  ServiceConfig(
    tracker_kind: String,
    tracker_endpoint: Option(String),
    tracker_api_key: String,
    tracker_project_slug: Option(String),
    tracker_active_states: List(String),
    tracker_terminal_states: List(String),
    poll_interval_ms: Int,
    workspace_root: String,
    hooks: ServiceHooks,
    max_concurrent_agents: Int,
    max_turns: Int,
    max_retry_backoff_ms: Option(Int),
    max_concurrent_agents_by_state: Dict(String, Int),
    codex_command: String,
    codex_turn_timeout_ms: Int,
    codex_read_timeout_ms: Option(Int),
    codex_stall_timeout_ms: Option(Int),
    codex_approval_policy: Option(String),
    codex_thread_sandbox: Option(String),
    codex_turn_sandbox_policy: Option(String),
  )
}

/// Workflow definition loaded from WORKFLOW.md
pub type WorkflowDefinition {
  WorkflowDefinition(config: Dict(String, Dynamic), prompt_template: String)
}

/// Runtime-specific handle for a scheduled retry timer.
pub type RetryTimerHandle {
  RetryTimerHandle(reference: String)
}

/// Entry in the retry queue.
pub type RetryEntry {
  RetryEntry(
    issue_id: String,
    identifier: String,
    attempt: Int,
    due_at_ms: Int,
    timer_handle: Option(RetryTimerHandle),
    error: Option(String),
  )
}

/// Normalized coding-agent event categories tracked for live sessions.
pub type CodexEvent {
  SessionStarted
  TurnStarted
  TurnCompleted
  ThreadCompleted
  Notification
  RateLimitUpdated
  ProcessError
  OtherCodexEvent(name: String)
}

/// Live session metadata tracked while a coding-agent subprocess is running.
pub type LiveSession {
  LiveSession(
    session_id: String,
    thread_id: String,
    turn_id: String,
    codex_app_server_pid: Option(String),
    last_codex_event: Option(CodexEvent),
    last_codex_timestamp: Option(Int),
    last_codex_message: String,
    codex_input_tokens: Int,
    codex_output_tokens: Int,
    codex_total_tokens: Int,
    last_reported_input_tokens: Int,
    last_reported_output_tokens: Int,
    last_reported_total_tokens: Int,
    turn_count: Int,
  )
}

/// Aggregate token and runtime totals across all attempts.
pub type CodexTotals {
  CodexTotals(
    input_tokens: Int,
    output_tokens: Int,
    total_tokens: Int,
    seconds_running: Float,
  )
}

/// Latest coding-agent rate-limit snapshot observed from session events.
pub type CodexRateLimits {
  CodexRateLimits(
    request_limit: Option(Int),
    request_remaining: Option(Int),
    request_reset_at_ms: Option(Int),
    token_limit: Option(Int),
    token_remaining: Option(Int),
    token_reset_at_ms: Option(Int),
  )
}

/// Active running entry keyed by issue ID inside orchestrator state.
pub type RunningEntry {
  RunningEntry(
    worker_handle: Option(String),
    monitor_handle: Option(String),
    issue_identifier: String,
    issue: Issue,
    session: Option(LiveSession),
    retry_attempt: Option(Int),
    started_at: Int,
  )
}

/// Result from a worker process.
pub type WorkerResult {
  WorkerSucceeded
  WorkerFailed(error: errors.RunError)
  WorkerTimedOut
}

/// Orchestrator message types.
pub type OrchestratorMessage {
  Tick
  WorkerCompleted(issue_id: String, result: WorkerResult)
  RetryIssue(retry_entry: RetryEntry)
  CleanupTerminalWorkspaces
  SetOwnSubject(subject: Subject(OrchestratorMessage))
}

/// Single authoritative runtime state for the orchestrator.
pub type OrchestratorState {
  OrchestratorState(
    poll_interval_ms: Int,
    max_concurrent_agents: Int,
    running: Dict(String, RunningEntry),
    claimed: Set(String),
    retry_attempts: Dict(String, RetryEntry),
    completed: Set(String),
    codex_totals: CodexTotals,
    codex_rate_limits: Option(CodexRateLimits),
    tracker_adapter: Option(TrackerAdapter),
    agent_adapter: Option(AgentAdapter),
    agent_kind: Option(AgentKind),
    last_cleanup_at: Option(Int),
    tick_count: Int,
    own_subject: Option(Subject(OrchestratorMessage)),
  )
}
