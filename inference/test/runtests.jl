using Test
using Random
using ShenInferenceKernels

# Independent scalar Float64 oracle; the residual addition is rounded to Float32
# because that rounded sum is itself one of the public outputs.
function oracle(x, residual, weight; epsilon=1f-6)
    summed = x + residual
    out = zeros(Float64, size(x))
    for token in axes(x, 2)
        square_sum = sum(Float64(summed[h, token])^2 for h in axes(x, 1))
        denominator = sqrt(square_sum / size(x, 1) + Float64(epsilon))
        for h in axes(x, 1)
            out[h, token] = Float64(summed[h, token]) * Float64(weight[h]) / denominator
        end
    end
    return out, summed
end

@testset "Float64 numerical oracle and input preservation" begin
    rng = MersenneTwister(81731)
    for hidden in (1, 3, 31, 32, 127, 1024, 4096, 8192), tokens in (0, 1, 7)
        x = randn(rng, Float32, hidden, tokens)
        residual = randn(rng, Float32, hidden, tokens)
        weight = randn(rng, Float32, hidden)
        originals = copy.((x, residual, weight))
        expected, expected_sum = oracle(x, residual, weight)
        out, summed = add_rmsnorm(x, residual, weight)
        @test isapprox(out, expected; rtol=1e-5, atol=1e-6)
        @test summed == expected_sum
        @test (x, residual, weight) == originals
    end
end

@testset "exact in-place identities" begin
    rng = MersenneTwister(901)
    for swapped in (false, true)
        x = randn(rng, Float32, 127, 5)
        residual = randn(rng, Float32, 127, 5)
        weight = randn(rng, Float32, 127)
        expected, expected_sum = oracle(x, residual, weight)
        out, summed = swapped ? (residual, x) : (x, residual)
        result = add_rmsnorm!(out, summed, x, residual, weight)
        @test result[1] === out
        @test result[2] === summed
        @test out ≈ expected rtol=1e-5 atol=1e-6
        @test summed == expected_sum
    end
    x = randn(rng, Float32, 33, 2)
    w = ones(Float32, 33)
    expected, expected_sum = oracle(x, x, w)
    out = similar(x)
    add_rmsnorm!(out, x, x, x, w)
    @test out ≈ expected rtol=1e-5 atol=1e-6
    @test x == expected_sum
end

@testset "boundary values and IEEE behavior" begin
    for magnitude in (0f0, 1f-20, 1f-4, 1f0, 1f10), epsilon in (1f-12, 1f-6, 1f-2)
        x = fill(magnitude, 33, 3)
        residual = -0.5f0 .* x
        weight = fill(-2f0, 33)
        expected, expected_sum = oracle(x, residual, weight; epsilon)
        out, summed = add_rmsnorm(x, residual, weight; epsilon)
        @test out ≈ expected rtol=1e-5 atol=1e-6
        @test summed == expected_sum
    end
    for exceptional in (Inf32, NaN32)
        x = fill(exceptional, 4, 1)
        out, _ = add_rmsnorm(x, zeros(Float32, 4, 1), ones(Float32, 4))
        @test all(isnan, out)
    end
end

@testset "invalid arguments never write outputs" begin
    x = ones(Float32, 4, 2)
    r = copy(x)
    w = ones(Float32, 4)
    out = fill(9f0, 4, 2)
    summed = fill(8f0, 4, 2)
    for epsilon in (0f0, -1f0, Inf32, NaN32)
        @test_throws ArgumentError add_rmsnorm!(out, summed, x, r, w; epsilon)
        @test all(==(9f0), out) && all(==(8f0), summed)
    end
    @test_throws DimensionMismatch add_rmsnorm!(out, summed, x, ones(Float32, 4, 3), w)
    @test_throws DimensionMismatch add_rmsnorm!(out, summed, x, r, ones(Float32, 3))
    @test_throws ArgumentError add_rmsnorm!(out, out, x, r, w)
    @test_throws ArgumentError add_rmsnorm(zeros(Float32, 0, 2), zeros(Float32, 0, 2), Float32[])
    alias_weight = reshape(w, 4, 1)
    @test_throws ArgumentError add_rmsnorm!(alias_weight, zeros(Float32, 4, 1),
                                         zeros(Float32, 4, 1), zeros(Float32, 4, 1), w)
    storage = ones(Float32, 4, 1)
    wrapped = reshape(vec(storage), size(storage))
    @test wrapped !== storage
    @test_throws ArgumentError add_rmsnorm!(wrapped, zeros(Float32, 4, 1), storage,
                                         zeros(Float32, 4, 1), w)
    @test all(==(9f0), out) && all(==(8f0), summed)
end

function allocation_count()
    x = ones(Float32, 4096, 8)
    r = copy(x)
    w = ones(Float32, 4096)
    out, summed = similar(x), similar(x)
    add_rmsnorm!(out, summed, x, r, w)
    return @allocated add_rmsnorm!(out, summed, x, r, w)
end

@testset "steady-state scratch allocation" begin
    allocation_count()
    @test allocation_count() == 0
end

@testset "foreign-buffer ABI, no copies and rejection before writes" begin
    x = reshape(Float32.(1:64), 32, 2)
    residual = -0.5f0 .* x
    weight = ones(Float32, 32)
    out, summed = fill(9f0, 32, 2), fill(8f0, 32, 2)
    expected, expected_sum = oracle(x, residual, weight)
    callback = ShenInferenceKernels.c_callback_pointer()
    @test callback != C_NULL
    GC.@preserve out summed x residual weight begin
        status = ccall(callback, Cint,
            (Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Csize_t, Csize_t, Cfloat),
            pointer(out), pointer(summed), pointer(x), pointer(residual), pointer(weight), 32, 2, 1f-6)
        @test status == 0
        @test out ≈ expected rtol=1e-5 atol=1e-6
        @test summed == expected_sum
        fill!(out, 9f0)
        fill!(summed, 8f0)
        # Null, overlapping and overflowing ranges must never be dereferenced.
        for (pout, psum, hidden, tokens, eps) in (
            (C_NULL, pointer(summed), 32, 2, 1f-6),
            (pointer(out), pointer(out), 32, 2, 1f-6),
            (pointer(x), pointer(summed), 32, 2, 1f-6),
            (pointer(out), pointer(summed), 32, 2, NaN32),
            (pointer(out), pointer(summed), typemax(Csize_t), 2, 1f-6))
            status = ccall(callback, Cint,
                (Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Csize_t, Csize_t, Cfloat),
                pout, psum, pointer(x), pointer(residual), pointer(weight), hidden, tokens, eps)
            @test status == 1
            @test all(==(9f0), out) && all(==(8f0), summed)
        end
        # Partial overlaps are rejected by byte ranges, not just equal pointers.
        status = ccall(callback, Cint,
            (Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Csize_t, Csize_t, Cfloat),
            pointer(x, 2), pointer(summed), pointer(x), pointer(residual), pointer(weight), 32, 2, 1f-6)
        @test status == 1
    end
end
