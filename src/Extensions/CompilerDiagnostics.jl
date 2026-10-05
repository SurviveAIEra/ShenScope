struct CompilerTarget
    name::String
    callable::Function
    arguments::Type
end
function compiler_targets()
    [CompilerTarget("digest_string",digest,Tuple{String}),
     CompilerTarget("canonical_dictionary",canonical,Tuple{Dict{String,Any}}),
     CompilerTarget("cliptext_string",cliptext,Tuple{String,Int}),
     CompilerTarget("symbol_identity",symbol_id,Tuple{String,Int}),
     CompilerTarget("resolve_call_reference",resolve_reference,Tuple{ProjectState,CallReference}),
     CompilerTarget("remove_graph_edge",remove_edge!,Tuple{ProjectState,String})]
end
function compiler_target(name::AbstractString)
    index=findfirst(t->t.name==name,compiler_targets())
    index===nothing && throw(ShenScopeError(:diagnostics,"Unknown compiler diagnostic target"))
    compiler_targets()[index]
end

mutable struct DiagnosticBuffer <: IO
    bytes::Vector{UInt8}
    total::Int
    limit::Int
end
Base.isopen(::DiagnosticBuffer)=true
Base.iswritable(::DiagnosticBuffer)=true
function Base.write(io::DiagnosticBuffer,byte::UInt8)
    io.total+=1;length(io.bytes)<io.limit && push!(io.bytes,byte);1
end
function Base.unsafe_write(io::DiagnosticBuffer,data::Ptr{UInt8},count::UInt)
    retained=min(Int(count),io.limit-length(io.bytes));io.total+=Int(count)
    for index in 1:retained;push!(io.bytes,unsafe_load(data,index));end
    count
end
function diagnostic_text(io::DiagnosticBuffer)
    bytes=copy(io.bytes)
    # A byte limit may split the last Unicode code point.
    while !isempty(bytes) && !isvalid(String(copy(bytes)));pop!(bytes);end
    String(bytes)
end
function inference_type_summary(type)
    small_union=type isa Union && length(Base.uniontypes(type))<=4 && all(isconcretetype,Base.uniontypes(type))
    Dict("type"=>cliptext(string(type),2048),"concrete"=>isconcretetype(type),"small_concrete_union"=>small_union,
        "bottom"=>type===Union{})
end
function compiler_report(name::AbstractString;mode="typed",max_ir_bytes=64*1024,max_statements=2048)
    mode=="graph" && return compiler_ir_report(name;limits=CompilerIRLimits(;max_statements))
    mode in ("typed","lowered") && 1024<=max_ir_bytes<=128*1024 || throw(ShenScopeError(:diagnostics,"Invalid compiler diagnostic limits"))
    target=compiler_target(name);started=time_ns()
    entries=mode=="typed" ? Base.code_typed(target.callable,target.arguments;optimize=false) : Base.code_lowered(target.callable,target.arguments)
    io=DiagnosticBuffer(UInt8[],0,max_ir_bytes);methods=Dict{String,Any}[]
    for entry in entries[1:min(length(entries),8)]
        code=mode=="typed" ? entry.first : entry
        summary=Dict{String,Any}("statements"=>length(code.code))
        if mode=="typed"
            summary["return"]=inference_type_summary(entry.second)
            slots=code.slottypes===nothing ? Any[] : collect(code.slottypes)
            summary["any_slots"]=count(t->t===Any,slots)
            summary["nonconcrete_slots"]=count(t->t!==Union{} && !(t isa Core.Const) && !(t isa Type && isconcretetype(t)),slots)
            summary["slot_count"]=length(slots)
        end
        push!(methods,summary);show(IOContext(io,:limit=>true,:compact=>true),MIME("text/plain"),entry);write(io,UInt8('\n'))
    end
    Dict("target"=>target.name,"arguments"=>string(target.arguments),"mode"=>mode,"methods"=>methods,
        "ir"=>diagnostic_text(io),"ir_total_bytes"=>io.total,"truncated"=>io.total>max_ir_bytes || length(entries)>8,
        "elapsed_seconds"=>(time_ns()-started)/1e9,"julia_version"=>string(Base.VERSION),
        "limits"=>["Inference of explicitly listed trusted Core methods; project source is not loaded.",
            "Concrete return types do not prove all intermediates are type-stable or that the algorithm is fast."])
