-module(symphony_shell_ffi).

-export([run_command/2, run_command_in_dir/3, run_command_in_dir_timeout/4]).

%% Run a command with args in the current working directory (30s timeout).
run_command(Cmd, Args) ->
    run_command_in_dir_timeout(Cmd, Args, ".", 30000).

%% Run a command with args in a specific directory (30s timeout).
run_command_in_dir(Cmd, Args, Dir) ->
    run_command_in_dir_timeout(Cmd, Args, Dir, 30000).

%% Run a command with args in a directory with a custom timeout (ms).
%% Returns {ok, Stdout} or {error, Message}.
run_command_in_dir_timeout(Cmd, Args, Dir, TimeoutMs) ->
    CmdStr = binary_to_list(iolist_to_binary(Cmd)),
    ArgStrs = [binary_to_list(iolist_to_binary(A)) || A <- Args],
    FullCmd = find_executable(CmdStr),
    case FullCmd of
        false ->
            {error, iolist_to_binary(["command not found: ", CmdStr])};
        ExecPath ->
            run_port(ExecPath, ArgStrs, Dir, TimeoutMs)
    end.

find_executable(Cmd) ->
    case os:find_executable(Cmd) of
        false -> false;
        Path -> Path
    end.

run_port(ExecPath, Args, Dir, TimeoutMs) ->
    DirStr = binary_to_list(iolist_to_binary(Dir)),
    Opts = [
        binary,
        exit_status,
        stderr_to_stdout,
        use_stdio,
        hide,
        {args, Args},
        {cd, DirStr}
    ],
    try
        Port = open_port({spawn_executable, ExecPath}, Opts),
        collect_output(Port, TimeoutMs, [])
    catch
        _:Reason ->
            {error, iolist_to_binary(io_lib:format("spawn failed: ~p", [Reason]))}
    end.

collect_output(Port, TimeoutMs, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, TimeoutMs, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, output_binary(Acc)};
        {Port, {exit_status, Status}} ->
            {error, iolist_to_binary([
                "exit status ", integer_to_binary(Status),
                ": ", output_binary(Acc)
            ])}
    after TimeoutMs ->
        catch port_close(Port),
        {error, <<"command timed out">>}
    end.

output_binary(Acc) ->
    iolist_to_binary(lists:reverse(Acc)).
