-record(worker_completed, {
    issue_id :: binary(),
    result :: symphony@orchestrator:worker_result()
}).
