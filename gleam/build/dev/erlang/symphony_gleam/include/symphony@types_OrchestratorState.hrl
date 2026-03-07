-record(orchestrator_state, {
    poll_interval_ms :: integer(),
    max_concurrent_agents :: integer(),
    running :: gleam@dict:dict(binary(), symphony@types:live_session()),
    claimed :: gleam@set:set(binary()),
    retry_attempts :: gleam@dict:dict(binary(), symphony@types:retry_entry()),
    completed :: gleam@set:set(binary())
}).
