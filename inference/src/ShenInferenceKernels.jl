module ShenInferenceKernels

export add_rmsnorm!, add_rmsnorm

function check_arguments(out, summed, x, residual, weight, epsilon)
    size(out) == size(summed) == size(x) == size(residual) ||
        throw(DimensionMismatch("all matrices must have the same (hidden, tokens) shape"))
    hidden = size(x, 1)
    hidden > 0 || throw(ArgumentError("hidden dimension must be positive"))
    length(weight) == hidden || throw(DimensionMismatch("weight length must equal hidden dimension"))
    isfinite(epsilon) && epsilon > 0 || throw(ArgumentError("epsilon must be finite and positive"))
    Base.mightalias(out, summed) && throw(ArgumentError("the two outputs must not overlap"))
    for output in (out, summed)
        Base.mightalias(output, weight) && throw(ArgumentError("outputs must not overlap weight"))
        for input in (x, residual)
            output === input && continue
            Base.mightalias(output, input) &&
                throw(ArgumentError("an output may alias an input only as the exact same matrix"))
        end
    end
    return hidden
end

"""
    add_rmsnorm!(out, summed, x, residual, weight; epsilon=1f-6)

Compute `summed = x + residual`, then normalize each token by
`out[:, t] = weight .* summed[:, t] / sqrt(mean(abs2, summed[:, t]) + epsilon)`.

All matrices are dense CPU `Matrix{Float32}` with shape `(hidden, tokens)`;
`weight` is a `Vector{Float32}`. The hidden dimension must be nonempty. Empty
token batches are accepted. Reduction and output arithmetic use Float32.

The two outputs must be distinct and must not overlap weight. Exact input/output
identity is supported, including `out === x` and `summed === residual` together.
Other overlapping input/output wrappers are rejected before any write. Inputs
not used as outputs are unchanged. No scratch allocation or worker threads are
needed. Nonfinite input arithmetic follows IEEE behavior; no fast-math is used.

Returns `(out, summed)`. This is an inference-only prototype, without gradients.
"""
function add_rmsnorm!(out::Matrix{Float32}, summed::Matrix{Float32},
                      x::Matrix{Float32}, residual::Matrix{Float32},
                      weight::Vector{Float32}; epsilon::Float32=1f-6)
    hidden = check_arguments(out, summed, x, residual, weight, epsilon)
    @inbounds for token in axes(x, 2)
        square_sum = 0f0
        @simd for h in 1:hidden
            value = x[h, token] + residual[h, token]
            summed[h, token] = value
            square_sum += value * value
        end
        scale = inv(sqrt(square_sum / Float32(hidden) + epsilon))
        @simd for h in 1:hidden
            out[h, token] = (summed[h, token] * scale) * weight[h]
        end
    end
    return out, summed
end

"""
    add_rmsnorm(x, residual, weight; epsilon=1f-6)

Allocating convenience wrapper returning the normalized and summed matrices.
"""
function add_rmsnorm(x::Matrix{Float32}, residual::Matrix{Float32},
                     weight::Vector{Float32}; epsilon::Float32=1f-6)
    return add_rmsnorm!(similar(x), similar(x), x, residual, weight; epsilon)
end

include("c_api.jl")

end
