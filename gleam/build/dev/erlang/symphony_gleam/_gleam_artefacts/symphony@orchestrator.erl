-module(symphony@orchestrator).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/orchestrator.gleam").
-export([start/1]).
-export_type([orchestrator_message/0, worker_result/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type orchestrator_message() :: tick |
    {worker_completed, binary(), worker_result()} |
    {retry_issue, symphony@types:retry_entry()}.

-type worker_result() :: worker_succeeded |
    {worker_failed, binary()} |
    worker_timed_out.

-file("src/symphony/orchestrator.gleam", 85).
?DOC(" Reconcile running issues\n").
-spec reconcile_running_issues(
    symphony@types:orchestrator_state(),
    symphony@config:config()
) -> symphony@types:orchestrator_state().
reconcile_running_issues(State, Config) ->
    Running_list = maps:to_list(erlang:element(4, State)),
    gleam@list:fold(
        Running_list,
        State,
        fun(Acc, Entry) ->
            {Issue_id, _} = Entry,
            case symphony@linear@client:fetch_issue_state(Config, Issue_id) of
                {ok, State_name} ->
                    case gleam@list:contains(
                        erlang:element(5, erlang:element(2, Config)),
                        State_name
                    ) of
                        true ->
                            Acc;

                        false ->
                            {orchestrator_state,
                                erlang:element(2, Acc),
                                erlang:element(3, Acc),
                                gleam@dict:delete(
                                    erlang:element(4, Acc),
                                    Issue_id
                                ),
                                erlang:element(5, Acc),
                                erlang:element(6, Acc),
                                gleam@set:insert(
                                    erlang:element(7, Acc),
                                    Issue_id
                                )}
                    end;

                {error, _} ->
                    Acc
            end
        end
    ).

-file("src/symphony/orchestrator.gleam", 117).
?DOC(" Filter candidate issues\n").
-spec filter_candidates(
    list(symphony@types:issue()),
    symphony@types:orchestrator_state()
) -> list(symphony@types:issue()).
filter_candidates(Issues, State) ->
    _pipe = Issues,
    gleam@list:filter(
        _pipe,
        fun(Issue) ->
            (not gleam@set:contains(
                erlang:element(5, State),
                erlang:element(2, Issue)
            )
            andalso not gleam@dict:has_key(
                erlang:element(4, State),
                erlang:element(2, Issue)
            ))
            andalso not gleam@set:contains(
                erlang:element(7, State),
                erlang:element(2, Issue)
            )
        end
    ).

-file("src/symphony/orchestrator.gleam", 145).
?DOC(" Dispatch a single issue\n").
-spec dispatch_single_issue(
    symphony@types:issue(),
    symphony@types:orchestrator_state(),
    symphony@config:config()
) -> symphony@types:orchestrator_state().
dispatch_single_issue(Issue, State, Config) ->
    Claimed_state = {orchestrator_state,
        erlang:element(2, State),
        erlang:element(3, State),
        erlang:element(4, State),
        gleam@set:insert(erlang:element(5, State), erlang:element(2, Issue)),
        erlang:element(6, State),
        erlang:element(7, State)},
    _ = gleam@erlang@process:start(
        fun() ->
            _ = symphony@agent_runner:run_issue(Issue, Config, 1),
            nil
        end,
        false
    ),
    Claimed_state.

-file("src/symphony/orchestrator.gleam", 130).
?DOC(" Dispatch issues to workers\n").
-spec dispatch_issues(
    list(symphony@types:issue()),
    symphony@types:orchestrator_state(),
    symphony@config:config()
) -> symphony@types:orchestrator_state().
dispatch_issues(Issues, State, Config) ->
    Available_slots = erlang:element(3, State) - maps:size(
        erlang:element(4, State)
    ),
    _pipe = Issues,
    _pipe@1 = gleam@list:take(_pipe, Available_slots),
    gleam@list:fold(
        _pipe@1,
        State,
        fun(Acc, Issue) -> dispatch_single_issue(Issue, Acc, Config) end
    ).

-file("src/symphony/orchestrator.gleam", 59).
?DOC(" Handle tick message\n").
-spec handle_tick(symphony@types:orchestrator_state(), symphony@config:config()) -> gleam@otp@actor:next(orchestrator_message(), symphony@types:orchestrator_state()).
handle_tick(State, Config) ->
    Reconciled_state = reconcile_running_issues(State, Config),
    case symphony@linear@client:fetch_active_issues(Config) of
        {ok, Issues} ->
            Candidates = filter_candidates(Issues, Reconciled_state),
            New_state = dispatch_issues(Candidates, Reconciled_state, Config),
            {continue, New_state, none};

        {error, _} ->
            {continue, State, none}
    end.

-file("src/symphony/orchestrator.gleam", 174).
?DOC(" Handle worker completed message\n").
-spec handle_worker_completed(
    symphony@types:orchestrator_state(),
    binary(),
    worker_result(),
    symphony@config:config()
) -> gleam@otp@actor:next(orchestrator_message(), symphony@types:orchestrator_state()).
handle_worker_completed(State, Issue_id, Result, _) ->
    case Result of
        worker_succeeded ->
            New_state = {orchestrator_state,
                erlang:element(2, State),
                erlang:element(3, State),
                gleam@dict:delete(erlang:element(4, State), Issue_id),
                erlang:element(5, State),
                erlang:element(6, State),
                gleam@set:insert(erlang:element(7, State), Issue_id)},
            {continue, New_state, none};

        {worker_failed, _} ->
            New_state@1 = {orchestrator_state,
                erlang:element(2, State),
                erlang:element(3, State),
                gleam@dict:delete(erlang:element(4, State), Issue_id),
                erlang:element(5, State),
                erlang:element(6, State),
                erlang:element(7, State)},
            {continue, New_state@1, none};

        worker_timed_out ->
            New_state@2 = {orchestrator_state,
                erlang:element(2, State),
                erlang:element(3, State),
                gleam@dict:delete(erlang:element(4, State), Issue_id),
                erlang:element(5, State),
                erlang:element(6, State),
                erlang:element(7, State)},
            {continue, New_state@2, none}
    end.

-file("src/symphony/orchestrator.gleam", 248).
?DOC(" Get current Erlang timestamp in milliseconds\n").
-spec erlang_timestamp() -> integer().
erlang_timestamp() ->
    erlang:system_time().

-file("src/symphony/orchestrator.gleam", 220).
?DOC(" Handle retry message\n").
-spec handle_retry(
    symphony@types:orchestrator_state(),
    symphony@types:retry_entry(),
    symphony@config:config()
) -> gleam@otp@actor:next(orchestrator_message(), symphony@types:orchestrator_state()).
handle_retry(State, Retry_entry, _) ->
    case erlang_timestamp() >= erlang:element(5, Retry_entry) of
        true ->
            New_state = {orchestrator_state,
                erlang:element(2, State),
                erlang:element(3, State),
                erlang:element(4, State),
                erlang:element(5, State),
                gleam@dict:delete(
                    erlang:element(6, State),
                    erlang:element(2, Retry_entry)
                ),
                erlang:element(7, State)},
            {continue, New_state, none};

        false ->
            {continue, State, none}
    end.

-file("src/symphony/orchestrator.gleam", 29).
?DOC(" Start the orchestrator\n").
-spec start(symphony@config:config()) -> {ok,
        gleam@erlang@process:subject(orchestrator_message())} |
    {error, binary()}.
start(Config) ->
    Initial_state = {orchestrator_state,
        erlang:element(2, erlang:element(3, Config)),
        erlang:element(2, erlang:element(5, Config)),
        gleam@dict:new(),
        gleam@set:new(),
        gleam@dict:new(),
        gleam@set:new()},
    _pipe = gleam@otp@actor:start_spec(
        {spec,
            fun() -> {ready, Initial_state, gleam_erlang_ffi:new_selector()} end,
            5000,
            fun(Message, State) -> case Message of
                    tick ->
                        handle_tick(State, Config);

                    {worker_completed, Issue_id, Result} ->
                        handle_worker_completed(State, Issue_id, Result, Config);

                    {retry_issue, Retry_entry} ->
                        handle_retry(State, Retry_entry, Config)
                end end}
    ),
    gleam@result:map_error(
        _pipe,
        fun(_) -> <<"Failed to start orchestrator actor"/utf8>> end
    ).
