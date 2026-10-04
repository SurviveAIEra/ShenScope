struct AnalyzersTool <: AbstractTool
    manager::AnalyzerManager
    projects::ProjectManager
end
AnalyzersTool(manager=AnalyzerManager()) = AnalyzersTool(manager,ProjectManager())
tool_name(::AnalyzersTool) = "analyzers"
tool_description(::AnalyzersTool) = "Register session-scoped Julia analyzers and compare external test fixtures; evaluate explicit JSON data in a bounded child with kernel-enforced filesystem/network/process restrictions."
execution_mode(::AnalyzersTool) = :exclusive

function tool_schema(::AnalyzersTool)
    dictionary = Dict("type"=>"object","additionalProperties"=>true)
    test = object_schema(Dict("name"=>string_schema(;max=128),"data"=>dictionary,
        "request"=>dictionary,"expected"=>dictionary);required=["name","data","request","expected"])
    limits = object_schema(Dict("wall_seconds"=>Dict("type"=>"number","minimum"=>0.05,"maximum"=>600),
        "cpu_seconds"=>integer_schema(1,300),"address_space_bytes"=>integer_schema(512*1024^2,32*1024^3),
        "input_bytes"=>integer_schema(1024,32*1024^2),"output_bytes"=>integer_schema(1024,4*1024^2),
        "source_bytes"=>integer_schema(64,1024^2),"max_tests"=>integer_schema(1,128)))
    object_schema(Dict("action"=>Dict("type"=>"string","enum"=>["status","catalog","register","list","inspect","validate","evaluate","run","select","remove","cancel",
            "archive","versions","archive_inspect","restore","promote","rollback","history"]),
        "name"=>string_schema(;max=64),"description"=>string_schema(;max=2048),"version"=>string_schema(;max=64),
        "source"=>string_schema(;max=1024^2),"source_path"=>string_schema(;max=4096),
        "tests"=>Dict("type"=>"array","maxItems"=>128,"items"=>test),"limits"=>limits,
        "data"=>dictionary,"request"=>dictionary,"offset"=>integer_schema(0),"limit"=>integer_schema(1,100),
        "backend"=>Dict("type"=>"string","enum"=>["tree_sitter","go_ast","codegraph","typescript"]),
        "scope"=>Dict("type"=>"string","enum"=>["project","user"]),"expected_pointer"=>integer_schema(0));required=["action"])
end

function analyzer_platform_status()
    dependency = compute_seccomp_available()
    Dict("platform"=>string(Sys.KERNEL),"architecture"=>string(Sys.ARCH),
        "sandbox_backend"=>"linux-seccomp-compute-v1","dependency_available"=>dependency,
        "enforcement"=>"Verified separately for every child before caller code is delivered",
        "fallback"=>false,"input_contract"=>"analyze(data::Dict, request::Dict) -> Dict; selftest() -> true",
        "default_lifetime"=>"session","host_sandbox_changed"=>false,
        "limits"=>compute_limits_dict(ComputeLimits()),
        "constraints"=>["No filesystem opens, network creation, child processes or process inspection after bootstrap.",
            "Preloaded Julia/Base and explicit JSON inputs only; arbitrary package loading is unavailable.",
            "Virtual-address-space limit is enforced; this is not a resident-memory quota.",
            "Linux x86_64 was runtime-verified; other platforms remain unverified or unavailable."])
end

