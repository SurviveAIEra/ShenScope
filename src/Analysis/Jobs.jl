function analyzer_job_view(job::AnalyzerJob)
    Dict("job_id"=>job.id,"action"=>job.action,"session_id"=>job.context.session_id,
        "status"=>String(job.status),"result"=>deepcopy(job.result),"error"=>job.error,
        "finished_at"=>job.finished_at,"result_bytes"=>job.result_bytes)
end

function analyzer_jobs_running(manager::AnalyzerManager;session_id=nothing)
    lock(manager.mutex) do
        any(job -> job.status == :running && (session_id === nothing || job.context.session_id == session_id),values(manager.jobs)) ||
            any(record -> !isempty(record.running) && (session_id === nothing || record.owner == session_id),values(manager.records))
    end
end

function start_analyzer_job!(tool::AnalyzersTool,args::AbstractDict,owner::RuntimeContext)
    validate_schema(args,tool_schema(tool))
    context = child_context(owner)
    arguments = deepcopy(args)
    job = AnalyzerJob(string(uuid4()),String(args["action"]),context,:running,nothing,nothing,nothing,0.0,0)
    manager = tool.manager
    lock(manager.mutex) do
        count(value -> value.status == :running,values(manager.jobs)) < manager.max_running ||
            throw(ShenScopeError(:capacity,"Analyzer job concurrency limit reached"))
        any(value -> value.status == :running && value.context.session_id == owner.session_id && value.context.root == owner.root,values(manager.jobs)) &&
            throw(ShenScopeError(:runtime,"An analyzer operation is already running in this conversation"))
        if length(manager.jobs) >= 64
            completed = sort!([value for value in values(manager.jobs) if value.status != :running];by=value -> value.finished_at)
            isempty(completed) && throw(ShenScopeError(:capacity,"Analyzer job retention capacity reached"))
            delete!(manager.jobs,first(completed).id)
        end
        manager.jobs[job.id] = job
    end
    job.task = @async with_context(context) do
        try
            result = execute(tool,arguments,context)
            check_cancelled(context.cancellation)
            size = ncodeunits(canonical(result))
            size <= 4 * 1024^2 || throw(ShenScopeError(:capacity,"Analyzer job result exceeds transport capacity"))
            lock(manager.mutex) do
                completed = sort!([value for value in values(manager.jobs) if value.status != :running];by=value -> value.finished_at)
                retained = sum(value.result_bytes for value in completed;init=0)
                for prior in completed
                    retained + size <= 16 * 1024^2 && break
                    delete!(manager.jobs,prior.id);retained -= prior.result_bytes
                end
                job.result = deepcopy(result);job.result_bytes = size;job.status = :complete;job.finished_at = time()
            end
            emit!(context,:analyzers_job_completed,analyzer_job_view(job))
        catch cause
            lock(manager.mutex) do
                job.status = iscancelled(context.cancellation) ? :cancelled : :failed
                job.error = cause isa ShenScopeError ? cause.message : "Analyzer operation failed"
                job.finished_at = time()
            end
            emit!(context,:analyzers_job_failed,analyzer_job_view(job))
        end
    end
    Dict("job_id"=>job.id,"started"=>true)
end

function analyzer_job(manager::AnalyzerManager,id::AbstractString,ctx::RuntimeContext;cancel=false)
    lock(manager.mutex) do
        job = get(manager.jobs,String(id),nothing)
        job !== nothing || throw(ShenScopeError(:analysis,"Analyzer job does not exist"))
        job.context.session_id == ctx.session_id && job.context.root == ctx.root && job.context.state_dir == ctx.state_dir ||
            throw(ShenScopeError(:permission,"Analyzer job belongs to another conversation or workspace"))
        cancel && cancel!(job.context.cancellation,"Analyzer job cancelled by owning conversation")
        analyzer_job_view(job)
    end
end
