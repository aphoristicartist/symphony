-record(config, {
    tracker :: symphony@config:tracker_config(),
    polling :: symphony@config:polling_config(),
    workspace :: symphony@config:workspace_config(),
    agent :: symphony@config:agent_config(),
    codex :: symphony@config:codex_config(),
    prompt_template :: binary()
}).
