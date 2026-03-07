-record(codex_process, {
    pid :: gleam@erlang@process:pid_(),
    stdin :: gleam@erlang@process:subject(binary()),
    stdout :: gleam@erlang@process:subject(binary())
}).
