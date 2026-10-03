struct ContractOperation
    name::Symbol
    callable::Function
    arguments::Type
    required::Bool
    fallback::Union{Nothing,Method}
end
function contract_operation(name,f,arguments,baseline;required=true)
    # A broad abstract signature may intersect many concrete implementations.
    # Only a method that covers the entire baseline is its default contract.
    signature=Tuple{typeof(f),baseline.parameters...}
    defaults=[method for method in methods(f) if signature<:method.sig]
    fallback=length(defaults)==1 ? only(defaults) : nothing
    ContractOperation(name,f,arguments,required,fallback)
end
function contract_operations(::Type{T}) where {T<:AbstractTool}
    [contract_operation(:name,tool_name,Tuple{T},Tuple{AbstractTool}),
     contract_operation(:schema,tool_schema,Tuple{T},Tuple{AbstractTool}),
     contract_operation(:execute,execute,Tuple{T,Dict{String,Any},RuntimeContext},Tuple{AbstractTool,Dict{String,Any},RuntimeContext}),
     contract_operation(:description,tool_description,Tuple{T},Tuple{AbstractTool};required=false),
     contract_operation(:mode,execution_mode,Tuple{T},Tuple{AbstractTool};required=false)]
end
function contract_operations(::Type{T}) where {T<:AbstractModelProvider}
    [contract_operation(:stream,stream_chat,Tuple{T,ModelRequest,Function,RuntimeContext},Tuple{AbstractModelProvider,ModelRequest,Function,RuntimeContext}),
     contract_operation(:name,provider_name,Tuple{T},Tuple{AbstractModelProvider};required=false),
     contract_operation(:capabilities,capabilities,Tuple{T},Tuple{AbstractModelProvider};required=false)]
end
function contract_operations(::Type{T}) where {T<:AbstractProjectDataBackend}
    [contract_operation(:capabilities,backend_capabilities,Tuple{T},Tuple{AbstractProjectDataBackend}),
     contract_operation(:extract,extract_files,Tuple{T,Vector{Dict{String,Any}},RuntimeContext},Tuple{AbstractProjectDataBackend,Vector{Dict{String,Any}},RuntimeContext}),
     contract_operation(:close,backend_close!,Tuple{T},Tuple{AbstractProjectDataBackend};required=false)]
end
function contract_operations(::Type{T}) where {T<:AbstractAnalyzer}
    [contract_operation(:name,analyzer_name,Tuple{T},Tuple{AbstractAnalyzer}),
     contract_operation(:analyze,analyze,Tuple{T,ProjectState,Dict{String,Any},RuntimeContext},Tuple{AbstractAnalyzer,ProjectState,Dict{String,Any},RuntimeContext}),
     contract_operation(:requirements,requirements,Tuple{T},Tuple{AbstractAnalyzer};required=false)]
end
contract_operations(::Type)=throw(ShenScopeError(:extension,"No contract exists for this extension type"))

function method_evidence(method::Method)
    file=String(method.file);source_root=dirname(@__DIR__)
    relative=try;relpath(file,source_root);catch;basename(file);end
    startswith(relative,"..") && (relative=basename(file))
    Dict("module"=>string(method.module),"signature"=>cliptext(string(method.sig),2048),
        "file"=>relative,"line"=>method.line)
end
function contract_report(::Type{T}) where T
    isconcretetype(T) || throw(ShenScopeError(:extension,"Inspect a concrete extension type"))
    operations=Dict{String,Any}[]
    for operation in contract_operations(T)
        selected=hasmethod(operation.callable,operation.arguments) ? which(operation.callable,operation.arguments) : nothing
        status=selected===nothing ? "missing_or_ambiguous" : selected===operation.fallback ? "default" : "implemented"
        valid=status=="implemented" || !operation.required && status=="default"
        result=Dict{String,Any}("operation"=>String(operation.name),"required"=>operation.required,"status"=>status,"valid"=>valid)
        selected===nothing || (result["method"]=method_evidence(selected))
        push!(operations,result)
    end
    Dict("type"=>string(T),"module"=>string(parentmodule(T)),"valid"=>all(r->r["valid"],operations),"operations"=>operations)
end
contract_report(instance)=contract_report(typeof(instance))

function interface_functions()
    [tool_name,tool_schema,tool_description,execution_mode,execute,provider_name,capabilities,stream_chat,
        backend_capabilities,extract_files,backend_close!,analyzer_name,requirements,analyze]
end
function dispatch_ambiguities(functions::AbstractVector;max_pairs=10000,limit=128,ctx=nothing)
    1<=max_pairs<=100000 && 1<=limit<=1000 || throw(ShenScopeError(:extension,"Invalid ambiguity scan limits"))
    length(functions)<=64 && all(f->f isa Function,functions) || throw(ShenScopeError(:extension,"Invalid interface function set"))
    checked=0;found=Dict{String,Any}[];truncated=false
    for f in unique(functions)
        selected=collect(methods(f));length(selected)<=1000 || throw(ShenScopeError(:extension,"Interface method limit reached"))
        for i in 1:length(selected),j in i+1:length(selected)
            ctx!==nothing && check_cancelled(ctx.cancellation)
            if checked>=max_pairs || length(found)>=limit;truncated=true;break;end
            checked+=1
            if Base.isambiguous(selected[i],selected[j])
                push!(found,Dict("function"=>string(nameof(f)),"first"=>method_evidence(selected[i]),"second"=>method_evidence(selected[j])))
            end
        end
        truncated && break
    end
    Dict("ambiguities"=>found,"checked_pairs"=>checked,"truncated"=>truncated,
        "scope"=>"Specified loaded interface functions; unrelated dependencies are not scanned")
end
dispatch_ambiguities(;kwargs...)=dispatch_ambiguities(interface_functions();kwargs...)

function interface_catalog()
    types=DataType[ReadTool,SearchTool,EditTool,WriteTool,PatchTool,ProcessTool,GitTool,MemoryTool,ProjectTool,
        HTTPProvider,MockProvider,GoASTBackend,TreeSitterBackend,CodeGraphBackend,TypeScriptSemanticBackend,ImpactAnalyzer,TestSelectionAnalyzer,ArchitectureAnalyzer]
    isdefined(@__MODULE__,:DiagnosticsTool) && push!(types,DiagnosticsTool)
    contract_report.(types)
end

# An explicit boundary for already loaded, trusted Julia extension callables.
# It neither loads source nor makes Module/world age an isolation mechanism.
function invoke_extension_latest(f::Function,args...;ctx::RuntimeContext,target=string(parentmodule(f))*"."*string(nameof(f)))
    authorize!(ctx,:dynamic,"extension.invoke",target;reason="Invoke an already loaded trusted Julia extension")
    result=Base.invokelatest(f,args...)
    check_cancelled(ctx.cancellation);result
end
