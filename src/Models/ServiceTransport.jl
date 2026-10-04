function model_service_json(provider::HTTPProvider,request::ModelServiceRequest,ctx::RuntimeContext;
        max_bytes=2*1024^2,allow_not_modified=false,authorization=nothing)
    max_bytes isa Integer && !(max_bytes isa Bool) && 1024 <= max_bytes <= 8*1024^2 ||
        throw(ShenScopeError(:arguments,"Invalid model service response capacity"))
    catalog_source_id(provider) == request.source_id || throw(ShenScopeError(:conflict,"Model service source changed"))
    uri = validate_endpoint(request.endpoint)
    grant = authorization === nothing ? authorize_model_service!(provider,request,ctx) : authorization
    grant isa ModelServiceAuthorization || throw(ShenScopeError(:permission,"Invalid model service authorization"))
    model_service_authorization_check(grant,request,ctx)
    model_service_checkpoint(ctx,provider,request)
    remaining = lock(ctx.budget.mutex) do
        check_budget(ctx.budget)
        ctx.budget.limits.max_seconds - (time_ns()-ctx.budget.started_ns)/1e9
    end
    remaining > 0 || throw(ShenScopeError(:budget,"Model service wall-clock budget exhausted"))
    timeout = min(provider.config.timeout,remaining)
    deadline = time()+timeout
    code = remaining <= provider.config.timeout ? :budget : :timeout
    received = Ref{Any}(nothing)
    try
        HTTP.open(request.method,request.endpoint,request.headers;readtimeout=ceil(Int,timeout),
                connect_timeout=ceil(Int,min(30,timeout)),retry=false,status_exception=false,redirect=false) do stream
            watcher = @async begin
                while isopen(stream) && !iscancelled(ctx.cancellation) && time() < deadline
                    denied = permission_decision(ctx.permissions,PermissionRequest("model-service-watch",:network,
                        provider_name(provider),String(uri.host),"Observe model service request")) == Deny
                    denied && break
                    sleep(0.025)
                end
                if isopen(stream) && (iscancelled(ctx.cancellation) || time() >= deadline ||
                        permission_decision(ctx.permissions,PermissionRequest("model-service-watch",:network,
                            provider_name(provider),String(uri.host),"Observe model service request")) == Deny)
                    try close(stream) catch end
                end
            end
            try
                model_service_checkpoint(ctx,provider,request)
                request.body === nothing || write(stream,request.body)
                HTTP.closewrite(stream)
                response = HTTP.startread(stream)
                status = Int(response.status)
                etag = HTTP.header(response,"ETag",nothing)
                if etag !== nothing
                    etag = String(etag)
                    ncodeunits(etag) <= 256 && !any(iscntrl,etag) || throw(ShenScopeError(:protocol,"Invalid catalog ETag"))
                end
                if status == 304
                    allow_not_modified || throw(ShenScopeError(:protocol,"Unexpected not-modified response"))
                    model_service_checkpoint(ctx,provider,request)
                    received[] = (status=status,data=nothing,etag=etag,bytes=0)
                    return nothing
                end
                if !(200 <= status < 300)
                    # No provider error body is included in a diagnostic; it can
                    # echo request headers, source text or account information.
                    throw(http_error(status))
                end
                content_type = lowercase(HTTP.header(response,"Content-Type",""))
                (isempty(content_type) || occursin("json",content_type)) || throw(ShenScopeError(:protocol,"Model service returned non-JSON content"))
                declared = HTTP.header(response,"Content-Length",nothing)
                if declared !== nothing
                    length_value = tryparse(Int,String(declared))
                    length_value !== nothing && 0 <= length_value <= max_bytes || throw(ShenScopeError(:capacity,"Model service response exceeds capacity"))
                end
                buffer = IOBuffer(;maxsize=max_bytes,sizehint=min(max_bytes,8192))
                while !eof(stream)
                    model_service_checkpoint(ctx,provider,request)
                    chunk = read(stream,min(8192,max_bytes-position(buffer)+1))
                    position(buffer)+length(chunk) <= max_bytes || throw(ShenScopeError(:capacity,"Model service response exceeds capacity"))
                    write(buffer,chunk)
                end
                model_service_checkpoint(ctx,provider,request)
                payload = String(take!(buffer))
                data = bounded_json_object(payload;maximum=max_bytes,max_depth=24,max_nodes=100_000,error_code=:protocol)
                received[] = (status=status,data=data,etag=etag,bytes=ncodeunits(payload))
            finally
                try close(stream) catch end
                wait(watcher)
                time() >= deadline && throw(ShenScopeError(code,code == :budget ?
                    "Model service wall-clock budget exhausted" : "Model service request timed out",code == :timeout))
            end
        end
        received[] === nothing && throw(ShenScopeError(:protocol,"Model service did not produce a complete response"))
        return received[]
    catch cause
        check_cancelled(ctx.cancellation)
        lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
        permission_decision(ctx.permissions,PermissionRequest("model-service-current",:network,provider_name(provider),String(uri.host),"Model service failure")) == Deny &&
            throw(ShenScopeError(:permission,"Model service network permission was revoked"))
        while cause isa HTTP.Exceptions.RequestError;cause = cause.error;end
        cause isa ShenScopeError && throw(cause)
        throw(ShenScopeError(:transport,"Model service transport failed",true))
    end
end
