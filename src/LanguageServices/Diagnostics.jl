function normalize_language_diagnostic(value, snapshot::WorkspaceSourceSnapshot, server::String;
        limits=ProblemLimits())
    value isa AbstractDict && haskey(value, "range") && haskey(value, "message") ||
        throw(ShenScopeError(:language_protocol, "Language diagnostic requires a range and message"))
    severity = language_integer(get(value, "severity", 3), "language diagnostic severity", 1, 4)
    tags = get(value, "tags", Any[])
    tags isa AbstractVector && length(tags) <= 2 && all(tag -> tag isa Integer && !(tag isa Bool) && tag in (1,2), tags) ||
        throw(ShenScopeError(:language_protocol, "Invalid language diagnostic tags"))
    related = get(value, "relatedInformation", Any[])
    related isa AbstractVector && length(related) <= 256 ||
        throw(ShenScopeError(:language_protocol, "Invalid language diagnostic related information"))
    metadata = Dict("server" => server, "related_information_omitted" => length(related))
    project_problem(snapshot, PROBLEM_SEVERITIES[severity], value["message"];
        source=get(value, "source", server), code=get(value, "code", nothing),
        location=language_range(snapshot.source, value["range"]),
        tags=unique([tag == 1 ? "unnecessary" : "deprecated" for tag in tags]),
        semantic=true, metadata, limits)
end

function receive_language_diagnostics!(client::LanguageClient, params::AbstractDict)
    language_fields(params, ["uri", "diagnostics"], ["version"], "published language diagnostics")
    _, path = try
        language_workspace_uri(client.context, params["uri"]; must_exist=false)
    catch cause
        cause isa ShenScopeError || rethrow()
        # A server can report dependency diagnostics outside the authorized
        # workspace. They are not imported into this conversation's store.
        return nothing
    end
    items = params["diagnostics"]
    items isa AbstractVector && length(items) <= 16_384 ||
        throw(ShenScopeError(:language_protocol, "Language diagnostic report exceeds capacity"))
    version = get(params, "version", nothing)
    version === nothing || (version = language_integer(version, "language diagnostic version", 0, 2^31-1))
    document = lock(client.mutex) do
        get(client.documents, path, nothing)
    end
    document === nothing && return nothing
    version === nothing || version == document.version || return nothing
    normalized = ProjectProblem[]
    for item in Iterators.take(items, client.limits.maximum_diagnostics)
        push!(normalized, normalize_language_diagnostic(item, document.snapshot, client.spec.name))
    end
    lock(client.mutex) do
        get(client.documents, path, nothing) === document && client.state in (:connecting, :ready) || return
        permission_decision(client.context.permissions, PermissionRequest("language-push", :read,
            "language", client.context.root, "Retain language diagnostic reports")) != Deny || return
        client.diagnostic_sequence < typemax(Int)-1 || throw(ShenScopeError(:capacity, "Language diagnostic sequence exhausted"))
        client.diagnostic_sequence += 1
        document.diagnostic_items = normalized
        document.diagnostic_received = true
        document.diagnostic_version = version
        document.diagnostic_omitted = max(0, length(items)-length(normalized))
        document.diagnostic_sequence = client.diagnostic_sequence
    end
    nothing
end

function pull_language_diagnostics!(client::LanguageClient, path::AbstractString, ctx::RuntimeContext)
    lock(client.document_mutex) do
        language_require_capability(client, "pull_diagnostics")
        _, relative = workspace_snapshot_path(ctx, path)
        document = language_document(client, relative)
        verify_workspace_snapshot(document.snapshot, ctx; tool="language.source")
        report = language_request!(client, "textDocument/diagnostic", Dict("textDocument" =>
            Dict("uri" => mcp_file_uri(document.snapshot.absolute))), ctx)
        report isa AbstractDict && get(report, "kind", nothing) == "full" && get(report, "items", nothing) isa AbstractVector ||
            throw(ShenScopeError(:language_protocol, "A full document diagnostic report is required"))
        verify_workspace_snapshot(document.snapshot, ctx; tool="language.source")
        receive_language_diagnostics!(client, Dict("uri" => mcp_file_uri(document.snapshot.absolute),
            "version" => document.version, "diagnostics" => report["items"]))
        language_document_status(document)
    end
end

function wait_language_diagnostics(client::LanguageClient, path::AbstractString, ctx::RuntimeContext; timeout=5.0)
    timeout isa Real && !(timeout isa Bool) && isfinite(timeout) && 0.05 <= timeout <= 120 ||
        throw(ShenScopeError(:language_config, "Invalid diagnostic wait timeout"))
    _, relative = workspace_snapshot_path(ctx, path)
    document = language_document(client, relative)
    deadline = time() + Float64(timeout)
    while true
        language_client_access(client, ctx)
        ready = lock(client.mutex) do
            get(client.documents, relative, nothing) === document ||
                throw(ShenScopeError(:conflict, "Language document changed while awaiting diagnostics"))
            document.diagnostic_received && document.diagnostic_version == document.version
        end
        if ready
            verify_workspace_snapshot(document.snapshot, ctx; tool="language.source")
            return language_document_status(document)
        end
        time() < deadline || return merge(language_document_status(document), Dict("wait_timed_out" => true))
        sleep(0.01)
    end
end

function capture_language_problems!(manager::ProblemManager, client::LanguageClient, ctx::RuntimeContext)
    language_client_access(client, ctx; process=false)
    authorize!(ctx, :read, "language", ctx.root; reason="Read owned language-server diagnostic reports")
    files, revision = lock(client.mutex) do
        reports = ProblemFileReport[]
        for path in sort!(collect(keys(client.documents)))
            document = client.documents[path]
            verified = document.diagnostic_received && document.diagnostic_version == document.version
            status = !document.diagnostic_received ? "not_reported" : verified ? "reported" : "unversioned_report"
            items = copy(document.diagnostic_items)
            push!(reports, problem_file_report(document.snapshot, items;
                reported_items=length(items)+document.diagnostic_omitted,
                omitted_items=document.diagnostic_omitted, version=document.version, status))
        end
        reports, client.diagnostic_sequence
    end
    coverage = Dict("producer_kind" => "language_server", "server" => client.spec.name,
        "supported_languages" => copy(client.spec.languages), "reported_files" => length(files),
        "configuration_sha256" => client.spec.fingerprint,
        "unversioned_reports" => count(file -> file.status == "unversioned_report", files),
        "documents_without_report" => count(file -> file.status == "not_reported", files),
        "omitted_items" => sum(file.omitted_items for file in files; init=0),
        "server_state" => String(client.state), "server_process_os_isolated" => false,
        "all_files_checked_by_compiler" => false)
    retain_problem_snapshot!(manager, ctx, "lsp:" * client.spec.name, revision, files; coverage)
end
