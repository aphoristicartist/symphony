-record(tracker_config, {
    kind :: binary(),
    api_key :: binary(),
    project_slug :: binary(),
    active_states :: list(binary()),
    terminal_states :: list(binary())
}).
