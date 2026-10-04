mutable struct WatchFixtureBackend <: ShenScope.AbstractProjectDataBackend
    attempts::Int
end
WatchFixtureBackend()=WatchFixtureBackend(0)
ShenScope.backend_capabilities(::WatchFixtureBackend)=BackendCapabilities(;name="watch_fixture",languages=["julia"])
function ShenScope.extract_files(backend::WatchFixtureBackend,documents,ctx;all_documents=documents,deleted=String[],full=false)
    backend.attempts+=1
    any(document->startswith(document["source"],"reject"),documents) &&
        throw(ShenScopeError(:fixture_rejection,"Explicit storage fixture rejection"))
    ShenScope.extract_files(SnapshotFixtureBackend(),documents,ctx;all_documents,deleted,full)
end
