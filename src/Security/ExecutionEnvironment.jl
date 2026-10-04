function execution_environment(policy::ExecutionPolicy;source=ENV,overlay=nothing)
    overlay===nothing || overlay isa AbstractDict || overlay isa AbstractVector{<:Pair} ||
        throw(ShenScopeError(:arguments,"Execution environment must be key/value pairs"))
    supplied=overlay===nothing ? Dict{String,String}() : Dict{String,String}(overlay)
    result=Dict{String,String}("PATH"=>"/usr/local/bin:/usr/bin:/bin","HOME"=>"/tmp/shenscope-home",
        "TMPDIR"=>"/tmp","XDG_CACHE_HOME"=>"/tmp/shenscope-cache","USER"=>"shenscope","LOGNAME"=>"shenscope")
    allowed=Set(policy.environment_keys)
    for key in keys(supplied)
        key in allowed || throw(ShenScopeError(:permission,"Restricted execution rejects undeclared environment keys"))
    end
    for key in policy.environment_keys
        value=get(supplied,key,get(source,key,nothing))
        value===nothing && continue
        value isa AbstractString && isvalid(value) && !occursin('\0',value) && ncodeunits(value)<=4096 ||
            throw(ShenScopeError(:arguments,"Invalid restricted environment value"))
        result[key]=String(value)
    end
    sum(ncodeunits(key)+ncodeunits(value)+2 for (key,value) in result)<=EXECUTION_MAX_ENVIRONMENT_BYTES ||
        throw(ShenScopeError(:capacity,"Restricted environment exceeds its byte capacity"))
    Tuple(sort!(collect(result);by=first))
end

function execution_environment_view(values)
    # Locale/display values are passed to the child but never returned in receipts.
    Dict("keys"=>sort!(String[first(pair) for pair in values]),"credentials_inherited"=>false,
        "private_home"=>true,"private_tmp"=>true)
end
