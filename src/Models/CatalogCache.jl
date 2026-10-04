function catalog_access_tag(manager::ModelCatalogManager,key::CredentialSnapshot)
    digest(manager.salt*":"*key.value)
end

function catalog_page_options(offset,limit)
    offset isa Integer && !(offset isa Bool) && 0 <= offset <= typemax(Int) &&
        limit isa Integer && !(limit isa Bool) && 1 <= limit <= 100 ||
        throw(ShenScopeError(:arguments,"Invalid model catalog pagination"))
    Int(offset),Int(limit)
end

function catalog_snapshot_view(snapshot::CatalogSnapshot;ttl_seconds,offset=0,limit=50,access_verified=true)
    offset,limit = catalog_page_options(offset,limit)
    first = min(offset,length(snapshot.models))
    selected = snapshot.models[first+1:min(first+limit,length(snapshot.models))]
    Dict("source_id"=>snapshot.source_id,"revision"=>snapshot.revision,"total"=>length(snapshot.models),
        "models"=>model_descriptor_dict.(selected),"offset"=>offset,
        "next_offset"=>offset < length(snapshot.models)-limit ? offset+limit : nothing,
        "checked_at"=>snapshot.checked_at,"age_seconds"=>max(0,time()-snapshot.checked_time),
        "fresh"=>access_verified && time()-snapshot.checked_time <= ttl_seconds,"access_verified"=>access_verified,
        "content_sha256"=>snapshot.content_sha256,"pages"=>snapshot.pages,"retained_bytes"=>snapshot.bytes,
        "diagnostics"=>catalog_diagnostic_dict.(snapshot.diagnostics),"lifetime"=>"conversation")
end

function catalog_read_checkpoint(ctx::RuntimeContext)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    permission_decision(ctx.permissions,PermissionRequest("catalog-read-current",:read,"models.catalog",ctx.root,"Read catalog")) != Deny ||
        throw(ShenScopeError(:permission,"Model catalog read permission was revoked"))
    nothing
end

function catalog_read_authorize!(ctx::RuntimeContext)
    authorize!(ctx,:read,"models.catalog",ctx.root;reason="Read conversation-scoped model catalog metadata")
    catalog_read_checkpoint(ctx)
end

function model_catalog_view(manager::ModelCatalogManager,provider::HTTPProvider,ctx::RuntimeContext;offset=0,limit=50,credentials=nothing)
    offset,limit = catalog_page_options(offset,limit)
    catalog_read_authorize!(ctx)
    source = catalog_key(provider,ctx)
    key = credentials === nothing ? CredentialSnapshot(provider.credential_lookup(provider.config.key_env)) : credentials
    key isa CredentialSnapshot || throw(ArgumentError("Catalog credentials must be a captured snapshot"))
    access = catalog_access_tag(manager,key)
    snapshot,failure = lock(manager.mutex) do
        deepcopy(get(manager.snapshots,source,nothing)),get(manager.failures,source,nothing)
    end
    configured = model_descriptor_dict(configured_model_descriptor(provider))
    catalog_read_checkpoint(ctx)
    if snapshot === nothing
        return Dict("source_id"=>source[end],"configured"=>configured,"revision"=>0,"total"=>0,"models"=>Any[],
            "offset"=>offset,"next_offset"=>nothing,"fresh"=>false,"access_verified"=>false,
            "checked_at"=>nothing,"failure"=>failure,"diagnostics"=>Any[],"lifetime"=>"conversation")
    end
    snapshot.access_tag == access || return Dict("source_id"=>source[end],"configured"=>configured,
        "revision"=>snapshot.revision,"total"=>0,"models"=>Any[],"offset"=>offset,"next_offset"=>nothing,
        "fresh"=>false,"access_verified"=>false,"checked_at"=>nothing,"failure"=>"Credential scope changed; refresh the catalog", "diagnostics"=>Any[],"lifetime"=>"conversation")
    merge(catalog_snapshot_view(snapshot;ttl_seconds=manager.ttl_seconds,offset,limit),Dict("configured"=>configured,"failure"=>failure))
end

