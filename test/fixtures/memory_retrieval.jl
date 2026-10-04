function memory_fixture_context(root;session_id="memory-owner",policy=nothing,sink=event->nothing,approve=request->:once)
    permissions=policy===nothing ? PermissionPolicy(;rules=Dict(:read=>Allow,:persistence=>Allow,
        :process=>Deny,:network=>Deny,:edit=>Deny)) : policy
    RuntimeContext(root;state_dir=joinpath(root,"state"),session_id,permissions,sink,approve)
end

function memory_fixture_put(ctx,key,content;namespace="default",title=key,tags=String[],source="user",expires=nothing)
    memory_put!(memory_store(ctx;namespace),key,content,ctx;expected_version=0,title,tags,source,expires)
end

function memory_fixture_corrupt(store,ctx,change::Function)
    records=ShenScope.journal_records(store.versions.journal)
    change(records)
    # Recompute outer framing to exercise the inner value/schema checks.
    atomic_write(store.versions.journal.path,ShenScope.journal_frames(records))
end
