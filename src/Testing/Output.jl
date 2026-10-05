const PROJECT_TEST_CASE_STATUSES=("passed","failed","error","skipped","expected_failure","unexpected_success","unknown")
const PROJECT_TEST_MAX_CASES=1024
const PROJECT_TEST_MAX_FRAMES=256
const PROJECT_TEST_MAX_OUTPUT_LINES=20000

mutable struct ProjectTestOutput
    framework::String
    cases::Vector{Dict{String,Any}}
    frames::Vector{Dict{String,Any}}
    summary::Dict{String,Any}
    notes::Set{String}
    cases_truncated::Bool
    frames_truncated::Bool
    lines_truncated::Bool
    invalid_records::Int
end
ProjectTestOutput(framework)=ProjectTestOutput(String(framework),Dict{String,Any}[],Dict{String,Any}[],Dict(),Set(),false,false,false,0)

function project_test_output_lines!(value::ProjectTestOutput,text::String)
    lines=String[]
    for line in eachline(IOBuffer(text))
        length(lines)<PROJECT_TEST_MAX_OUTPUT_LINES || (value.lines_truncated=true;break)
        if ncodeunits(line)>65536
            push!(value.notes,"An oversized output line was not parsed.");value.invalid_records+=1;continue
        end
        # Terminal decorations are removed from interpreted fields only. The
        # receipt retains the original bounded stdout and stderr separately.
        cleaned=replace(line,r"\e\[[0-?]*[ -/]*[@-~]"=>"",r"[\x00-\x08\x0b-\x1f\x7f]"=>"")
        push!(lines,cleaned)
    end
    lines
end

function project_test_add_case!(value::ProjectTestOutput,name,status; suite="",duration=nothing,details="")
    status in PROJECT_TEST_CASE_STATUSES || throw(ShenScopeError(:testing,"Invalid parsed case status"))
    length(value.cases)<PROJECT_TEST_MAX_CASES || (value.cases_truncated=true;return)
    label=cliptext(String(name),2048);group=cliptext(String(suite),1024)
    body=Dict{String,Any}("name"=>label,"suite"=>group,"status"=>String(status),"duration_seconds"=>duration,
        "details"=>cliptext(String(details),2048),"source"=>"framework_reported")
    identity=Dict("framework"=>value.framework,"name"=>label,"suite"=>group,"occurrence"=>
        count(prior->prior["name"]==label && prior["suite"]==group,value.cases)+1)
    body["id"]=digest(canonical(identity));push!(value.cases,body)
    nothing
end

function project_test_output_location(ctx::RuntimeContext,cwd::String,path::AbstractString,line,column)
    ncodeunits(path)<=4096 && !occursin('\0',path) || return nothing
    name=String(strip(path))
    startswith(name,"file:///") && (name=name[8:end])
    occursin("://",name) && return nothing
    !Sys.iswindows() && occursin(r"^[A-Za-z]:[\\/]",name) && return nothing
    target=normpath(isabspath(name) ? name : joinpath(cwd,name))
    relative=relpath(target,ctx.root);parts=splitpath(relative)
    if isabspath(relative) || !isempty(parts) && first(parts)==".."
        return nothing
    end
    isempty(parts) && return nothing
    protected=Sys.iswindows() ? lowercase.(parts) : parts
    any(part->part in (".git",".env",".ssh",".aws"),protected) && return nothing
    startswith(last(protected),".env.") && return nothing
    number=tryparse(Int,String(line));col=column===nothing ? nothing : tryparse(Int,String(column))
    number!==nothing && 1<=number<=10_000_000 || return nothing
    column===nothing || col!==nothing && 1<=col<=1_000_000 || return nothing
    Dict{String,Any}("path"=>relative,"line"=>number,"column"=>col,
        "column_unit"=>"framework_reported_unspecified","source"=>"captured_output",
        "file_existence_checked"=>false,"source_snapshot_verified"=>false)
end

function project_test_add_frame!(value::ProjectTestOutput,ctx::RuntimeContext,cwd::String,path,line,column;stream)
    frame=project_test_output_location(ctx,cwd,path,line,column)
    frame===nothing && return
    frame["stream"]=String(stream);frame["id"]=digest(canonical(frame))
    any(prior->prior["id"]==frame["id"],value.frames) && return
    length(value.frames)<PROJECT_TEST_MAX_FRAMES || (value.frames_truncated=true;return)
    push!(value.frames,frame)
    nothing
end

function project_test_parse_frames!(value::ProjectTestOutput,ctx::RuntimeContext,cwd::String,lines;stream)
    for line in lines
        python=match(r"File \"([^\"]+)\", line ([1-9][0-9]{0,7})",line)
        if python!==nothing
            project_test_add_frame!(value,ctx,cwd,python[1],python[2],nothing;stream);continue
        end
        # Node stack frames and conventional compiler/test diagnostics. Paths
        # remain untrusted references until a separately authorized preview.
        cleaned=replace(strip(line),r"^at\s+"=>"")
        parenthesized=match(r"\(([^()]+):([1-9][0-9]{0,7}):([1-9][0-9]{0,6})\)",cleaned)
        direct=parenthesized===nothing ? match(r"^(.+?):([1-9][0-9]{0,7})(?::([1-9][0-9]{0,6}))?(?::|\s|$)",cleaned) : parenthesized
        direct===nothing || project_test_add_frame!(value,ctx,cwd,direct[1],direct[2],direct[3];stream)
    end
    nothing
end

function project_test_output_view(value::ProjectTestOutput)
    counts=Dict(status=>count(case->case["status"]==status,value.cases) for status in PROJECT_TEST_CASE_STATUSES)
    Dict("framework"=>value.framework,"cases"=>deepcopy(value.cases),"frames"=>deepcopy(value.frames),
        "observed_case_counts"=>counts,"framework_summary"=>deepcopy(value.summary),"notes"=>sort!(collect(value.notes)),
        "cases_truncated"=>value.cases_truncated,"frames_truncated"=>value.frames_truncated,
        "lines_truncated"=>value.lines_truncated,"invalid_records"=>value.invalid_records,
        "case_results_independently_verified"=>false,"complete_project_coverage"=>false)
end
