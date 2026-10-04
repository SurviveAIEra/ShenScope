using Test,ShenScope
isdefined(Main,:SnapshotFixtureBackend) || include("fixtures/project_storage_backend.jl")
include("fixtures/project_watch_backend.jl")
include("unit/project_watch.jl")
include("integration/project_watch_cli.jl")
