function project_test_parse_unittest!(value::ProjectTestOutput,lines)
    statuses=Dict("ok"=>"passed","FAIL"=>"failed","ERROR"=>"error","skipped"=>"skipped",
        "expected failure"=>"expected_failure","unexpected success"=>"unexpected_success")
    for line in lines
        case=match(r"^(.+?) \((.+?)\) \.\.\. (ok|FAIL|ERROR|skipped|expected failure|unexpected success)(?: (.*))?$",strip(line))
        case===nothing || project_test_add_case!(value,case[2],statuses[case[3]];details=something(case[4],""))
        total=match(r"^Ran ([0-9]{1,8}) tests? in ([0-9]+(?:\.[0-9]+)?)s$",strip(line))
        if total!==nothing
            value.summary["tests"]=parse(Int,total[1]);value.summary["duration_seconds"]=parse(Float64,total[2])
        end
        result=match(r"^(OK|FAILED)(?: \((.*)\))?$",strip(line))
        if result!==nothing
            value.summary["status"]=result[1]=="OK" ? "passed" : "failed"
            for count in eachmatch(r"(failures|errors|skipped|expected failures|unexpected successes)=([0-9]{1,8})",something(result[2],""))
                value.summary[replace(count[1],' '=>'_')]=parse(Int,count[2])
            end
        end
    end
    nothing
end

function project_test_parse_pytest!(value::ProjectTestOutput,lines)
    statuses=Dict("PASSED"=>"passed","FAILED"=>"failed","ERROR"=>"error","SKIPPED"=>"skipped","XFAIL"=>"expected_failure","XPASS"=>"unexpected_success")
    for line in lines
        case=match(r"^(.+?::\S+)\s+(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS)(?:\s|$)",strip(line))
        case===nothing || project_test_add_case!(value,case[1],statuses[case[2]])
        failure=match(r"^(FAILED|ERROR) (.+?::\S+)(?:\s+-\s+(.*))?$",strip(line))
        if failure!==nothing && !any(case->case["name"]==failure[2],value.cases)
            project_test_add_case!(value,failure[2],statuses[failure[1]];details=something(failure[3],""))
        end
        # Pytest's terse progress dots are not invented individual cases.
        if occursin(r"[0-9]+ (?:passed|failed|error|errors|skipped|xfailed|xpassed|deselected)",line)
            for count in eachmatch(r"([0-9]{1,8}) (passed|failed|errors?|skipped|xfailed|xpassed|deselected)\b",line)
                value.summary[count[2]=="error" ? "errors" : String(count[2])]=parse(Int,count[1])
            end
        end
        occursin(r"\bno tests ran\b",line) && (value.summary["tests"]=0)
    end
    nothing
end

function project_test_parse_tap!(value::ProjectTestOutput,lines)
    statuses=Dict{Int,String}();plan=nothing
    for line in lines
        startswith(line,"    ") && continue # Nested subtests are not flattened into duplicate parents.
        entry=match(r"^(not ok|ok) ([0-9]{1,8})(?:\s+-?\s*(.*))?$",strip(line))
        if entry!==nothing
            number=parse(Int,entry[2]);haskey(statuses,number) && (value.invalid_records+=1;continue)
            label=something(entry[3],"test "*entry[2]);directive=match(r"\s+#\s*(SKIP|TODO)\b(.*)$"i,label)
            status=entry[1]=="ok" ? "passed" : "failed"
            if directive!==nothing
                status=uppercase(directive[1])=="SKIP" ? "skipped" : (entry[1]=="ok" ? "unexpected_success" : "expected_failure")
                label=first(split(label,'#';limit=2))
            end
            length(statuses)<PROJECT_TEST_MAX_CASES || (value.cases_truncated=true;continue)
            statuses[number]=status;project_test_add_case!(value,strip(label),status;details=directive===nothing ? "" : strip(directive[2]))
        end
        declared=match(r"^1\.\.([0-9]{1,8})(?:\s+#.*)?$",strip(line))
        if declared!==nothing
            plan===nothing || (value.invalid_records+=1)
            plan=parse(Int,declared[1]);value.summary["tests"]=plan
        end
        startswith(strip(line),"Bail out!") && (value.summary["bailout"]=cliptext(strip(line),1024))
    end
    if plan!==nothing
        complete=length(statuses)==plan && all(number->1<=number<=plan,keys(statuses))
        value.summary["plan_matches_observed_top_level_cases"]=complete
        complete || push!(value.notes,"The TAP plan does not match retained top-level case records.")
    else
        push!(value.notes,"No top-level TAP plan was captured.")
    end
    nothing