function begin_catalog_refresh!(manager::ModelCatalogManager,provider::HTTPProvider,ctx::RuntimeContext,key::CredentialSnapshot)
    source = catalog_key(provider,ctx);access = catalog_access_tag(manager,key)
    lock(manager.mutex) do
        manager.closed && throw(ShenScopeError(:runtime,"Model catalog manager is closed"))
        haskey(manager.running,source) && throw(ShenScopeError(:runtime,"This conversation's provider catalog is already refreshing"))
        length(manager.running) < 4 || throw(ShenScopeError(:capacity,"Model catalog refresh concurrency reached"))
        if !haskey(manager.epochs,source)
            length(manager.epochs) < manager.max_sources || throw(ShenScopeError(:capacity,"Conversation catalog source capacity reached"))
            manager.epochs[source] = 0
        end
        epoch = manager.epochs[source]+1;manager.epochs[source] = epoch
        lease = CatalogLease(source,epoch,ctx.cancellation,access,current_task())
        manager.running[source] = lease
        lease,manager.generation,deepcopy(get(manager.snapshots,source,nothing))
    end
end

function finish_catalog_refresh!(manager::ModelCatalogManager,lease::CatalogLease,generation::Int,
        models::Vector{ModelDescriptor},diagnostics::Vector{CatalogDiagnostic},etag,pages::Int,ctx::RuntimeContext)
    catalog_read_checkpoint(ctx)
    content = Dict("models"=>model_descriptor_dict.(models),"diagnostics"=>catalog_diagnostic_dict.(diagnostics))
    encoded = bounded_canonical_json(content;maximum=manager.max_bytes,max_nodes=1_000_000);bytes = ncodeunits(encoded)
    bytes <= manager.max_bytes || throw(ShenScopeError(:capacity,"Model catalog snapshot exceeds retained capacity"))
    lock(manager.mutex) do
        check_cancelled(ctx.cancellation)
        manager.generation == generation && get(manager.running,lease.key,nothing) === lease && manager.epochs[lease.key] == lease.epoch ||
            throw(ShenScopeError(:conflict,"Model catalog ownership changed before publication"))
        previous = get(manager.snapshots,lease.key,nothing)
        retained = sum(snapshot.bytes for snapshot in values(manager.snapshots);init=0)-(previous === nothing ? 0 : previous.bytes)
        retained+bytes <= manager.max_bytes || throw(ShenScopeError(:capacity,"Combined model catalogs exceed retained capacity"))
        revision = previous === nothing ? 1 : previous.revision+1
        snapshot = CatalogSnapshot(lease.key[end],operation_scope(ctx),lease.access_tag,revision,deepcopy(models),deepcopy(diagnostics),
            utcstamp(),time(),digest(encoded),etag,pages,bytes)
        manager.snapshots[lease.key] = snapshot;delete!(manager.failures,lease.key)
        deepcopy(snapshot)
    end
end

