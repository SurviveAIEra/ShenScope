function semantic_context(root, state="state")
    RuntimeContext(root;state_dir=joinpath(root,state),approve=r->:once)
end

function semantic_error_code(f)
    try
        f(); nothing
    catch error
        error isa ShenScopeError || rethrow()
        error.code
    end
end