end

function project_test_parse_go!(value::ProjectTestOutput,lines;ctx=nothing,cwd=nothing)
    terminal=Set{Tuple{String,String}}();packages=Dict{String,String}()
    for line in lines
        isempty(strip(line)) && continue
        record=try
            bounded_json_object(line;maximum=65536,max_depth=8,max_nodes=512,error_code=:testing)
        catch cause
            cause isa ShenScopeError || rethrow()
            value.invalid_records+=1;continue
        end
        action=get(record,"Action",nothing);action isa AbstractString || (value.invalid_records+=1;continue)
        output=get(record,"Output",nothing)
        if output isa String && ctx!==nothing
            project_test_parse_frames!(value,ctx,cwd,project_test_output_lines!(value,output);stream="stdout")
        end
        action in ("pass","fail","skip") || continue
        package=get(record,"Package",nothing);package isa AbstractString && ncodeunits(package)<=1024 || (value.invalid_records+=1;continue)
        test=get(record,"Test",nothing);status=action=="pass" ? "passed" : action=="fail" ? "failed" : "skipped"
        if test===nothing
            length(packages)<1024 || (value.cases_truncated=true;continue)
            packages[String(package)]=status;continue
        end
        test isa AbstractString && ncodeunits(test)<=2048 || (value.invalid_records+=1;continue)
        key=(String(package),String(test));key in terminal && (value.invalid_records+=1;continue)
        length(terminal)<PROJECT_TEST_MAX_CASES || (value.cases_truncated=true;continue)
        elapsed=get(record,"Elapsed",nothing)
        elapsed===nothing || elapsed isa Real && !(elapsed isa Bool) && isfinite(elapsed) && 0<=elapsed<=86400 || (value.invalid_records+=1;continue)
        push!(terminal,key);project_test_add_case!(value,test,status;suite=package,duration=elapsed)
    end
    value.summary["packages"]=packages
    value.summary["packages_failed"]=count(status->status=="failed",values(packages))
    nothing
end

function project_test_parse_ctest!(value::ProjectTestOutput,lines)
    for line in lines
        case=match(r"^\s*[0-9]{1,8}/[0-9]{1,8} Test\s+#[0-9]{1,8}: (.+?)\s+\.+\s+(Passed|\*\*\*Failed|\*\*\*Exception[^0-9]*|\*\*\*Not Run)(?:\s+([0-9.]+) sec)?\s*$",line)
        if case!==nothing
            status=case[2]=="Passed" ? "passed" : occursin("Not Run",case[2]) ? "skipped" : occursin("Exception",case[2]) ? "error" : "failed"
            seconds=case[3]===nothing ? nothing : tryparse(Float64,case[3])
            seconds!==nothing && (!isfinite(seconds) || seconds<0) && (seconds=nothing)
            project_test_add_case!(value,case[1],status;duration=seconds)
        end
        summary=match(r"([0-9]{1,3})% tests passed, ([0-9]{1,8}) tests failed out of ([0-9]{1,8})",line)
        if summary!==nothing
            value.summary["failed"]=parse(Int,summary[2]);value.summary["tests"]=parse(Int,summary[3])
        end
        occursin("No tests were found",line) && (value.summary["tests"]=0)
    end
    nothing
end

function parse_project_test_output(framework,stdout::String,stderr::String,ctx::RuntimeContext,cwd::String)
    framework in PROJECT_TEST_FRAMEWORKS || throw(ShenScopeError(:testing,"Unknown test reporting framework"))
    value=ProjectTestOutput(framework)
    out=project_test_output_lines!(value,stdout);err=project_test_output_lines!(value,stderr)
    framework=="go_json" || project_test_parse_frames!(value,ctx,cwd,out;stream="stdout")
    project_test_parse_frames!(value,ctx,cwd,err;stream="stderr")
    parser=framework=="unittest" ? project_test_parse_unittest! : framework=="pytest" ? project_test_parse_pytest! :
        framework=="tap" ? project_test_parse_tap! : framework=="go_json" ? project_test_parse_go! :
        framework=="ctest" ? project_test_parse_ctest! : nothing
    if parser!==nothing
        if framework=="go_json"
            parser(value,out;ctx,cwd)
        else
            parser(value,vcat(out,err))
        end
    else
        push!(value.notes,"Raw output is retained; no individual framework cases are inferred.")
    end
    project_test_output_view(value)
end
