-module(symphony_gleam_test).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "test/symphony_gleam_test.gleam").
-export([main/0, workspace_key_sanitizes_special_chars_test/0, workspace_key_replaces_unsafe_chars_test/0, workspace_key_preserves_alphanumeric_test/0, workspace_key_preserves_underscores_test/0, workspace_key_preserves_dashes_test/0, workspace_key_preserves_dots_test/0, template_renders_issue_identifier_test/0, template_renders_issue_title_test/0, template_renders_attempt_test/0, template_renders_multiple_variables_test/0, template_handles_unknown_variable_test/0, orchestration_state_unclaimed_exists_test/0, orchestration_state_claimed_exists_test/0, orchestration_state_running_exists_test/0, orchestration_state_retry_queued_exists_test/0, orchestration_state_released_exists_test/0, run_attempt_phase_succeeded_exists_test/0, run_attempt_phase_failed_exists_test/0, run_attempt_phase_timed_out_exists_test/0, issue_can_be_created_with_all_fields_test/0, issue_can_be_created_with_minimal_fields_test/0]).

-file("test/symphony_gleam_test.gleam", 8).
-spec main() -> nil.
main() ->
    gleeunit:main().

-file("test/symphony_gleam_test.gleam", 16).
-spec workspace_key_sanitizes_special_chars_test() -> nil.
workspace_key_sanitizes_special_chars_test() ->
    _pipe = symphony@workspace:workspace_key(<<"TEST-123_abc"/utf8>>),
    gleeunit_ffi:should_equal(_pipe, <<"TEST-123_abc"/utf8>>).

-file("test/symphony_gleam_test.gleam", 21).
-spec workspace_key_replaces_unsafe_chars_test() -> nil.
workspace_key_replaces_unsafe_chars_test() ->
    _pipe = symphony@workspace:workspace_key(<<"test issue #123!"/utf8>>),
    gleeunit_ffi:should_equal(_pipe, <<"test_issue__123_"/utf8>>).

-file("test/symphony_gleam_test.gleam", 26).
-spec workspace_key_preserves_alphanumeric_test() -> nil.
workspace_key_preserves_alphanumeric_test() ->
    _pipe = symphony@workspace:workspace_key(<<"ABC123def456"/utf8>>),
    gleeunit_ffi:should_equal(_pipe, <<"ABC123def456"/utf8>>).

-file("test/symphony_gleam_test.gleam", 31).
-spec workspace_key_preserves_underscores_test() -> nil.
workspace_key_preserves_underscores_test() ->
    _pipe = symphony@workspace:workspace_key(<<"test_issue_name"/utf8>>),
    gleeunit_ffi:should_equal(_pipe, <<"test_issue_name"/utf8>>).

-file("test/symphony_gleam_test.gleam", 36).
-spec workspace_key_preserves_dashes_test() -> nil.
workspace_key_preserves_dashes_test() ->
    _pipe = symphony@workspace:workspace_key(<<"test-issue-name"/utf8>>),
    gleeunit_ffi:should_equal(_pipe, <<"test-issue-name"/utf8>>).

-file("test/symphony_gleam_test.gleam", 41).
-spec workspace_key_preserves_dots_test() -> nil.
workspace_key_preserves_dots_test() ->
    _pipe = symphony@workspace:workspace_key(<<"v1.2.3"/utf8>>),
    gleeunit_ffi:should_equal(_pipe, <<"v1.2.3"/utf8>>).

-file("test/symphony_gleam_test.gleam", 50).
-spec template_renders_issue_identifier_test() -> nil.
template_renders_issue_identifier_test() ->
    Issue = {issue,
        <<"123"/utf8>>,
        <<"TEST-1"/utf8>>,
        <<"Test Issue"/utf8>>,
        none,
        <<"Todo"/utf8>>,
        {some, 1},
        none,
        none,
        [],
        [],
        none,
        none},
    Context = symphony@template:context_from_issue(Issue, 1),
    _pipe = symphony@template:render(
        <<"Issue: {{ issue.identifier }}"/utf8>>,
        Context
    ),
    gleeunit_ffi:should_equal(_pipe, {ok, <<"Issue: TEST-1"/utf8>>}).

-file("test/symphony_gleam_test.gleam", 72).
-spec template_renders_issue_title_test() -> nil.
template_renders_issue_title_test() ->
    Issue = {issue,
        <<"123"/utf8>>,
        <<"TEST-1"/utf8>>,
        <<"Test Issue"/utf8>>,
        none,
        <<"Todo"/utf8>>,
        {some, 1},
        none,
        none,
        [],
        [],
        none,
        none},
    Context = symphony@template:context_from_issue(Issue, 1),
    _pipe = symphony@template:render(
        <<"Title: {{ issue.title }}"/utf8>>,
        Context
    ),
    gleeunit_ffi:should_equal(_pipe, {ok, <<"Title: Test Issue"/utf8>>}).

