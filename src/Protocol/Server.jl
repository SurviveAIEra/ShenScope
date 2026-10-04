mutable struct AgentRun
    context::RuntimeContext
    control::AgentControl
    task::Union{Nothing,Task}
end

mutable struct CoreServer
    root::String
    state_dir::String
    config_file::String
    config::Dict{String,Any}
    initialized::Bool
    stopping::Bool
    output::IO
    write_mutex::ReentrantLock
    mutex::ReentrantLock
    runs::Dict{String,AgentRun}
    contexts::Dict{String,RuntimeContext}
    approvals::Dict{String,Tuple{String,Channel{Symbol}}}
    credentials::Dict{String,String}
    tools::Vector{AbstractTool}
    provider_factory::Function
end

function CoreServer(root::AbstractString;state_dir=get(ENV,"SHENSCOPE_STATE_DIR",joinpath(homedir(),".local/state/shenscope")),
        config_file=config_path(),output=stdout,provider_factory=nothing)
    server=CoreServer(realpath(root),abspath(state_dir),abspath(config_file),load_config(;path=config_file),
        false,false,output,ReentrantLock(),ReentrantLock(),Dict{String,AgentRun}(),
        Dict{String,RuntimeContext}(),Dict{String,Tuple{String,Channel{Symbol}}}(),
        Dict{String,String}(),core_tools(),s->nothing)
    lookup=key->lock(server.mutex) do;get(server.credentials,key,get(ENV,key,""));end
    server.tools=core_tools(;config=server.config,config_source=server.config_file,credential_lookup=lookup)
    server.provider_factory=provider_factory===nothing ? s->begin
        agent_model_provider(server_models_tool(s))
    end : provider_factory
    workers = server_task_tool(server).manager
    worker_factory = provider_factory === nothing ? ctx->begin
        model = server_models_tool(server);agent_model_provider(model;role=model_worker_role(model))
    end : ctx->server.provider_factory(server)
    workers.executor = WorkExecutor(;tools=collect(values(workers.executor.tools)),provider_factory=worker_factory)
    return server
end

function rpc_notify(server::CoreServer,method::String,params)
    write_rpc(server.output,Dict("jsonrpc"=>"2.0","method"=>method,"params"=>params),server.write_mutex)
end

function server_event(server::CoreServer,event::AgentEvent)
    if event.kind==:permission_request
        lock(server.mutex) do
            length(server.approvals)<64 || throw(ShenScopeError(:permission,"Too many pending approvals"))
            server.approvals[event.payload["id"]]=(event.session_id,Channel{Symbol}(1))
        end
    end
    rpc_notify(server,"agent/event",Dict("sequence"=>event.sequence,"kind"=>String(event.kind),
        "session_id"=>event.session_id,"trace_id"=>event.trace_id,"timestamp"=>event.timestamp,"payload"=>event.payload))
end

function server_approval(server::CoreServer,session_id::String,token::CancellationToken,request::PermissionRequest)
    channel=lock(server.mutex) do
        pending=get(server.approvals,request.id,nothing)
        pending!==nothing || throw(ShenScopeError(:permission,"Approval request was not registered"))
        pending[2]
    end
    # The runtime event is emitted before this callback. Register the request
    # before yielding, so the next incoming RPC can resolve it reliably.
    try
        deadline=time()+300
        while !isready(channel)
            active = CURRENT_CONTEXT[]
            (server.stopping || iscancelled(token) || active !== nothing && iscancelled(active.cancellation) || time()>deadline) && return :deny
            sleep(0.025)
        end
        return take!(channel)
    finally
        lock(server.mutex) do;delete!(server.approvals,request.id);end
    end
end

function server_context(server::CoreServer,id::String)
    prior=get(server.contexts,id,nothing)
    token=CancellationToken()
    policy=prior===nothing ? permissions_from_config(server.config) : prior.permissions
    budget=prior===nothing ? BudgetLedger(limits_from_config(server.config)) : prior.budget
    ctx=RuntimeContext(server.root;session_id=id,state_dir=server.state_dir,cancellation=token,
        permissions=policy,budget,sandbox=sandbox_from_config(server.config),approve=r->server_approval(server,id,token,r),sink=e->server_event(server,e))
    prior!==nothing && (ctx.sequence=prior.sequence)
    server.contexts[id]=ctx
    return ctx
