function model_context(root)
    RuntimeContext(root;state_dir=joinpath(root,"state"),
        permissions=PermissionPolicy(;rules=Dict(:network=>Allow,:read=>Allow,:edit=>Allow,:process=>Allow)))
end
