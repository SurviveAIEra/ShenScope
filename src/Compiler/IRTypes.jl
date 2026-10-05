const COMPILER_IR_SCHEMA = "shenscope.compiler-ir/1"
const COMPILER_IR_MAX_BYTES = 2 * 1024^2

struct CompilerIRLimits
    max_statements::Int
    max_operands::Int
    max_depth::Int
    max_blocks::Int
    max_flow_operations::Int
    max_findings::Int
    function CompilerIRLimits(;max_statements=2048,max_operands=40_000,
            max_depth=64,max_blocks=512,max_flow_operations=2_000_000,max_findings=128)
        values=(max_statements,max_operands,max_depth,max_blocks,max_flow_operations,max_findings)
        all(v->v isa Integer && !(v isa Bool),values) ||
            throw(ShenScopeError(:diagnostics,"Compiler graph limits must be integers"))
        1<=max_statements<=4096 && 1<=max_operands<=80_000 && 1<=max_depth<=128 &&
            1<=max_blocks<=1024 && 1<=max_flow_operations<=4_000_000 && 1<=max_findings<=256 ||
            throw(ShenScopeError(:diagnostics,"Compiler graph limits exceed supported bounds"))
        new(Int.(values)...)
    end
end

mutable struct CompilerIRWork
    limits::CompilerIRLimits
    operands::Int
    flow_operations::Int
end
CompilerIRWork(limits::CompilerIRLimits)=CompilerIRWork(limits,0,0)

function compiler_ir_tick!(work::CompilerIRWork;depth=0,operations=0)
    if operations==0
        work.operands+=1
        work.operands<=work.limits.max_operands && depth<=work.limits.max_depth ||
            throw(ShenScopeError(:capacity,"Compiler operands exceed their node or depth limit"))
    else
        work.flow_operations+=operations
        work.flow_operations<=work.limits.max_flow_operations ||
            throw(ShenScopeError(:capacity,"Compiler graph dataflow exceeds its operation limit"))
    end
    (work.operands+work.flow_operations)%256==0 && yield()
end

function compiler_ir_integer(value,name,minimum,maximum)
    value isa Integer && !(value isa Bool) && minimum<=value<=maximum ||
        throw(ShenScopeError(:diagnostics,"Invalid compiler "*name))
    Int(value)
end

function compiler_ir_type(value)
    if value isa Core.Const
        return Dict("type"=>cliptext(string(typeof(value.val)),512),"classification"=>"constant",
            "concrete"=>true,"bottom"=>false,"constant_value_exposed"=>false)
    end
    if value isa Type
        bottom=value===Union{}
        members=value isa Union ? Base.uniontypes(value) : Any[]
        classification=bottom ? "bottom" : value===Any ? "any" : isconcretetype(value) ? "concrete" :
            !isempty(members) && length(members)<=8 && all(isconcretetype,members) ? "small_concrete_union" : "nonconcrete"
        return Dict("type"=>cliptext(string(value),512),"classification"=>classification,
            "concrete"=>!bottom && isconcretetype(value),"bottom"=>bottom,"constant_value_exposed"=>false)
    end
    Dict("type"=>cliptext(string(typeof(value)),512),"classification"=>"compiler_lattice_value",
        "concrete"=>false,"bottom"=>false,"constant_value_exposed"=>false)
end

function compiler_ir_method_identity(method::Method,snapshot::RuntimeSourceSnapshot)
    file=String(method.file)
    isfile(file) || throw(ShenScopeError(:diagnostics,"Trusted compiler target source is unavailable"))
    relative=replace(relpath(realpath(file),snapshot.root),'\\'=>'/')
    startswith(relative,"src/") || throw(ShenScopeError(:diagnostics,"Compiler target is outside authored Core source"))
    index=findfirst(item->item.path==relative,snapshot.files)
    index===nothing && throw(ShenScopeError(:diagnostics,"Compiler target source is absent from the current inventory"))
    source=snapshot.files[index]
    Dict("module"=>string(method.module),"signature"=>cliptext(string(method.sig),2048),
        "file"=>relative,"line"=>Int(method.line),"source_sha256"=>source.sha256,
        "argument_slots"=>Int(method.nargs),"method_world_start"=>string(method.primary_world),
        "method_world_end"=>string(method.deleted_world))
end

function compiler_ir_location(code::Core.CodeInfo,index::Int,root::String)
    unknown=Dict("file"=>nothing,"line"=>nothing,"scope"=>"unknown")
    index<=length(code.codelocs) || return unknown
    location=Int(code.codelocs[index])
    1<=location<=length(code.linetable) || return unknown
    info=code.linetable[location]
    info isa Core.LineInfoNode || return unknown
    Int(info.line)>0 || return unknown
    file=String(info.file)
    relative=isabspath(file) ? replace(relpath(file,root),'\\'=>'/') : file
    own=startswith(relative,"src/") && all(component->component!="..",split(relative,'/'))
    Dict("file"=>cliptext(own ? relative : basename(file),512),
        "line"=>Int(info.line),"scope"=>own ? "core" : "external")
end
