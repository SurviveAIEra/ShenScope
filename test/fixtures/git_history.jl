struct HistoryFixtureBackend <: ShenScope.AbstractProjectDataBackend end
ShenScope.backend_capabilities(::HistoryFixtureBackend) = BackendCapabilities(;name="history_fixture", languages=["julia"])

function ShenScope.extract_files(::HistoryFixtureBackend, documents, ctx;all_documents=documents, deleted=String[], full=false)
    [begin
        path = document["path"]
        id = ShenScope.symbol_id("history_fixture", path)
        location = SourceRange(path, 1, 1)
        symbol = CodeSymbol(id, :function, basename(path), path, location, :julia, Dict{String,Any}())
        relations = path == "b.jl" && any(item -> item["path"] == "a.jl", all_documents) ?
            [Relation(id, ShenScope.symbol_id("history_fixture", "a.jl"), :calls, location;provenance="fixture")] : Relation[]
        FileFacts(path, document["sha256"], [symbol], relations, CallReference[], Dict{String,Any}[])
    end for document in documents]
end

function history_fixture_git(root::String, arguments::String...;capture=false, environment=Dict{String,String}())
    env = merge(ShenScope.git_history_environment(), Dict("GIT_AUTHOR_DATE" => "2026-10-01T12:00:00Z",
        "GIT_COMMITTER_DATE" => "2026-10-01T12:00:00Z"), environment)
    command = setenv(Cmd(Cmd(vcat(["git", "-c", "user.name=History Fixture", "-c", "user.email=fixture@example.invalid"], collect(arguments)));dir=root), env)
    capture ? String(chomp(read(command, String))) : run(pipeline(command;stdout=devnull, stderr=devnull))
end

function history_fixture_commit(root::String)
    history_fixture_git(root, "add", "--all", "--", ".")
    history_fixture_git(root, "commit", "--allow-empty", "--no-gpg-sign", "-m", "fixture change")
    history_fixture_git(root, "rev-parse", "HEAD";capture=true)
end

function history_fixture_repository(root::String)
    history_fixture_git(root, "init", "--object-format=sha1", "--initial-branch=main")
    special = "空间 \t中文\ncode.jl"
    for path in ("a.jl", "b.jl", "c.jl", special)
        write(joinpath(root, path), "fixture() = 1\n")
    end
    ids = [history_fixture_commit(root)]
    for paths in (("a.jl", "b.jl"), ("b.jl", "c.jl"), ("a.jl", "b.jl"))
        for path in paths; open(io -> write(io, "# changed\n"), joinpath(root, path), "a"); end
        push!(ids, history_fixture_commit(root))
    end
    push!(ids, history_fixture_commit(root))
    write(joinpath(root, "binary.bin"), UInt8[0x00, 0x01, 0x02])
    push!(ids, history_fixture_commit(root))
    history_fixture_git(root, "mv", "--", special, "renamed 中文.jl")
    push!(ids, history_fixture_commit(root))
    ids, special
end

function history_fixture_context(root::String;permissions=PermissionPolicy(;rules=Dict(:read=>Allow,
        :process=>Allow, :persistence=>Allow, :network=>Deny)), kwargs...)
    RuntimeContext(root;state_dir=joinpath(root, "state"), permissions, kwargs...)
end

function history_test_record(id::String, parents::Vector{String}, records::Vector{String};timestamp="1790856000")
    "\0" * id * "\0" * join(parents, ' ') * "\0" * timestamp * "\0\0" *
        (isempty(records) ? "" : "\n" * join(records, '\0') * "\0")
end
