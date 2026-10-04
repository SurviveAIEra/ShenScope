function cli_project_arguments(positional::Vector{String}, flags::AbstractDict)
    length(positional)>=2 || throw(ShenScopeError(:input,"Project action required"))
    action=positional[2]
    args=Dict{String,Any}("action"=>action,"backend"=>get(flags,"--backend","tree_sitter"))
    if action in PROJECT_NAVIGATION_ACTIONS
        if action!="diagnostics"
            if haskey(flags,"--symbol")
                length(positional)==2 || throw(ShenScopeError(:input,"Choose --symbol or FILE LINE COLUMN"))
                args["symbol_id"]=flags["--symbol"]
            else
                length(positional)==5 || throw(ShenScopeError(:input,"Use project $action FILE LINE COLUMN or --symbol ID"))
                args["file"]=positional[3]
                for (key,value) in (("line",positional[4]),("column",positional[5]))
                    parsed=tryparse(Int,value)
                    parsed===nothing && throw(ShenScopeError(:input,"Project $key must be an integer"))
                    args[key]=parsed
                end
                args["column_unit"]=get(flags,"--column-unit","utf8_byte")
            end
        else
            length(positional)<=3 || throw(ShenScopeError(:input,"Use project diagnostics [FILE]"))
            length(positional)==3 && (args["file"]=positional[3])
        end
        for key in ("limit","offset","revision")
            option="--"*key
            haskey(flags,option) || continue
            parsed=tryparse(Int,flags[option])
            parsed===nothing && throw(ShenScopeError(:input,"Project $key must be an integer"))
            args[key]=parsed
        end
        haskey(flags,"--sha256") && (args["sha256"]=flags["--sha256"])
        get(flags,"--exclude-declarations",false) && (args["include_declarations"]=false)
    elseif action=="compact"
        length(positional)==2 || throw(ShenScopeError(:input,"Use project compact without source paths"))
        get(flags,"--force",false) && (args["force"]=true)
        for (option,key) in (("--revision","revision"),("--minimum-savings","minimum_savings"))
            haskey(flags,option) || continue
            parsed=tryparse(Int,flags[option])
            parsed===nothing && throw(ShenScopeError(:input,"Project $key must be an integer"))
            args[key]=parsed
        end
    elseif action=="search"
        args["query"]=join(positional[3:end]," ")
    else
        args["paths"]=positional[3:end]
    end
    args
end

function cli_project_command(positional::Vector{String},flags::AbstractDict,config::AbstractDict,state_dir::String)
    args=cli_project_arguments(positional,flags)
    policy=permissions_from_config(config)
    get(flags,"--allow-process",false) && (policy.rules[:process]=Allow)
    get(flags,"--allow-persistence",false) && (policy.rules[:persistence]=Allow)
    ctx=RuntimeContext(get(flags,"--root",pwd());state_dir,permissions=policy,
        budget=BudgetLedger(limits_from_config(config)),approve=cli_approval)
    tool=ProjectTool()
    try
        validate_tool_arguments(tool,args)
        println(canonical(execute(tool,args,ctx)))
        0
    finally
        cleanup_projects!(tool.manager)
    end
end
