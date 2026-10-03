function failed_call(call::ToolCall,error::AbstractString)
    ToolResult(call.id,false,nothing,String(error))
end

function dispatch_call(tools::Dict{String,AbstractTool},call::ToolCall,ctx::RuntimeContext)
    t=get(tools,call.name,nothing)
    t===nothing && return failed_call(call,"Unknown tool: " * call.name)
    try
        return execute_call(t,call,ctx)
    catch e
        e isa InterruptException && rethrow()
        return failed_call(call,e isa ShenScopeError ? sprint(showerror,e) : "Tool dispatch failed")
    end
end

function execute_batch(tools::Dict{String,AbstractTool},calls::Vector{ToolCall},ctx::RuntimeContext;
        concurrency=4)
    concurrency>0 || throw(ArgumentError("Concurrency must be positive"))
    results=Vector{ToolResult}(undef,length(calls))
    next=1
    while next<=length(calls)
        if iscancelled(ctx.cancellation)
            for i in next:length(calls);results[i]=failed_call(calls[i],"Cancelled before dispatch");end
            break
        end
        t=get(tools,calls[next].name,nothing)
        if t===nothing || execution_mode(t)!=:parallel
            results[next]=dispatch_call(tools,calls[next],ctx);next+=1;continue
        end
        finish=next
        while finish<=length(calls)
            tool=get(tools,calls[finish].name,nothing)
            (tool===nothing || execution_mode(tool)!=:parallel) && break
            finish+=1
        end
        # Queue indices rather than materializing tasks for every tool call.
        jobs=Channel{Int}(finish-next)
        for i in next:finish-1;put!(jobs,i);end
        close(jobs)
        workers=Task[]
        for _ in 1:min(concurrency,finish-next)
            push!(workers,@async begin
                for i in jobs
                    results[i]=iscancelled(ctx.cancellation) ? failed_call(calls[i],"Cancelled before dispatch") :
                        dispatch_call(tools,calls[i],ctx)
                end
            end)
        end
        foreach(wait,workers)
        next=finish
    end
    return results
end

function core_tools(; tasks = true)
    process=ProcessTool()
    tools = AbstractTool[ReadTool(),SearchTool(),EditTool(),WriteTool(),PatchTool(),process,GitTool(process),MemoryTool(),ProjectTool(),DiagnosticsTool()]
    tasks && push!(tools, TaskTool(WorkExecutor(; tools)))
    tools
end
