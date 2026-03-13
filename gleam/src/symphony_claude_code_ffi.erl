-module(symphony_claude_code_ffi).
-export([start_claude/2, read_line/1, stop_process/1]).

start_claude(Args, Cwd) ->
    Command = case os:find_executable("claude") of
        false -> "claude";
        Path -> Path
    end,
    BinArgs = [unicode:characters_to_list(A) || A <- Args],
    BinCwd = unicode:characters_to_list(Cwd),
    try
        Port = open_port({spawn_executable, Command},
            [{args, BinArgs}, {cd, BinCwd}, binary, {line, 102400},
             use_stdio, stderr_to_stdout, exit_status]),
        {ok, Port}
    catch
        _:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

read_line(Port) ->
    receive
        {Port, {data, {eol, Line}}} ->
            {ok, Line};
        {Port, {data, {noeol, _Partial}}} ->
            read_line(Port);
        {Port, {exit_status, Code}} ->
            {error, unicode:characters_to_binary(
                io_lib:format("process exited with status ~p", [Code]))}
    after 30000 ->
        {error, <<"read timeout">>}
    end.

stop_process(Port) ->
    catch port_close(Port),
    nil.
