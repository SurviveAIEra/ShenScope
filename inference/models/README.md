# 真实模型 CPU 对照

[English](README.en.md)

这个流程检查 Julia 算子的局部收益能否传到完整模型。使用同一份公开的
SmolLM2-135M 权重，比较原版 Transformers、PyTorch 原生归一化和 Julia 融合三个版本。

**当前没有整模型速度结果。** 模型元数据、配置和部分分词器文件已取回，但权重文件
跳转到 `us.aws.cdn.hf.co` 后被当前云环境代理以 403 拒绝。
所需域名已保存进环境草稿，尚需在环境设置中审阅、保存并发布。
不需要 GPU 或模型 API 密钥。

## 固定的实验计划

模型为 `HuggingFaceTB/SmolLM2-135M`，版本固定为
`93efa2f097d58c2a74874c7e644dbc9b0cee75a2`。
官方文件大小、Git 对象哈希与权重 LFS SHA-256 保存在 [model-spec.json](model-spec.json)。
权重文件大小为 269,060,552 字节；加载时统一转为 CPU Float32。

| 项目 | 设置 |
| --- | --- |
| 输入 | 三段固定文本，分别取 24、96、256 个 token |
| 输出 | 贪心生成 32 个 token，忽略 EOS，保证各组计算量相同 |
| 批次 | 1 |
| 线程 | 1 和 4，绑定相应数量的可用 CPU 核心 |
| 对照 | 原版、PyTorch 原生归一化、Julia 融合 |
| 轮次 | 3 轮，每轮轮换三组运行顺序；共 18 个独立进程 |
| 分析 | 性能试验结束后，另起进程采集原版的 CPU 算子耗时 |

Julia 版本每层只替换注意力之后的“残差相加 + RMSNorm”。注意力、RoPE、KV 缓存更新、
前馈网络、最终归一化及语言模型输出头继续调用原有模块。
PyTorch 原生版本在同一位置调用 `torch.nn.functional.rms_norm`。
原版模型不打补丁。另有控制测试检查适配层调用原始归一化时与原版完全一致。

## 测什么

- 首个 token 的计算等待时间，包括处理输入和选择首个 token。
- 后续 31 个 token 的生成速度，以及 32 个 token 的总生成速度。
- 导入、权重加载和 Julia 初始化耗时，进程峰值与结束时的驻留内存。
- 每组的全部生成 token，以及处理输入和最后一步的完整输出分数。

tokenization 和输出文本解码不计入模型计算计时。每次请求重新建立 KV 缓存，
后续 token 复用该请求的缓存。分词、模型版本、数据类型、注意力设置和权重必须一致。
Julia 的参数检查、跨语言调用与需要时的连续内存转换都计入耗时。

输出 token 要求逐个相同；分数按 `rtol=1e-4, atol=1e-4` 检查，非有限数直接失败。
这些检查只覆盖所选输入，不代表完整模型质量评测。

继续投入的暂定门槛是：相对最快的现有对照，六组任务的解码吞吐量几何平均提高至少 10%，
峰值驻留内存增加不超过 10%，并通过所有输出检查。它是本项目的投入标准，不是行业定律。
启动成本单独报告；没有将其摊销成一个适用于所有部署场景的数字。

## 运行

从仓库根目录执行：

```bash
bash inference/scripts/setup-model.sh
/workspace/toolchains/inference-python/bin/python inference/models/prepare.py
/workspace/toolchains/inference-python/bin/python inference/models/run.py \
  --output inference/results/my-full-model-run.json
```

安装使用 [model-requirements.lock](../model-requirements.lock) 的固定版本与哈希。
权重只缓存一份，在 `/workspace/model-cache/SmolLM2-135M`；不会为每组复制文件。
中断后只复用哈希正确的文件，不覆盖不明内容。已有结果文件不会被覆盖。
不运行远程仓库代码，不读取 pickle 权重；执行阶段只从本地 safetensors 加载。
临时 logits、进程日志和随机测试夹具在检查后清理。

基础算子环境仍可使用 `setup.sh`。它会按较小的基础锁文件同步依赖，移除模型运行依赖；
进行整模型试验时应使用 `setup-model.sh`，两者共用一个 Python 环境。

## 当前完成与未完成的检查

使用随机初始化的小配置验证了原始与控制路径、真实 Julia 调用、单线程与四线程、
KV 缓存续写、权重不变，以及实际 safetensors 加载和三组逐 token 生成流程。
下载校验、断点复用和未知文件保护另有测试。这些都是接入与完整性检查，
**没有把随机权重的运行时间当成预训练模型的性能结果。**

[下载记录](../results/model-download.json)保留了首次 503；
[后续尝试](../results/model-download-retry.json)记录权重 CDN 的连接 403。
[预检记录](../results/full-model-attempt.json)没有模型推理样本，状态为 `BLOCKED_MODEL_DOWNLOAD`。
这些记录不计入成功的模型试验。

当前还没有 llama.cpp、量化模型、并发服务、GPU 或跨机器对照。
在权重下载完成并取得真实结果之前，不能据此决定 Julia 方案是否值得扩大开发。
