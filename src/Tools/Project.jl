mutable struct ProjectManager
    backends::Dict{String,AbstractProjectDataBackend}
    states::Dict{String,ProjectState}
    jobs::Dict{String,Dict{String,Any}}
    watches::Dict{String,ProjectWatch}
    mutations::Set{String}
    mutex::ReentrantLock
end
ProjectManager()=ProjectManager(Dict{String,AbstractProjectDataBackend}(),Dict{String,ProjectState}(),Dict{String,Dict{String,Any}}(),Dict{String,ProjectWatch}(),Set{String}(),ReentrantLock())
struct ProjectTool <: AbstractTool
    manager::ProjectManager
end
ProjectTool()=ProjectTool(ProjectManager())
tool_name(::ProjectTool)="project"
tool_description(::ProjectTool)="Index source, navigate recorded facts and compute impact, tests, architecture, local Git co-change and review-priority evidence."
execution_mode(::ProjectTool)=:exclusive
tool_schema(::ProjectTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["build","update","compact","status","search","impact","test_selection","architecture","git_cochange","risk",
        "definitions","references","hover","incoming_calls","outgoing_calls","implementations","diagnostics"]),
    "backend"=>Dict("type"=>"string","enum"=>["tree_sitter","go_ast","codegraph","typescript"]),
    "paths"=>Dict("type"=>"array","maxItems"=>10000,"items"=>string_schema(;max=4096)),
    "query"=>string_schema(;max=4096),"limit"=>integer_schema(1,1000),"offset"=>integer_schema(0,100000),
    "symbols"=>Dict("type"=>"array","maxItems"=>128,"items"=>string_schema(;max=32)),
    "history_limit"=>integer_schema(1,512),"bulk_threshold"=>integer_schema(2,512),"minimum_support"=>integer_schema(1,512),
    "history_timeout"=>Dict("type"=>"number","minimum"=>0.05,"maximum"=>600),
    "symbol_id"=>string_schema(;max=32),"file"=>string_schema(;max=4096),"line"=>integer_schema(1,8*1024*1024),
    "column"=>integer_schema(1,8*1024*1024),"column_unit"=>Dict("type"=>"string","enum"=>["utf8_byte","utf16"]),
    "revision"=>integer_schema(0),"sha256"=>string_schema(;max=64),"include_declarations"=>Dict("type"=>"boolean"),
    "force"=>Dict("type"=>"boolean"),"minimum_savings"=>integer_schema(0,128*1024*1024),
    "category"=>Dict("type"=>"string","enum"=>["error","warning","suggestion","message"]));required=["action"])
function project_backend!(manager::ProjectManager,name::String)
    get!(manager.backends,name) do
        name=="tree_sitter" && return TreeSitterBackend()
        name=="go_ast" && return GoASTBackend()
        name=="codegraph" && return CodeGraphBackend()
        name=="typescript" && return TypeScriptSemanticBackend()
        throw(ShenScopeError(:backend,"Unknown project backend"))
    end
end
function execute(tool::ProjectTool,args::AbstractDict,ctx::RuntimeContext)
    name=get(args,"backend","tree_sitter");manager=tool.manager
    mutation=args["action"] in ("build","update","compact")
    key=digest(ctx.root)*":"*name
    if mutation
        lock(manager.mutex) do
            any(w->w.context.root==ctx.root && w.state.backend==name && watch_live(w),values(manager.watches)) &&
                throw(ShenScopeError(:watch_busy,"Stop this backend watcher before changing its index manually"))
            key in manager.mutations && throw(ShenScopeError(:graph_busy,"Another operation owns this project index"))
            push!(manager.mutations,key)
        end
    end
    try
        execute_project(tool,args,ctx)
    finally
        mutation && lock(manager.mutex) do;delete!(manager.mutations,key);end
    end
end
function execute_project(tool::ProjectTool,args::AbstractDict,ctx::RuntimeContext)
    name=get(args,"backend","tree_sitter");manager=tool.manager
    backend=lock(manager.mutex) do;project_backend!(manager,name);end
    key=digest(ctx.root)*":"*name
    state=lock(manager.mutex) do;get(manager.states,key,nothing);end
    action=args["action"]
    if action!="build" && state===nothing
        candidate=ProjectState(ctx,backend)
        if isfile(candidate.journal.path)
            authorize!(ctx,:read,"project.cache",ctx.root)
            state=load_project(backend,ctx;authorized=true)
            lock(manager.mutex) do;manager.states[key]=state;end
        end
    end
    if action=="build"
        state=build!(backend,ctx)
        lock(manager.mutex) do;manager.states[key]=state;end
        return project_status(state)
    end
    state===nothing && throw(ShenScopeError(:graph,"Build this workspace index first"))
    state.root==ctx.root || throw(ShenScopeError(:permission,"Project state belongs to another workspace"))
    action=="update" && return delta_dict(update!(backend,state,get(args,"paths",String[]),ctx))
    action=="compact" && return compact_project!(state,ctx;expected_revision=get(args,"revision",nothing),
        minimum_savings=get(args,"minimum_savings",1),force=get(args,"force",false))
    action in PROJECT_NAVIGATION_ACTIONS && return project_navigation(state,args,ctx)
    authorize!(ctx,:read,"project.query",ctx.root)
    action=="status" && return project_status(state)
    action=="search" && return graph_search(state,get(args,"query","");limit=get(args,"limit",50),offset=get(args,"offset",0))
    analyzer=action=="impact" ? ImpactAnalyzer() : action=="test_selection" ? TestSelectionAnalyzer() :
        action=="architecture" ? ArchitectureAnalyzer() : action=="git_cochange" ? GitCochangeAnalyzer() :
        action=="risk" ? RiskAnalyzer() : nothing
    analyzer===nothing && throw(ShenScopeError(:arguments,"Unknown project action"))
    analyze(analyzer,state,args,ctx)
end
function cleanup_projects!(manager::ProjectManager)
    watches=lock(manager.mutex) do;collect(values(manager.watches));end
    for watch in watches;stop_project_watch!(watch;wait_for_completion=false);end
    jobs=lock(manager.mutex) do;collect(values(manager.jobs));end
    for job in jobs
        get(job,"context",nothing)!==nothing && cancel!(job["context"].cancellation)
    end
    for backend in values(manager.backends);backend_close!(backend);end
    for job in jobs
        task=get(job,"task",nothing);task!==nothing && task!==current_task() && wait(task)
    end
    for watch in watches;stop_project_watch!(watch);end
end
