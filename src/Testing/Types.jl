const PROJECT_TEST_CATALOG_SCHEMA="shenscope.project-test-catalog/1"
const PROJECT_TEST_REPORT_SCHEMA="shenscope.project-test-report/1"
const PROJECT_TEST_FRAMEWORKS=("unittest","pytest","tap","go_json","ctest","raw")
const PROJECT_TEST_DISCOVERY_NOTES=[
    "Discovery reads project declarations; it does not execute tests or prove a runner is installed.",
    "Candidates can execute project code and require explicit Process permission.",
    "Marker hashes identify the selected declaration, not a snapshot of every project source file."]

function project_test_integer(value,label,minimum,maximum)
    value isa Integer && !(value isa Bool) && minimum<=value<=maximum ||
        throw(ShenScopeError(:testing,"Invalid "*label))
    Int(value)
end
function project_test_text(value,label,maximum;empty=false)
    value isa AbstractString && isvalid(value) && ncodeunits(value)<=maximum && !occursin('\0',value) &&
        (empty || !isempty(strip(value))) || throw(ShenScopeError(:testing,"Invalid "*label))
    String(value)
end
function project_test_fields(value,fields,label)
    value isa AbstractDict && Set(keys(value))==Set(fields) || throw(ShenScopeError(:testing,"Invalid "*label*" fields"))
    value
end

struct ProjectTestDiscoveryLimits
    files::Int
    directories::Int
    depth::Int
    directory_entries::Int
    marker_bytes::Int
    total_marker_bytes::Int
    candidates::Int
end
function ProjectTestDiscoveryLimits(;files=512,directories=128,depth=4,directory_entries=4096,
        marker_bytes=256*1024,total_marker_bytes=2*1024^2,candidates=64)
    values=(project_test_integer(files,"discovery file bound",1,4096),
        project_test_integer(directories,"discovery directory bound",1,1024),
        project_test_integer(depth,"discovery depth",0,12),
        project_test_integer(directory_entries,"directory entry bound",1,16384),
        project_test_integer(marker_bytes,"marker byte bound",64,1024^2),
        project_test_integer(total_marker_bytes,"total marker byte bound",64,8*1024^2),
        project_test_integer(candidates,"candidate bound",1,256))
    values[5]<=values[6] || throw(ShenScopeError(:testing,"One marker cannot exceed the total marker bound"))
    ProjectTestDiscoveryLimits(values...)
end
project_test_limits_view(value::ProjectTestDiscoveryLimits)=Dict(String(name)=>getfield(value,name) for name in fieldnames(ProjectTestDiscoveryLimits))

struct ProjectTestMarker
    path::String
    sha256::String
    bytes::Int
end
project_test_marker_view(value::ProjectTestMarker)=Dict("path"=>value.path,"sha256"=>value.sha256,"bytes"=>value.bytes)

struct ProjectTestCandidate
    id::String
    label::String
    language::String
    framework::String
    cwd::String
    argv::Vector{String}
    markers::Vector{ProjectTestMarker}
    confidence::String
    notes::Vector{String}
end
function project_test_candidate_body(value::ProjectTestCandidate)
    Dict("label"=>value.label,"language"=>value.language,"framework"=>value.framework,"cwd"=>value.cwd,
        "argv"=>copy(value.argv),"markers"=>project_test_marker_view.(value.markers),"confidence"=>value.confidence,"notes"=>copy(value.notes))
end
project_test_candidate_view(value::ProjectTestCandidate)=merge(project_test_candidate_body(value),Dict("id"=>value.id))

struct ProjectTestCatalog
    id::String
    owner::String
    root_sha256::String
    created_at::String
    scopes::Vector{String}
    candidates::Vector{ProjectTestCandidate}
    markers::Vector{ProjectTestMarker}
    coverage::Dict{String,Any}
    limits::ProjectTestDiscoveryLimits
end
function project_test_catalog_body(value::ProjectTestCatalog)
    Dict("schema"=>PROJECT_TEST_CATALOG_SCHEMA,"session_id"=>value.owner,"root_sha256"=>value.root_sha256,
        "created_at"=>value.created_at,"scopes"=>copy(value.scopes),"candidates"=>project_test_candidate_view.(value.candidates),
        "markers"=>project_test_marker_view.(value.markers),"coverage"=>deepcopy(value.coverage),
        "limits"=>project_test_limits_view(value.limits),"limitations"=>copy(PROJECT_TEST_DISCOVERY_NOTES))
end
project_test_catalog_view(value::ProjectTestCatalog)=merge(project_test_catalog_body(value),Dict("catalog_id"=>value.id))

mutable struct ProjectTestManager
    catalogs::Dict{String,Tuple{Tuple{String,String,String},ProjectTestCatalog}}
    reports::Dict{String,Tuple{Tuple{String,String,String},Dict{String,Any},Int}}
    mutex::ReentrantLock
    processes::ProcessManager
    max_catalogs::Int
    max_reports::Int
    max_report_bytes::Int
    max_retained_bytes::Int
end
function ProjectTestManager(;max_catalogs=32,max_reports=32,max_report_bytes=4*1024^2,max_retained_bytes=16*1024^2)
    capacities=(project_test_integer(max_catalogs,"catalog capacity",1,128),
        project_test_integer(max_reports,"report capacity",1,128),
        project_test_integer(max_report_bytes,"report byte capacity",4096,8*1024^2),
        project_test_integer(max_retained_bytes,"retained report byte capacity",4096,64*1024^2))
    capacities[3]<=capacities[4] || throw(ShenScopeError(:testing,"A report cannot exceed total retention"))
    ProjectTestManager(Dict(),Dict(),ReentrantLock(),ProcessManager(),capacities...)
end

function project_test_checkpoint(ctx::RuntimeContext;read_target=nothing)
    check_cancelled(ctx.cancellation)
    lock(ctx.budget.mutex) do;check_budget(ctx.budget);end
    read_target===nothing || permission_decision(ctx.permissions,PermissionRequest(
        "testing-read-current",:read,"testing",String(read_target),"Read current project test data"))!=Deny ||
        throw(ShenScopeError(:permission,"Project test data is now denied"))
    nothing
end

function project_test_workspace_directory(ctx::RuntimeContext,value)
    requested=project_test_text(value,"test working directory",4096)
    original=normpath(isabspath(requested) ? requested : joinpath(ctx.root,requested))
    dirname(original)==original || (original=rstrip(original,Sys.iswindows() ? ('/','\\') : ('/',)))
    target=workspace_path(ctx.root,requested)
    original==target && !islink(original) && isdir(target) ||
        throw(ShenScopeError(:permission,"Test working directory must be an ordinary workspace directory"))
    target
end
