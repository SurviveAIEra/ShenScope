mutable struct ProjectManager
    backends::Dict{String,AbstractProjectDataBackend}
    states::Dict{String,ProjectState}
    jobs::Dict{String,Dict{String,Any}}
    mutex::ReentrantLock
end
ProjectManager()=ProjectManager(Dict{String,AbstractProjectDataBackend}(),Dict{String,ProjectState}(),Dict{String,Dict{String,Any}}(),ReentrantLock())
struct ProjectTool <: AbstractTool
    manager::ProjectManager
end
ProjectTool()=ProjectTool(ProjectManager())
tool_name(::ProjectTool)="project"
tool_description(::ProjectTool)="Index source with a real parser backend, search symbols and compute evidence-bearing impact/test/architecture candidates."
execution_mode(::ProjectTool)=:exclusive
tool_schema(::ProjectTool)=object_schema(Dict(
    "action"=>Dict("type"=>"string","enum"=>["build","update","status","search","impact","test_selection","architecture"]),
    "backend"=>Dict("type"=>"string","enum"=>["tree_sitter","go_ast","codegraph"]),
    "paths"=>Dict("type"=>"array","maxItems"=>10000,"items"=>string_schema(;max=4096)),
    "query"=>string_schema(;max=4096),"limit"=>integer_schema(1,1000),"offset"=>integer_schema(0,100000));required=["action"])
function project_backend!(manager::ProjectManager,name::String)
    get!(manager.backends,name) do
        name=="tree_sitter" && return TreeSitterBackend()
        name=="go_ast" && return GoASTBackend()
        name=="codegraph" && return CodeGraphBackend()
        throw(ShenScopeError(:backend,"Unknown project backend"))
    end
end
function execute(tool::ProjectTool,args::AbstractDict,ctx::RuntimeContext)
    name=get(args,"backend","tree_sitter");manager=tool.manager
    backend=lock(manager.mutex) do;project_backend!(manager,name);end
    key=digest(ctx.root)*":"*name
    state=lock(manager.mutex) do;get(manager.states,key,nothing);end
    action=args["action"]
    if action!="build" && state===nothing
        candidate=ProjectState(ctx,backend)
        if isfile(candidate.journal.path)
            authorize!(ctx,:read,"project.cache",ctx.root)
            state=load_project(backend,ctx)
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
    authorize!(ctx,:read,"project.query",ctx.root)
    action=="status" && return project_status(state)
    action=="search" && return graph_search(state,get(args,"query","");limit=get(args,"limit",50),offset=get(args,"offset",0))
    analyzer=action=="impact" ? ImpactAnalyzer() : action=="test_selection" ? TestSelectionAnalyzer() : action=="architecture" ? ArchitectureAnalyzer() : nothing
    analyzer===nothing && throw(ShenScopeError(:arguments,"Unknown project action"))
    analyze(analyzer,state,args,ctx)
end
function cleanup_projects!(manager::ProjectManager)
    jobs=lock(manager.mutex) do;collect(values(manager.jobs));end
    for job in jobs
        get(job,"context",nothing)!==nothing && cancel!(job["context"].cancellation)
    end
    for backend in values(manager.backends);backend_close!(backend);end
    for job in jobs
        task=get(job,"task",nothing);task!==nothing && task!==current_task() && wait(task)
    end
end