function refresh_model_catalog!(manager::ModelCatalogManager,provider::HTTPProvider,owner::RuntimeContext;force=false,max_pages=16,offset=0,limit=50)
    offset,limit = catalog_page_options(offset,limit)
    force isa Bool && max_pages isa Integer && !(max_pages isa Bool) && 1 <= max_pages <= 32 ||
        throw(ShenScopeError(:arguments,"Invalid model catalog refresh options"))
    catalog_read_authorize!(owner)
    context = child_context(owner)
    key = CredentialSnapshot(provider.credential_lookup(provider.config.key_env))
    lease,generation,previous = begin_catalog_refresh!(manager,provider,context,key)
    try
        if !force && previous !== nothing && previous.access_tag == lease.access_tag && time()-previous.checked_time <= manager.ttl_seconds
            catalog_read_checkpoint(context)
            return merge(catalog_snapshot_view(previous;ttl_seconds=manager.ttl_seconds,offset,limit),Dict("cache_hit"=>true))
        end
        models = Dict{String,ModelDescriptor}();invalid = Set{String}();diagnostics = CatalogDiagnostic[]
        cursors = Set{String}();cursor = nothing;pages = 0;etag = nothing;authorization = nothing
        conditional = previous !== nothing && previous.access_tag == lease.access_tag && previous.pages == 1 ? previous.etag : nothing
        while true
            check_cancelled(context.cancellation)
            pages < max_pages || throw(ShenScopeError(:capacity,"Model catalog pagination exceeds capacity"))
            request = model_service_request(provider,key,"catalog";cursor,etag=pages == 0 ? conditional : nothing)
            authorization === nothing && (authorization = authorize_model_service!(provider,request,context))
            response = model_service_json(provider,request,context;allow_not_modified=pages == 0 && conditional !== nothing,authorization)
            if response.status == 304
                # Only a single-page snapshot can use its whole-list validator.
                snapshot = finish_catalog_refresh!(manager,lease,generation,previous.models,previous.diagnostics,
                    response.etag === nothing ? previous.etag : response.etag,1,context)
                emit!(context,:model_catalog_refreshed,Dict("source_id"=>snapshot.source_id,"revision"=>snapshot.revision,"not_modified"=>true))
                return merge(catalog_snapshot_view(snapshot;ttl_seconds=manager.ttl_seconds,offset,limit),Dict("cache_hit"=>false,"not_modified"=>true))
            end
            pages += 1
            page = parse_catalog_page(provider,response.data)
            merge_catalog_page!(models,invalid,diagnostics,page)
            pages == 1 && (etag = response.etag)
            page.cursor === nothing && break
            page.cursor in cursors && throw(ShenScopeError(:protocol,"Model catalog repeated a pagination cursor"))
            push!(cursors,page.cursor);cursor = page.cursor
        end
        ordered = sort!(collect(values(models));by=model -> model.id)
        snapshot = finish_catalog_refresh!(manager,lease,generation,ordered,diagnostics,pages == 1 ? etag : nothing,pages,context)
        emit!(context,:model_catalog_refreshed,Dict("source_id"=>snapshot.source_id,"revision"=>snapshot.revision,"models"=>length(ordered),"pages"=>pages))
        merge(catalog_snapshot_view(snapshot;ttl_seconds=manager.ttl_seconds,offset,limit),Dict("cache_hit"=>false,"not_modified"=>false))
    catch cause
        lock(manager.mutex) do
            manager.generation == generation && (manager.failures[lease.key] = cause isa ShenScopeError ? cause.message : "Model catalog refresh failed")
        end
        rethrow()
    finally
        lock(manager.mutex) do
            get(manager.running,lease.key,nothing) === lease && delete!(manager.running,lease.key)
        end
    end
end

function invalidate_model_catalogs!(manager::ModelCatalogManager;reason="Model catalog configuration changed")
    lock(manager.mutex) do
        manager.generation += 1
        for lease in values(manager.running);cancel!(lease.token,reason);end
        empty!(manager.snapshots);empty!(manager.failures)
    end
    nothing
end

function cleanup_model_catalogs!(manager::ModelCatalogManager)
    leases = lock(manager.mutex) do
        manager.closed = true
        collect(values(manager.running))
    end
    invalidate_model_catalogs!(manager;reason="Model catalog manager closing")
    close_operations!(manager.operations)
    for lease in leases
        lease.task === current_task() && continue
        try wait(lease.task) catch cause;cause isa TaskFailedException || rethrow();end
    end
    lock(manager.mutex) do
        empty!(manager.epochs);empty!(manager.running)
    end
    nothing
end

function release_model_catalog_session!(manager::ModelCatalogManager,session_id::String;root=nothing)
    selected_keys,leases = lock(manager.mutex) do
        selected = [key for key in keys(manager.epochs) if key[3] == session_id && (root === nothing || key[1] == root)]
        running = [manager.running[key] for key in selected if haskey(manager.running,key)]
        for lease in running;cancel!(lease.token,"Conversation catalog retiring");end
        selected,running
    end
    release_operations!(manager.operations,session_id;root)
    for lease in leases
        lease.task === current_task() && continue
        try wait(lease.task) catch cause;cause isa TaskFailedException || rethrow();end
    end
    lock(manager.mutex) do
        for key in selected_keys
            delete!(manager.snapshots,key);delete!(manager.failures,key);delete!(manager.epochs,key);delete!(manager.running,key)
        end
    end
    nothing
end

function forget_model_catalog!(manager::ModelCatalogManager,provider::HTTPProvider,ctx::RuntimeContext)
    catalog_read_authorize!(ctx)
    key = catalog_key(provider,ctx)
    lock(manager.mutex) do
        haskey(manager.running,key) && throw(ShenScopeError(:runtime,"Cancel or finish this catalog refresh before clearing it"))
        deleted = haskey(manager.snapshots,key) || haskey(manager.epochs,key)
        delete!(manager.snapshots,key);delete!(manager.failures,key);delete!(manager.epochs,key)
        Dict("cleared"=>deleted,"source_id"=>key[end])
    end
end
