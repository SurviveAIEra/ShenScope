mutable struct GitHistoryCursor
    bytes::Vector{UInt8}
    offset::Int
end

function git_history_token!(cursor::GitHistoryCursor)
    start = cursor.offset
    finish = findnext(==(0x00), cursor.bytes, start)
    finish === nothing && throw(ShenScopeError(:git_protocol, "Unterminated Git history record"))
    cursor.offset = finish + 1
    value = String(cursor.bytes[start:finish-1])
    isvalid(value) || throw(ShenScopeError(:git_protocol, "Git history contains invalid UTF-8"))
    value
end

function git_history_count(value::AbstractString)
    occursin(r"^(?:0|[1-9][0-9]{0,9})$", value) || throw(ShenScopeError(:git_protocol, "Invalid Git line-change count"))
    count = tryparse(Int, value)
    count !== nothing && count <= 1_000_000_000 || throw(ShenScopeError(:git_protocol, "Git line-change count exceeds capacity"))
    count
end

function git_history_change(record::String)
    fields = split(record, '\t';limit=3, keepempty=true)
    length(fields) == 3 || throw(ShenScopeError(:git_protocol, "Invalid Git numstat record"))
    path = git_history_path(fields[3])
    binary = fields[1] == "-" || fields[2] == "-"
    if binary
        fields[1] == fields[2] == "-" || throw(ShenScopeError(:git_protocol, "Inconsistent Git binary change record"))
        return GitHistoryChange(path, nothing, nothing)
    end
    GitHistoryChange(path, git_history_count(fields[1]), git_history_count(fields[2]))
end

function parse_git_history(bytes::Vector{UInt8}, head::String, limits::GitHistoryLimits=GitHistoryLimits())
    git_object_id(head) || throw(ShenScopeError(:git_protocol, "Invalid history HEAD identity"))
    !isempty(bytes) && length(bytes) <= limits.output_bytes || throw(ShenScopeError(:capacity, "Invalid Git history response capacity"))
    cursor = GitHistoryCursor(bytes, 1)
    commits = GitHistoryCommit[]
    seen = Set{String}()
    total_changes = 0
    expected = head
    while cursor.offset <= length(bytes)
        bytes[cursor.offset] == 0x00 || throw(ShenScopeError(:git_protocol, "Missing Git commit boundary"))
        cursor.offset += 1
        id = git_history_token!(cursor)
        git_object_id(id) && ncodeunits(id) == ncodeunits(head) && !(id in seen) && id == expected ||
            throw(ShenScopeError(:git_protocol, "Git history commit identities are inconsistent"))
        push!(seen, id)
        parents_text = git_history_token!(cursor)
        parents = isempty(parents_text) ? String[] : String.(split(parents_text, ' ';keepempty=true))
        length(parents) <= 64 && length(unique(parents)) == length(parents) &&
            all(parent -> git_object_id(parent) && ncodeunits(parent) == ncodeunits(head) && parent != id, parents) ||
            throw(ShenScopeError(:git_protocol, "Invalid Git parent identities"))
        time_text = git_history_token!(cursor)
        occursin(r"^(?:0|[1-9][0-9]{0,11})$", time_text) || throw(ShenScopeError(:git_protocol, "Invalid Git commit timestamp"))
        committed_at = tryparse(Int, time_text)
        committed_at !== nothing || throw(ShenScopeError(:git_protocol, "Git timestamp exceeds integer capacity"))
        # Git -z terminates each formatted header with a second NUL. Numstat's
        # first record has one separator LF; path whitespace remains untouched.
        git_history_token!(cursor) == "" || throw(ShenScopeError(:git_protocol, "Invalid Git header terminator"))
        changes = GitHistoryChange[]
        paths = Set{String}()
        omitted = 0
        first_record = true
        while cursor.offset <= length(bytes) && bytes[cursor.offset] != 0x00
            record = git_history_token!(cursor)
            if first_record
                startswith(record, '\n') || throw(ShenScopeError(:git_protocol, "Missing Git numstat separator"))
                record = record[nextind(record, firstindex(record)):end]
                first_record = false
            end
            change = git_history_change(record)
            change.path in paths && throw(ShenScopeError(:git_protocol, "Duplicate file in one Git commit"))
            push!(paths, change.path)
            total_changes += 1
            total_changes <= limits.total_changes || throw(ShenScopeError(:capacity, "Git history change count exceeds capacity"))
            if length(changes) < limits.files_per_commit
                push!(changes, change)
            else
                omitted += 1
            end
        end
        push!(commits, GitHistoryCommit(id, Tuple(parents), committed_at, changes, omitted, length(commits) + 1))
        length(commits) <= limits.commits + 1 || throw(ShenScopeError(:capacity, "Git history commit count exceeds capacity"))
        expected = isempty(parents) ? "" : first(parents)
    end
    isempty(commits) && throw(ShenScopeError(:git_protocol, "Git history omitted the fixed HEAD"))
    truncated = length(commits) > limits.commits
    truncated && pop!(commits)
    commits, truncated
end
