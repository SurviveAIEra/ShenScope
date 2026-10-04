struct AnalyzerTestCase
    name::String
    data::Dict{String,Any}
    request::Dict{String,Any}
    expected::Dict{String,Any}
    function AnalyzerTestCase(name::AbstractString, data::AbstractDict, request::AbstractDict, expected::AbstractDict)
        isvalid(name) && 1 <= ncodeunits(name) <= 128 && !occursin('\0', name) ||
            throw(ShenScopeError(:analysis, "Invalid external analyzer test name"))
        payload = canonical(Dict("data"=>data,"request"=>request,"expected"=>expected))
        parsed = bounded_json_object(payload; maximum=2 * 1024^2, max_depth=24,
            max_nodes=100_000, error_code=:analysis)
        new(String(name), parsed["data"], parsed["request"], parsed["expected"])
    end
end

analyzer_test_dict(test::AnalyzerTestCase) = Dict("name"=>test.name,"data"=>test.data,
    "request"=>test.request,"expected"=>test.expected)

function analyzer_test_from_dict(value::AbstractDict)
    Set(keys(value)) == Set(["name","data","request","expected"]) &&
        value["name"] isa AbstractString && all(key -> value[key] isa AbstractDict, ("data","request","expected")) ||
        throw(ShenScopeError(:analysis, "Invalid external analyzer test definition"))
    AnalyzerTestCase(value["name"],value["data"],value["request"],value["expected"])
end

struct AnalyzerDefinition
    name::String
    description::String
    source::String
    tests::Vector{AnalyzerTestCase}
    limits::ComputeLimits
    source_sha256::String
    version::String
    bytes::Int
end

function analyzer_name_valid(name::AbstractString)
    occursin(r"^[a-z][a-z0-9_.-]{0,63}$",name) &&
        !(name in ("impact","test_selection","architecture","git_cochange","migration","risk"))
end

function analyzer_definition_payload(name, description, source, tests, limits)
    Dict("format"=>1,"name"=>name,"description"=>description,"source"=>source,
        "tests"=>analyzer_test_dict.(tests),"limits"=>compute_limits_dict(limits))
end

function AnalyzerDefinition(name::AbstractString, source::AbstractString;
        description="", tests=AnalyzerTestCase[], limits=ComputeLimits())
    analyzer_name_valid(name) || throw(ShenScopeError(:analysis, "Invalid or reserved analyzer name"))
    description isa AbstractString && isvalid(description) && ncodeunits(description) <= 2048 ||
        throw(ShenScopeError(:analysis, "Invalid analyzer description"))
    code = compute_source(source,limits)
    tests isa AbstractVector && length(tests) <= limits.max_tests && all(test -> test isa AnalyzerTestCase,tests) ||
        throw(ShenScopeError(:analysis, "External analyzer tests exceed capacity or have an invalid type"))
    length(unique(test.name for test in tests)) == length(tests) ||
        throw(ShenScopeError(:analysis, "External analyzer test names must be unique"))
    copied = deepcopy(collect(AnalyzerTestCase,tests))
    payload = canonical(analyzer_definition_payload(String(name),String(description),code,copied,limits))
    ncodeunits(payload) <= limits.input_bytes || throw(ShenScopeError(:capacity, "Analyzer definition exceeds input capacity"))
    AnalyzerDefinition(String(name),String(description),code,copied,limits,digest(code),digest(payload),ncodeunits(payload))
end

function analyzer_definition_dict(definition::AnalyzerDefinition; include_source=true, include_tests=true)
    result = Dict{String,Any}("format"=>1,"name"=>definition.name,"description"=>definition.description,
        "version"=>definition.version,"source_sha256"=>definition.source_sha256,"bytes"=>definition.bytes,
        "test_count"=>length(definition.tests),"limits"=>compute_limits_dict(definition.limits))
    include_source && (result["source"] = definition.source)
    include_tests && (result["tests"] = analyzer_test_dict.(definition.tests))
    result
end

function analyzer_definition_verify(definition::AnalyzerDefinition)
    digest(definition.source) == definition.source_sha256 ||
        throw(ShenScopeError(:conflict, "Analyzer source changed after registration"))
    payload = canonical(analyzer_definition_payload(definition.name,definition.description,
        definition.source,definition.tests,definition.limits))
    digest(payload) == definition.version && ncodeunits(payload) == definition.bytes ||
        throw(ShenScopeError(:conflict, "Analyzer definition changed after registration"))
    nothing
end

function analyzer_definition_from_dict(value::AbstractDict)
    allowed = Set(["format","name","description","source","tests","limits","version","source_sha256","bytes","test_count"])
    Set(keys(value)) == allowed && value["format"] === 1 && value["tests"] isa AbstractVector &&
        value["limits"] isa AbstractDict && value["name"] isa AbstractString && value["source"] isa AbstractString ||
        throw(ShenScopeError(:analysis, "Archived analyzer definition is invalid"))
    tests = AnalyzerTestCase[analyzer_test_from_dict(test) for test in value["tests"]]
    definition = AnalyzerDefinition(value["name"],value["source"];description=value["description"],tests,
        limits=compute_limits_from_dict(value["limits"]))
    definition.version == value["version"] && definition.source_sha256 == value["source_sha256"] &&
        definition.bytes == value["bytes"] && length(tests) == value["test_count"] && !(value["test_count"] isa Bool) ||
        throw(ShenScopeError(:analysis, "Archived analyzer integrity check failed"))
    definition
end
