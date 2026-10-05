module CompilerIRFixtures
function branch(flag::Bool)
    value=flag ? 1 : "a"
    value
end

function loop(value::Int)
    total=0
    while value>0
        total+=value
        value-=1
    end
    total
end

function exception(value::Int)
    try
        value+1
    catch
        0
    end
end
end

function compiler_fixture_graph(callable,arguments;limits=ShenScope.CompilerIRLimits())
    method=which(callable,arguments)
    code=only(Base.code_typed(callable,arguments;optimize=false)).first
    identity=Dict("argument_slots"=>Int(method.nargs),"signature"=>string(method.sig))
    ShenScope.compiler_ir_method_graph(code,identity,dirname(@__DIR__);limits)
end

function compiler_fixture_rehash!(value)
    value["report_sha256"]=digest(canonical(Dict(k=>v for (k,v) in value if k!="report_sha256")))
    value
end
