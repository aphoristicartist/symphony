-record(live_session, {
    session_id :: binary(),
    thread_id :: binary(),
    turn_id :: binary(),
    turn_count :: integer(),
    input_tokens :: integer(),
    output_tokens :: integer()
}).