-file("test/symphony_gleam_test.gleam", 94).
-spec template_renders_attempt_test() -> nil.
template_renders_attempt_test() ->
    Issue = {issue,
        <<"123"/utf8>>,
        <<"TEST-1"/utf8>>,
        <<"Test Issue"/utf8>>,
        none,
        <<"Todo"/utf8>>,
        {some, 1},
        none,
        none,
        [],
        [],
        none,
        none},
    Context = symphony@template:context_from_issue(Issue, 3),
    _pipe = symphony@template:render(<<"Attempt: {{ attempt }}"/utf8>>, Context),
    gleeunit_ffi:should_equal(_pipe, {ok, <<"Attempt: 3"/utf8>>}).

-file("test/symphony_gleam_test.gleam", 116).
-spec template_renders_multiple_variables_test() -> nil.
template_renders_multiple_variables_test() ->
    Issue = {issue,
        <<"123"/utf8>>,
        <<"TEST-1"/utf8>>,
        <<"Test Issue"/utf8>>,
        none,
        <<"Todo"/utf8>>,
        {some, 1},
        none,
        none,
        [],
        [],
        none,
        none},
    Context = symphony@template:context_from_issue(Issue, 2),
    _pipe = symphony@template:render(
        <<"{{ issue.identifier }}: {{ issue.title }} (attempt {{ attempt }})"/utf8>>,
        Context
    ),
    gleeunit_ffi:should_equal(
        _pipe,
        {ok, <<"TEST-1: Test Issue (attempt 2)"/utf8>>}
    ).

-file("test/symphony_gleam_test.gleam", 141).
-spec template_handles_unknown_variable_test() -> nil.
template_handles_unknown_variable_test() ->
    Issue = {issue,
        <<"123"/utf8>>,
        <<"TEST-1"/utf8>>,
        <<"Test Issue"/utf8>>,
        none,
        <<"Todo"/utf8>>,
        {some, 1},
        none,
        none,
        [],
        [],
        none,
        none},
    Context = symphony@template:context_from_issue(Issue, 1),
    _pipe = symphony@template:render(
        <<"Unknown: {{ unknown_var }}"/utf8>>,
        Context
    ),
    gleeunit_ffi:should_equal(
        _pipe,
        {ok, <<"Unknown: {{ UNDEFINED: unknown_var }}"/utf8>>}
    ).

-file("test/symphony_gleam_test.gleam", 167).
-spec orchestration_state_unclaimed_exists_test() -> nil.
orchestration_state_unclaimed_exists_test() ->
    _ = unclaimed,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 172).
-spec orchestration_state_claimed_exists_test() -> nil.
orchestration_state_claimed_exists_test() ->
    _ = claimed,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 177).
-spec orchestration_state_running_exists_test() -> nil.
orchestration_state_running_exists_test() ->
    _ = running,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 182).
-spec orchestration_state_retry_queued_exists_test() -> nil.
orchestration_state_retry_queued_exists_test() ->
    _ = retry_queued,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 187).
-spec orchestration_state_released_exists_test() -> nil.
orchestration_state_released_exists_test() ->
    _ = released,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 192).
-spec run_attempt_phase_succeeded_exists_test() -> nil.
run_attempt_phase_succeeded_exists_test() ->
    _ = succeeded,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 197).
-spec run_attempt_phase_failed_exists_test() -> nil.
run_attempt_phase_failed_exists_test() ->
    _ = failed,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 202).
-spec run_attempt_phase_timed_out_exists_test() -> nil.
run_attempt_phase_timed_out_exists_test() ->
    _ = timed_out,
    gleeunit_ffi:should_equal(1, 1).

-file("test/symphony_gleam_test.gleam", 211).
-spec issue_can_be_created_with_all_fields_test() -> nil.
issue_can_be_created_with_all_fields_test() ->
    Issue = {issue,
        <<"123"/utf8>>,
        <<"TEST-1"/utf8>>,
        <<"Test Issue"/utf8>>,
        {some, <<"Description"/utf8>>},
        <<"Todo"/utf8>>,
        {some, 1},
        {some, <<"feature/test"/utf8>>},
        {some, <<"https://example.com"/utf8>>},
        [<<"bug"/utf8>>, <<"urgent"/utf8>>],
        [],
        {some, 1234567890},
        {some, 1234567900}},
    _pipe = erlang:element(3, Issue),
    gleeunit_ffi:should_equal(_pipe, <<"TEST-1"/utf8>>).

-file("test/symphony_gleam_test.gleam", 231).
-spec issue_can_be_created_with_minimal_fields_test() -> nil.
issue_can_be_created_with_minimal_fields_test() ->
    Issue = {issue,
        <<"123"/utf8>>,
        <<"TEST-1"/utf8>>,
        <<"Test Issue"/utf8>>,
        none,
        <<"Todo"/utf8>>,
        none,
        none,
        none,
        [],
        [],
        none,
        none},
    _pipe = erlang:element(3, Issue),
    gleeunit_ffi:should_equal(_pipe, <<"TEST-1"/utf8>>).
