# Experimental synchronous host-buffer ABI. The caller owns valid storage for
# hidden*tokens Float32 elements per matrix and hidden elements for weight.
# This adapter permits only disjoint output/input ranges. It wraps buffers, not
# their contents; temporary Julia Array headers can allocate and be collected.

function ranges_overlap(a::Ptr{Float32}, n::UInt, b::Ptr{Float32}, m::UInt)
    n == 0 || m == 0 ? false : (UInt(a) <= UInt(b) ? UInt(b) - UInt(a) < n : UInt(a) - UInt(b) < m)
end

function c_add_rmsnorm(out_ptr::Ptr{Float32}, sum_ptr::Ptr{Float32},
                       x_ptr::Ptr{Float32}, residual_ptr::Ptr{Float32}, weight_ptr::Ptr{Float32},
                       hidden::Csize_t, tokens::Csize_t, epsilon::Cfloat)::Cint
    try
        hidden > 0 && hidden <= typemax(Int) && tokens <= typemax(Int) || return 1
        hidden <= UInt(typemax(Int)) ÷ max(tokens, UInt(1)) ÷ sizeof(Float32) || return 1
        isfinite(epsilon) && epsilon > 0 || return 1
        tokens == 0 && return 0
        any(==(C_NULL), (out_ptr, sum_ptr, x_ptr, residual_ptr, weight_ptr)) && return 1
        matrix_bytes = hidden * tokens * sizeof(Float32)
        weight_bytes = hidden * sizeof(Float32)
        ranges_overlap(out_ptr, matrix_bytes, sum_ptr, matrix_bytes) && return 1
        for output in (out_ptr, sum_ptr)
            for input in (x_ptr, residual_ptr)
                ranges_overlap(output, matrix_bytes, input, matrix_bytes) && return 1
            end
            ranges_overlap(output, matrix_bytes, weight_ptr, weight_bytes) && return 1
        end
        shape = (Int(hidden), Int(tokens))
        out = unsafe_wrap(Array, out_ptr, shape; own=false)
        summed = unsafe_wrap(Array, sum_ptr, shape; own=false)
        x = unsafe_wrap(Array, x_ptr, shape; own=false)
        residual = unsafe_wrap(Array, residual_ptr, shape; own=false)
        weight = unsafe_wrap(Array, weight_ptr, Int(hidden); own=false)
        add_rmsnorm!(out, summed, x, residual, weight; epsilon)
        return 0
    catch
        # No Julia exception can unwind through ctypes or the foreign C caller.
        return 2
    end
end

# Obtain the address at runtime; raw pointers must not be serialized in a
# precompilation cache, where they would be restored as null.
function c_callback_pointer()
    return @cfunction(c_add_rmsnorm, Cint,
        (Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Csize_t, Csize_t, Cfloat))
end
