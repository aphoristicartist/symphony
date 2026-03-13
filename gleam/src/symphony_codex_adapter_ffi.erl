-module(symphony_codex_adapter_ffi).
-export([put_process_dict/2, get_process_dict/1]).

put_process_dict(Key, Value) ->
    erlang:put(Key, Value),
    Value.

get_process_dict(Key) ->
    case erlang:get(Key) of
        undefined -> nil;
        Value -> Value
    end.