end

function compiler_worker_main()
    while !eof(stdin)
        raw=bounded_record(stdin,8192);isempty(raw) && break
        endswith(raw,"\n") || return 1
        identifier=nothing
        response=try
            request=parsejson(raw);identifier=request["id"]
            operation=request["operation"]
            result=if operation=="compiler"
                allowed=Set(["id","operation","target","mode","max_ir_bytes","max_statements","source_fingerprint"])
                all(key->key in allowed,keys(request)) || throw(ShenScopeError(:diagnostics,"Unknown compiler diagnostics field"))
                report=compiler_report(request["target"];mode=get(request,"mode","typed"),
                    max_ir_bytes=get(request,"max_ir_bytes",64*1024),max_statements=get(request,"max_statements",2048))
                if get(request,"mode","typed")=="graph"
                    report["source"]["fingerprint"]==get(request,"source_fingerprint",nothing) ||
                        throw(ShenScopeError(:conflict,"Compiler caller source fingerprint is stale"))
                elseif haskey(request,"source_fingerprint")
                    throw(ShenScopeError(:diagnostics,"A source fingerprint is supported only for structured compiler graphs"))
                end
                report
            elseif operation=="profile"
                allowed=Set(["id","operation","target","fixture","limits","source_fingerprint"])
                all(key->key in allowed,keys(request)) || throw(ShenScopeError(:diagnostics,"Unknown profiling field"))
                fingerprint=compiler_archive_hash(get(request,"source_fingerprint",nothing),"profile source fingerprint")
                limits=compiler_profile_limits_from_view(request["limits"])
                compiler_profile_report(request["target"];fixture=get(request,"fixture","default"),limits,
                    expected_source_fingerprint=fingerprint)
            else
                throw(ShenScopeError(:diagnostics,"Unknown diagnostics operation"))
            end
            Dict("id"=>identifier,"result"=>result)
        catch error
            Dict("id"=>identifier,"error"=>Dict("message"=>error isa ShenScopeError ? error.message : "Compiler diagnostics failed"))
        end
        println(stdout,canonical(response));flush(stdout)
    end
    0
end
function compiler_diagnostic_checkpoint(ctx::RuntimeContext,target;source_root=nothing)
    check_cancelled(ctx.cancellation);check_budget(ctx.budget)
    permission_decision(ctx.permissions,PermissionRequest("compiler-result-current",:read,"runtime.diagnostics",ctx.root,
        "Current compiler result read permission"))==Deny && throw(ShenScopeError(:permission,"Compiler evidence reads were revoked"))
    permission_decision(ctx.permissions,PermissionRequest("compiler-current",:dynamic,"runtime.diagnostics",target,
        "Current trusted Core diagnostic permission"))==Deny && throw(ShenScopeError(:permission,"Trusted Core diagnostic execution was revoked"))
    if source_root!==nothing
        permission_decision(ctx.permissions,PermissionRequest("compiler-source-current",:read,"runtime.source",source_root,
            "Current compiler source evidence permission"))==Deny && throw(ShenScopeError(:permission,"Compiler source reads were revoked"))
    end
end

