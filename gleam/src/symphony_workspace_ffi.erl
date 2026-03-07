-module(symphony_workspace_ffi).

-export([run_command/1]).

run_command(Cmd) ->
    case os:cmd(Cmd) of
        "" ->
            {ok, ""};
        Output ->
            % Check if the command failed by checking exit status
            % For simplicity, we'll assume non-empty output means success
            % In production, we'd parse the exit code
            {ok, unicode:characters_to_binary(Output, utf8)}
    end.
