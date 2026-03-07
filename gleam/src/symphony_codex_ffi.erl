-module(symphony_codex_ffi).

-export([start_codex/2, send_to_process/2, read_event/1, stop_codex/1]).

-define(TIMEOUT, 5000).

start_codex(Command, Cwd) ->
    case filelib:is_dir(Cwd) of
        false ->
            {error, "Working directory does not exist: " ++ Cwd};
        true ->
            PortOpts = [
                {cd, Cwd},
                {line, 100000},
                exit_status,
                use_stdio,
                stderr_to_stdout
            ],
            Port = open_port({spawn, Command}, PortOpts),
            {ok, #{port => Port}}
    end.

send_to_process(#{port := Port}, Data) ->
    true = port_command(Port, Data ++ "\n"),
    {ok, nil}.

read_event(#{port := Port}) ->
    receive
        {Port, {data, {eol, Line}}} ->
            {ok, unicode:characters_to_binary(Line, utf8)};
        {Port, {exit_status, Status}} ->
            {error, "Process exited with status: " ++ integer_to_list(Status)}
    after ?TIMEOUT ->
        {error, "Read timeout"}
    end.

stop_codex(#{port := Port}) ->
    port_close(Port),
    nil.
