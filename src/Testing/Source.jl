function read_project_test_source(manager::ProjectTestManager,run_id,frame_id,ctx::RuntimeContext;
        context_lines=3,expected_sha256=nothing)
    radius=project_test_integer(context_lines,"test source context",0,20)
    report=read_project_test_report(manager,run_id,ctx)
    project_test_report_source(report,frame_id,ctx;context_lines=radius,expected_sha256)
end

function project_test_report_source(report::AbstractDict,frame_id,ctx::RuntimeContext;
        context_lines=3,expected_sha256=nothing)
    radius=project_test_integer(context_lines,"test source context",0,20)
    id=project_test_text(frame_id,"reported frame ID",64)
    position=findfirst(frame->frame["id"]==id,report["parsed"]["frames"])
    position===nothing && throw(ShenScopeError(:testing,"Reported source frame is absent from the owned test result"))
    frame=report["parsed"]["frames"][position]
    text=read_scoped_text(ctx,ctx.root,frame["path"],2*1024^2;tool="testing",reason="Read the current workspace source referenced by captured test output")
    sha=digest(text)
    if expected_sha256!==nothing
        hash=project_test_text(expected_sha256,"expected source hash",64)
        occursin(r"^[0-9a-f]{64}$",hash) || throw(ShenScopeError(:testing,"Invalid expected source hash"))
        hash==sha || throw(ShenScopeError(:conflict,"Test source preview changed; read the current source before opening it"))
    end
    lines=split(text,'\n';keepempty=true);line=frame["line"]
    line<=length(lines) || throw(ShenScopeError(:testing,"Reported line is outside the current source file"))
    first_line=max(1,line-radius);last_line=min(length(lines),line+radius)
    excerpt=[Dict("line"=>number,"text"=>cliptext(String(lines[number]),4096),"reported"=>number==line) for number in first_line:last_line]
    project_test_checkpoint(ctx;read_target=joinpath(ctx.root,frame["path"]))
    Dict("run_id"=>report["run_id"],"report_sha256"=>report["sha256"],"frame"=>deepcopy(frame),
        "path"=>frame["path"],"sha256"=>sha,"lines"=>excerpt,"first_line"=>first_line,"last_line"=>last_line,
        "execution_source_snapshot_verified"=>false,"description"=>"Current source referenced by captured output; not a source snapshot from the test execution.")
end
