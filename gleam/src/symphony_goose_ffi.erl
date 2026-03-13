-module(symphony_goose_ffi).
-export([run_goose/5]).

run_goose(Command, Args, Cwd, Env, TimeoutMs) ->
    Cmd = case os:find_executable(binary_to_list(Command)) of
        false -> binary_to_list(Command);
        Path -> Path
    end,
    EnvList = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Env],
    try
        Port = open_port({spawn_executable, Cmd},
            [{args, [binary_to_list(A) || A <- Args]},
             {cd, binary_to_list(Cwd)},
             {env, EnvList},
             binary, use_stdio, stderr_to_stdout, exit_status]),
        collect_output(Port, <<>>, TimeoutMs)
    catch
        _:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

collect_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>, TimeoutMs);
        {Port, {exit_status, Code}} ->
            {ok, {Code, Acc, <<>>}}
    after TimeoutMs ->
        catch port_close(Port),
        {error, <<"goose process timed out">>}
    end.
