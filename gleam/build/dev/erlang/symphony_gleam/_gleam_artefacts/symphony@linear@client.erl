-module(symphony@linear@client).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/linear/client.gleam").
-export([fetch_active_issues/1, fetch_issue_state/2]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-file("src/symphony/linear/client.gleam", 51).
?DOC(" Build GraphQL query for active issues\n").
-spec build_active_issues_query(binary()) -> binary().
build_active_issues_query(Project_slug) ->
    <<<<"query { issues(filter: { project: { identifier: { eq: \""/utf8,
            Project_slug/binary>>/binary,
        "\" } } }) { nodes { id identifier title description state { name } priority branchName url labels { nodes { name } } blockedBy { nodes { id identifier state { name } } } createdAt updatedAt } } }"/utf8>>.

-file("src/symphony/linear/client.gleam", 58).
?DOC(" Build GraphQL query for issue state\n").
-spec build_issue_state_query(binary()) -> binary().
build_issue_state_query(Issue_id) ->
    <<<<"query { issue(id: \""/utf8, Issue_id/binary>>/binary,
        "\") { state { name } } }"/utf8>>.

-file("src/symphony/linear/client.gleam", 75).
?DOC(" Parse GraphQL response\n").
-spec parse_graphql_response(gleam@http@response:response(binary())) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, binary()}.
parse_graphql_response(Response) ->
    case erlang:element(2, Response) of
        200 ->
            _pipe = gleam@json:decode(
                erlang:element(4, Response),
                fun gleam@dynamic:dynamic/1
            ),
            gleam@result:map_error(
                _pipe,
                fun(_) -> <<"Failed to parse JSON response"/utf8>> end
            );

        _ ->
            {error,
                <<"HTTP error: "/utf8,
                    (gleam@int:to_string(erlang:element(2, Response)))/binary>>}
    end.

-file("src/symphony/linear/client.gleam", 103).
?DOC(" Extract state from GraphQL response\n").
-spec extract_state_from_response(gleam@dynamic:dynamic_()) -> {ok, binary()} |
    {error, binary()}.
extract_state_from_response(Body) ->
    Decoder = gleam@dynamic:field(
        <<"data"/utf8>>,
        gleam@dynamic:field(
            <<"issue"/utf8>>,
            gleam@dynamic:field(
                <<"state"/utf8>>,
                gleam@dynamic:field(<<"name"/utf8>>, fun gleam@dynamic:string/1)
            )
        )
    ),
    case Decoder(Body) of
        {ok, State} ->
            {ok, State};

        {error, _} ->
            {error, <<"Failed to decode issue state from response"/utf8>>}
    end.

-file("src/symphony/linear/client.gleam", 187).
?DOC(" Decode a BlockerRef from dynamic\n").
-spec decode_blocker_ref(gleam@dynamic:dynamic_()) -> {ok,
        symphony@types:blocker_ref()} |
    {error, list(gleam@dynamic:decode_error())}.
decode_blocker_ref(Dyn) ->
    Id_decoder = gleam@dynamic:optional_field(
        <<"id"/utf8>>,
        fun gleam@dynamic:string/1
    ),
    Identifier_decoder = gleam@dynamic:optional_field(
        <<"identifier"/utf8>>,
        fun gleam@dynamic:string/1
    ),
    State_decoder = gleam@dynamic:field(
        <<"state"/utf8>>,
        gleam@dynamic:optional(
            gleam@dynamic:field(<<"name"/utf8>>, fun gleam@dynamic:string/1)
        )
    ),
    gleam@result:'try'(
        Id_decoder(Dyn),
        fun(Id) ->
            gleam@result:'try'(
                Identifier_decoder(Dyn),
                fun(Identifier) ->
                    gleam@result:'try'(
                        State_decoder(Dyn),
                        fun(State) ->
                            {ok, {blocker_ref, Id, Identifier, State}}
                        end
                    )
                end
            )
        end
    ).

-file("src/symphony/linear/client.gleam", 119).
?DOC(" Decode an Issue from dynamic\n").
-spec decode_issue(gleam@dynamic:dynamic_()) -> {ok, symphony@types:issue()} |
    {error, list(gleam@dynamic:decode_error())}.
