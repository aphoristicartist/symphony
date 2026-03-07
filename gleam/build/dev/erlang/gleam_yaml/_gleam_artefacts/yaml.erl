-module(yaml).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/yaml.gleam").
-export([main/0]).

-file("src/yaml.gleam", 3).
-spec main() -> nil.
main() ->
    gleam@io:println(<<"Hello from yaml!"/utf8>>).
