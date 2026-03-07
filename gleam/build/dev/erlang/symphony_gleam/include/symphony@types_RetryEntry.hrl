-record(retry_entry, {
    issue_id :: binary(),
    identifier :: binary(),
    attempt :: integer(),
    due_at_ms :: integer(),
    error :: gleam@option:option(binary())
}).
