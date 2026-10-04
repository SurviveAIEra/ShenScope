mutable struct AnalyzerRecord
    definition::AnalyzerDefinition
    owner::String
    root::String
    created_at::String
    epoch::Int
    running::Dict{Int,CancellationToken}
    validation::Union{Nothing,Dict{String,Any}}
    failure::Union{Nothing,String}
end

mutable struct AnalyzerManager
    records::Dict{Tuple{String,String,String,String},AnalyzerRecord}
    selected::Dict{Tuple{String,String,String},String}
    processes::ProcessManager
    mutex::ReentrantLock
    max_records::Int
    max_bytes::Int
    max_running::Int
end

function AnalyzerManager(;max_records=128,max_bytes=32 * 1024^2,max_running=4)
    1 <= max_records <= 1024 && 1024 <= max_bytes <= 128 * 1024^2 && 1 <= max_running <= 16 ||
        throw(ArgumentError("Invalid analyzer registry limits"))
    AnalyzerManager(Dict(),Dict(),ProcessManager(;max_handles=max_running),ReentrantLock(),max_records,max_bytes,max_running)
end

analyzer_scope(ctx::RuntimeContext,name::String) = (ctx.session_id,ctx.root,name)
analyzer_record_key(ctx::RuntimeContext,name::String,version::String) = (ctx.session_id,ctx.root,name,version)

function analyzer_record_view(record::AnalyzerRecord, manager::AnalyzerManager, ctx::RuntimeContext)
    definition = record.definition
    selected = get(manager.selected,analyzer_scope(ctx,definition.name),nothing) == definition.version
    Dict("definition"=>analyzer_definition_dict(definition;include_source=false,include_tests=false),
        "lifetime"=>"session","selected"=>selected,"created_at"=>record.created_at,
        "running"=>length(record.running),"validation"=>deepcopy(record.validation),"failure"=>record.failure)
end

function register_analyzer!(manager::AnalyzerManager,definition::AnalyzerDefinition,ctx::RuntimeContext)
    analyzer_definition_verify(definition)
    snapshot = deepcopy(definition)
    target = canonical(Dict("name"=>snapshot.name,"version"=>snapshot.version,"source_sha256"=>snapshot.source_sha256))
    authorize!(ctx,:dynamic,"analysis.register",target;reason="Register a session-scoped Julia analyzer candidate")
    check_cancelled(ctx.cancellation)
    permission_decision(ctx.permissions,PermissionRequest("analyzer-register-current",:dynamic,"analysis.register",target,"Recheck candidate registration")) != Deny ||
        throw(ShenScopeError(:permission,"Analyzer registration was revoked"))
    lock(manager.mutex) do
        key = analyzer_record_key(ctx,snapshot.name,snapshot.version)
        existing = get(manager.records,key,nothing)
        existing !== nothing && return analyzer_record_view(existing,manager,ctx)
        length(manager.records) < manager.max_records || throw(ShenScopeError(:capacity,"Analyzer registry is full"))
        sum(record.definition.bytes for record in values(manager.records);init=0) + snapshot.bytes <= manager.max_bytes ||
            throw(ShenScopeError(:capacity,"Analyzer registry byte capacity reached"))
        count(record -> record.owner == ctx.session_id && record.root == ctx.root,values(manager.records)) < 32 ||
            throw(ShenScopeError(:capacity,"Session analyzer capacity reached"))
        record = AnalyzerRecord(snapshot,ctx.session_id,ctx.root,utcstamp(),0,Dict(),nothing,nothing)
        manager.records[key] = record
        # Registration does not silently replace a previously selected version.
        get!(manager.selected,analyzer_scope(ctx,snapshot.name),snapshot.version)
        analyzer_record_view(record,manager,ctx)
    end
end

