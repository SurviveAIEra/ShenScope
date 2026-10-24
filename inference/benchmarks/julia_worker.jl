using ShenInferenceKernels
using LinearAlgebra
using Random
using TOML

BLAS.set_num_threads(1)

function read_f32(path, dims...)
    data = read(path)
    length(data) == prod(dims) * sizeof(Float32) || error("invalid input length: $path")
    return reshape(copy(reinterpret(Float32, data)), dims...)
end

function unfused!(out, summed, x, residual, weight, epsilon)
    summed .= x .+ residual
    hidden = size(x, 1)
    @inbounds for t in axes(x, 2)
        square_sum = 0f0
        @simd for h in 1:hidden
            square_sum += summed[h, t] * summed[h, t]
        end
        scale = inv(sqrt(square_sum / Float32(hidden) + epsilon))
        @simd for h in 1:hidden
            out[h, t] = (summed[h, t] * scale) * weight[h]
        end
    end
    return out, summed
end

function broadcast_reference(x, residual, weight, epsilon)
    summed = x + residual
    scale = inv.(sqrt.(sum(abs2, summed; dims=1) ./ Float32(size(x, 1)) .+ epsilon))
    return summed .* scale .* weight, summed
end

# The barrier keeps every invocation observable instead of timing an inlined,
# repeatedly simplified loop. Public argument checks remain in the timed call.
Base.@noinline invoke_once(f) = f()

function summary_ns(values)
    sorted = sort(values)
    n = length(sorted)
    return Dict("median_ns" => sorted[cld(n, 2)], "min_ns" => first(sorted),
                "p90_ns" => sorted[clamp(ceil(Int, 0.9n), 1, n)], "samples_ns" => values)
end

function measure(operations, samples, target_ns)
    iterations = Dict{String,Int}()
    values = Dict(name => Float64[] for name in keys(operations))
    for (name, f) in operations
        for _ in 1:5
            invoke_once(f)
        end
        start = time_ns()
        for _ in 1:10
            invoke_once(f)
        end
        per_call = max(1.0, Float64(time_ns() - start) / 10)
        iterations[name] = clamp(ceil(Int, target_ns / per_call), 1, 10000)
    end
    rng = MersenneTwister(631)
    for _ in 1:samples
        for name in shuffle(rng, sort!(collect(keys(operations))))
            f, count = operations[name], iterations[name]
            start = time_ns()
            for _ in 1:count
                invoke_once(f)
            end
            push!(values[name], Float64(time_ns() - start) / count)
        end
    end
    return Dict(name => merge(summary_ns(values[name]), Dict(
                    "iterations_per_sample" => iterations[name],
                    "allocated_bytes_per_call" => @allocated(invoke_once(f))))
                for (name, f) in operations)
end

function main(root, result_path)
    config = TOML.parsefile(joinpath(root, "cases.toml"))
    records = []
    for case in config["cases"]
        id, hidden, tokens = case["id"], case["hidden"], case["tokens"]
        dir = joinpath(root, id)
        x = read_f32(joinpath(dir, "x.f32"), hidden, tokens)
        residual = read_f32(joinpath(dir, "residual.f32"), hidden, tokens)
        weight = vec(read_f32(joinpath(dir, "weight.f32"), hidden))
        projection = read_f32(joinpath(dir, "projection.f32"), case["projected"], hidden)
        epsilon = Float32(config["epsilon"])
        out, summed = similar(x), similar(x)
        projected = zeros(Float32, case["projected"], tokens)
        operations = Dict{String,Function}(
            "julia_broadcast_allocating" => () -> broadcast_reference(x, residual, weight, epsilon),
            "julia_unfused_preallocated" => () -> unfused!(out, summed, x, residual, weight, epsilon),
            "julia_fused_preallocated" => () -> add_rmsnorm!(out, summed, x, residual, weight; epsilon),
            "julia_fused_allocating" => () -> add_rmsnorm(x, residual, weight; epsilon))
        for stage in ("norm", "norm_projection")
            stage_ops = stage == "norm" ? operations : Dict{String,Function}(
                name => let fn = f
                    () -> begin
                        normalized, residual_sum = fn()
                        mul!(projected, projection, normalized)
                        (projected, residual_sum)
                    end
                end for (name, f) in operations)
            cold = Dict{String,Float64}()
            for name in sort!(collect(keys(stage_ops)))
                start = time_ns()
                values = invoke_once(stage_ops[name])
                cold[name] = Float64(time_ns() - start)
                # Export actual outputs for an independent Python Float64 oracle.
                for (suffix, value) in zip(("output", "summed"), values)
                    open(joinpath(dir, "$name-$stage-$suffix.f32"), "w") do io
                        write(io, value)
                    end
                end
            end
            stats = measure(stage_ops, config["samples"], config["target_sample_ns"])
            for (name, data) in stats
                data["first_invocation_ns"] = cold[name]
            end
            push!(records, Dict("id" => id, "stage" => stage, "methods" => stats))
        end
    end
    open(result_path, "w") do io
        TOML.print(io, Dict("runtime" => Dict("julia_version" => string(VERSION),
            "cpu" => Sys.CPU_NAME, "julia_threads" => Threads.nthreads(),
            "blas_threads" => BLAS.get_num_threads(), "blas" => string(BLAS.get_config())),
            "records" => records))
    end
end

main(ARGS[1], ARGS[2])
