-record(issue, {
    id :: binary(),
    identifier :: binary(),
    title :: binary(),
    description :: gleam@option:option(binary()),
    state :: binary(),
    priority :: gleam@option:option(integer()),
    branch_name :: gleam@option:option(binary()),
    url :: gleam@option:option(binary()),
    labels :: list(binary()),
    blocked_by :: list(symphony@types:blocker_ref()),
    created_at :: gleam@option:option(integer()),
    updated_at :: gleam@option:option(integer())
}).
