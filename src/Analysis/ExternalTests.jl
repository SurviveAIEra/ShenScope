function analyzer_external_inputs(definition::AnalyzerDefinition)
    [Dict("data"=>deepcopy(test.data),"request"=>deepcopy(test.request)) for test in definition.tests]
end

function analyzer_compare_external_tests(definition::AnalyzerDefinition,results::AbstractVector)
    length(results) == length(definition.tests) || throw(ShenScopeError(:analysis,"External analyzer test result count differs"))
    receipts = Dict{String,Any}[]
    for (test,result) in zip(definition.tests,results)
        expected = canonical(test.expected)
        actual = canonical(result)
        push!(receipts,Dict("name"=>test.name,"data_sha256"=>digest(canonical(test.data)),
            "request_sha256"=>digest(canonical(test.request)),"expected_sha256"=>digest(expected),
            "actual_sha256"=>digest(actual),"passed"=>actual == expected))
    end
    Dict("passed"=>!isempty(receipts) && all(receipt -> receipt["passed"],receipts),
        "count"=>length(receipts),"receipts"=>receipts,
        "test_suite_sha256"=>digest(canonical(analyzer_test_dict.(definition.tests))))
end

function analyzer_begin_run!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing)
    lock(manager.mutex) do
        record = analyzer_record!(manager,name,ctx;version)
        sum(length(candidate.running) for candidate in values(manager.records);init=0) < manager.max_running ||
            throw(ShenScopeError(:capacity,"Analyzer execution capacity reached"))
        length(record.running) < 2 || throw(ShenScopeError(:capacity,"Analyzer version already has two running requests"))
        record.epoch += 1
        epoch = record.epoch
        child = child_context(ctx)
        record.running[epoch] = child.cancellation
        (record=record,definition=deepcopy(record.definition),epoch=epoch,context=child)
    end
end

function analyzer_finish_run!(manager::AnalyzerManager,lease;validation=nothing,failure=nothing)
    lock(manager.mutex) do
        record = lease.record
        delete!(record.running,lease.epoch)
        if record.epoch == lease.epoch
            record.validation = validation === nothing ? nothing : deepcopy(validation)
            record.failure = failure
        end
    end
    nothing
end

function validate_analyzer!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing)
    lease = analyzer_begin_run!(manager,name,ctx;version)
    try
        definition = lease.definition
        isempty(definition.tests) && throw(ShenScopeError(:analysis,"At least one external test is required for validation"))
        result = run_isolated_compute(lease.context,definition.source,analyzer_external_inputs(definition);
            limits=definition.limits,manager=manager.processes)
        external = analyzer_compare_external_tests(definition,result["results"])
        receipt = Dict("version"=>definition.version,"source_sha256"=>definition.source_sha256,
            "external_tests"=>external,"selftest"=>result["selftest"],"sandbox"=>result["sandbox"],
            "limits"=>result["limits"],"elapsed_seconds"=>result["elapsed_seconds"],
            "child_reported_metrics"=>result["metrics"],"tested_at"=>utcstamp(),
            "passed"=>external["passed"],"core_version"=>string(VERSION))
        check_cancelled(lease.context.cancellation)
        analyzer_definition_verify(lease.record.definition)
        analyzer_finish_run!(manager,lease;validation=receipt,
            failure=external["passed"] ? nothing : "External analyzer tests did not match expected outputs")
        emit!(ctx,:analyzer_validated,Dict("name"=>definition.name,"version"=>definition.version,
            "passed"=>external["passed"],"test_count"=>external["count"]))
        deepcopy(receipt)
    catch cause
        message = cause isa ShenScopeError ? cause.message : "Analyzer validation failed"
        analyzer_finish_run!(manager,lease;failure=message)
        rethrow()
    end
end

function cancel_analyzer!(manager::AnalyzerManager,name::AbstractString,ctx::RuntimeContext;version=nothing)
    lock(manager.mutex) do
        record = analyzer_record!(manager,name,ctx;version)
        for token in values(record.running);cancel!(token,"Analyzer cancelled by owning session");end
        Dict("cancelled"=>length(record.running),"name"=>record.definition.name,"version"=>record.definition.version)
    end
end

function evaluate_analyzer!(manager::AnalyzerManager,name::AbstractString,data::AbstractDict,request::AbstractDict,
        ctx::RuntimeContext;version=nothing)
    lease = analyzer_begin_run!(manager,name,ctx;version)
    try
        definition = lease.definition
        isempty(definition.tests) && throw(ShenScopeError(:analysis,"At least one external test is required for evaluation"))
        inputs = analyzer_external_inputs(definition)
        push!(inputs,Dict("data"=>deepcopy(data),"request"=>deepcopy(request)))
        computed = run_isolated_compute(lease.context,definition.source,inputs;
            limits=definition.limits,manager=manager.processes)
        external = analyzer_compare_external_tests(definition,computed["results"][1:end-1])
        external["passed"] || throw(ShenScopeError(:analysis,"External analyzer tests did not match expected outputs"))
        validation = Dict("version"=>definition.version,"source_sha256"=>definition.source_sha256,
            "external_tests"=>external,"selftest"=>computed["selftest"],"sandbox"=>computed["sandbox"],
            "limits"=>computed["limits"],"elapsed_seconds"=>computed["elapsed_seconds"],
            "child_reported_metrics"=>computed["metrics"],"tested_at"=>utcstamp(),"passed"=>true,
            "core_version"=>string(VERSION))
        check_cancelled(lease.context.cancellation)
        analyzer_definition_verify(lease.record.definition)
        result = Dict("name"=>definition.name,"version"=>definition.version,"lifetime"=>"session",
            "result"=>computed["results"][end],"validation"=>validation,
            "limitations"=>["External fixtures establish agreement for the supplied cases; they do not prove general correctness.",
                "Child timing counters are untrusted observations. Parent elapsed time includes Julia startup and validation."])
        analyzer_finish_run!(manager,lease;validation)
        emit!(ctx,:analyzer_evaluated,Dict("name"=>definition.name,"version"=>definition.version,
            "external_tests"=>external["count"],"elapsed_seconds"=>computed["elapsed_seconds"]))
        result
    catch cause
        message = cause isa ShenScopeError ? cause.message : "Analyzer evaluation failed"
        analyzer_finish_run!(manager,lease;failure=message)
        rethrow()
    end
end
