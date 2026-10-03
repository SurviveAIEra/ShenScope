function http_error(status::Integer, body=nothing)
    status in (400, 413, 422) && model_context_error(body) &&
        return ShenScopeError(:context_overflow, "Model endpoint rejected the input context", false)
    code=status in (401,403) ? :authentication : status==429 ? :rate_limit :
        status in (408,504) ? :timeout : status>=500 ? :server : :request
    return ShenScopeError(code,"Model endpoint returned HTTP " * string(status),
        status in (408,429,500,502,503,504))
end

function collect_event!(c::StreamCollector,protocol::Symbol,d,sink::Function)
    d isa AbstractDict || throw(ShenScopeError(:protocol,"Expected a model JSON object"))
    if protocol==:openai_chat
        collect_chat!(c,d,sink)
    elseif protocol==:openai_responses
        collect_responses!(c,d,sink)
    elseif protocol==:anthropic
        collect_anthropic!(c,d,sink)
    elseif protocol==:gemini
        collect_gemini!(c,d,sink)
    else
        collect_ollama!(c,d,sink)
    end
end

function stream_attempt(p::HTTPProvider,prepared::PreparedRequest,sink::Function,ctx::RuntimeContext)
    collector=StreamCollector(prepared.identity)
    decoder=SSEDecoder()
    remaining = lock(ctx.budget.mutex) do
        check_budget(ctx.budget)
        ctx.budget.limits.max_seconds - (time_ns()-ctx.budget.started_ns)/1e9
    end
    remaining > 0 || throw(ShenScopeError(:budget, "Model wall-clock budget exhausted"))
    timeout = min(p.config.timeout, remaining)
    deadline = time() + timeout
    timeout_code = remaining <= p.config.timeout ? :budget : :timeout
    HTTP.open("POST",prepared.endpoint,prepared.headers;readtimeout=ceil(Int,timeout),
            connect_timeout=ceil(Int,min(30,timeout)),retry=false,status_exception=false,redirect=false) do stream
        watcher=@async begin
            while isopen(stream) && !iscancelled(ctx.cancellation) && time() < deadline
                sleep(0.025)
            end
            (iscancelled(ctx.cancellation) || time() >= deadline) && try close(stream) catch end
        end
        try
            check_cancelled(ctx.cancellation)
            lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
            write(stream,canonical(prepared.body));HTTP.closewrite(stream)
            result=HTTP.startread(stream)
            200<=result.status<300 || throw(http_error(result.status, bounded_model_error_body(stream)))
            if prepared.protocol==:ollama
                while !eof(stream)
                    check_cancelled(ctx.cancellation)
                    append!(decoder.bytes,readavailable(stream))
                    start=1
                    for i in eachindex(decoder.bytes)
                        decoder.bytes[i]==0x0a || continue
                        line=String(decoder.bytes[start:i-1])
                        ncodeunits(line)<=decoder.max_bytes || throw(ShenScopeError(:protocol,"Model JSON line exceeds limit"))
                        !isempty(strip(line)) && collect_event!(collector,prepared.protocol,parsejson(line),sink)
                        start=i+1
                    end
                    start>1 && deleteat!(decoder.bytes,1:start-1)
                    length(decoder.bytes)<=decoder.max_bytes || throw(ShenScopeError(:protocol,"Model JSON line exceeds limit"))
                end
                !isempty(decoder.bytes) && collect_event!(collector,prepared.protocol,parsejson(String(decoder.bytes)),sink)
            else
                callback=(event,data)->begin
                    check_cancelled(ctx.cancellation)
                    data=="[DONE]" && return
                    json=try parsejson(data) catch
                        throw(ShenScopeError(:protocol,"Malformed JSON in model stream"))
                    end
                    collect_event!(collector,prepared.protocol,json,sink)
                end
                while !eof(stream)
                    check_cancelled(ctx.cancellation)
                    feed_sse!(callback,decoder,readavailable(stream))
                end
                finish_sse!(callback,decoder)
            end
        finally
            try close(stream) catch end
            wait(watcher)
            time() >= deadline && throw(ShenScopeError(timeout_code, timeout_code == :budget ?
                "Model wall-clock budget exhausted" : "Model request timed out", timeout_code == :timeout))
        end
    end
    check_cancelled(ctx.cancellation)
    return finish_collection!(collector,sink,p.config)
end

function stream_chat(p::HTTPProvider,request::ModelRequest,sink::Function,ctx::RuntimeContext)
    prepared=prepare_request(p,request)
    authorize!(ctx,:network,provider_name(p),string(HTTP.URI(prepared.endpoint).host);reason="Model API request")
    lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
    # The prepared headers/body remain fixed across attempts. No retry is hidden
    # once text, usage or tools reached the caller.
    delivered=Ref(false)
    guarded=(kind,payload)->begin
        kind in (:text_delta,:usage,:tool_call,:model_progress) && (delivered[]=true)
        sink(kind,payload)
    end
    for attempt in 0:p.config.retries
        check_cancelled(ctx.cancellation)
        try
            return stream_attempt(p,prepared,guarded,ctx)
        catch e
            check_cancelled(ctx.cancellation)
            lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
            cause=e
            while cause isa HTTP.Exceptions.RequestError
                cause=cause.error
            end
            error=cause isa ShenScopeError ? cause : ShenScopeError(:transport,"Model transport failed",true)
            (!error.retryable || delivered[] || attempt==p.config.retries) && throw(error)
            emit!(ctx,:model_retry,Dict("attempt"=>attempt+1,"code"=>String(error.code)))
            cancellable_wait(ctx.cancellation,min(2.0,0.25*2.0^attempt))
        end
    end
    throw(ShenScopeError(:provider,"Model attempts exhausted"))
end
