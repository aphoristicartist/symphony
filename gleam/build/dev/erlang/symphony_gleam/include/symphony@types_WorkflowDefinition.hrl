-record(workflow_definition, {
    config :: gleam@dict:dict(binary(), gleam@dynamic:dynamic_()),
    prompt_template :: binary()
}).
