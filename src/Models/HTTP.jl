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

function stream_attempt(p::HTTPProvider,prepared::PreparedRequest,sink::Function,ctx::RuntimeContext;encoded_body=nothing)
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
                permission_decision(ctx.permissions,PermissionRequest("model-stream-watch",:network,
                    provider_name(p),String(HTTP.URI(prepared.endpoint).host),"Observe model inference")) == Deny && break
                sleep(0.025)
            end
            denied = permission_decision(ctx.permissions,PermissionRequest("model-stream-watch",:network,
                provider_name(p),String(HTTP.URI(prepared.endpoint).host),"Observe model inference")) == Deny
            (iscancelled(ctx.cancellation) || time() >= deadline || denied) && try close(stream) catch end
        end
        try
            model_network_checkpoint(p,prepared,ctx)
            lock(ctx.budget.mutex) do; check_budget(ctx.budget); end
            body = encoded_body === nothing ? bounded_canonical_json(prepared.body;maximum=8*1024^2) : encoded_body
            write(stream,body);HTTP.closewrite(stream)
            result=HTTP.startread(stream)
            if !(200 <= result.status < 300)
                advice = model_retry_advice(result)
                throw(model_response_failure(result,bounded_model_error_body(stream);advice))
            end
            if prepared.protocol==:ollama
                while !eof(stream)
                    model_network_checkpoint(p,prepared,ctx)
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
                    model_network_checkpoint(p,prepared,ctx)
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
    model_network_checkpoint(p,prepared,ctx)
    # One prepared body/credential snapshot is retained across every attempt.
    model_stream_with_policy(p,prepared,sink,ctx)
end
