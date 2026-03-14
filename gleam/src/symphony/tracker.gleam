import symphony/config.{type Config}
import symphony/errors
import symphony/gitbug/adapter as gitbug_adapter
import symphony/linear/adapter as linear_adapter
import symphony/local/adapter as local_adapter
import symphony/plane/adapter as plane_adapter
import symphony/taskwarrior/adapter as taskwarrior_adapter
import symphony/types

/// Build a TrackerAdapter from the given config, dispatching on the TrackerConfig variant.
pub fn build_tracker_adapter(
  config: Config,
) -> Result(types.TrackerAdapter, errors.RunError) {
  case config.tracker {
    config.LinearConfig(..) -> Ok(linear_adapter.build(config))
    config.PlaneConfig(..) -> Ok(plane_adapter.build(config))
    config.LocalConfig(..) as local_cfg -> Ok(local_adapter.build(local_cfg))
    config.TaskwarriorConfig(..) as tw_cfg ->
      Ok(taskwarrior_adapter.build(tw_cfg))
    config.GitBugConfig(..) as gb_cfg -> Ok(gitbug_adapter.build(gb_cfg))
  }
}
