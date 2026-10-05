function workspace_diff_hunk_dict(hunk::WorkspaceDiffHunk)
    Dict("before_start"=>hunk.before_start,"before_count"=>hunk.before_count,
        "after_start"=>hunk.after_start,"after_count"=>hunk.after_count,
        "lines"=>[Dict("operation"=>String(line.operation),"before_line"=>line.before_line,
            "after_line"=>line.after_line,"text"=>line.text) for line in hunk.lines])
end

function workspace_diff_projection(diff::WorkspaceSourceDiff; maximum_bytes=128*1024)
    maximum_bytes isa Integer && !(maximum_bytes isa Bool) && 128 <= maximum_bytes <= 512*1024 ||
        throw(ShenScopeError(:workspace_diff,"Invalid source diff output capacity"))
    output=IOBuffer(;maxsize=maximum_bytes)
    bytes=0
    truncated=false
    function append_text(text)
        if bytes+ncodeunits(text)>maximum_bytes
            truncated=true
            return false
        end
        write(output,text)
        bytes+=ncodeunits(text)
        true
    end
    # Header labels are JSON-quoted display strings. This is a review artifact,
    # not an executable patch accepted by an external patch command.
    append_text("--- "*canonical("a/"*diff.path)*"\n")
    append_text("+++ "*canonical("b/"*diff.path)*"\n")
    displayed=0
    for hunk in diff.hunks
        append_text("@@ -$(hunk.before_start),$(hunk.before_count) +$(hunk.after_start),$(hunk.after_count) @@\n") || break
        for line in hunk.lines
            marker=line.operation==:add ? "+" : line.operation==:remove ? "-" : " "
            append_text(marker*line.text*"\n") || break
        end
        truncated && break
        displayed+=1
    end
    if !truncated && diff.before_final_newline!=diff.after_final_newline
        append_text("Final newline: before=$(diff.before_final_newline), after=$(diff.after_final_newline)\n")
    end
    Dict("path"=>diff.path,"before_sha256"=>diff.before_sha256,"after_sha256"=>diff.after_sha256,
        "text"=>String(take!(output)),"hunks_displayed"=>displayed,"hunks_total_retained"=>length(diff.hunks),
        "omitted_hunks"=>diff.omitted_hunks,"preview_truncated"=>truncated || diff.omitted_hunks>0,
        "added_lines"=>diff.added_lines,"removed_lines"=>diff.removed_lines,
        "before_final_newline"=>diff.before_final_newline,"after_final_newline"=>diff.after_final_newline,
        "preview_format"=>"bounded_unified_display","changed"=>diff.before_sha256!=diff.after_sha256,
        "external_patch_execution_supported"=>false)
end
