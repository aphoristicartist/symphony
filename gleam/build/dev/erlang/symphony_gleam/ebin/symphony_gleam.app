{application, symphony_gleam, [
    {vsn, "0.1.0"},
    {applications, [filepath,
                    gleam_erlang,
                    gleam_http,
                    gleam_httpc,
                    gleam_json,
                    gleam_otp,
                    gleam_stdlib,
                    gleam_yaml,
                    gleeunit,
                    logging,
                    simplifile]},
    {description, "Gleam implementation of the Symphony orchestrator for coding agents"},
    {modules, [symphony_gleam_test]},
    {registered, []}
]}.