end

function session_view(session::Session;include_messages=true)
    result=Dict{String,Any}("id"=>session.id,"root"=>session.root,"title"=>session.title,
        "status"=>String(session.status),"revision"=>session.revision,"metadata"=>session.metadata,
        "usage"=>[Dict("input_tokens"=>u.input_tokens,"output_tokens"=>u.output_tokens,"cost"=>u.cost,
            "source"=>String(u.source)) for u in session.usage])
    include_messages && (result["messages"]=message_dict.(session.messages))
    return result
end

function server_session(server::CoreServer,params::AbstractDict)
    id=rpc_string(params,"session_id";max_bytes=128)
    session=load_session(server.state_dir,id)
    realpath(session.root)==server.root || throw(ShenScopeError(:permission,"Session belongs to another workspace"))
    return session
end

function idle_session(server::CoreServer,params::AbstractDict)
    session=server_session(server,params)
    haskey(server.runs,session.id) && throw(ShenScopeError(:session,"Session has an active run"))
    operations_running(server_extensions_tool(server).operations;session_id=session.id) &&
        throw(ShenScopeError(:extension_busy,"Finish this conversation's extension operation first"))
    operations_running(server_terminal_tool(server).manager.operations;session_id=session.id) &&
        throw(ShenScopeError(:terminal_busy,"Finish this conversation's terminal operation first"))
    operations_running(server_memory_tool(server).manager.operations;session_id=session.id) &&
        throw(ShenScopeError(:memory_busy,"Finish this conversation's memory operation first"))
    operations_running(server_security_tool(server).manager.operations;session_id=session.id) &&
        throw(ShenScopeError(:security_busy,"Finish this conversation's security operation first"))
    context_jobs_running(server_context_tool(server).manager; session_id=session.id) &&
        throw(ShenScopeError(:context_busy, "Finish this conversation's context operation first"))
    analyzer_jobs_running(server_analyzers_tool(server).manager;session_id=session.id) &&
        throw(ShenScopeError(:analysis,"Finish this conversation's analyzer operation first"))
    return session
end

function start_agent!(server::CoreServer,params::AbstractDict)
    extension_session=server_session(server,params)
    operations_running(server_extensions_tool(server).operations;session_id=extension_session.id) &&
        throw(ShenScopeError(:extension_busy,"Finish this conversation's extension operation before starting the agent"))
    session=server_session(server,params)
    haskey(server.runs,session.id) && throw(ShenScopeError(:session,"Session has an active run"))
    operations_running(server_terminal_tool(server).manager.operations;session_id=session.id) &&
        throw(ShenScopeError(:terminal_busy,"Finish this conversation's terminal operation before starting the agent"))
    operations_running(server_memory_tool(server).manager.operations;session_id=session.id) &&
        throw(ShenScopeError(:memory_busy,"Finish this conversation's memory operation first"))
    operations_running(server_security_tool(server).manager.operations;session_id=session.id) &&
        throw(ShenScopeError(:security_busy,"Finish this conversation's security operation first"))
    context_jobs_running(server_context_tool(server).manager; session_id=session.id) &&
        throw(ShenScopeError(:context_busy, "Finish this conversation's context operation before starting the agent"))
    analyzer_jobs_running(server_analyzers_tool(server).manager;session_id=session.id) &&
        throw(ShenScopeError(:analysis,"Finish this conversation's analyzer operation before starting the agent"))
    skillsmanager=server_skills_tool(server).manager
    lock(skillsmanager.mutex) do
        any(job->job.status==:running && job.context.session_id==session.id,values(skillsmanager.jobs)) &&
            throw(ShenScopeError(:skill_busy,"Finish the conversation's Skills operation before starting the agent"))
    end
    hooksmanager=server_hooks_tool(server).manager
    lock(hooksmanager.mutex) do
        any(job->job.status==:running && job.context.session_id==session.id,values(hooksmanager.jobs)) &&
            throw(ShenScopeError(:hook_busy,"Finish the conversation's Hook operation before starting the agent"))
    end
    length(server.runs)<8 || throw(ShenScopeError(:runtime,"Concurrent agent limit reached"))
    prompt=rpc_string(params,"prompt";max_bytes=1024*1024)
    isempty(strip(prompt)) && throw(RPCFault(-32602,"Prompt required"))
    provider=server.provider_factory(server)
    if haskey(params,"model_role")
        provider isa RoutedProvider || throw(ShenScopeError(:config,"Model role selection requires configured routing"))
        provider=RoutedProvider(provider.fleet;role=rpc_string(params,"model_role";max_bytes=64))
    end
    ctx=server_context(server,session.id)
    run=AgentRun(ctx,AgentControl(),nothing)
    server.runs[session.id]=run
    run.task=@async begin
        try
            run_agent!(provider,prompt,ctx;session,tools=server.tools,control=run.control)
        catch e
            # run_agent! reports sanitized error events. Keep full exceptions
            # away from the transport and credentials-bearing HTTP objects.
            if session.status==:idle
                server_event(server,emit!(RuntimeContext(server.root;session_id=session.id,state_dir=server.state_dir),
                    :session_error,Dict("code"=>e isa ShenScopeError ? String(e.code) : "internal","message"=>"Unable to start run")))
            end
        finally
            lock(server.mutex) do;delete!(server.runs,session.id);end
        end
    end
    return Dict("session_id"=>session.id,"started"=>true)
