import symphony/claude_code/adapter as claude_code_adapter
import symphony/codex/adapter as codex_adapter
import symphony/config.{type Config}
import symphony/errors
import symphony/goose/adapter as goose_adapter
import symphony/types
import symphony/validation

/// Build an AgentAdapter from the configured agent kind.
///
/// Dispatches on `config.agent.kind` to select the appropriate backend.
pub fn build_agent_adapter(
  config: Config,
) -> Result(types.AgentAdapter, errors.RunError) {
  case validation.parse_agent_kind(config.agent.kind) {
    Ok(types.Codex) -> Ok(codex_adapter.build())
    Ok(types.ClaudeCode) -> Ok(claude_code_adapter.build())
    Ok(types.Goose) -> Ok(goose_adapter.build())
    Error(validation_err) ->
      Error(
        errors.ConfigFailure(errors.ValidationFailed(error: validation_err)),
      )
  }
}
