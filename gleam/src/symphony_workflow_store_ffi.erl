-module(symphony_workflow_store_ffi).
-export([get_file_mtime/1]).

%% Return the file modification time as Unix seconds (integer), or an error.
get_file_mtime(Path) ->
    case filelib:last_modified(binary_to_list(Path)) of
        0 -> {error, nil};
        DateTime ->
            Secs = calendar:datetime_to_gregorian_seconds(DateTime)
                   - calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
            {ok, Secs}
    end.