end

function capability_manifest()
    Dict("agent"=>true,"streaming_protocols"=>["openai_chat","openai_responses","anthropic","gemini","ollama"],
        "tools"=>["read","search","edit","write","patch","process","terminal","git","memory","security","project","diagnostics","analyzers","models","tasks","mcp","skills","hooks","context","extensions"],"session_journal"=>true,"memory"=>true,"memory_namespaces"=>true,"memory_retrieval_evidence"=>true,
        "execution_sandbox_policy"=>true,"execution_sandbox_probe"=>true,
        "permission_approvals"=>true,"config_profiles"=>true,"os_isolation"=>false,
        "mcp"=>true,"mcp_transports"=>["stdio","streamable_http"],"skills"=>true,"hooks"=>true,"project_intelligence"=>true,
        "julia_extension_lifecycle"=>true,"julia_optional_extensions"=>true,"extension_isolation"=>"trusted_in_process",
        "terminal_pty"=>terminal_platform_view(),
        "durable_tasks"=>true,"dynamic_analyzers"=>true,"context_checkpoints"=>true,"context_recovery"=>true,
        "model_catalog"=>true,"model_counting"=>true,"model_health"=>true,"model_routing"=>true,
        "isolated_compute"=>Dict("dependency_available"=>compute_seccomp_available(),"backend"=>"linux-seccomp-compute-v1",
            "enforcement_checked_per_child"=>true,"host_tools_isolated"=>false))
end