decode_issue(Dyn) ->
    Id_decoder = gleam@dynamic:field(<<"id"/utf8>>, fun gleam@dynamic:string/1),
    Identifier_decoder = gleam@dynamic:field(
        <<"identifier"/utf8>>,
        fun gleam@dynamic:string/1
    ),
    Title_decoder = gleam@dynamic:field(
        <<"title"/utf8>>,
        fun gleam@dynamic:string/1
    ),
    Description_decoder = gleam@dynamic:optional_field(
        <<"description"/utf8>>,
        gleam@dynamic:optional(fun gleam@dynamic:string/1)
    ),
    State_decoder = gleam@dynamic:field(
        <<"state"/utf8>>,
        gleam@dynamic:field(<<"name"/utf8>>, fun gleam@dynamic:string/1)
    ),
    Priority_decoder = gleam@dynamic:optional_field(
        <<"priority"/utf8>>,
        gleam@dynamic:optional(fun gleam@dynamic:int/1)
    ),
    Branch_name_decoder = gleam@dynamic:optional_field(
        <<"branchName"/utf8>>,
        gleam@dynamic:optional(fun gleam@dynamic:string/1)
    ),
    Url_decoder = gleam@dynamic:optional_field(
        <<"url"/utf8>>,
        gleam@dynamic:optional(fun gleam@dynamic:string/1)
    ),
    Labels_decoder = gleam@dynamic:field(
        <<"labels"/utf8>>,
        gleam@dynamic:field(
            <<"nodes"/utf8>>,
            gleam@dynamic:list(
                gleam@dynamic:field(<<"name"/utf8>>, fun gleam@dynamic:string/1)
            )
        )
    ),
    Blocked_by_decoder = gleam@dynamic:field(
        <<"blockedBy"/utf8>>,
        gleam@dynamic:field(
            <<"nodes"/utf8>>,
            gleam@dynamic:list(fun decode_blocker_ref/1)
        )
    ),
    Created_at_decoder = gleam@dynamic:optional_field(
        <<"createdAt"/utf8>>,
        gleam@dynamic:optional(fun gleam@dynamic:int/1)
    ),
    Updated_at_decoder = gleam@dynamic:optional_field(
        <<"updatedAt"/utf8>>,
        gleam@dynamic:optional(fun gleam@dynamic:int/1)
    ),
    gleam@result:'try'(
        Id_decoder(Dyn),
        fun(Id) ->
            gleam@result:'try'(
                Identifier_decoder(Dyn),
                fun(Identifier) ->
                    gleam@result:'try'(
                        Title_decoder(Dyn),
                        fun(Title) ->
                            gleam@result:'try'(
                                Description_decoder(Dyn),
                                fun(Description) ->
                                    gleam@result:'try'(
                                        State_decoder(Dyn),
                                        fun(State) ->
                                            gleam@result:'try'(
                                                Priority_decoder(Dyn),
                                                fun(Priority) ->
                                                    gleam@result:'try'(
                                                        Branch_name_decoder(Dyn),
                                                        fun(Branch_name) ->
                                                            gleam@result:'try'(
                                                                Url_decoder(Dyn),
                                                                fun(Url) ->
                                                                    gleam@result:'try'(
                                                                        Labels_decoder(
                                                                            Dyn
                                                                        ),
                                                                        fun(
                                                                            Labels
                                                                        ) ->
                                                                            gleam@result:'try'(
                                                                                Blocked_by_decoder(
                                                                                    Dyn
                                                                                ),
                                                                                fun(
                                                                                    Blocked_by
                                                                                ) ->
                                                                                    gleam@result:'try'(
                                                                                        Created_at_decoder(
                                                                                            Dyn
                                                                                        ),
                                                                                        fun(
                                                                                            Created_at
                                                                                        ) ->
                                                                                            gleam@result:'try'(
                                                                                                Updated_at_decoder(
                                                                                                    Dyn
                                                                                                ),
                                                                                                fun(
                                                                                                    Updated_at
                                                                                                ) ->
                                                                                                    {ok,
                                                                                                        {issue,
                                                                                                            Id,
                                                                                                            Identifier,
                                                                                                            Title,
                                                                                                            begin
                                                                                                                _pipe = Description,
                                                                                                                gleam@option:flatten(
                                                                                                                    _pipe
                                                                                                                )
                                                                                                            end,
                                                                                                            State,
                                                                                                            begin
                                                                                                                _pipe@1 = Priority,
                                                                                                                gleam@option:flatten(
                                                                                                                    _pipe@1
                                                                                                                )
                                                                                                            end,
                                                                                                            begin
                                                                                                                _pipe@2 = Branch_name,
                                                                                                                gleam@option:flatten(
                                                                                                                    _pipe@2
                                                                                                                )
                                                                                                            end,
                                                                                                            begin
                                                                                                                _pipe@3 = Url,
                                                                                                                gleam@option:flatten(
                                                                                                                    _pipe@3
                                                                                                                )
                                                                                                            end,
                                                                                                            Labels,
                                                                                                            Blocked_by,
                                                                                                            begin
                                                                                                                _pipe@4 = Created_at,
                                                                                                                gleam@option:flatten(
                                                                                                                    _pipe@4
                                                                                                                )
                                                                                                            end,
                                                                                                            begin
                                                                                                                _pipe@5 = Updated_at,
                                                                                                                gleam@option:flatten(
                                                                                                                    _pipe@5
                                                                                                                )
                                                                                                            end}}
                                                                                                end
                                                                                            )
                                                                                        end
                                                                                    )
                                                                                end
                                                                            )
                                                                        end
                                                                    )
                                                                end
                                                            )
                                                        end
                                                    )
                                                end
                                            )
                                        end
                                    )
                                end
                            )
                        end
                    )
                end
            )
        end
    ).

