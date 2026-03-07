-module(symphony).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony.gleam").
-export([main/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-file("src/symphony.gleam", 56).
?DOC(" Get environment variable\n").
-spec get_env(binary()) -> {ok, binary()} | {error, nil}.
get_env(Name) ->
    os:getenv(Name).

-file("src/symphony.gleam", 48).
?DOC(" Get configuration path from environment\n").
-spec get_config_path() -> {ok, binary()} | {error, binary()}.
get_config_path() ->
    case get_env(<<"WORKFLOW_PATH"/utf8>>) of
        {ok, Path} ->
            {ok, Path};

        {error, _} ->
            {error, <<"WORKFLOW_PATH environment variable not set"/utf8>>}
    end.

-file("src/symphony.gleam", 8).
?DOC(" Main entry point for the Symphony orchestrator\n").
-spec main() -> nil.
main() ->
    gleam@io:println(<<"Symphony Orchestrator starting..."/utf8>>),
    case get_config_path() of
        {ok, Config_path} ->
            gleam@io:println(
                <<"Loading configuration from: "/utf8, Config_path/binary>>
            ),
            case symphony@config:load(Config_path) of
                {ok, Config} ->
                    gleam@io:println(
                        <<"Configuration loaded successfully"/utf8>>
                    ),
                    case symphony@orchestrator:start(Config) of
                        {ok, _} ->
                            gleam@io:println(
                                <<"Orchestrator started successfully"/utf8>>
                            ),
                            gleam_erlang_ffi:sleep_forever();

                        {error, E} ->
                            gleam@io:println(
                                <<"Failed to start orchestrator: "/utf8,
                                    E/binary>>
                            ),
                            gleam_erlang_ffi:sleep(1000)
                    end;

                {error, E@1} ->
                    gleam@io:println(
                        <<"Failed to load configuration: "/utf8, E@1/binary>>
                    ),
                    gleam_erlang_ffi:sleep(1000)
            end;

        {error, E@2} ->
            gleam@io:println(<<"Configuration error: "/utf8, E@2/binary>>),
            gleam_erlang_ffi:sleep(1000)
    end.