function run_trusted_runtime_diagnostic(validate::Function,ctx::RuntimeContext,selected::CompilerTarget;
        operation::String,request::AbstractDict,timeout=60.0,pin_source=true,reason::String)
    operation in ("compiler","profile") && get(request,"target",nothing)==selected.name &&
        timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.1<=timeout<=120 ||
        throw(ShenScopeError(:diagnostics,"Invalid trusted diagnostic request or timeout"))
    ctx.sandbox isa HostSandbox || throw(ShenScopeError(:capability,"Trusted Core diagnostics do not support the configured restricted sandbox"))
    authorize!(ctx,:dynamic,"runtime.diagnostics",selected.name;reason)
    check_cancelled(ctx.cancellation)
    project=runtime_core_root()
    snapshot=pin_source ? runtime_source_snapshot(ctx;root=project) : nothing
    argv=[first(Base.julia_cmd().exec),"--startup-file=no","--history-file=no","--compiled-modules=existing","--threads=1",
        "--project="*project,"-e","using ShenScope; exit(ShenScope.compiler_worker_main())"]
    worker=BackendWorker(argv)
    try
        worker_start!(worker,ctx;reason="Start a separate trusted Core diagnostic helper")
        arguments=deepcopy(Dict{String,Any}(request))
        snapshot===nothing || (arguments["source_fingerprint"]=snapshot.fingerprint)
        checkpoint=()->compiler_diagnostic_checkpoint(ctx,selected.name;source_root=snapshot===nothing ? nothing : snapshot.root)
        result=worker_request(worker,operation,arguments,ctx;timeout,checkpoint)
        checkpoint()
        validate(result,snapshot)
        if pin_source
            runtime_source_snapshot(ctx;root=project,authorized=true).fingerprint==snapshot.fingerprint ||
                throw(ShenScopeError(:conflict,"Core source changed before diagnostic publication"))
        end
        checkpoint()
        execution=Dict("separate_process"=>true,"os_sandbox"=>false,"timeout_seconds"=>timeout)
        Dict("report"=>result,"execution"=>execution)
    finally;worker_close!(worker);end
end

function run_compiler_diagnostic(ctx::RuntimeContext,target::AbstractString;mode="typed",timeout=60.0,
        max_ir_bytes=64*1024,max_statements=2048)
    selected=compiler_target(target)
    mode in ("typed","lowered","graph") && max_ir_bytes isa Integer && !(max_ir_bytes isa Bool) &&
        1024<=max_ir_bytes<=128*1024 || throw(ShenScopeError(:diagnostics,"Invalid compiler diagnostic limits"))
    limits=CompilerIRLimits(;max_statements)
    request=Dict{String,Any}("target"=>target,"mode"=>mode,"max_ir_bytes"=>max_ir_bytes,"max_statements"=>max_statements)
    result=run_trusted_runtime_diagnostic(ctx,selected;operation="compiler",request,timeout,pin_source=mode=="graph",
            reason="Infer trusted Core methods in a separate Julia process") do report,snapshot
        mode=="graph" && compiler_ir_validate_report(report,selected,snapshot;limits)
    end
    report=result["report"]
    emit!(ctx,:compiler_diagnostic,Dict("target"=>target,"mode"=>mode,"elapsed_seconds"=>report["elapsed_seconds"],
        "truncated"=>mode=="graph" ? report["methods_truncated"] : report["truncated"]))
    mode=="graph" ? result : merge(report,Dict("execution"=>result["execution"]))
end

function run_profile_diagnostic(ctx::RuntimeContext,target::AbstractString;fixture="default",timeout=60.0,
        iterations=8,repetitions=3,max_samples=128,max_frames=4,sample_rate=1.0)
    selected=compiler_profile_target(target)
    compiler_profile_fixture(target,fixture)
    limits=CompilerProfileLimits(;iterations,repetitions,max_samples,max_frames,sample_rate)
    request=Dict{String,Any}("target"=>target,"fixture"=>fixture,"limits"=>compiler_profile_limits_view(limits))
    run_trusted_runtime_diagnostic(ctx,selected;operation="profile",request,timeout,
            reason="Execute fixed trusted Core fixtures and measure runtime allocations in a separate Julia process") do report,snapshot
        compiler_profile_validate_report(report,selected,snapshot;limits,fixture)
    end
end
