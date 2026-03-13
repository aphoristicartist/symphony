import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import symphony/config.{type Config}
import symphony/errors

/// Messages for the workflow store actor.
pub type WorkflowStoreMessage {
  CheckForChanges
  GetConfig(reply_to: Subject(Result(Config, errors.ConfigError)))
  Shutdown
  SetSubject(subject: Subject(WorkflowStoreMessage))
}

/// Internal state of the workflow store actor.
pub type WorkflowStoreState {
  WorkflowStoreState(
    path: String,
    current_config: Option(Config),
    last_mtime: Option(Int),
    check_interval_ms: Int,
    own_subject: Option(Subject(WorkflowStoreMessage)),
  )
}

/// Start the workflow store actor.
/// Immediately loads config from `path`, then polls for changes every
/// `check_interval_ms` milliseconds.
pub fn start(
  path: String,
  check_interval_ms: Int,
) -> Result(Subject(WorkflowStoreMessage), errors.ConfigError) {
  let initial_state =
    WorkflowStoreState(
      path: path,
      current_config: None,
      last_mtime: None,
      check_interval_ms: check_interval_ms,
      own_subject: None,
    )

  actor.start_spec(actor.Spec(
    init: fn() {
      // Do an immediate load on startup
      let loaded_state = do_reload(initial_state)
      actor.Ready(loaded_state, process.new_selector())
    },
    init_timeout: 5000,
    loop: fn(message, state) {
      case message {
        CheckForChanges -> {
          let new_state = check_and_reload(state)
          case state.own_subject {
            Some(subject) -> schedule_check(subject, state.check_interval_ms)
            None -> Nil
          }
          actor.Continue(new_state, None)
        }
        GetConfig(reply_to) -> {
          process.send(reply_to, state.current_config |> config_or_error(state))
          actor.Continue(state, None)
        }
        Shutdown -> actor.Stop(process.Normal)
        SetSubject(subject) -> {
          let new_state =
            WorkflowStoreState(..state, own_subject: Some(subject))
          schedule_check(subject, state.check_interval_ms)
          actor.Continue(new_state, None)
        }
      }
    },
  ))
  |> result.map(fn(subject) {
    process.send(subject, SetSubject(subject))
    subject
  })
  |> result.map_error(fn(_) {
    errors.ParseError(details: "Failed to start workflow store actor")
  })
}

/// Get the current config from a running workflow store.
pub fn get_config(
  store: Subject(WorkflowStoreMessage),
) -> Result(Config, errors.ConfigError) {
  process.call(store, fn(reply_to) { GetConfig(reply_to) }, 5000)
}

/// Trigger a config reload check.
pub fn check_changes(store: Subject(WorkflowStoreMessage)) -> Nil {
  process.send(store, CheckForChanges)
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Schedule the next periodic check after check_interval_ms.
fn schedule_check(
  subject: Subject(WorkflowStoreMessage),
  interval_ms: Int,
) -> Nil {
  process.send_after(subject, interval_ms, CheckForChanges)
  Nil
}

/// Check if the file has changed; reload if so.
fn check_and_reload(state: WorkflowStoreState) -> WorkflowStoreState {
  let mtime = get_file_mtime(state.path)
  case mtime == state.last_mtime {
    True -> state
    False -> do_reload(state)
  }
}

/// Reload the config from disk.
fn do_reload(state: WorkflowStoreState) -> WorkflowStoreState {
  let mtime = get_file_mtime(state.path)
  case config.load(state.path) {
    Ok(cfg) ->
      WorkflowStoreState(..state, current_config: Some(cfg), last_mtime: mtime)
    Error(_) ->
      // Keep existing config on parse error; update mtime to avoid spam-reloading
      WorkflowStoreState(..state, last_mtime: mtime)
  }
}

/// Return the current config or an error if not yet loaded.
fn config_or_error(
  state: WorkflowStoreState,
) -> fn(Option(Config)) -> Result(Config, errors.ConfigError) {
  fn(opt) {
    case opt {
      Some(cfg) -> Ok(cfg)
      None ->
        Error(errors.MissingFile(path: state.path <> " (config not yet loaded)"))
    }
  }
}

/// Get file modification time as an integer (seconds since epoch), or None.
fn get_file_mtime(path: String) -> Option(Int) {
  case do_get_mtime(path) {
    Ok(mtime) -> Some(mtime)
    Error(_) -> None
  }
}

@external(erlang, "symphony_workflow_store_ffi", "get_file_mtime")
fn do_get_mtime(path: String) -> Result(Int, Nil)
