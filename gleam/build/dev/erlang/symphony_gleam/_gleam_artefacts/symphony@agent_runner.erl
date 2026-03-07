-module(symphony@agent_runner).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/agent_runner.gleam").
-export([current_phase/0, run_issue/3]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-file("src/symphony/agent_runner.gleam", 51).
?DOC(" Ensure workspace exists for an issue\n").
-spec ensure_issue_workspace(symphony@types:issue(), symphony@config:config()) -> {ok,
        binary()} |
    {error, nil}.
ensure_issue_workspace(Issue, Config) ->
    Key = symphony@workspace:workspace_key(erlang:element(3, Issue)),
    symphony@workspace:ensure_workspace(
        erlang:element(2, erlang:element(4, Config)),
        Key
    ).

-file("src/symphony/agent_runner.gleam", 57).
?DOC(" Run before_run hook\n").
-spec run_before_hook(symphony@config:config(), binary()) -> {ok, nil} |
    {error, binary()}.
run_before_hook(Config, Workspace_path) ->
    {ok, nil}.

-file("src/symphony/agent_runner.gleam", 64).
?DOC(" Run after_run hook\n").
-spec run_after_hook(symphony@config:config(), binary()) -> {ok, nil} |
    {error, binary()}.
run_after_hook(Config, Workspace_path) ->
    {ok, nil}.

-file("src/symphony/agent_runner.gleam", 71).
?DOC(" Build prompt from template\n").
-spec build_prompt(symphony@types:issue(), symphony@config:config(), integer()) -> {ok,
        binary()} |
    {error, binary()}.
build_prompt(Issue, Config, Attempt) ->
    Context = symphony@template:context_from_issue(Issue, Attempt),
    symphony@template:render(erlang:element(7, Config), Context).

-file("src/symphony/agent_runner.gleam", 77).
?DOC(" Start Codex thread\n").
-spec start_codex_thread(symphony@config:config(), binary()) -> {ok,
        symphony@codex@app_server:codex_process()} |
    {error, binary()}.
start_codex_thread(Config, Workspace_path) ->
    symphony@codex@app_server:start_thread(
        erlang:element(2, erlang:element(6, Config)),
        Workspace_path
    ).

-file("src/symphony/agent_runner.gleam", 158).
?DOC(" Check if issue is still in an active state\n").
-spec check_issue_state(symphony@types:issue(), symphony@config:config()) -> {ok,
        boolean()} |
    {error, binary()}.
check_issue_state(Issue, Config) ->
    {ok,
        gleam@list:contains(
            erlang:element(5, erlang:element(2, Config)),
            erlang:element(6, Issue)
        )}.

-file("src/symphony/agent_runner.gleam", 165).
?DOC(" Get the current phase\n").
-spec current_phase() -> symphony@types:run_attempt_phase().
current_phase() ->
    initializing_session.

-file("src/symphony/agent_runner.gleam", 106).
?DOC(" Stream events for a single turn\n").
-spec stream_turn_events(
    symphony@codex@app_server:codex_process(),
    symphony@config:config(),
    symphony@types:issue(),
    integer()
) -> {ok, symphony@types:run_attempt_phase()} | {error, binary()}.
stream_turn_events(Codex_process, Config, Issue, Turn_count) ->
    Result = gleam@erlang@process:new_subject(),
    symphony@codex@app_server:stream_events(
        Codex_process,
        fun(Event) -> case Event of
                {turn_complete, _, _, _} ->
                    case check_issue_state(Issue, Config) of
                        {ok, true} ->
                            _ = gleam@erlang@process:send(
                                Result,
                                {ok, streaming_turn}
                            );

                        {ok, false} ->
                            _ = gleam@erlang@process:send(
                                Result,
                                {ok, succeeded}
                            );

                        {error, E} ->
                            _ = gleam@erlang@process:send(Result, {error, E})
                    end;

                {thread_complete, _} ->
                    _ = gleam@erlang@process:send(Result, {ok, succeeded});

                {process_error, Message} ->
                    _ = gleam@erlang@process:send(Result, {error, Message});

                _ ->
                    nil
            end end
    ),
    case gleam@erlang@process:'receive'(
        Result,
        erlang:element(3, erlang:element(6, Config))
    ) of
        {ok, Phase_result} ->
            case Phase_result of
                {ok, streaming_turn} ->
                    run_turns(
                        Codex_process,
                        <<""/utf8>>,
                        Config,
                        Issue,
                        Turn_count + 1
                    );

                _ ->
                    Phase_result
            end;

        {error, _} ->
            {ok, timed_out}
    end.

-file("src/symphony/agent_runner.gleam", 82).
?DOC(" Run turns until completion or max turns\n").
-spec run_turns(
    symphony@codex@app_server:codex_process(),
    binary(),
    symphony@config:config(),
    symphony@types:issue(),
    integer()
) -> {ok, symphony@types:run_attempt_phase()} | {error, binary()}.
run_turns(Codex_process, Prompt, Config, Issue, Turn_count) ->
    case Turn_count >= erlang:element(3, erlang:element(5, Config)) of
        true ->
            {ok, timed_out};

        false ->
            gleam@result:'try'(
                begin
                    _pipe = symphony@codex@app_server:start_turn(
                        Codex_process,
                        Prompt
                    ),
                    gleam@result:map_error(
                        _pipe,
                        fun(E) ->
                            <<"Failed to start turn: "/utf8, E/binary>>
                        end
                    )
                end,
                fun(_) ->
                    stream_turn_events(Codex_process, Config, Issue, Turn_count)
                end
            )
    end.

-file("src/symphony/agent_runner.gleam", 13).
?DOC(" Run an issue through the agent\n").
-spec run_issue(symphony@types:issue(), symphony@config:config(), integer()) -> {ok,
        symphony@types:run_attempt_phase()} |
    {error, binary()}.
run_issue(Issue, Config, Attempt) ->
    gleam@result:'try'(
        begin
            _pipe = ensure_issue_workspace(Issue, Config),
            gleam@result:map_error(
                _pipe,
                fun(_) -> <<"Failed to create workspace"/utf8>> end
            )
        end,
        fun(Workspace_path) ->
            gleam@result:'try'(
                begin
                    _pipe@1 = run_before_hook(Config, Workspace_path),
                    gleam@result:map_error(
                        _pipe@1,
                        fun(E) ->
                            <<"before_run hook failed: "/utf8, E/binary>>
                        end
                    )
                end,
                fun(_) ->
                    gleam@result:'try'(
                        begin
                            _pipe@2 = build_prompt(Issue, Config, Attempt),
                            gleam@result:map_error(
                                _pipe@2,
                                fun(E@1) ->
                                    <<"Failed to build prompt: "/utf8,
                                        E@1/binary>>
                                end
                            )
                        end,
                        fun(Prompt) ->
                            gleam@result:'try'(
                                begin
                                    _pipe@3 = start_codex_thread(
                                        Config,
                                        Workspace_path
                                    ),
                                    gleam@result:map_error(
                                        _pipe@3,
                                        fun(E@2) ->
                                            <<"Failed to start Codex: "/utf8,
                                                E@2/binary>>
                                        end
                                    )
                                end,
                                fun(Codex_process) ->
                                    Result = run_turns(
                                        Codex_process,
                                        Prompt,
                                        Config,
                                        Issue,
                                        0
                                    ),
                                    _ = run_after_hook(Config, Workspace_path),
                                    symphony@codex@app_server:stop_thread(
                                        Codex_process
                                    ),
                                    Result
                                end
                            )
                        end
                    )
                end
            )
        end
    ).
