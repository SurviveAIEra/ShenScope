# Julia 推理算子实验

[English](README.en.md)

这里开始探索用 Julia 做推理计算。第一步是 **CPU 上的残差相加与 RMSNorm 融合**，
先回答一个具体问题：把相加和平方和归约放在同一遍循环里，能否减少计算时间？

这是一份独立 Julia 包，不加载原来的 agent，也不需要模型密钥。
当前运行环境没有 GPU；尚未测过 GPU、完整模型的生成速度或推理服务。
实测数据、保留的失败记录和复现步骤见[首轮实验报告](REPORT.md)。

## 这段计算做什么

Transformer 常在保留残差的同时，对每个 token 的隐藏向量做归一化：

```text
s = x + residual
y = weight * s / sqrt(mean(s²) + epsilon)
```

实现会保存 `s`，供后续残差路径使用。第一遍循环完成相加、保存和平方和归约，
第二遍计算归一化输出。预热后的原地接口不分配临时内存。
这是常见的算子融合思路，并非新的 RMSNorm 算法。

```julia
using ShenInferenceKernels

# Julia 的列主序布局：(隐藏维度, token 数)，每个 token 连续存储。
x = randn(Float32, 4096, 8)
residual = randn(Float32, 4096, 8)
weight = ones(Float32, 4096)
y, summed = add_rmsnorm(x, residual, weight)

# 重用输入缓冲区；两个输出必须互不重叠。
add_rmsnorm!(x, residual, x, residual, weight; epsilon=1f-6)
```

目前仅支持 CPU 上的 `Matrix{Float32}` 和 `Vector{Float32}`。
隐藏维度不能为空，可以传入空 token 批次。归约使用 Float32；极端数值仍可能溢出。
没有自动求导、GPU 内核、低精度或量化实现。

## 从 PyTorch 调用

实验接口通过 Julia 的 C ABI 包装现有 CPU 张量的指针，不复制张量数据。
可以将输出继续交给 PyTorch；对照中的矩阵投影正是这样执行的。

```python
# 从仓库根目录运行前，设置 PYTHONPATH=inference。
import torch
from bridge import JuliaRMSNorm

kernel = JuliaRMSNorm()  # 一个进程只初始化一次 Julia。
x = torch.randn(8, 4096, dtype=torch.float32)
residual = torch.randn_like(x)
weight = torch.ones(4096)
y, summed = torch.empty_like(x), torch.empty_like(x)
kernel.add_rmsnorm_into(x, residual, weight, y, summed)
```

这个适配层目前只允许初始化线程同步调用，拒绝梯度张量和输出与输入重叠。
调用期间不能从别处修改或调整缓冲区大小。它会分配少量 Python 对象和 Julia 数组头；
Julia 内部算子零临时分配，不代表跨语言调用零分配。
初始化与编译成本单独记录，逐次参数检查和 `ctypes` 开销计入计时。
算子报告仍是局部测量。新增的[整模型对照流程](models/README.md)复用 Transformers
的注意力、KV 缓存和解码，当前等待权重下载，尚无整模型性能结果。

## 安装与运行

已有 Julia 1.11 时，在仓库根目录运行测试，无需安装第三方 Julia 包：

```bash
julia --startup-file=no --project=inference inference/test/runtests.jl
```

本云环境使用一份共享 Julia 1.11.7 工具链和单独的 CPU 对照环境：

```bash
bash inference/scripts/setup.sh
/workspace/toolchains/inference-python/bin/python inference/benchmarks/run.py \
  --output inference/results/my-cpu-run.json
```

安装脚本校验固定 Julia OCI 层的 SHA-256，从 PyTorch 官方 CPU 索引按哈希锁文件安装依赖。
不下载模型，不安装 CUDA，不复制仓库。原始结果文件存在时会拒绝覆盖。
加上 `--smoke` 可以先跑一个小尺寸，验证工具链与数值输出。

## 对照怎么做

完整基准固定六种 `(隐藏维度, token 数)`：
`(1024, 1)`、`(4096, 1)`、`(4096, 8)`、`(4096, 64)`、`(8192, 1)`、`(8192, 32)`。
每种尺寸同时测归一化，以及归一化后接 256 维矩阵投影的计算片段。

- Julia：分配内存的广播实现、预分配内存的分步实现、融合实现，以及融合实现的分配内存版本。
- PyTorch 2.14.1 CPU：原生 `rms_norm` 调用、Inductor 编译后的函数，以及编译后的预分配版本。
- Python→Julia：检查现有 PyTorch 缓冲区，调用实际 Julia 算子，再使用与 PyTorch 对照相同的矩阵乘法。
- 每组使用完全相同的 Float32 二进制输入，用独立 NumPy Float64 计算检查实际输出；残差和要求逐元素相等。
- 单线程、同一个 CPU 核心；每轮打乱方法顺序，保留 21 个样本、首次调用时间与分配信息。

归一化的误差阈值为 `rtol=1e-5, atol=1e-6`；矩阵投影采用 PyTorch 默认的
Float32 校验阈值 `rtol=1.3e-6, atol=1e-5`。最初共用较小的绝对误差阈值时，
投影检查失败；独立的普通 Float32 矩阵乘法也出现同类误差。
失败记录和该项核对保留在 `results/cpu-first.json` 与
`results/float32-projection-roundoff.json`，不计作通过的性能实验。
最初的 PyTorch 2.8 对照也保留原始结果及 `requirements-pytorch28.lock`；
它们与当前 2.14.1 的结果分开。2.14.1 的原生 RMSNorm 已有融合分派，
旧版的速度差不能用来说明比当前 PyTorch 更快。

计时包含各自语言端的调用开销。Python/PyTorch 与 Julia 的调用成本不同，
尤其会影响很小的算子；跨语言时间比不能直接当作底层内核的速度比。
矩阵投影还受两套 BLAS 实现影响。最直接的融合收益，应看同一 Julia 运行时中
预分配分步实现和预分配融合实现的差异。

预热数据会反复使用；首次调用也可能复用之前的编译缓存。
当前没有测冷缓存数据流、Python 调用 Julia 的开销或接入成熟推理引擎后的收益。
“归一化 + 投影”只是计算片段，不能据此推算整模型每秒生成多少 token。

## 参考资料与许可

参考 [PyTorch v2.8.0 RMSNorm 的定义与类型处理](https://github.com/pytorch/pytorch/blob/v2.8.0/aten/src/ATen/native/layer_norm.cpp)
及当前 [v2.14.1 的融合分派](https://github.com/pytorch/pytorch/blob/v2.14.1/aten/src/ATen/native/layer_norm.cpp)。
这些资料用于核对数学定义、epsilon 和 Float32 计算约定；本目录未复制其实现。
源文件下载地址、哈希和阅读结论保存在 [references.json](references.json)。
跨语言接口遵循 [Julia 1.11.7 嵌入文档](https://github.com/JuliaLang/julia/blob/v1.11.7/doc/src/manual/embedding.md)中的
初始化、回调和线程限制。

本目录原创代码沿用仓库根目录的[受限贡献许可](../LICENSE)。
PyTorch、Julia、NumPy 等依赖保留各自许可证，不包含在本项目的原创代码许可中。
