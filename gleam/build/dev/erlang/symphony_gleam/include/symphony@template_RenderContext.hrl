-record(render_context, {
    issue :: symphony@types:issue(),
    attempt :: integer(),
    extra :: gleam@dict:dict(binary(), binary())
}).
