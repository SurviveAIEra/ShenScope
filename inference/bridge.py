"""Experimental synchronous CPU PyTorch -> Julia bridge, without tensor copies.

One embedded Julia runtime is owned by the initializing Python thread. Calls
from other threads, GPU tensors, gradients and overlapping buffers are rejected.
The caller must exclude concurrent mutation of these tensors during a call.
"""
import atexit
import ctypes
import json
import math
import os
from pathlib import Path
import shutil
import threading
import time

import torch

_backend = None
_backend_lock = threading.Lock()
_initialization_attempted = False


class _Backend:
    def __init__(self, julia):
        self.owner = threading.get_ident()
        self.pid = os.getpid()
        self.closed = False
        self.julia = Path(shutil.which(julia) or julia).resolve()
        runtime = self.julia.parent.parent
        self.library = ctypes.CDLL(str(runtime / "lib/libjulia.so"), mode=ctypes.RTLD_GLOBAL)
        self.library.jl_init.argtypes = []
        self.library.jl_init.restype = None
        self.library.jl_is_initialized.argtypes = []
        self.library.jl_is_initialized.restype = ctypes.c_int
        self.library.jl_eval_string.argtypes = [ctypes.c_char_p]
        self.library.jl_eval_string.restype = ctypes.c_void_p
        self.library.jl_exception_occurred.argtypes = []
        self.library.jl_exception_occurred.restype = ctypes.c_void_p
        self.library.jl_unbox_voidpointer.argtypes = [ctypes.c_void_p]
        self.library.jl_unbox_voidpointer.restype = ctypes.c_void_p
        self.library.jl_atexit_hook.argtypes = [ctypes.c_int]
        self.library.jl_atexit_hook.restype = None
        if self.library.jl_is_initialized():
            raise RuntimeError("Julia is already initialized by another integration; use a separate process")
        start = time.perf_counter_ns()
        self.library.jl_init()
        atexit.register(self._close)
        source = Path(__file__).resolve().parent / "src/ShenInferenceKernels.jl"
        expression = f"include({json.dumps(str(source))}); ShenInferenceKernels.c_callback_pointer()"
        boxed = self.library.jl_eval_string(expression.encode())
        if self.library.jl_exception_occurred() or not boxed:
            raise RuntimeError("Julia kernel load failed; no callbacks were installed")
        pointer = self.library.jl_unbox_voidpointer(boxed)
        if not pointer:
            raise RuntimeError("Julia callback address is null")
        signature = ctypes.CFUNCTYPE(ctypes.c_int, *([ctypes.c_void_p] * 5),
                                    ctypes.c_size_t, ctypes.c_size_t, ctypes.c_float)
        self.callback = signature(pointer)
        self.startup_ns = time.perf_counter_ns() - start

    def _close(self):
        if not self.closed and os.getpid() == self.pid and threading.get_ident() == self.owner:
            self.closed = True
            self.library.jl_atexit_hook(0)


class JuliaRMSNorm:
    def __init__(self, julia=None):
        global _backend, _initialization_attempted
        julia = julia or os.environ.get("SHEN_INFERENCE_JULIA") or shutil.which("julia") or \
            "/workspace/toolchains/julia-1.11.7/bin/julia"
        julia = shutil.which(julia) or julia
        with _backend_lock:
            if _backend is None:
                if _initialization_attempted:
                    raise RuntimeError("previous Julia initialization failed; start a new process")
                _initialization_attempted = True
                _backend = _Backend(julia)
            elif _backend.julia != Path(julia).resolve():
                raise RuntimeError("cannot initialize a second Julia toolchain in this process")
            self._backend = _backend
        self.startup_ns = self._backend.startup_ns

    def add_rmsnorm_into(self, x, residual, weight, out, summed, epsilon=1e-6):
        backend = self._backend
        if backend.closed or os.getpid() != backend.pid or threading.get_ident() != backend.owner:
            raise RuntimeError("Julia bridge must run on its initializing thread while the runtime is open")
        tensors = (out, summed, x, residual, weight)
        for tensor in tensors:
            if not isinstance(tensor, torch.Tensor):
                raise TypeError("all buffers must be torch.Tensor objects")
            if (tensor.device.type != "cpu" or tensor.dtype != torch.float32
                    or not tensor.is_contiguous() or tensor.requires_grad):
                raise ValueError("only contiguous CPU Float32 tensors without gradients are supported")
        if x.ndim != 2 or x.shape[1] == 0:
            raise ValueError("x must have shape (tokens, hidden) with positive hidden dimension")
        if any(tensor.shape != x.shape for tensor in (residual, out, summed)):
            raise ValueError("matrix shapes must match")
        if weight.ndim != 1 or weight.shape[0] != x.shape[1]:
            raise ValueError("weight must have one element per hidden feature")
        epsilon = ctypes.c_float(epsilon).value
        if not math.isfinite(epsilon) or epsilon <= 0:
            raise ValueError("epsilon must be representable as a finite positive Float32")
        addresses = tuple(tensor.data_ptr() for tensor in tensors)
        ranges = tuple((address, address + tensor.numel() * 4) for address, tensor in zip(addresses, tensors))
        for i, j in ((0, 1), (0, 2), (0, 3), (0, 4), (1, 2), (1, 3), (1, 4)):
            if max(ranges[i][0], ranges[j][0]) < min(ranges[i][1], ranges[j][1]):
                raise ValueError("bridge outputs must not overlap each other or any input")
        status = backend.callback(*addresses, x.shape[1], x.shape[0], epsilon)
        if status:
            raise RuntimeError(f"Julia kernel rejected the call (status {status})")
        return out, summed
