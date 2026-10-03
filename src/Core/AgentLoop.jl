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

function run_agent!(provider::AbstractModelProvider,prompt::AbstractString,ctx::RuntimeContext;
        session=nothing,tools=core_tools(),control=AgentControl(),max_output=2048,
        options=Dict{String,Any}(),concurrency=4,context_bytes=256*1024)
    s=session===nothing ? new_session(ctx;title=cliptext(prompt,128)) : session
    s.id==ctx.session_id && realpath(s.root)==ctx.root || throw(ShenScopeError(:session,"Runtime session identity mismatch"))
    s.status==:running && throw(ShenScopeError(:session,"Session is already running"))
    restore_budget!(ctx,s);recover_tool_pairs!(s)
    !isempty(prompt) && add_message!(s,Message(:user,prompt))
    registry=Dict{String,AbstractTool}(tool_name(t)=>t for t in tools)
    length(registry)==length(tools) || throw(ShenScopeError(:extension,"Duplicate tool names"))
    schemas=[declaration(t) for t in tools]
    set_status!(s,:running)
    emit!(ctx,:session_started,Dict("id"=>s.id,"provider"=>provider_name(provider)))
    last_signature="";repeats=0
    try
        return with_context(ctx) do
            while true
                check_cancelled(ctx.cancellation)
                while isready(control.steering)
                    text=take!(control.steering)
                    add_message!(s,Message(:user,text));emit!(ctx,:steering_applied,Dict("text"=>text))
                end
                messages=request_messages(s,ctx;context_bytes)
                request=ModelRequest(messages,deepcopy(schemas),max_output,deepcopy(options))
                validate_request(provider,request)
                estimated=estimate_request_tokens(request)
                prices=provider isa HTTPProvider ? (provider.config.input_price,provider.config.output_price) : (0.0,0.0)
                lease=reserve!(ctx.budget,estimated+max_output,(estimated*prices[1]+max_output*prices[2])/1_000_000)
                partial=IOBuffer();delivered_usage=Ref{Union{Nothing,Usage}}(nothing)
                sink=(kind,payload)->begin
                    kind==:text_delta && write(partial,payload)
                    kind==:usage && (delivered_usage[]=payload)
                    if kind==:tool_call
                        emit!(ctx,kind,Dict("id"=>payload.id,"name"=>payload.name,"arguments"=>payload.arguments))
                    elseif kind==:usage
                        emit!(ctx,:usage,Dict("input_tokens"=>payload.input_tokens,"output_tokens"=>payload.output_tokens))
                    else
                        emit!(ctx,kind,Dict("text"=>payload))
                    end
                end
                model_result=try
                    emit!(ctx,:model_request,Dict("provider"=>provider_name(provider),"estimated_input_tokens"=>estimated))
                    result=stream_chat(provider,request,sink,ctx)
                    settle!(ctx.budget,lease,result.usage);record_usage!(s,result.usage)
                    result
                catch
                    active=lock(ctx.budget.mutex) do;haskey(ctx.budget.reservations,lease);end
                    if active
                        if delivered_usage[]!==nothing
                            settle!(ctx.budget,lease,delivered_usage[]);record_usage!(s,delivered_usage[])
                        else
                            release!(ctx.budget,lease)
                        end
                    end
                    text=String(take!(partial))
                    !isempty(text) && add_message!(s,Message(:assistant,text;native=Dict("interrupted"=>true)))
                    rethrow()
                finally
                    save_budget!(s,ctx)
                end
                add_message!(s,model_result.message)
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
                    archive_output!(ctx,result)
                    add_message!(s,Message(:tool,trim_tool_result(result);call_id=result.id))
                end
                signature=digest(canonical([Dict("name"=>call.name,"args"=>call.arguments,
                    "ok"=>result.ok,"value"=>result.value,"error"=>result.error) for (call,result) in zip(calls,results)]))
                repeats=signature==last_signature ? repeats+1 : 0
                last_signature=signature
                repeats>=2 && emit!(ctx,:no_progress,Dict("identical_result_batches"=>repeats+1))
                repeats>=5 && throw(ShenScopeError(:no_progress,"Repeated tool batches returned identical evidence"))
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