function analyzer_record!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing)
    analyzer_name_valid(name) || throw(ShenScopeError(:analysis,"Invalid analyzer name"))
    chosen = version === nothing ? get(manager.selected,analyzer_scope(ctx,String(name)),nothing) : String(version)
    chosen !== nothing && occursin(r"^[a-f0-9]{64}$",chosen) || throw(ShenScopeError(:analysis,"Analyzer version is not selected"))
    record = get(manager.records,analyzer_record_key(ctx,String(name),chosen),nothing)
    record !== nothing || throw(ShenScopeError(:analysis,"Analyzer version is not registered in this session"))
    record.owner == ctx.session_id && record.root == ctx.root || throw(ShenScopeError(:permission,"Analyzer belongs to another session"))
    analyzer_definition_verify(record.definition)
    record
end

function analyzer_list(manager::AnalyzerManager,ctx::RuntimeContext;offset=0,limit=50)
    offset isa Integer && !(offset isa Bool) && offset >= 0 && limit isa Integer && !(limit isa Bool) && 1 <= limit <= 100 ||
        throw(ShenScopeError(:arguments,"Invalid analyzer list pagination"))
    authorize!(ctx,:read,"analysis.list",ctx.root)
    lock(manager.mutex) do
        records = sort!([record for record in values(manager.records) if record.owner == ctx.session_id && record.root == ctx.root];
            by=record -> (record.definition.name,record.created_at,record.definition.version))
        selected = records[min(offset+1,length(records)+1):min(offset+limit,length(records))]
        Dict("total"=>length(records),"offset"=>offset,"next_offset"=>offset+limit < length(records) ? offset+limit : nothing,
            "analyzers"=>[analyzer_record_view(record,manager,ctx) for record in selected])
    end
end

function analyzer_inspect(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing)
    authorize!(ctx,:read,"analysis.inspect",ctx.root)
    lock(manager.mutex) do
        record = analyzer_record!(manager,name,ctx;version)
        merge(analyzer_record_view(record,manager,ctx),Dict("source"=>record.definition.source,
            "tests"=>deepcopy(analyzer_test_dict.(record.definition.tests))))
    end
end

function select_analyzer!(manager::AnalyzerManager,name::AbstractString,version::AbstractString,ctx::RuntimeContext)
    target = canonical(Dict("name"=>name,"version"=>version))
    authorize!(ctx,:dynamic,"analysis.select",target;reason="Select a session analyzer version")
    check_cancelled(ctx.cancellation)
    permission_decision(ctx.permissions,PermissionRequest("analyzer-select-current",:dynamic,"analysis.select",target,"Recheck analyzer selection")) != Deny ||
        throw(ShenScopeError(:permission,"Analyzer selection was revoked"))
    lock(manager.mutex) do
        record = analyzer_record!(manager,name,ctx;version)
        isempty(record.running) || throw(ShenScopeError(:runtime,"Analyzer candidate is still running"))
        manager.selected[analyzer_scope(ctx,record.definition.name)] = record.definition.version
        analyzer_record_view(record,manager,ctx)
    end
end

function remove_analyzer!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing)
    lock(manager.mutex) do
        record = analyzer_record!(manager,name,ctx;version)
        isempty(record.running) || throw(ShenScopeError(:runtime,"Cancel the running analyzer before removing it"))
        delete!(manager.records,analyzer_record_key(ctx,record.definition.name,record.definition.version))
        scope = analyzer_scope(ctx,record.definition.name)
        get(manager.selected,scope,nothing) == record.definition.version && delete!(manager.selected,scope)
        Dict("removed"=>true,"name"=>record.definition.name,"version"=>record.definition.version)
    end
end

function cleanup_analyzers!(manager::AnalyzerManager;session_id=nothing)
    lock(manager.mutex) do
        for (key,record) in collect(manager.records)
            session_id !== nothing && record.owner != session_id && continue
            for token in values(record.running);cancel!(token,"Analyzer registry closed");end
            delete!(manager.records,key)
        end
        for scope in collect(keys(manager.selected))
            (session_id === nothing || first(scope) == session_id) && delete!(manager.selected,scope)
        end
    end
    nothing
end
