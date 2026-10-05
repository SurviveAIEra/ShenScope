function project_test_candidate(marker::ProjectTestMarker;label,language,framework,cwd,argv,confidence="heuristic",notes=String[])
    framework in PROJECT_TEST_FRAMEWORKS || throw(ShenScopeError(:testing,"Unknown test reporting framework"))
    confidence in ("declared","heuristic") || throw(ShenScopeError(:testing,"Unknown test discovery confidence"))
    1<=length(argv)<=128 || throw(ShenScopeError(:testing,"Invalid test command size"))
    command=String[project_test_text(value,"test command argument",8192;empty=true) for value in argv]
    !isempty(first(command)) || throw(ShenScopeError(:testing,"Test executable cannot be empty"))
    note_values=String[project_test_text(value,"candidate note",1024) for value in notes]
    length(note_values)<=8 || throw(ShenScopeError(:testing,"Too many candidate notes"))
    provisional=ProjectTestCandidate("",project_test_text(label,"candidate label",512),
        project_test_text(language,"project language",64),String(framework),project_test_text(cwd,"test working directory",4096),
        command,[marker],String(confidence),note_values)
    id=digest(canonical(project_test_candidate_body(provisional)))
    ProjectTestCandidate(id,provisional.label,provisional.language,provisional.framework,provisional.cwd,
        provisional.argv,provisional.markers,provisional.confidence,provisional.notes)
end

function project_test_marker_candidates(marker::ProjectTestMarker,text::String)
    name=basename(marker.path);cwd=dirname(marker.path);isempty(cwd) && (cwd=".")
    result=ProjectTestCandidate[]
    candidate(;kwargs...)=project_test_candidate(marker;cwd,kwargs...)
    if name=="package.json"
        value=bounded_json_object(text;maximum=1024^2,max_depth=24,max_nodes=16384,error_code=:testing)
        scripts=get(value,"scripts",Dict());scripts isa AbstractDict || throw(ShenScopeError(:testing,"Package scripts must be an object"))
        if get(scripts,"test",nothing) isa AbstractString && !isempty(strip(scripts["test"]))
            push!(result,candidate(label="Package test script",language="javascript/typescript",framework="raw",argv=["npm","test"],confidence="declared",
                notes=["Runs the declared package test script. Output format and dependency availability are not inferred."]))
        end
    elseif name in ("pytest.ini","pyproject.toml")
        pytest=name=="pytest.ini"
        if name=="pyproject.toml"
            value=try TOML.parse(text) catch;throw(ShenScopeError(:testing,"Invalid Python project TOML"));end
            tools=get(value,"tool",Dict());tools isa AbstractDict || throw(ShenScopeError(:testing,"Python tool declarations must be an object"))
            pytest=haskey(tools,"pytest")
        end
        if pytest
            push!(result,candidate(label="Python pytest",language="python",framework="pytest",argv=["python3","-m","pytest","-q"],confidence="declared"))
        else
            push!(result,candidate(label="Python unittest discovery",language="python",framework="unittest",argv=["python3","-m","unittest","discover","-v"],
                notes=["A Python project marker alone does not establish unittest use or any collected tests."]))
        end
    elseif name=="go.mod"
        occursin(r"(?m)^\s*module\s+\S+",text) || throw(ShenScopeError(:testing,"Go module declaration is absent"))
        push!(result,candidate(label="Go package tests",language="go",framework="go_json",argv=["go","test","-json","./..."]))
    elseif name=="Cargo.toml"
        value=try TOML.parse(text) catch;throw(ShenScopeError(:testing,"Invalid Cargo TOML"));end
        haskey(value,"package") || haskey(value,"workspace") || throw(ShenScopeError(:testing,"Cargo package/workspace declaration is absent"))
        push!(result,candidate(label="Cargo tests",language="rust",framework="raw",argv=["cargo","test"],notes=["Stable Cargo text is retained; individual test events are not assumed to be machine-readable JSON."]))
    elseif name=="CMakeLists.txt"
        push!(result,candidate(label="CTest in existing build directory",language="c/c++",framework="ctest",argv=["ctest","--test-dir","build","--output-on-failure"],
            notes=["Requires an existing configured build directory; discovery does not configure or compile it."]))
    elseif name=="Makefile" && occursin(r"(?m)^test\s*:",text)
        push!(result,candidate(label="Make test target",language="any",framework="raw",argv=["make","test"],confidence="declared"))
    elseif name=="pom.xml"
        push!(result,candidate(label="Maven tests",language="java/jvm",framework="raw",argv=["mvn","test"],notes=["Maven may compile and use the network; ordinary execution policy still applies."]))
    elseif name in ("build.gradle","build.gradle.kts")
        push!(result,candidate(label="Gradle tests",language="java/kotlin/jvm",framework="raw",argv=["gradle","test"],notes=["Uses the explicitly authorized Gradle executable; project wrappers are not automatically selected."]))
    elseif endswith(name,".csproj") || endswith(name,".fsproj") || endswith(name,".sln")
        push!(result,candidate(label=".NET tests",language="c#/f#/dotnet",framework="raw",argv=["dotnet","test",name]))
    elseif name=="composer.json"
        value=bounded_json_object(text;maximum=1024^2,max_depth=24,max_nodes=16384,error_code=:testing)
        scripts=get(value,"scripts",Dict());scripts isa AbstractDict || throw(ShenScopeError(:testing,"Composer scripts must be an object"))
        declaration=get(scripts,"test",nothing)
        declared=declaration isa AbstractString && !isempty(strip(declaration)) ||
            declaration isa AbstractVector && !isempty(declaration) && all(item->item isa AbstractString && !isempty(strip(item)),declaration)
        declared && push!(result,candidate(label="Composer test script",language="php",framework="raw",argv=["composer","run-script","test"],confidence="declared"))
    elseif name=="Rakefile"
        push!(result,candidate(label="Rake test task",language="ruby",framework="raw",argv=["rake","test"]))
    elseif name=="Project.toml"
        value=try TOML.parse(text) catch;throw(ShenScopeError(:testing,"Invalid Julia project TOML"));end
        haskey(value,"name") && push!(result,candidate(label="Julia package tests",language="julia",framework="raw",
            argv=["julia","--startup-file=no","--project=.","-e","using Pkg; Pkg.test()"],notes=["Package testing can resolve dependencies; discovery does not instantiate the project."]))
    end
    result
