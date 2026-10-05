const PROJECT_TEST_HISTORY_SCHEMA="shenscope.project-test-history/1"

struct ProjectTestHistoryLimits
    reports::Int
    report_bytes::Int
    snapshot_bytes::Int
end
function ProjectTestHistoryLimits(;reports=32,report_bytes=4*1024^2,snapshot_bytes=16*1024^2)
    values=(project_test_integer(reports,"saved test report limit",1,32),
        project_test_integer(report_bytes,"saved test report byte limit",4096,4*1024^2),
        project_test_integer(snapshot_bytes,"saved test history byte limit",4096,16*1024^2))
    values[2]<=values[3] || throw(ShenScopeError(:testing,"One saved result cannot exceed history capacity"))
    ProjectTestHistoryLimits(values...)
end

struct ProjectTestHistoryStore
    directory::String
    workspace_sha256::String
    session_id::String
    limits::ProjectTestHistoryLimits
end
function project_test_history_store(ctx::RuntimeContext;limits=ProjectTestHistoryLimits())
    session=valid_id(ctx.session_id);workspace=digest(ctx.root)
    directory=joinpath(ctx.state_dir,"project-tests",workspace,digest(session))
    ProjectTestHistoryStore(directory,workspace,session,limits)
end
project_test_history_owner(store::ProjectTestHistoryStore)=Dict("workspace_sha256"=>store.workspace_sha256,"session_id"=>store.session_id)
project_test_history_target(store::ProjectTestHistoryStore)=canonical(merge(project_test_history_owner(store),Dict("purpose"=>"saved_project_tests")))
project_test_history_path(store::ProjectTestHistoryStore)=joinpath(store.directory,"history.json")
project_test_history_revision(value)=project_test_integer(value,"saved test history revision",0,typemax(Int)-2)
function project_test_history_hash(value,label="saved test digest")
    text=project_test_text(value,label,64)
    occursin(r"^[0-9a-f]{64}$",text) || throw(ShenScopeError(:testing,"Invalid "*label))
    text
end
function project_test_history_timestamp(value)
    text=project_test_text(value,"saved test timestamp",64)
    endswith(text,"Z") && tryparse(DateTime,chop(text;tail=1))!==nothing ||
        throw(ShenScopeError(:testing,"Invalid saved test UTC timestamp"))
    text
end
function project_test_history_empty(store::ProjectTestHistoryStore)
    value=Dict{String,Any}("schema"=>PROJECT_TEST_HISTORY_SCHEMA,"owner"=>project_test_history_owner(store),
        "revision"=>0,"entries"=>Any[])
    value["sha256"]=digest(canonical(value));value
end
