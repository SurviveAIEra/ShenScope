# 首轮 CPU 推理算子实验

首个原型已经跑通：Julia 实现残差相加与 RMSNorm，Python 可直接复用 PyTorch CPU
张量的内存调用它。当前固定尺寸的测试测出了部分收益，但还不足以说明整模型推理会变快。

## 当前实现与检查

- 独立 Julia 包，提供分配内存和重用缓冲区两种接口；原地接口预热后零临时分配。
- 一个进程只初始化一次 Julia，通过 C ABI 同步调用；检查尺寸、类型、重叠内存、线程与运行时归属。
- 146 项 Julia 断言、8 项基准结果检查、7 项实际跨语言测试通过。
- 两轮完整对照各校验 96 组输出，共 192 组；残差和逐元素一致，输入文件没有被修改。
- 每个方法保留 21 个计时样本、首次调用时间；临时输入、输出均已清理。

环境是 AMD EPYC 9V74 的云端虚拟机，5 个可见 CPU，计时固定在一个核心、使用单线程。
Julia 1.11.7、PyTorch 2.14.1+cpu、NumPy 2.2.6。当前没有 GPU。

## 从 PyTorch 调用 Julia 后的结果

下面取每轮 21 个样本的中位数，再将两轮中位数求平均。
“PyTorch 最快对照”是原生调用、编译后的分配版本、编译后的预分配版本中汇总时间最短的一项。
两轮分别先运行 Julia、先运行 PyTorch；运行时之间顺序执行，没有同时跑其他基准。

归一化及残差相加：

| 隐藏维度 | token 数 | PyTorch 最快对照 / µs | Python→Julia / µs | 耗时减少 |
| ---: | ---: | ---: | ---: | ---: |
| 1024 | 1 | 11.055 | 9.810 | 11.3% |
| 4096 | 1 | 12.235 | 10.417 | 14.9% |
| 4096 | 8 | 28.449 | 17.584 | 38.2% |
| 4096 | 64 | 137.729 | 84.175 | 38.9% |
| 8192 | 1 | 14.138 | 11.163 | 21.0% |
| 8192 | 32 | 131.231 | 85.018 | 35.2% |

归一化后接同一套 PyTorch 矩阵乘法，投影到 256 维：

| 隐藏维度 | token 数 | PyTorch 最快对照 / µs | Python→Julia / µs | 耗时减少 |
| ---: | ---: | ---: | ---: | ---: |
| 1024 | 1 | 45.351 | 42.252 | 6.8% |
| 4096 | 1 | 120.210 | 118.758 | 1.2% |
| 4096 | 8 | 356.299 | 337.427 | 5.3% |
| 4096 | 64 | 1708.794 | 1644.662 | 3.8% |
| 8192 | 1 | 232.314 | 225.503 | 2.9% |
| 8192 | 32 | 2204.972 | 2099.958 | 4.8% |

这里记录的是整次 Python 接口调用的时间，包含参数检查、`ctypes` 和 Julia 包装开销。
投影对照共用 PyTorch 的矩阵乘法，避免把两套 BLAS 的差异混入这项比较。
两轮平均值有收益，不代表每轮、每个尺寸都会更快；几个百分点的变化仍需要更多机器与真实任务验证。

## 哪部分收益来自融合

同一 Julia 进程内，预分配的分步实现与融合实现相比，单独归一化的速度比为
1.009–1.159。
这是较小的优化。加入 Julia 自己的矩阵投影后，一些尺寸更慢，差别主要在几个百分点。
完整数据见 [summary.json](results/summary.json) 和原始结果。

Julia 直接调用的极小时间，不能与 Python 调用时间相除后宣称内核快几十倍。
跨语言接口只共享张量数据；Python 对象和 Julia 数组头仍有分配。
两次嵌入运行时初始化及回调准备分别耗时 0.339 / 0.327 秒，不计入预热后的单次调用时间。
首次调用和编译缓存信息保留在原始结果中；没有测全新机器的完整冷启动成本。

## 数值校验与失败记录

独立 NumPy Float64 参考计算校验实际二进制输出。归一化采用
`rtol=1e-5, atol=1e-6`；投影采用 PyTorch 的默认 Float32 阈值
`rtol=1.3e-6, atol=1e-5`。当前两轮最大绝对误差分别为
7.61285448e-07（归一化）和 9.29633335e-06（投影）。

[最初的一轮](results/cpu-first.json)因投影统一采用较小的绝对误差阈值而失败，
没有计入通过次数。[独立检查](results/float32-projection-roundoff.json)表明，
普通 NumPy Float32 矩阵乘法也会在这些输入上超过该阈值，因此将投影单独按标准 Float32 阈值验收。
这次改的是校验标准，算子的计算公式没有为了通过检查而修改。

最初 PyTorch 2.8 的两组对照分别保留在 `cpu-forward.json` / `cpu-reverse.json`
及 `cpu-bridge-forward.json` / `cpu-bridge-reverse.json`。
核对官方 CPU 索引后，当前锁文件升级到 2.14.1；旧版结果未混入上述表格。
`cpu-pytorch214-forward.json` 是补上重复初始化保护之前的一轮 2.14.1 结果，
同样保留，表格只采用最终实现的两个 `cpu-current-*` 文件。

## 复现

在仓库根目录：

```bash
bash inference/scripts/setup.sh
/workspace/toolchains/inference-python/bin/python inference/benchmarks/run.py \
  --output inference/results/new-forward.json
/workspace/toolchains/inference-python/bin/python inference/benchmarks/run.py \
  --first torch --output inference/results/new-reverse.json
python3 inference/scripts/summarize.py \
  inference/results/new-forward.json inference/results/new-reverse.json
```

结果文件存在时拒绝覆盖。固定输入、源码和依赖的 SHA-256 写入原始记录。
安装重用单一 Julia 工具链与 Python 环境，不复制仓库、不下载模型、不需要模型 API 密钥。

## 这次还没有回答的问题

这里没有注意力、KV 缓存、低精度权重、量化、模型解码循环或推理服务，也没有 GPU 实现。
矩阵投影使用随机权重，并非已加载的模型层。没有测模型质量、每秒生成 token 数、首字延迟或并发吞吐。
预热测试会重复使用数据，不能代表超出缓存的持续数据流。

这次建立的是可检查的实现、真实跨语言调用和可复现实验。下一步应在真实模型上先找出主要耗时，
再选值得优化的部分；有 GPU 后另做 GPU 算子对照。当前结果不支持直接承诺通用推理引擎的加速幅度。
