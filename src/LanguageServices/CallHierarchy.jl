function language_call_item(value, sources::LanguageResultSources)
    value isa AbstractDict && all(key -> haskey(value,key), ("name","kind","uri","range","selectionRange")) ||
        throw(ShenScopeError(:language_protocol, "Call hierarchy item lacks identity or ranges"))
    snapshot = language_result_source!(sources, value["uri"])
    snapshot === nothing && return nothing
    selection = language_range(snapshot.source, value["selectionRange"])
    declaration = language_range(snapshot.source, value["range"])
    first, last = source_range_indices(snapshot.source, declaration)
    start, finish = source_range_indices(snapshot.source, selection)
    first <= start <= finish <= last || throw(ShenScopeError(:language_protocol, "Call item selection escapes its range"))
    name = language_text(value["name"], "call item name", 4096)
    kind = language_symbol_kind(value["kind"])
    Dict("id" => digest(canonical([snapshot.path,name,kind,range_dict(selection)])),
        "name" => name, "kind" => kind, "path" => snapshot.path,
        "source_sha256" => snapshot.sha256, "location" => range_dict(selection),
        "declaration_range" => range_dict(declaration))
end

function query_language_call_hierarchy(client::LanguageClient, action::String, arguments, ctx::RuntimeContext)
    action in ("incoming_calls", "outgoing_calls") || throw(ShenScopeError(:language_config, "Unknown call hierarchy direction"))
    lock(client.document_mutex) do
        language_require_capability(client, "call_hierarchy")
        path = language_text(get(arguments,"path",nothing), "call hierarchy source", 4096)
        synchronize_language_document!(client, path, ctx; language=get(arguments,"language",nothing),
            expected_sha256=get(arguments,"expected_sha256",nothing))
        _, relative = workspace_snapshot_path(ctx,path)
        document = language_document(client,relative)
        position = language_cursor(document.snapshot.source,get(arguments,"line",0),get(arguments,"character",0))
        prepared = language_request!(client,"textDocument/prepareCallHierarchy",Dict("textDocument"=>
            Dict("uri"=>mcp_file_uri(document.snapshot.absolute)),"position"=>position),ctx)
        prepared === nothing && (prepared = Any[])
        prepared isa AbstractVector && length(prepared) <= 32 || throw(ShenScopeError(:language_protocol,"Call hierarchy roots exceed capacity"))
        maximum = language_integer(get(arguments,"limit",100),"call hierarchy result limit",1,client.limits.maximum_result_items)
        sources = LanguageResultSources(ctx; primary=document.snapshot)
        roots = Dict{String,Any}[]
        calls = Dict{String,Any}[]
        omitted = 0
        for raw in prepared
            root = language_call_item(raw,sources)
            root === nothing && continue
            push!(roots,root)
            method = action == "incoming_calls" ? "callHierarchy/incomingCalls" : "callHierarchy/outgoingCalls"
            response = language_request!(client,method,Dict("item"=>raw),ctx)
            response === nothing && (response = Any[])
            response isa AbstractVector && length(response) <= 16_384 || throw(ShenScopeError(:language_protocol,"Call hierarchy response exceeds capacity"))
            for row in response
                if length(calls) >= maximum
                    omitted += 1
                    continue
                end
                peer_key = action == "incoming_calls" ? "from" : "to"
                row isa AbstractDict && haskey(row,peer_key) && get(row,"fromRanges",nothing) isa AbstractVector ||
                    throw(ShenScopeError(:language_protocol,"Call hierarchy edge lacks peer or source ranges"))
                peer = language_call_item(row[peer_key],sources)
                peer === nothing && continue
                source = action == "incoming_calls" ? sources.cache[peer["path"]] : sources.cache[root["path"]]
                ranges = row["fromRanges"]
                length(ranges) <= 256 || throw(ShenScopeError(:language_protocol,"Call hierarchy edge has too many ranges"))
                locations = range_dict.([language_range(source.source,range) for range in ranges])
                push!(calls,Dict("root_id"=>root["id"],"peer"=>peer,"source_ranges"=>locations,
                    "relationship"=>action,"resolution"=>"language_server_report"))
            end
        end
        verify_workspace_snapshot(document.snapshot,ctx;tool="language.source")
        Dict("server"=>client.spec.name,"action"=>action,"roots"=>roots,"calls"=>calls,
            "omitted_items"=>omitted,"source_omissions"=>deepcopy(sources.omitted),
            "projection_truncated"=>omitted>0 || !isempty(sources.omitted),
            "runtime_calls_independently_verified"=>false,"complete_project_coverage"=>false)
    end
end
