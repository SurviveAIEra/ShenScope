struct SnapshotFixtureBackend <: ShenScope.AbstractProjectDataBackend end
ShenScope.backend_capabilities(::SnapshotFixtureBackend)=BackendCapabilities(;name="snapshot_fixture",languages=["julia"])
function ShenScope.extract_files(::SnapshotFixtureBackend,documents,ctx;all_documents=documents,deleted=String[],full=false)
    [begin
        path=document["path"];range=SourceRange(path,1,1;end_column=ncodeunits(document["source"])+1)
        id=ShenScope.symbol_id(path,"fixture");symbol=CodeSymbol(id,:function,"Fixture",path,range,:julia,
            Dict{String,Any}("source"=>document["source"]))
        FileFacts(path,document["sha256"],CodeSymbol[symbol],Relation[],CallReference[],Dict{String,Any}[])
    end for document in documents]
end
