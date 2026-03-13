import symphony/config.{type Config}
import symphony/errors
import symphony/linear/adapter as linear_adapter
import symphony/plane/adapter as plane_adapter
import symphony/types
import symphony/validation

/// Build a TrackerAdapter from the given config, dispatching on tracker.kind.
pub fn build_tracker_adapter(
  config: Config,
) -> Result(types.TrackerAdapter, errors.RunError) {
  case validation.parse_tracker_kind(config.tracker.kind) {
    Ok(kind) -> Ok(build_adapter_for_kind(kind))
    Error(e) -> Error(errors.ConfigFailure(errors.ValidationFailed(error: e)))
  }
}

/// Construct an adapter for the given tracker kind.
fn build_adapter_for_kind(kind: types.TrackerKind) -> types.TrackerAdapter {
  case kind {
    types.Linear -> linear_adapter.build()
    types.Plane -> plane_adapter.build()
  }
}