end

function project_test_custom_candidate(ctx::RuntimeContext,argv;cwd=".",framework="raw",label="Explicit test command")
    argv isa AbstractVector && 1<=length(argv)<=128 || throw(ShenScopeError(:testing,"A bounded argument vector is required"))
    command=String[project_test_text(value,"test command argument",8192;empty=true) for value in argv]
    !isempty(first(command)) || throw(ShenScopeError(:testing,"Test executable cannot be empty"))
    framework in PROJECT_TEST_FRAMEWORKS || throw(ShenScopeError(:testing,"Unknown test reporting framework"))
    path=project_test_workspace_directory(ctx,cwd)
    provisional=ProjectTestCandidate("",project_test_text(label,"candidate label",512),"any",String(framework),
        relpath(path,ctx.root),command,ProjectTestMarker[],"explicit",
        ["The caller selected this command and output format. This does not establish test coverage or installed dependencies."])
    ProjectTestCandidate(digest(canonical(project_test_candidate_body(provisional))),provisional.label,provisional.language,
        provisional.framework,provisional.cwd,provisional.argv,provisional.markers,provisional.confidence,provisional.notes)
end

function project_test_is_marker(name::AbstractString)
    name in ("package.json","pyproject.toml","pytest.ini","go.mod","Cargo.toml","CMakeLists.txt","Makefile",
        "pom.xml","build.gradle","build.gradle.kts","composer.json","Rakefile","Project.toml") ||
        endswith(name,".csproj") || endswith(name,".fsproj") || endswith(name,".sln")
end