function execute(tool::AnalyzersTool,args::AbstractDict,ctx::RuntimeContext)
    action = args["action"]
    if action == "status"
        authorize!(ctx,:read,"analysis.status",ctx.root)
        return analyzer_platform_status()
    elseif action == "catalog"
        return analyzer_catalog(tool,ctx)
    elseif action == "list"
        return analyzer_list(tool.manager,ctx;offset=get(args,"offset",0),limit=get(args,"limit",50))
    elseif action == "versions"
        return analyzer_archive_list(ctx;scope=Symbol(get(args,"scope","project")),name=get(args,"name",nothing),
            offset=get(args,"offset",0),limit=get(args,"limit",50))
    end
    name = get(args,"name",nothing)
    name isa AbstractString || throw(ShenScopeError(:arguments,"Analyzer name is required"))
    version = get(args,"version",nothing)
    scope = Symbol(get(args,"scope","project"))
    if action == "register"
        haskey(args,"source") != haskey(args,"source_path") || throw(ShenScopeError(:arguments,"Provide exactly one analyzer source or source_path"))
        limits = compute_limits_from_dict(get(args,"limits",Dict{String,Any}()))
        source = haskey(args,"source") ? args["source"] : read_scoped_text(ctx,ctx.root,args["source_path"],limits.source_bytes;
            tool="analysis.source",reason="Read Julia analyzer candidate source")
        tests = AnalyzerTestCase[analyzer_test_from_dict(value) for value in get(args,"tests",Any[])]
        definition = AnalyzerDefinition(name,source;description=get(args,"description",""),tests,limits)
        return register_analyzer!(tool.manager,definition,ctx)
    elseif action == "inspect"
        return analyzer_inspect(tool.manager,name,ctx;version)
    elseif action == "validate"
        return validate_analyzer!(tool.manager,name,ctx;version)
    elseif action == "evaluate"
        get(args,"data",nothing) isa AbstractDict || throw(ShenScopeError(:arguments,"Explicit analyzer data is required"))
        return evaluate_analyzer!(tool.manager,name,args["data"],get(args,"request",Dict{String,Any}()),ctx;version)
    elseif action == "run"
        state = analyzer_project_state(tool,ctx,get(args,"backend","tree_sitter"))
        return analyze(IsolatedJuliaAnalyzer(tool.manager,name;version),state,get(args,"request",Dict{String,Any}()),ctx)
    elseif action == "archive"
        return archive_analyzer!(tool.manager,name,ctx;version,scope)
    elseif action == "archive_inspect"
        version isa AbstractString || throw(ShenScopeError(:arguments,"Archived version is required"))
        return analyzer_archive_inspect(ctx,name,version;scope)
    elseif action == "restore"
        return restore_analyzer!(tool.manager,name,ctx;version,scope)
    elseif action in ("promote","rollback")
        expected = get(args,"expected_pointer",nothing)
        expected isa Integer && !(expected isa Bool) && expected >= 0 || throw(ShenScopeError(:arguments,"Expected active pointer revision is required"))
        if action == "rollback"
            version isa AbstractString || throw(ShenScopeError(:arguments,"Rollback version is required"))
            return rollback_analyzer!(tool.manager,name,version,ctx;scope,expected_pointer=expected)
        end
        return promote_analyzer!(tool.manager,name,ctx;version,scope,expected_pointer=expected)
    elseif action == "history"
        return analyzer_archive_history(ctx,name;scope,limit=get(args,"limit",16))
    elseif action == "select"
        version isa AbstractString || throw(ShenScopeError(:arguments,"Analyzer version is required"))
        return select_analyzer!(tool.manager,name,version,ctx)
    elseif action == "remove"
        return remove_analyzer!(tool.manager,name,ctx;version)
    elseif action == "cancel"
        return cancel_analyzer!(tool.manager,name,ctx;version)
    end
    throw(ShenScopeError(:arguments,"Unknown analyzer action"))
end

function analyzer_project_state(tool::AnalyzersTool,ctx::RuntimeContext,name::String)
    key = digest(ctx.root)*":"*name
    authorize!(ctx,:read,"analysis.project",ctx.root)
    state = lock(tool.projects.mutex) do;get(tool.projects.states,key,nothing);end
    if state === nothing
        backend = lock(tool.projects.mutex) do;project_backend!(tool.projects,name);end
        candidate = ProjectState(ctx,backend)
        isfile(candidate.journal.path) || throw(ShenScopeError(:analysis,"Index this project backend before running an analyzer"))
        loaded = load_project(backend,ctx;authorized=true)
        state = lock(tool.projects.mutex) do;get!(tool.projects.states,key,loaded);end
    end
    state
end
