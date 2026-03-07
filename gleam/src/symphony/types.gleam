import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import gleam/set.{type Set}

/// Represents a Linear issue to be processed by the orchestrator
pub type Issue {
  Issue(
    id: String,
    identifier: String,
    title: String,
    description: Option(String),
    state: String,
    priority: Option(Int),
    branch_name: Option(String),
    url: Option(String),
    labels: List(String),
    blocked_by: List(BlockerRef),
    created_at: Option(Int),
    updated_at: Option(Int),
  )
}

/// Reference to a blocking issue
pub type BlockerRef {
  BlockerRef(
    id: Option(String),
    identifier: Option(String),
    state: Option(String),
  )
}

/// State of an issue in the orchestration lifecycle
pub type OrchestrationState {
  Unclaimed
  Claimed
  Running
  RetryQueued
  Released
}

/// Phase of a run attempt for an agent
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

/// Workflow definition loaded from WORKFLOW.md
pub type WorkflowDefinition {
  WorkflowDefinition(config: Dict(String, Dynamic), prompt_template: String)
}

/// Entry in the retry queue
pub type RetryEntry {
  RetryEntry(
    issue_id: String,
    identifier: String,
    attempt: Int,
    due_at_ms: Int,
    error: Option(String),
  )
}

/// Live session tracking for running agents
pub type LiveSession {
  LiveSession(
    session_id: String,
    thread_id: String,
    turn_id: String,
    turn_count: Int,
    input_tokens: Int,
    output_tokens: Int,
  )
}

/// State of the orchestrator process
pub type OrchestratorState {
  OrchestratorState(
    poll_interval_ms: Int,
    max_concurrent_agents: Int,
    running: Dict(String, LiveSession),
    claimed: Set(String),
    retry_attempts: Dict(String, RetryEntry),
    completed: Set(String),
  )
}
