-module(symphony@template).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/template.gleam").
-export([render/2, context_from_issue/2, with_extra/3]).
-export_type([render_context/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type render_context() :: {render_context,
        symphony@types:issue(),
        integer(),
        gleam@dict:dict(binary(), binary())}.

-file("src/symphony/template.gleam", 67).
?DOC(" Resolve an issue field\n").
-spec resolve_issue_field(binary(), symphony@types:issue()) -> {ok, binary()} |
    {error, binary()}.
resolve_issue_field(Field, Issue) ->
    case Field of
        <<"id"/utf8>> ->
            {ok, erlang:element(2, Issue)};

        <<"identifier"/utf8>> ->
            {ok, erlang:element(3, Issue)};

        <<"title"/utf8>> ->
            {ok, erlang:element(4, Issue)};

        <<"description"/utf8>> ->
            {ok, gleam@option:unwrap(erlang:element(5, Issue), <<""/utf8>>)};

        <<"state"/utf8>> ->
            {ok, erlang:element(6, Issue)};

        <<"priority"/utf8>> ->
            {ok,
                gleam@option:unwrap(
                    gleam@option:map(
                        erlang:element(7, Issue),
                        fun gleam@int:to_string/1
                    ),
                    <<""/utf8>>
                )};

        <<"branch_name"/utf8>> ->
            {ok, gleam@option:unwrap(erlang:element(8, Issue), <<""/utf8>>)};

        <<"url"/utf8>> ->
            {ok, gleam@option:unwrap(erlang:element(9, Issue), <<""/utf8>>)};

        <<"labels"/utf8>> ->
            {ok, gleam@string:join(erlang:element(10, Issue), <<", "/utf8>>)};

        <<"created_at"/utf8>> ->
            {ok,
                gleam@option:unwrap(
                    gleam@option:map(
                        erlang:element(12, Issue),
                        fun gleam@int:to_string/1
                    ),
                    <<""/utf8>>
                )};

        <<"updated_at"/utf8>> ->
            {ok,
                gleam@option:unwrap(
                    gleam@option:map(
                        erlang:element(13, Issue),
                        fun gleam@int:to_string/1
                    ),
                    <<""/utf8>>
                )};

        _ ->
            {error, <<"Unknown issue field: "/utf8, Field/binary>>}
    end.

-file("src/symphony/template.gleam", 97).
?DOC(" Format an entire issue as a string\n").
-spec format_issue(symphony@types:issue()) -> binary().
format_issue(Issue) ->
    <<<<<<<<"Issue("/utf8, (erlang:element(3, Issue))/binary>>/binary,
                ": "/utf8>>/binary,
            (erlang:element(4, Issue))/binary>>/binary,
        ")"/utf8>>.

-file("src/symphony/template.gleam", 85).
?DOC(" Resolve nested issue field\n").
-spec resolve_nested_issue_field(list(binary()), symphony@types:issue()) -> {ok,
        binary()} |
    {error, binary()}.
resolve_nested_issue_field(Path, Issue) ->
    case Path of
        [] ->
            {ok, format_issue(Issue)};

        [Field] ->
            resolve_issue_field(Field, Issue);

        [Field@1 | Rest] ->
            {error,
                <<"Nested field access not supported: "/utf8,
                    (gleam@string:join([Field@1 | Rest], <<"."/utf8>>))/binary>>}
    end.

-file("src/symphony/template.gleam", 42).
?DOC(" Resolve a variable name to its value\n").
-spec resolve_variable(binary(), render_context()) -> {ok, binary()} |
    {error, binary()}.
resolve_variable(Name, Context) ->
    Parts = gleam@string:split(Name, <<"."/utf8>>),
    case Parts of
        [<<"issue"/utf8>>] ->
            {ok, format_issue(erlang:element(2, Context))};

        [<<"issue"/utf8>>, Field] ->
            resolve_issue_field(Field, erlang:element(2, Context));

        [<<"attempt"/utf8>>] ->
            {ok, gleam@int:to_string(erlang:element(3, Context))};

        [Key] ->
            case gleam@dict:get(erlang:element(4, Context), Key) of
                {ok, Value} ->
                    {ok, Value};

                {error, _} ->
                    {error, <<"Undefined variable: "/utf8, Key/binary>>}
            end;

        [Namespace | Rest] ->
            case Namespace of
                <<"issue"/utf8>> ->
                    resolve_nested_issue_field(Rest, erlang:element(2, Context));

                _ ->
                    {error, <<"Unknown namespace: "/utf8, Namespace/binary>>}
            end;

        _ ->
            {error, <<"Invalid variable path: "/utf8, Name/binary>>}
    end.

-file("src/symphony/template.gleam", 11).
?DOC(
    " Render a template string with variable substitution\n"
    " Supports: {{ variable }}, {{ nested.field }}, {{ object.property }}\n"
).
-spec render(binary(), render_context()) -> {ok, binary()} | {error, binary()}.
render(Template, Context) ->
    Var_pattern@1 = case gleam@regex:from_string(
        <<"\\{\\{\\s*([^}]+?)\\s*\\}\\}"/utf8>>
    ) of
        {ok, Var_pattern} -> Var_pattern;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"symphony/template"/utf8>>,
                        function => <<"render"/utf8>>,
                        line => 13,
                        value => _assert_fail,
                        start => 427,
                        'end' => 505,
                        pattern_start => 438,
                        pattern_end => 453})
    end,
    Matches = gleam@regex:scan(Var_pattern@1, Template),
    _pipe = gleam@list:fold(Matches, Template, fun(Acc, Match) -> case Match of
                {match, Full_match, [{some, Var_name}]} ->
                    case resolve_variable(Var_name, Context) of
                        {ok, Value} ->
                            gleam@string:replace(Acc, Full_match, Value);

                        {error, _} ->
                            gleam@string:replace(
                                Acc,
                                Full_match,
                                <<<<"{{ UNDEFINED: "/utf8, Var_name/binary>>/binary,
                                    " }}"/utf8>>
                            )
                    end;

                _ ->
                    Acc
            end end),
    {ok, _pipe}.

-file("src/symphony/template.gleam", 106).
?DOC(" Create a render context from an issue\n").
-spec context_from_issue(symphony@types:issue(), integer()) -> render_context().
context_from_issue(Issue, Attempt) ->
    {render_context, Issue, Attempt, gleam@dict:new()}.

-file("src/symphony/template.gleam", 111).
?DOC(" Add extra variables to the context\n").
-spec with_extra(render_context(), binary(), binary()) -> render_context().
with_extra(Context, Key, Value) ->
    {render_context,
        erlang:element(2, Context),
        erlang:element(3, Context),
        gleam@dict:insert(erlang:element(4, Context), Key, Value)}.
