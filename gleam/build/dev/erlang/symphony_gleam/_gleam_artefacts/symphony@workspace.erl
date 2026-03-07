-module(symphony@workspace).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/workspace.gleam").
-export([workspace_key/1, ensure_workspace/2, run_hook/3, remove_workspace/2, workspace_exists/2]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-file("src/symphony/workspace.gleam", 24).
?DOC(" Check if a character is safe for workspace key\n").
-spec is_safe_char(binary()) -> boolean().
is_safe_char(Grapheme) ->
    Safe_chars = [<<"a"/utf8>>,
        <<"b"/utf8>>,
        <<"c"/utf8>>,
        <<"d"/utf8>>,
        <<"e"/utf8>>,
        <<"f"/utf8>>,
        <<"g"/utf8>>,
        <<"h"/utf8>>,
        <<"i"/utf8>>,
        <<"j"/utf8>>,
        <<"k"/utf8>>,
        <<"l"/utf8>>,
        <<"m"/utf8>>,
        <<"n"/utf8>>,
        <<"o"/utf8>>,
        <<"p"/utf8>>,
        <<"q"/utf8>>,
        <<"r"/utf8>>,
        <<"s"/utf8>>,
        <<"t"/utf8>>,
        <<"u"/utf8>>,
        <<"v"/utf8>>,
        <<"w"/utf8>>,
        <<"x"/utf8>>,
        <<"y"/utf8>>,
        <<"z"/utf8>>,
        <<"A"/utf8>>,
        <<"B"/utf8>>,
        <<"C"/utf8>>,
        <<"D"/utf8>>,
        <<"E"/utf8>>,
        <<"F"/utf8>>,
        <<"G"/utf8>>,
        <<"H"/utf8>>,
        <<"I"/utf8>>,
        <<"J"/utf8>>,
        <<"K"/utf8>>,
        <<"L"/utf8>>,
        <<"M"/utf8>>,
        <<"N"/utf8>>,
        <<"O"/utf8>>,
        <<"P"/utf8>>,
        <<"Q"/utf8>>,
        <<"R"/utf8>>,
        <<"S"/utf8>>,
        <<"T"/utf8>>,
        <<"U"/utf8>>,
        <<"V"/utf8>>,
        <<"W"/utf8>>,
        <<"X"/utf8>>,
        <<"Y"/utf8>>,
        <<"Z"/utf8>>,
        <<"0"/utf8>>,
        <<"1"/utf8>>,
        <<"2"/utf8>>,
        <<"3"/utf8>>,
        <<"4"/utf8>>,
        <<"5"/utf8>>,
        <<"6"/utf8>>,
        <<"7"/utf8>>,
        <<"8"/utf8>>,
        <<"9"/utf8>>,
        <<"."/utf8>>,
        <<"_"/utf8>>,
        <<"-"/utf8>>],
    gleam@list:contains(Safe_chars, Grapheme).

-file("src/symphony/workspace.gleam", 16).
?DOC(" Sanitize a single character for workspace key\n").
-spec sanitize_char(binary()) -> binary().
sanitize_char(Grapheme) ->
    case is_safe_char(Grapheme) of
        true ->
            Grapheme;

        false ->
            <<"_"/utf8>>
    end.

-file("src/symphony/workspace.gleam", 8).
?DOC(
    " Generate a workspace key from an issue identifier\n"
    " Sanitizes to [A-Za-z0-9._-]\n"
).
-spec workspace_key(binary()) -> binary().
workspace_key(Identifier) ->
    _pipe = Identifier,
    _pipe@1 = gleam@string:to_graphemes(_pipe),
    _pipe@2 = gleam@list:map(_pipe@1, fun sanitize_char/1),
    gleam@string:concat(_pipe@2).

-file("src/symphony/workspace.gleam", 37).
?DOC(
    " Ensure a workspace directory exists\n"
    " Returns the full path to the workspace\n"
).
-spec ensure_workspace(binary(), binary()) -> {ok, binary()} | {error, nil}.
ensure_workspace(Root, Key) ->
    Path = <<<<Root/binary, "/"/utf8>>/binary, Key/binary>>,
    case simplifile:create_directory_all(Path) of
        {ok, _} ->
            {ok, Path};

        {error, _} ->
            {error, nil}
    end.

-file("src/symphony/workspace.gleam", 68).
?DOC(" Run a command with timeout using Erlang FFI\n").
-spec run_command(binary(), integer()) -> {ok, binary()} | {error, binary()}.
run_command(Cmd, Timeout_ms) ->
    symphony_workspace_ffi:run_command(Cmd).

-file("src/symphony/workspace.gleam", 47).
?DOC(" Run a hook script in the specified directory\n").
-spec run_hook(binary(), binary(), integer()) -> {ok, nil} | {error, binary()}.
run_hook(Script, Cwd, Timeout_ms) ->
    case Script =:= <<""/utf8>> of
        true ->
            {ok, nil};

        false ->
            Cmd = <<<<<<<<"cd "/utf8, Cwd/binary>>/binary, " && "/utf8>>/binary,
                    Script/binary>>/binary,
                " 2>&1"/utf8>>,
            Result = run_command(Cmd, Timeout_ms),
            case Result of
                {ok, _} ->
                    {ok, nil};

                {error, E} ->
                    {error, E}
            end
    end.

-file("src/symphony/workspace.gleam", 78).
?DOC(" Remove a workspace directory\n").
-spec remove_workspace(binary(), binary()) -> {ok, nil} | {error, nil}.
remove_workspace(Root, Key) ->
    Path = <<<<Root/binary, "/"/utf8>>/binary, Key/binary>>,
    case simplifile:delete(Path) of
        {ok, _} ->
            {ok, nil};

        {error, _} ->
            {error, nil}
    end.

-file("src/symphony/workspace.gleam", 88).
?DOC(" Check if a workspace exists\n").
-spec workspace_exists(binary(), binary()) -> boolean().
workspace_exists(Root, Key) ->
    Path = <<<<Root/binary, "/"/utf8>>/binary, Key/binary>>,
    case simplifile:verify_is_directory(Path) of
        {ok, true} ->
            true;

        _ ->
            false
    end.
