-module(symphony@config).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/config.gleam").
-export([load/1]).
-export_type([tracker_config/0, polling_config/0, workspace_config/0, agent_config/0, codex_config/0, config/0, yaml_line/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type tracker_config() :: {tracker_config,
        binary(),
        binary(),
        binary(),
        list(binary()),
        list(binary())}.

-type polling_config() :: {polling_config, integer()}.

-type workspace_config() :: {workspace_config, binary()}.

-type agent_config() :: {agent_config, integer(), integer()}.

-type codex_config() :: {codex_config, binary(), integer()}.

-type config() :: {config,
        tracker_config(),
        polling_config(),
        workspace_config(),
        agent_config(),
        codex_config(),
        binary()}.

-type yaml_line() :: {key_value, binary(), binary()} |
    {section_start, binary()} |
    {nested_key_value, binary(), binary(), binary()}.

-file("src/symphony/config.gleam", 161).
?DOC(" Parse a single YAML line\n").
-spec parse_yaml_line(binary()) -> {ok, yaml_line()} | {error, binary()}.
parse_yaml_line(Line) ->
    case gleam@string:starts_with(Line, <<"  "/utf8>>) orelse gleam@string:starts_with(
        Line,
        <<"\t"/utf8>>
    ) of
        true ->
            {error, <<"Nested values require parent context"/utf8>>};

        false ->
            case gleam@string:ends_with(Line, <<":"/utf8>>) andalso not gleam_stdlib:contains_string(
                Line,
                <<": "/utf8>>
            ) of
                true ->
                    Name = begin
                        _pipe = gleam@string:drop_right(Line, 1),
                        gleam@string:trim(_pipe)
                    end,
                    {ok, {section_start, Name}};

                false ->
                    case gleam@string:split_once(Line, <<":"/utf8>>) of
                        {ok, {Key, Value}} ->
                            Trimmed_key = gleam@string:trim(Key),
                            Trimmed_value = gleam@string:trim(Value),
                            {ok, {key_value, Trimmed_key, Trimmed_value}};

                        {error, _} ->
                            {error, <<"Invalid YAML line: "/utf8, Line/binary>>}
                    end
            end
    end.

-file("src/symphony/config.gleam", 95).
?DOC(" Parse YAML lines into a dictionary\n").
-spec parse_yaml_lines(
    list(binary()),
    gleam@dict:dict(binary(), gleam@dynamic:dynamic_())
) -> {ok, gleam@dict:dict(binary(), gleam@dynamic:dynamic_())} |
    {error, binary()}.
parse_yaml_lines(Lines, Acc) ->
    case Lines of
        [] ->
            {ok, Acc};

        [Line | Rest] ->
            Trimmed = gleam@string:trim(Line),
            case gleam@string:starts_with(Trimmed, <<"#"/utf8>>) orelse (Trimmed
            =:= <<""/utf8>>) of
                true ->
                    parse_yaml_lines(Rest, Acc);

                false ->
                    case parse_yaml_line(Trimmed) of
                        {ok, {key_value, Key, Value}} ->
                            New_acc = gleam@dict:insert(
                                Acc,
                                Key,
                                gleam@dynamic:from(Value)
                            ),
                            parse_yaml_lines(Rest, New_acc);

                        {ok, {section_start, Name}} ->
                            case gleam@dict:get(Acc, Name) of
                                {ok, _} ->
                                    parse_yaml_lines(Rest, Acc);

                                {error, _} ->
                                    New_acc@1 = gleam@dict:insert(
                                        Acc,
                                        Name,
                                        gleam@dynamic:from(gleam@dict:new())
                                    ),
                                    parse_yaml_lines(Rest, New_acc@1)
                            end;

                        {ok, {nested_key_value, Parent, Key@1, Value@1}} ->
                            case gleam@dict:get(Acc, Parent) of
                                {ok, Parent_dyn} ->
                                    Decoder = gleam@dynamic:dict(
                                        fun gleam@dynamic:string/1,
                                        fun gleam@dynamic:dynamic/1
                                    ),
                                    case Decoder(Parent_dyn) of
                                        {ok, Parent_dict} ->
                                            New_parent = gleam@dict:insert(
                                                Parent_dict,
                                                Key@1,
                                                gleam@dynamic:from(Value@1)
                                            ),
                                            New_acc@2 = gleam@dict:insert(
                                                Acc,
                                                Parent,
                                                gleam@dynamic:from(New_parent)
                                            ),
                                            parse_yaml_lines(Rest, New_acc@2);

                                        {error, _} ->
                                            {error,
                                                <<"Invalid nested structure for "/utf8,
                                                    Parent/binary>>}
                                    end;

                                {error, _} ->
                                    {error,
                                        <<"Parent section not found: "/utf8,
                                            Parent/binary>>}
                            end;

                        {error, E} ->
                            {error, E}
                    end
            end
    end.

-file("src/symphony/config.gleam", 90).
?DOC(" Simple YAML parser for basic key-value pairs\n").
-spec parse_simple_yaml(list(binary())) -> {ok,
        gleam@dict:dict(binary(), gleam@dynamic:dynamic_())} |
    {error, binary()}.
parse_simple_yaml(Lines) ->
    parse_yaml_lines(Lines, gleam@dict:new()).

-file("src/symphony/config.gleam", 193).
?DOC(" Find the closing --- delimiter\n").
-spec find_closing_delimiter(list(binary()), list(binary())) -> {ok,
        list(binary())} |
    {error, binary()}.
find_closing_delimiter(Lines, Acc) ->
    case Lines of
        [] ->
            {error, <<"YAML front matter not closed (missing ---)"/utf8>>};

        [<<"---"/utf8>> | _] ->
            {ok, lists:reverse(Acc)};

        [Line | Rest] ->
            find_closing_delimiter(Rest, [Line | Acc])
    end.

-file("src/symphony/config.gleam", 72).
?DOC(" Parse YAML front matter from WORKFLOW.md content\n").
-spec parse_yaml_front_matter(binary()) -> {ok,
        gleam@dict:dict(binary(), gleam@dynamic:dynamic_())} |
    {error, binary()}.
parse_yaml_front_matter(Content) ->
    Lines = gleam@string:split(Content, <<"\n"/utf8>>),
    case Lines of
        [<<"---"/utf8>> | Rest] ->
            case find_closing_delimiter(Rest, []) of
                {ok, Yaml_lines} ->
                    _pipe = parse_simple_yaml(Yaml_lines),
                    gleam@result:map_error(
                        _pipe,
                        fun(E) -> <<"YAML parse error: "/utf8, E/binary>> end
                    );

                {error, E@1} ->
                    {error, E@1}
            end;

        _ ->
            {error,
                <<"WORKFLOW.md must start with YAML front matter (---)"/utf8>>}
    end.

-file("src/symphony/config.gleam", 319).
?DOC(" Get a nested dictionary from a parent dictionary\n").
-spec get_dict(gleam@dict:dict(binary(), gleam@dynamic:dynamic_()), binary()) -> {ok,
        gleam@dict:dict(binary(), gleam@dynamic:dynamic_())} |
    {error, binary()}.
get_dict(Dict, Key) ->
    case gleam@dict:get(Dict, Key) of
        {ok, Dyn} ->
            Decoder = gleam@dynamic:dict(
                fun gleam@dynamic:string/1,
                fun gleam@dynamic:dynamic/1
            ),
            case Decoder(Dyn) of
                {ok, D} ->
                    {ok, D};

                {error, _} ->
                    {error, <<Key/binary, " must be a mapping"/utf8>>}
            end;

        {error, _} ->
            {error, <<"Missing required key: "/utf8, Key/binary>>}
    end.

-file("src/symphony/config.gleam", 387).
?DOC(" Get an integer value with a default\n").
-spec get_int_with_default(
    gleam@dict:dict(binary(), gleam@dynamic:dynamic_()),
    binary(),
    integer()
) -> integer().
get_int_with_default(Dict, Key, Default) ->
    case gleam@dict:get(Dict, Key) of
        {ok, Dyn} ->
            case gleam@dynamic:int(Dyn) of
                {ok, I} ->
                    I;

                {error, _} ->
                    case gleam@dynamic:string(Dyn) of
                        {ok, S} ->
                            case gleam@int:parse(S) of
                                {ok, I@1} ->
                                    I@1;

                                {error, _} ->
                                    Default
                            end;

                        {error, _} ->
                            Default
                    end
            end;

        {error, _} ->
            Default
    end.

-file("src/symphony/config.gleam", 257).
?DOC(" Build polling configuration with defaults\n").
-spec build_polling_config(gleam@dict:dict(binary(), gleam@dynamic:dynamic_())) -> {ok,
        polling_config()} |
    {error, binary()}.
build_polling_config(Dict) ->
    gleam@result:'try'(
        get_dict(Dict, <<"polling"/utf8>>),
        fun(Polling_dict) ->
            Interval_ms = get_int_with_default(
                Polling_dict,
                <<"interval_ms"/utf8>>,
                30000
            ),
            {ok, {polling_config, Interval_ms}}
        end
    ).

-file("src/symphony/config.gleam", 283).
?DOC(" Build agent configuration with defaults\n").
-spec build_agent_config(gleam@dict:dict(binary(), gleam@dynamic:dynamic_())) -> {ok,
        agent_config()} |
    {error, binary()}.
build_agent_config(Dict) ->
    gleam@result:'try'(
        get_dict(Dict, <<"agent"/utf8>>),
        fun(Agent_dict) ->
            Max_concurrent_agents = get_int_with_default(
                Agent_dict,
                <<"max_concurrent_agents"/utf8>>,
                10
            ),
            Max_turns = get_int_with_default(
                Agent_dict,
                <<"max_turns"/utf8>>,
                20
            ),
            {ok, {agent_config, Max_concurrent_agents, Max_turns}}
        end
    ).

-file("src/symphony/config.gleam", 411).
?DOC(" Get a list of strings with a default\n").
-spec get_string_list_with_default(
    gleam@dict:dict(binary(), gleam@dynamic:dynamic_()),
    binary(),
    list(binary())
) -> list(binary()).
get_string_list_with_default(Dict, Key, Default) ->
    Decoder = gleam@dynamic:list(fun gleam@dynamic:string/1),
    case gleam@dict:get(Dict, Key) of
        {ok, Dyn} ->
            case Decoder(Dyn) of
                {ok, Items} ->
                    Items;

                {error, _} ->
                    Default
            end;

        {error, _} ->
            Default
    end.

-file("src/symphony/config.gleam", 474).
?DOC(" Check if a character is valid in a variable name\n").
-spec is_var_name_char(binary()) -> boolean().
is_var_name_char(Grapheme) ->
    Lowercase = [<<"a"/utf8>>,
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
        <<"z"/utf8>>],
    Uppercase = [<<"A"/utf8>>,
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
        <<"Z"/utf8>>],
    Digits = [<<"0"/utf8>>,
        <<"1"/utf8>>,
        <<"2"/utf8>>,
        <<"3"/utf8>>,
        <<"4"/utf8>>,
        <<"5"/utf8>>,
        <<"6"/utf8>>,
        <<"7"/utf8>>,
        <<"8"/utf8>>,
        <<"9"/utf8>>],
    (((Grapheme =:= <<"_"/utf8>>) orelse gleam@list:contains(
        Lowercase,
        Grapheme
    ))
    orelse gleam@list:contains(Uppercase, Grapheme))
    orelse gleam@list:contains(Digits, Grapheme).

-file("src/symphony/config.gleam", 461).
?DOC(" Find the end of a variable name\n").
-spec find_var_name_end(binary(), integer()) -> integer().
find_var_name_end(S, Pos) ->
    case gleam@string:pop_grapheme(gleam@string:drop_left(S, Pos)) of
        {ok, {Grapheme, _}} ->
            case is_var_name_char(Grapheme) of
                true ->
                    find_var_name_end(S, Pos + 1);

                false ->
                    Pos
            end;

        {error, _} ->
            Pos
    end.

-file("src/symphony/config.gleam", 443).
?DOC(" Expand a single variable reference\n").
-spec expand_single_var(binary(), binary()) -> {ok, binary()} |
    {error, binary()}.
expand_single_var(Acc, Part) ->
    Var_name_end = find_var_name_end(Part, 0),
    Var_name = gleam@string:slice(Part, 0, Var_name_end),
    Rest = gleam@string:drop_left(Part, Var_name_end),
    case Var_name of
        <<""/utf8>> ->
            {ok, <<<<Acc/binary, "$"/utf8>>/binary, Part/binary>>};

        _ ->
            case gleam_erlang_ffi:get_env(Var_name) of
                {ok, Value} ->
                    {ok, <<<<Acc/binary, Value/binary>>/binary, Rest/binary>>};

                {error, _} ->
                    {error,
                        <<"Environment variable not found: "/utf8,
                            Var_name/binary>>}
            end
    end.

-file("src/symphony/config.gleam", 429).
?DOC(" Expand environment variables in a string ($VAR_NAME)\n").
-spec expand_env_vars(binary()) -> {ok, binary()} | {error, binary()}.
expand_env_vars(S) ->
    case gleam@string:split(S, <<"$"/utf8>>) of
        [] ->
            {ok, S};

        [First] ->
            {ok, First};

        [First@1 | Rest] ->
            gleam@result:'try'(
                gleam@list:try_fold(Rest, First@1, fun expand_single_var/2),
                fun(Expanded) -> {ok, Expanded} end
            )
    end.

-file("src/symphony/config.gleam", 336).
?DOC(" Get a required string value\n").
-spec get_string_required(
    gleam@dict:dict(binary(), gleam@dynamic:dynamic_()),
    binary(),
    binary()
) -> {ok, binary()} | {error, binary()}.
get_string_required(Dict, Key, Path) ->
    case gleam@dict:get(Dict, Key) of
        {ok, Dyn} ->
            case gleam@dynamic:string(Dyn) of
                {ok, S} ->
                    expand_env_vars(S);

                {error, _} ->
                    {error, <<Path/binary, " must be a string"/utf8>>}
            end;

        {error, _} ->
            {error, <<"Missing required key: "/utf8, Path/binary>>}
    end.

-file("src/symphony/config.gleam", 310).
?DOC(" Get prompt template (required)\n").
-spec get_prompt_template(gleam@dict:dict(binary(), gleam@dynamic:dynamic_())) -> {ok,
        binary()} |
    {error, binary()}.
get_prompt_template(Dict) ->
    get_string_required(
        Dict,
        <<"prompt_template"/utf8>>,
        <<"prompt_template"/utf8>>
    ).

-file("src/symphony/config.gleam", 353).
?DOC(" Get a string value with environment variable expansion\n").
-spec get_string_with_env(
    gleam@dict:dict(binary(), gleam@dynamic:dynamic_()),
    binary(),
    binary()
) -> {ok, binary()} | {error, binary()}.
get_string_with_env(Dict, Key, Path) ->
    case gleam@dict:get(Dict, Key) of
        {ok, Dyn} ->
            case gleam@dynamic:string(Dyn) of
                {ok, S} ->
                    expand_env_vars(S);

                {error, _} ->
                    {error, <<Path/binary, " must be a string"/utf8>>}
            end;

        {error, _} ->
            {error, <<"Missing required key: "/utf8, Path/binary>>}
    end.

-file("src/symphony/config.gleam", 224).
?DOC(" Build tracker configuration with defaults\n").
-spec build_tracker_config(gleam@dict:dict(binary(), gleam@dynamic:dynamic_())) -> {ok,
        tracker_config()} |
    {error, binary()}.
build_tracker_config(Dict) ->
    gleam@result:'try'(
        get_dict(Dict, <<"tracker"/utf8>>),
        fun(Tracker_dict) ->
            gleam@result:'try'(
                get_string_required(
                    Tracker_dict,
                    <<"kind"/utf8>>,
                    <<"tracker.kind"/utf8>>
                ),
                fun(Kind) ->
                    gleam@result:'try'(
                        get_string_with_env(
                            Tracker_dict,
                            <<"api_key"/utf8>>,
                            <<"tracker.api_key"/utf8>>
                        ),
                        fun(Api_key) ->
                            gleam@result:'try'(
                                get_string_required(
                                    Tracker_dict,
                                    <<"project_slug"/utf8>>,
                                    <<"tracker.project_slug"/utf8>>
                                ),
                                fun(Project_slug) ->
                                    Active_states = get_string_list_with_default(
                                        Tracker_dict,
                                        <<"active_states"/utf8>>,
                                        [<<"Todo"/utf8>>,
                                            <<"In Progress"/utf8>>,
                                            <<"In Review"/utf8>>]
                                    ),
                                    Terminal_states = get_string_list_with_default(
                                        Tracker_dict,
                                        <<"terminal_states"/utf8>>,
                                        [<<"Done"/utf8>>,
                                            <<"Canceled"/utf8>>,
                                            <<"Duplicate"/utf8>>]
                                    ),
                                    {ok,
                                        {tracker_config,
                                            Kind,
                                            Api_key,
                                            Project_slug,
                                            Active_states,
                                            Terminal_states}}
                                end
                            )
                        end
                    )
                end
            )
        end
    ).

-file("src/symphony/config.gleam", 492).
?DOC(" Expand env vars or return default if any var is missing\n").
-spec expand_env_vars_or_default(binary(), binary()) -> binary().
expand_env_vars_or_default(S, Default) ->
    case expand_env_vars(S) of
        {ok, Expanded} ->
            Expanded;

        {error, _} ->
            Default
    end.

-file("src/symphony/config.gleam", 370).
?DOC(" Get a string value with a default\n").
-spec get_string_with_default(
    gleam@dict:dict(binary(), gleam@dynamic:dynamic_()),
    binary(),
    binary()
) -> binary().
get_string_with_default(Dict, Key, Default) ->
    case gleam@dict:get(Dict, Key) of
        {ok, Dyn} ->
            case gleam@dynamic:string(Dyn) of
                {ok, S} ->
                    expand_env_vars_or_default(S, Default);

                {error, _} ->
                    Default
            end;

        {error, _} ->
            Default
    end.

-file("src/symphony/config.gleam", 268).
?DOC(" Build workspace configuration with defaults\n").
-spec build_workspace_config(
    gleam@dict:dict(binary(), gleam@dynamic:dynamic_())
) -> {ok, workspace_config()} | {error, binary()}.
build_workspace_config(Dict) ->
    gleam@result:'try'(
        get_dict(Dict, <<"workspace"/utf8>>),
        fun(Workspace_dict) ->
            Root = get_string_with_default(
                Workspace_dict,
                <<"root"/utf8>>,
                <<"/tmp/symphony_workspaces"/utf8>>
            ),
            {ok, {workspace_config, Root}}
        end
    ).

-file("src/symphony/config.gleam", 300).
?DOC(" Build Codex configuration with defaults\n").
-spec build_codex_config(gleam@dict:dict(binary(), gleam@dynamic:dynamic_())) -> {ok,
        codex_config()} |
    {error, binary()}.
build_codex_config(Dict) ->
    gleam@result:'try'(
        get_dict(Dict, <<"codex"/utf8>>),
        fun(Codex_dict) ->
            Command = get_string_with_default(
                Codex_dict,
                <<"command"/utf8>>,
                <<"codex app-server"/utf8>>
            ),
            Turn_timeout_ms = get_int_with_default(
                Codex_dict,
                <<"turn_timeout_ms"/utf8>>,
                3600000
            ),
            {ok, {codex_config, Command, Turn_timeout_ms}}
        end
    ).

-file("src/symphony/config.gleam", 205).
?DOC(" Build Config from parsed YAML dictionary\n").
-spec build_config(gleam@dict:dict(binary(), gleam@dynamic:dynamic_())) -> {ok,
        config()} |
    {error, binary()}.
build_config(Dict) ->
    gleam@result:'try'(
        build_tracker_config(Dict),
        fun(Tracker) ->
            gleam@result:'try'(
                build_polling_config(Dict),
                fun(Polling) ->
                    gleam@result:'try'(
                        build_workspace_config(Dict),
                        fun(Workspace) ->
                            gleam@result:'try'(
                                build_agent_config(Dict),
                                fun(Agent) ->
                                    gleam@result:'try'(
                                        build_codex_config(Dict),
                                        fun(Codex) ->
                                            gleam@result:'try'(
                                                get_prompt_template(Dict),
                                                fun(Prompt_template) ->
                                                    {ok,
                                                        {config,
                                                            Tracker,
                                                            Polling,
                                                            Workspace,
                                                            Agent,
                                                            Codex,
                                                            Prompt_template}}
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

-file("src/symphony/config.gleam", 60).
?DOC(" Load configuration from a WORKFLOW.md file\n").
-spec load(binary()) -> {ok, config()} | {error, binary()}.
load(Path) ->
    gleam@result:'try'(
        begin
            _pipe = simplifile:read(Path),
            gleam@result:map_error(
                _pipe,
                fun(_) -> <<"Failed to read "/utf8, Path/binary>> end
            )
        end,
        fun(Content) ->
            gleam@result:'try'(
                parse_yaml_front_matter(Content),
                fun(Config_dict) -> build_config(Config_dict) end
            )
        end
    ).