-file("src/symphony/linear/client.gleam", 86).
?DOC(" Extract issues from GraphQL response\n").
-spec extract_issues_from_response(gleam@dynamic:dynamic_()) -> {ok,
        list(symphony@types:issue())} |
    {error, binary()}.
extract_issues_from_response(Body) ->
    Decoder = gleam@dynamic:field(
        <<"data"/utf8>>,
        gleam@dynamic:field(
            <<"issues"/utf8>>,
            gleam@dynamic:field(
                <<"nodes"/utf8>>,
                gleam@dynamic:list(fun decode_issue/1)
            )
        )
    ),
    case Decoder(Body) of
        {ok, Issues} ->
            {ok, Issues};

        {error, _} ->
            {error, <<"Failed to decode issues from response"/utf8>>}
    end.

-file("src/symphony/linear/client.gleam", 63).
?DOC(" Build a GraphQL HTTP request\n").
-spec build_graphql_request(binary(), binary()) -> gleam@http@request:request(binary()).
build_graphql_request(Api_key, Query) ->
    Body = begin
        _pipe = gleam@json:object(
            [{<<"query"/utf8>>, gleam@json:string(Query)}]
        ),
        gleam@json:to_string(_pipe)
    end,
    _pipe@1 = gleam@http@request:new(),
    _pipe@2 = gleam@http@request:set_method(_pipe@1, post),
    _pipe@3 = gleam@http@request:set_host(
        _pipe@2,
        <<"https://api.linear.app/graphql"/utf8>>
    ),
    _pipe@4 = gleam@http@request:prepend_header(
        _pipe@3,
        <<"Authorization"/utf8>>,
        <<"Bearer "/utf8, Api_key/binary>>
    ),
    _pipe@5 = gleam@http@request:prepend_header(
        _pipe@4,
        <<"Content-Type"/utf8>>,
        <<"application/json"/utf8>>
    ),
    gleam@http@request:set_body(_pipe@5, Body).

-file("src/symphony/linear/client.gleam", 20).
?DOC(" Fetch active issues from Linear\n").
-spec fetch_active_issues(symphony@config:config()) -> {ok,
        list(symphony@types:issue())} |
    {error, binary()}.
fetch_active_issues(Config) ->
    Query = build_active_issues_query(
        erlang:element(4, erlang:element(2, Config))
    ),
    Req = build_graphql_request(
        erlang:element(3, erlang:element(2, Config)),
        Query
    ),
    gleam@result:'try'(
        begin
            _pipe = gleam@httpc:send(Req),
            gleam@result:map_error(
                _pipe,
                fun(_) -> <<"HTTP request failed"/utf8>> end
            )
        end,
        fun(Response) ->
            gleam@result:'try'(
                parse_graphql_response(Response),
                fun(Body) -> extract_issues_from_response(Body) end
            )
        end
    ).

-file("src/symphony/linear/client.gleam", 34).
?DOC(" Fetch the state of a specific issue\n").
-spec fetch_issue_state(symphony@config:config(), binary()) -> {ok, binary()} |
    {error, binary()}.
fetch_issue_state(Config, Issue_id) ->
    Query = build_issue_state_query(Issue_id),
    Req = build_graphql_request(
        erlang:element(3, erlang:element(2, Config)),
        Query
    ),
    gleam@result:'try'(
        begin
            _pipe = gleam@httpc:send(Req),
            gleam@result:map_error(
                _pipe,
                fun(_) -> <<"HTTP request failed"/utf8>> end
            )
        end,
        fun(Response) ->
            gleam@result:'try'(
                parse_graphql_response(Response),
                fun(Body) -> extract_state_from_response(Body) end
            )
        end
    ).
