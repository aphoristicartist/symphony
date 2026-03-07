-module(symphony@codex@app_server).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/symphony/codex/app_server.gleam").
-export([start_thread/2, stream_events/2, start_turn/2, stop_thread/1]).
-export_type([codex_process/0, json_rpc_message/1, json_rpc_error/0, codex_event/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type codex_process() :: {codex_process,
        gleam@erlang@process:pid_(),
        gleam@erlang@process:subject(binary()),
        gleam@erlang@process:subject(binary())}.

-type json_rpc_message(BEJ) :: {json_rpc_message,
        binary(),
        gleam@option:option(binary()),
        gleam@option:option(BEJ),
        gleam@option:option(integer()),
        gleam@option:option(BEJ),
        gleam@option:option(json_rpc_error())}.

-type json_rpc_error() :: {json_rpc_error,
        integer(),
        binary(),
        gleam@option:option(gleam@dynamic:dynamic_())}.

-type codex_event() :: {turn_started, binary()} |
    {turn_update, binary(), binary()} |
    {turn_complete, binary(), integer(), integer()} |
    {thread_started, binary()} |
    {thread_complete, binary()} |
    {process_error, binary()}.

-file("src/symphony/codex/app_server.gleam", 56).
?DOC(" Start a Codex thread by spawning the app-server process\n").
-spec start_thread(binary(), binary()) -> {ok, codex_process()} |
    {error, binary()}.
start_thread(Command, Cwd) ->
    symphony_codex_ffi:start_codex(Command, Cwd).

-file("src/symphony/codex/app_server.gleam", 185).
-spec get_params(gleam@dynamic:dynamic_()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, binary()}.
get_params(Dyn) ->
    gleam@result:'try'(
        begin
            _pipe = (gleam@dynamic:field(
                <<"params"/utf8>>,
                gleam@dynamic:optional(fun gleam@dynamic:dynamic/1)
            ))(Dyn),
            gleam@result:map_error(
                _pipe,
                fun(_) -> <<"Failed to parse params"/utf8>> end
            )
        end,
        fun(Opt) -> case Opt of
                {some, P} ->
                    {ok, P};

                none ->
                    {error, <<"Missing params"/utf8>>}
            end end
    ).

-file("src/symphony/codex/app_server.gleam", 197).
-spec get_string_field(gleam@dynamic:dynamic_(), binary()) -> {ok, binary()} |
    {error, binary()}.
get_string_field(Dyn, Field) ->
    _pipe = (gleam@dynamic:field(Field, fun gleam@dynamic:string/1))(Dyn),
    gleam@result:map_error(
        _pipe,
        fun(_) -> <<"Missing "/utf8, Field/binary>> end
    ).

-file("src/symphony/codex/app_server.gleam", 148).
-spec parse_turn_started(gleam@dynamic:dynamic_()) -> {ok, codex_event()} |
    {error, binary()}.
parse_turn_started(Dyn) ->
    gleam@result:'try'(
        get_params(Dyn),
        fun(Params) ->
            gleam@result:'try'(
                get_string_field(Params, <<"turn_id"/utf8>>),
                fun(Turn_id) -> {ok, {turn_started, Turn_id}} end
            )
        end
    ).

-file("src/symphony/codex/app_server.gleam", 154).
-spec parse_turn_update(gleam@dynamic:dynamic_()) -> {ok, codex_event()} |
    {error, binary()}.
parse_turn_update(Dyn) ->
    gleam@result:'try'(
        get_params(Dyn),
        fun(Params) ->
            gleam@result:'try'(
                get_string_field(Params, <<"turn_id"/utf8>>),
                fun(Turn_id) ->
                    gleam@result:'try'(
                        get_string_field(Params, <<"content"/utf8>>),
                        fun(Content) ->
                            {ok, {turn_update, Turn_id, Content}}
                        end
                    )
                end
            )
        end
    ).

-file("src/symphony/codex/app_server.gleam", 173).
-spec parse_thread_started(gleam@dynamic:dynamic_()) -> {ok, codex_event()} |
    {error, binary()}.
parse_thread_started(Dyn) ->
    gleam@result:'try'(
        get_params(Dyn),
        fun(Params) ->
            gleam@result:'try'(
                get_string_field(Params, <<"thread_id"/utf8>>),
                fun(Thread_id) -> {ok, {thread_started, Thread_id}} end
            )
        end
    ).

-file("src/symphony/codex/app_server.gleam", 179).
-spec parse_thread_complete(gleam@dynamic:dynamic_()) -> {ok, codex_event()} |
    {error, binary()}.
parse_thread_complete(Dyn) ->
    gleam@result:'try'(
        get_params(Dyn),
        fun(Params) ->
            gleam@result:'try'(
                get_string_field(Params, <<"thread_id"/utf8>>),
                fun(Thread_id) -> {ok, {thread_complete, Thread_id}} end
            )
        end
    ).

-file("src/symphony/codex/app_server.gleam", 202).
-spec get_int_field(gleam@dynamic:dynamic_(), binary()) -> {ok, integer()} |
    {error, binary()}.
get_int_field(Dyn, Field) ->
    _pipe = (gleam@dynamic:field(Field, fun gleam@dynamic:int/1))(Dyn),
    gleam@result:map_error(
        _pipe,
        fun(_) -> <<"Missing "/utf8, Field/binary>> end
    ).

-file("src/symphony/codex/app_server.gleam", 161).
-spec parse_turn_complete(gleam@dynamic:dynamic_()) -> {ok, codex_event()} |
    {error, binary()}.
parse_turn_complete(Dyn) ->
    gleam@result:'try'(
        get_params(Dyn),
        fun(Params) ->
            gleam@result:'try'(
                get_string_field(Params, <<"turn_id"/utf8>>),
                fun(Turn_id) ->
                    gleam@result:'try'(
                        get_int_field(Params, <<"input_tokens"/utf8>>),
                        fun(Input_tokens) ->
                            gleam@result:'try'(
                                get_int_field(Params, <<"output_tokens"/utf8>>),
                                fun(Output_tokens) ->
                                    {ok,
                                        {turn_complete,
                                            Turn_id,
                                            Input_tokens,
                                            Output_tokens}}
                                end
                            )
                        end
                    )
                end
            )
        end
    ).

-file("src/symphony/codex/app_server.gleam", 126).
?DOC(" Parse a Codex event from JSON\n").
-spec parse_event(binary()) -> {ok, codex_event()} | {error, binary()}.
parse_event(Json_str) ->
    gleam@result:'try'(
        begin
            _pipe = gleam@json:decode(Json_str, fun gleam@dynamic:dynamic/1),
            gleam@result:map_error(
                _pipe,
                fun(_) -> <<"Failed to decode event JSON"/utf8>> end
            )
        end,
        fun(Dyn) ->
            gleam@result:'try'(
                begin
                    _pipe@1 = (gleam@dynamic:field(
                        <<"method"/utf8>>,
                        gleam@dynamic:optional(fun gleam@dynamic:string/1)
                    ))(Dyn),
                    gleam@result:map_error(
                        _pipe@1,
                        fun(_) -> <<"Failed to parse event method"/utf8>> end
                    )
                end,
                fun(Method) -> case Method of
                        {some, <<"turn.started"/utf8>>} ->
                            parse_turn_started(Dyn);

                        {some, <<"turn.update"/utf8>>} ->
                            parse_turn_update(Dyn);

                        {some, <<"turn.complete"/utf8>>} ->
                            parse_turn_complete(Dyn);

                        {some, <<"thread.started"/utf8>>} ->
                            parse_thread_started(Dyn);

                        {some, <<"thread.complete"/utf8>>} ->
                            parse_thread_complete(Dyn);

                        {some, _} ->
                            {error, <<"Unknown event method"/utf8>>};

                        none ->
                            {error, <<"Event missing method field"/utf8>>}
                    end end
            )
        end
    ).

-file("src/symphony/codex/app_server.gleam", 114).
?DOC(" Read a single event from the process\n").
-spec read_event(codex_process()) -> {ok, codex_event()} | {error, binary()}.
read_event(Process) ->
    case symphony_codex_ffi:read_event(Process) of
        {ok, Event_str} ->
            parse_event(Event_str);

        {error, E} ->
            {error, E}
    end.

-file("src/symphony/codex/app_server.gleam", 99).
?DOC(" Stream loop\n").
-spec stream_loop(codex_process(), fun((codex_event()) -> nil)) -> nil.
stream_loop(Process, Handler) ->
    case read_event(Process) of
        {ok, Event} ->
            Handler(Event),
            case Event of
                {thread_complete, _} ->
                    nil;

                {process_error, _} ->
                    nil;

                _ ->
                    stream_loop(Process, Handler)
            end;

        {error, _} ->
            nil
    end.

-file("src/symphony/codex/app_server.gleam", 90).
?DOC(" Stream events from the Codex process\n").
-spec stream_events(codex_process(), fun((codex_event()) -> nil)) -> nil.
stream_events(Process, Handler) ->
    stream_loop(Process, Handler).

-file("src/symphony/codex/app_server.gleam", 234).
?DOC(" Convert dynamic to JSON (simplified)\n").
-spec dynamic_to_json(gleam@dynamic:dynamic_()) -> gleam@json:json().
dynamic_to_json(Dyn) ->
    case gleam@dynamic:string(Dyn) of
        {ok, S} ->
            gleam@json:string(S);

        {error, _} ->
            gleam@json:null()
    end.

-file("src/symphony/codex/app_server.gleam", 208).
?DOC(" Encode a JSON-RPC request\n").
-spec encode_request(json_rpc_message(gleam@dynamic:dynamic_())) -> binary().
encode_request(Request) ->
    Base_fields = [{<<"jsonrpc"/utf8>>,
            gleam@json:string(erlang:element(2, Request))}],
    Method_fields = case erlang:element(3, Request) of
        {some, Method} ->
            [{<<"method"/utf8>>, gleam@json:string(Method)}];

        none ->
            []
    end,
    Params_fields = case erlang:element(4, Request) of
        {some, Params} ->
            [{<<"params"/utf8>>, dynamic_to_json(Params)}];

        none ->
            []
    end,
    Id_fields = case erlang:element(5, Request) of
        {some, Id} ->
            [{<<"id"/utf8>>, gleam@json:int(Id)}];

        none ->
            []
    end,
    All_fields = gleam@list:concat(
        [Base_fields, Method_fields, Params_fields, Id_fields]
    ),
    _pipe = gleam@json:object(All_fields),
    gleam@json:to_string(_pipe).

-file("src/symphony/codex/app_server.gleam", 80).
?DOC(" Send a JSON-RPC request\n").
-spec send_request(codex_process(), json_rpc_message(gleam@dynamic:dynamic_())) -> {ok,
        nil} |
    {error, binary()}.
send_request(Process, Request) ->
    Json_str = encode_request(Request),
    symphony_codex_ffi:send_to_process(Process, Json_str).

-file("src/symphony/codex/app_server.gleam", 66).
?DOC(" Start a turn in the Codex thread\n").
-spec start_turn(codex_process(), binary()) -> {ok, nil} | {error, binary()}.
start_turn(Process, Prompt) ->
    Request = {json_rpc_message,
        <<"2.0"/utf8>>,
        {some, <<"turn.start"/utf8>>},
        {some,
            gleam@dynamic:from(
                maps:from_list(
                    [{<<"prompt"/utf8>>, gleam@dynamic:from(Prompt)}]
                )
            )},
        {some, 1},
        none,
        none},
    send_request(Process, Request).

-file("src/symphony/codex/app_server.gleam", 243).
?DOC(" Stop the Codex process\n").
-spec stop_thread(codex_process()) -> nil.
stop_thread(Process) ->
    symphony_codex_ffi:stop_codex(Process).