function dispatch_rpc(server::CoreServer,method::String,params::AbstractDict)
    if method=="initialize"
        server.initialized && throw(RPCFault(-32600,"Already initialized"))
        version=rpc_string(params,"protocol_version";default=PROTOCOL_VERSION,max_bytes=32)
        version==PROTOCOL_VERSION || throw(RPCFault(-32001,"Unsupported protocol version",Dict("supported"=>[PROTOCOL_VERSION])))
        server.initialized=true
        return Dict("protocol_version"=>PROTOCOL_VERSION,"server"=>Dict("name"=>"ShenScope","version"=>string(VERSION)),
            "root"=>server.root,"capabilities"=>capability_manifest())
    end
    server.initialized || throw(RPCFault(-32002,"Initialize first"))
    server.stopping && method!="shutdown" && throw(RPCFault(-32003,"Server is stopping"))
    # Service controllers own separate compilation/lifecycle boundaries. The
    # initialize/health path must not infer every model, parser and worker branch.
    startswith(method,"project/") && return Base.invokelatest(project_rpc,server,method,params)
    startswith(method,"extensions/") && return Base.invokelatest(extensions_rpc,server,method,params)
    startswith(method,"terminal/") && return terminal_rpc(server,method,params)
    startswith(method,"analyzers/") && return Base.invokelatest(analyzers_rpc,server,method,params)
    startswith(method,"models/") && return Base.invokelatest(models_rpc,server,method,params)
    startswith(method,"memory/") && return Base.invokelatest(memory_rpc,server,method,params)
    startswith(method,"security/") && return Base.invokelatest(security_rpc,server,method,params)
    startswith(method,"tasks/") && return Base.invokelatest(tasks_rpc,server,method,params)
    startswith(method,"mcp/") && return Base.invokelatest(mcp_rpc,server,method,params)
    startswith(method,"skills/") && return Base.invokelatest(skills_rpc,server,method,params)
    startswith(method,"hooks/") && return Base.invokelatest(hooks_rpc,server,method,params)
    startswith(method,"context/") && return Base.invokelatest(context_rpc,server,method,params)
    if method=="health"
        return Dict("ready"=>!server.stopping,"active_runs"=>length(server.runs),"pending_approvals"=>length(server.approvals))
    elseif method=="shutdown"
        server.stopping=true
        for run in values(server.runs);cancel!(run.context.cancellation);end
        return nothing
    elseif method=="config/get"
        revision=isfile(server.config_file) ? digest(read(server.config_file,String)) : digest("")
        return Dict("value"=>deepcopy(server.config),"sha256"=>revision)
    elseif method=="config/set"
        isempty(server.runs) || throw(ShenScopeError(:config,"Finish active runs before changing configuration"))
        for tool in server.tools
            if tool isa ProcessTool
                active=lock(tool.manager.mutex) do
                    any(handle->!process_exited(handle.process) || (handle.monitor!==nothing && !istaskdone(handle.monitor)),values(tool.manager.handles))
                end
                active && throw(ShenScopeError(:config,"Finish owned processes before changing configuration"))
            end
        end
        context_jobs_running(server_context_tool(server).manager) &&
            throw(ShenScopeError(:config, "Finish context operations before changing configuration"))
        analyzer_jobs_running(server_analyzers_tool(server).manager) &&
            throw(ShenScopeError(:config,"Finish analyzer operations before changing configuration"))
        operations_running(server_models_tool(server).manager.operations) &&
            throw(ShenScopeError(:config,"Finish model service operations before changing configuration"))
        operations_running(server_extensions_tool(server).operations) &&
            throw(ShenScopeError(:config,"Finish extension operations before changing configuration"))
        operations_running(server_terminal_tool(server).manager.operations) &&
            throw(ShenScopeError(:config,"Finish terminal operations before changing configuration"))
        taskmanager = server_task_tool(server).manager
        lock(taskmanager.mutex) do
            any(job -> job.status == :running, values(taskmanager.jobs)) &&
                throw(ShenScopeError(:config, "Finish task jobs before changing configuration"))
        end
        manager=server_project_tool(server).manager
        lock(manager.mutex) do
            any(job->job["status"]=="running",values(manager.jobs)) &&
                throw(ShenScopeError(:config,"Finish project jobs before changing configuration"))
            any(watch_live,values(manager.watches)) &&
                throw(ShenScopeError(:config,"Stop project watchers before changing configuration"))
            isempty(manager.mutations) || throw(ShenScopeError(:config,"Finish project tool operations before changing configuration"))
        end
        mcpmanager=server_mcp_tool(server).manager
        lock(mcpmanager.mutex) do
            any(job->job.status==:running,values(mcpmanager.jobs)) &&
                throw(ShenScopeError(:config,"Finish MCP jobs before changing configuration"))
        end
        skillsmanager=server_skills_tool(server).manager
        lock(skillsmanager.mutex) do
            any(job->job.status==:running,values(skillsmanager.jobs)) &&
                throw(ShenScopeError(:config,"Finish Skills operations before changing configuration"))
        end
        hooksmanager=server_hooks_tool(server).manager
        lock(hooksmanager.mutex) do
            (any(job->job.status==:running,values(hooksmanager.jobs)) || !isempty(hooksmanager.active)) &&
                throw(ShenScopeError(:config,"Finish Hook operations before changing configuration"))
        end
        operations_running(server_memory_tool(server).manager.operations) &&
            throw(ShenScopeError(:config,"Finish memory operations before changing configuration"))
        operations_running(server_security_tool(server).manager.operations) &&
            throw(ShenScopeError(:config,"Finish security operations before changing configuration"))
        value=get(params,"value",nothing)
        value isa AbstractDict || throw(RPCFault(-32602,"Configuration object required"))
        expected=rpc_string(params,"expected_sha256";max_bytes=64)
        revision=save_config!(Dict{String,Any}(value);path=server.config_file,expected_sha256=expected,
            before_write=()->begin;cleanup_mcp!(mcpmanager);cleanup_skills!(skillsmanager);cleanup_hooks!(hooksmanager);cleanup_context!(server_context_tool(server).manager);cleanup_analyzers!(server_analyzers_tool(server).manager);close_extension_registry!(server_extensions_tool(server).registry);close_operations!(server_extensions_tool(server).operations);end)
        server.config=load_config(;path=server.config_file)
        for (index,tool) in pairs(server.tools)
            if tool isa MemoryTool || tool isa SecurityTool || tool isa TerminalTool
                if tool isa MemoryTool;cleanup_memory!(tool.manager)
                elseif tool isa SecurityTool;cleanup_execution!(tool.manager)
                else;cleanup_terminals!(tool.manager;close_manager=true);end
                replacement=tool isa MemoryTool ? MemoryTool() : tool isa SecurityTool ? SecurityTool() : TerminalTool()
                server.tools[index]=replacement
                server_task_tool(server).manager.executor.tools[tool_name(replacement)]=replacement
            end
        end
        reset_models_tool!(server_models_tool(server),server.config)
        mcpmanager.specs=mcp_specs_from_config(server.config)
        skillsmanager.config=skill_config(server.config)
        hooksmanager.config=hook_config(server.config)
        hooksmanager.config_source_digest=revision
        server_context_tool(server).manager.config=context_config(server.config)
        empty!(server.contexts)
        rpc_notify(server,"config/changed",Dict("sha256"=>revision))
        return Dict("sha256"=>revision)
    elseif method=="credentials/set"
        variable=rpc_string(params,"variable";max_bytes=128)
        occursin(r"^[A-Za-z_][A-Za-z0-9_]*$",variable) || throw(RPCFault(-32602,"Invalid credential variable"))
        value=rpc_string(params,"value";max_bytes=16384)
        lock(server.mutex) do
            isempty(value) ? delete!(server.credentials,variable) : (server.credentials[variable]=value)
        end
        invalidate_model_catalogs!(server_models_tool(server).manager;reason="Model credentials changed")
        invalidate_model_circuits!(server_models_tool(server).provider.runtime.circuits)
        invalidate_model_fleet_credentials!(server_models_tool(server).fleet)
        return Dict("configured"=>!isempty(value))
    elseif method=="credentials/status"
        variable=rpc_string(params,"variable";default=server.config["provider"]["key_env"],max_bytes=128)
        return Dict("variable"=>variable,"configured"=>lock(server.mutex) do
            !isempty(get(server.credentials,variable,get(ENV,variable,"")))
        end)
    elseif method=="sessions/list"
        sessions=list_sessions(server.state_dir;search=rpc_string(params,"search";default="",max_bytes=1024),
            include_archived=get(params,"include_archived",false)===true)
        return [s for s in sessions if s["root"]==server.root]
    elseif method=="sessions/create"
        id=string(uuid4());ctx=server_context(server,id)
        title=rpc_string(params,"title";default="New conversation",max_bytes=512)
        return session_view(new_session(ctx;title))
    elseif method in ("sessions/get","sessions/export")
        return session_view(server_session(server,params))
    elseif method=="sessions/rename"
        session=idle_session(server,params)
        rename_session!(session,rpc_string(params,"title";max_bytes=512))
        return session_view(session;include_messages=false)
    elseif method in ("sessions/archive","sessions/pin")
        session=idle_session(server,params)
        value=get(params,"value",true)
        value isa Bool || throw(RPCFault(-32602,"Boolean value required"))
        key=method=="sessions/archive" ? "archived" : "pinned"
        session_record!(session,"metadata",Dict(key=>value))
        return Dict(key=>value)
    elseif method=="sessions/branch"
        session=idle_session(server,params)
        through=get(params,"through",length(session.messages))
        through isa Integer || throw(RPCFault(-32602,"Integer boundary required"))
        child=branch_session(session,server_context(server,string(uuid4()));through)
        return session_view(child)
    elseif method=="agent/start"
        return start_agent!(server,params)
    elseif method in ("agent/cancel","agent/steer")
        id=rpc_string(params,"session_id";max_bytes=128)
        run=get(server.runs,id,nothing)
        run===nothing && throw(ShenScopeError(:session,"No active run"))
        method=="agent/cancel" ? cancel!(run.context.cancellation) : steer!(run.control,rpc_string(params,"prompt"))
        return Dict("accepted"=>true)
    elseif method=="permissions/respond"
        id=rpc_string(params,"request_id";max_bytes=128)
        session_id=rpc_string(params,"session_id";max_bytes=128)
        decision=Symbol(rpc_string(params,"decision";max_bytes=16))
        decision in (:once,:session,:deny) || throw(RPCFault(-32602,"Invalid decision"))
        lock(server.mutex) do
            pending=get(server.approvals,id,nothing)
            pending===nothing && throw(ShenScopeError(:permission,"Approval no longer pending"))
            pending[1]==session_id || throw(ShenScopeError(:permission,"Approval belongs to another session"))
            isready(pending[2]) && throw(ShenScopeError(:permission,"Approval already answered"))
            put!(pending[2],decision)
        end
        return Dict("accepted"=>true)
    elseif method=="tools/list"
        return declaration.(server.tools)
    elseif method=="runtime/status"
        return Dict("active_sessions"=>collect(keys(server.runs)),"contexts"=>length(server.contexts),
            "budgets"=>Dict(id=>budget_status(ctx.budget) for (id,ctx) in server.contexts),
            "security"=>execution_sandbox_view(sandbox_from_config(server.config)),"capabilities"=>capability_manifest())
    end
    throw(RPCFault(-32601,"Method not found"))
