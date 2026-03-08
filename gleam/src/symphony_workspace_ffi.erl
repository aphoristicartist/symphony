-module(symphony_workspace_ffi).

-export([run_command/3]).

run_command(Command, WorkspacePath, TimeoutMs) ->
    case filelib:is_dir(WorkspacePath) of
        false ->
            {error, {<<"spawn">>, <<"workspace directory does not exist">>}};
        true ->
            start_and_collect(Command, WorkspacePath, TimeoutMs)
    end.

start_and_collect(_Command, _WorkspacePath, TimeoutMs) when TimeoutMs =< 0 ->
    {error, {<<"timeout">>, <<"hook timeout must be positive">>}};
start_and_collect(Command, WorkspacePath, TimeoutMs) ->
    try
        Port = open_port(
            {spawn_executable, "/bin/sh"},
            [
                binary,
                exit_status,
                stderr_to_stdout,
                use_stdio,
                hide,
                {cd, WorkspacePath},
                {args, ["-lc", Command]}
            ]
        ),
        collect_output(Port, TimeoutMs, [])
    catch
        _:Reason ->
            {error, {<<"spawn">>, reason_binary(Reason)}}
    end.

collect_output(Port, TimeoutMs, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, TimeoutMs, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {ok, {Status, output_binary(Acc)}}
    after TimeoutMs ->
        catch port_close(Port),
        {error, {<<"timeout">>, output_binary(Acc)}}
    end.

output_binary(Acc) ->
    iolist_to_binary(lists:reverse(Acc)).

reason_binary(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
