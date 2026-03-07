-module(symphony@types).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/types.gleam").
-export_type([issue/0, blocker_ref/0, orchestration_state/0, run_attempt_phase/0, workflow_definition/0, retry_entry/0, live_session/0, orchestrator_state/0]).

-type issue() :: {issue,
        binary(),
        binary(),
        binary(),
        gleam@option:option(binary()),
        binary(),
        gleam@option:option(integer()),
        gleam@option:option(binary()),
        gleam@option:option(binary()),
        list(binary()),
        list(blocker_ref()),
        gleam@option:option(integer()),
        gleam@option:option(integer())}.

-type blocker_ref() :: {blocker_ref,
        gleam@option:option(binary()),
        gleam@option:option(binary()),
        gleam@option:option(binary())}.

-type orchestration_state() :: unclaimed |
    claimed |
    running |
    retry_queued |
    released.

-type run_attempt_phase() :: preparing_workspace |
    building_prompt |
    launching_agent_process |
    initializing_session |
    streaming_turn |
    finishing |
    succeeded |
    failed |
    timed_out |
    stalled |
    canceled_by_reconciliation.

-type workflow_definition() :: {workflow_definition,
        gleam@dict:dict(binary(), gleam@dynamic:dynamic_()),
        binary()}.

-type retry_entry() :: {retry_entry,
        binary(),
        binary(),
        integer(),
        integer(),
        gleam@option:option(binary())}.

-type live_session() :: {live_session,
        binary(),
        binary(),
        binary(),
        integer(),
        integer(),
        integer()}.

-type orchestrator_state() :: {orchestrator_state,
        integer(),
        integer(),
        gleam@dict:dict(binary(), live_session()),
        gleam@set:set(binary()),
        gleam@dict:dict(binary(), retry_entry()),
        gleam@set:set(binary())}.


