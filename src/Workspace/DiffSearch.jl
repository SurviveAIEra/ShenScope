function workspace_diff_operations(before::Vector{String},after::Vector{String},
        options::WorkspaceDiffOptions; context=nothing)
    n,m=length(before),length(after)
    maximum=min(n+m,options.maximum_edit_distance)
    width=2*maximum+3
    offset=maximum+2
    frontier=fill(-1,width)
    frontier[offset+1]=0
    traces=Vector{Int}[]
    found=nothing
    comparisons=0
    for distance in 0:maximum
        workspace_diff_checkpoint(context,distance*128)
        (length(traces)+1)*width <= options.maximum_trace_cells ||
            throw(ShenScopeError(:workspace_diff,"Diff search exceeded its trace memory capacity"))
        push!(traces,copy(frontier))
        for diagonal in -distance:2:distance
            index=offset+diagonal
            x = diagonal == -distance || diagonal != distance && frontier[index-1] < frontier[index+1] ?
                frontier[index+1] : frontier[index-1]+1
            y=x-diagonal
            x >= 0 && y >= 0 || throw(ShenScopeError(:workspace_diff,"Diff search produced an invalid frontier"))
            while x<n && y<m && before[x+1]==after[y+1]
                x+=1
                y+=1
                comparisons+=1
                workspace_diff_checkpoint(context,comparisons)
            end
            frontier[index]=x
            if x>=n && y>=m
                found=distance
                break
            end
        end
        found === nothing || break
    end
    found === nothing && throw(ShenScopeError(:workspace_diff,"Source difference exceeds the configured edit-distance capacity"))
    operations=WorkspaceDiffLine[]
    x,y=n,m
    for distance in found:-1:0
        prior=traces[distance+1]
        diagonal=x-y
        index=offset+diagonal
        previous_diagonal=diagonal == -distance || diagonal != distance && prior[index-1] < prior[index+1] ?
            diagonal+1 : diagonal-1
        previous_x=prior[offset+previous_diagonal]
        previous_y=previous_x-previous_diagonal
        while x>previous_x && y>previous_y
            push!(operations,WorkspaceDiffLine(:context,x,y,before[x]))
            x-=1
            y-=1
        end
        distance==0 && break
        if x==previous_x
            push!(operations,WorkspaceDiffLine(:add,nothing,y,after[y]))
            y-=1
        else
            push!(operations,WorkspaceDiffLine(:remove,x,nothing,before[x]))
            x-=1
        end
    end
    reverse!(operations)
    operations
end

function workspace_diff_hunk(operations::Vector{WorkspaceDiffLine},first::Int,last::Int)
    lines=operations[first:last]
    old_before=count(line->line.operation!=:add,@view operations[1:first-1])
    new_before=count(line->line.operation!=:remove,@view operations[1:first-1])
    old_count=count(line->line.operation!=:add,lines)
    new_count=count(line->line.operation!=:remove,lines)
    WorkspaceDiffHunk(old_count==0 ? old_before : old_before+1,old_count,
        new_count==0 ? new_before : new_before+1,new_count,lines)
end

function workspace_diff_hunks(operations::Vector{WorkspaceDiffLine},options::WorkspaceDiffOptions)
    intervals=Tuple{Int,Int}[]
    for (index,line) in enumerate(operations)
        line.operation==:context && continue
        first=max(1,index-options.context_lines)
        last=min(length(operations),index+options.context_lines)
        if !isempty(intervals) && first<=intervals[end][2]+1
            intervals[end]=(intervals[end][1],max(intervals[end][2],last))
        else
            push!(intervals,(first,last))
        end
    end
    selected=collect(Iterators.take(intervals,options.maximum_hunks))
    [workspace_diff_hunk(operations,first,last) for (first,last) in selected],length(intervals)-length(selected)
end

function workspace_source_diff(path::AbstractString,before::String,after::String;
        options=WorkspaceDiffOptions(),context=nothing)
    validate_workspace_diff_options(options)
    name=workspace_edit_text(path,"source diff file",4096)
    old=workspace_diff_lines(before,options)
    new=workspace_diff_lines(after,options)
    operations=workspace_diff_operations(old,new,options;context)
    hunks,omitted=workspace_diff_hunks(operations,options)
    # A final-newline-only change is real even when all line bodies match.
    if isempty(hunks) && endswith(before,'\n')!=endswith(after,'\n') && !isempty(operations)
        push!(hunks,workspace_diff_hunk(operations,max(1,length(operations)-options.context_lines),length(operations)))
    end
    WorkspaceSourceDiff(name,digest(before),digest(after),endswith(before,'\n'),endswith(after,'\n'),
        hunks,count(line->line.operation==:add,operations),count(line->line.operation==:remove,operations),omitted)
end
