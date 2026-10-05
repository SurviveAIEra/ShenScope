mutable struct AgentControl
    steering::Channel{String}
    mutex::ReentrantLock
end
AgentControl()=AgentControl(Channel{String}(32),ReentrantLock())
function steer!(control::AgentControl,text::AbstractString)
    isempty(strip(text)) && throw(ShenScopeError(:input,"Empty steering message"))
    ncodeunits(text)<=64*1024 || throw(ShenScopeError(:input,"Steering message too long"))
    lock(control.mutex) do
        Base.n_avail(control.steering)<32 || throw(ShenScopeError(:input,"Steering queue full"))
        put!(control.steering,String(text))
    end
end

function restore_budget!(ctx::RuntimeContext,session::Session)
    lock(ctx.budget.mutex) do
        # Restore only an untouched ledger, preserving shared parent accounting.
        ctx.budget.steps==0 && isempty(ctx.budget.reservations) || return
        snapshot=get(session.metadata,"budget",nothing)
        if snapshot!==nothing
            ctx.budget.steps=snapshot["steps"]
            ctx.budget.tokens=snapshot["tokens"]
            ctx.budget.cost=snapshot["cost"]
            ctx.budget.reported_cost=get(snapshot,"reported_cost",0.0)
        else
            ctx.budget.tokens=sum(u.input_tokens+u.output_tokens for u in session.usage;init=0)
            ctx.budget.cost=sum(u.cost for u in session.usage;init=0.0)
        end
    end
end

function save_budget!(session::Session,ctx::RuntimeContext)
    status=budget_status(ctx.budget)
    session_record!(session,"metadata",Dict("budget"=>status))
    session.metadata["budget"]=status
end

function run_agent!(provider::AbstractModelProvider,prompt::AbstractString,ctx::RuntimeContext;session=nothing,kwargs...)
    selected=session===nothing ? new_session(ctx;title=cliptext(prompt,128)) : session
    entered=false
    try
        return with_session_run_fence(selected,ctx) do
            setting=agent_mode_setting(selected)
            entered=true
            with_agent_execution_mode(setting["mode"]) do
                run_agent_owned!(provider,prompt,ctx;session=selected,kwargs...)
            end
        end
    catch error
        entered || emit!(ctx,:session_error,Dict("code"=>error isa ShenScopeError ? String(error.code) : "internal",
            "message"=>error isa ShenScopeError ? error.message : "Unable to acquire conversation execution fence"))
        rethrow()
    end
end

function run_agent_owned!(provider::AbstractModelProvider,prompt::AbstractString,ctx::RuntimeContext;
        session=nothing,tools=core_tools(),control=AgentControl(),max_output=min(2048,capabilities(provider).max_output),
        options=Dict{String,Any}(),concurrency=4,context_bytes=256*1024)
    s=session===nothing ? new_session(ctx;title=cliptext(prompt,128)) : session
    s.id==ctx.session_id && realpath(s.root)==ctx.root || throw(ShenScopeError(:session,"Runtime session identity mismatch"))
    s.status==:running && throw(ShenScopeError(:session,"Session is already running"))
    restore_budget!(ctx,s);recover_tool_pairs!(s)
    !isempty(prompt) && add_message!(s,Message(:user,prompt))
    registry=Dict{String,AbstractTool}(tool_name(t)=>t for t in tools)
    length(registry)==length(tools) || throw(ShenScopeError(:extension,"Duplicate tool names"))
    set_status!(s,:running)
    emit!(ctx,:session_started,Dict("id"=>s.id,"provider"=>provider_name(provider),"agent_mode"=>agent_mode_name(current_agent_mode())))
    last_signature="";repeats=0
    try
        return with_context(ctx) do
          with_lifecycle_hooks(tools,ctx) do
           try
            enforce_hook_outcomes!(run_lifecycle_hooks!(HookSessionStart,ctx;metadata=Dict("provider"=>provider_name(provider),"status"=>"running")))
            while true
                check_cancelled(ctx.cancellation)
                while isready(control.steering)
                    text=take!(control.steering)
                    add_message!(s,Message(:user,text));emit!(ctx,:steering_applied,Dict("text"=>text))
                end
                enforce_hook_outcomes!(run_lifecycle_hooks!(HookBeforeModel,ctx;metadata=Dict("provider"=>provider_name(provider),"step"=>budget_status(ctx.budget)["steps"])))
                bind_request_sessions!(tools, s, ctx)
                hook_context=take_hook_context!()
                available=active_tools(tools,ctx)
                registry=Dict{String,AbstractTool}(tool_name(t)=>t for t in available)
                schemas=declaration.(available)
                model_result=request_with_context_recovery!(provider,s,ctx;
                    tools,schemas,max_output,options,context_bytes,hook_context)
                add_message!(s,model_result.message)
                observe_lifecycle_hooks!(HookAfterModel,ctx;metadata=Dict("provider"=>provider_name(provider),
                    "finish"=>String(model_result.finish),"input_tokens"=>model_result.usage.input_tokens,"output_tokens"=>model_result.usage.output_tokens))
                check_cancelled(ctx.cancellation)
                calls=model_result.message.calls
                if isempty(calls)
                    model_result.finish==:stop || throw(ShenScopeError(:incomplete,"Model did not complete the turn"))
                    set_status!(s,:complete)
                    emit!(ctx,:session_completed,Dict("text"=>model_result.message.text,"budget"=>budget_status(ctx.budget)))
                    return model_result.message.text
                end
                prior_ids=Set(c.id for m in s.messages[1:end-1] for c in m.calls)
                any(c->c.id in prior_ids,calls) && throw(ShenScopeError(:protocol,"Model reused a prior tool call ID"))
                results=execute_batch(registry,calls,ctx;concurrency)
                for result in results
                    artifact=archive_output!(ctx,result)
                    add_message!(s,Message(:tool,trim_tool_result(result;artifact_sha256=artifact);call_id=result.id))
                end
                hook_stop_requested() && throw(ShenScopeError(:hook_stopped,"Configured Hook requested a stop after the tool batch"))
                signature=digest(canonical([Dict("name"=>call.name,"args"=>call.arguments,
                    "ok"=>result.ok,"value"=>result.value,"error"=>result.error) for (call,result) in zip(calls,results)]))
                repeats=signature==last_signature ? repeats+1 : 0
                last_signature=signature
                repeats>=2 && emit!(ctx,:no_progress,Dict("identical_result_batches"=>repeats+1))
                repeats>=5 && throw(ShenScopeError(:no_progress,"Repeated tool batches returned identical evidence"))
            end
           finally
            terminal_status = s.status == :running ? iscancelled(ctx.cancellation) ? :cancelled : :interrupted : s.status
            observe_lifecycle_hooks!(HookSessionEnd,ctx;metadata=Dict("status"=>String(terminal_status)))
           end
          end
        end
    catch e
        recover_tool_pairs!(s)
        set_status!(s,iscancelled(ctx.cancellation) ? :cancelled : :interrupted)
        emit!(ctx,:session_error,Dict("code"=>e isa ShenScopeError ? String(e.code) : "internal",
            "message"=>e isa ShenScopeError ? e.message : "Agent execution failed"))
        rethrow()
    end
end