end

function handle_rpc(server::CoreServer,message::AbstractDict)
    id=get(message,"id",nothing)
    try
        params=validate_rpc(message)
        result=dispatch_rpc(server,message["method"],params)
        haskey(message,"id") && write_rpc(server.output,Dict("jsonrpc"=>"2.0","id"=>id,"result"=>result),server.write_mutex)
    catch e
        fault=e isa RPCFault ? e : e isa ShenScopeError ? RPCFault(-32010,e.message,Dict("code"=>String(e.code))) :
            e isa ArgumentError ? RPCFault(-32602,"Invalid parameter values") : RPCFault(-32603,"Core request failed")
        # Invalid envelopes require a null-ID error, while valid notifications
        # never produce responses.
        if haskey(message,"id") || fault.code in (-32700,-32600)
            error=Dict("code"=>fault.code,"message"=>fault.message)
            fault.data!==nothing && (error["data"]=fault.data)
            write_rpc(server.output,Dict("jsonrpc"=>"2.0","id"=>fault.code==-32600 ? nothing : id,"error"=>error),server.write_mutex)
        end
    end
end

function stop_server!(server::CoreServer)
    server.stopping=true
    for run in collect(values(server.runs));cancel!(run.context.cancellation);end
    for run in collect(values(server.runs));run.task!==nothing && wait(run.task);end
    cleanup_tasks!(server_task_tool(server).manager)
    cleanup_mcp!(server_mcp_tool(server).manager)
    cleanup_skills!(server_skills_tool(server).manager)
    cleanup_hooks!(server_hooks_tool(server).manager)
    cleanup_context!(server_context_tool(server).manager)
    for tool in server.tools
        tool isa ProjectTool && cleanup_projects!(tool.manager)
        tool isa AnalyzersTool && cleanup_analyzers!(tool.manager)
        tool isa ModelsTool && cleanup_models_tool!(tool)
        tool isa MemoryTool && cleanup_memory!(tool.manager)
        tool isa SecurityTool && cleanup_execution!(tool.manager)
        tool isa TerminalTool && cleanup_terminals!(tool.manager;close_manager=true)
        if tool isa ExtensionsTool
            close_operations!(tool.operations);close_extension_registry!(tool.registry)
        end
        tool isa ProcessTool || continue
        for id in keys(server.contexts);cleanup_processes!(tool.manager,id);end
    end
    empty!(server.credentials)
end

function serve_stdio(server::CoreServer;input=stdin)
    try
        while !server.stopping
            message=read_rpc(input)
            message===nothing && break
            handle_rpc(server,message)
            yield()
        end
    catch e
        e isa RPCFault || rethrow()
        write_rpc(server.output,Dict("jsonrpc"=>"2.0","id"=>nothing,
            "error"=>Dict("code"=>e.code,"message"=>e.message)),server.write_mutex)
    finally
        stop_server!(server)
    end
    return 0
end
