# 逐提交实现记录

已核对的范围：从 `07eaccd` 到 `b55a079`，共 42 个提交。
本表只说明各提交新增或修改的范围；实现和局部测试通过不代表整个产品已经完成。详细验证及平台限制见 `WORK_STATUS.md` 和 `docs/validation/`。Core 约 25 万行与完整功能门槛尚未达到。

| 顺序 | 提交 | 本次实现 |
|---:|---|---|
| 1 | [07eaccd](https://github.com/SurviveAIEra/ShenScope/commit/07eaccdf5c9e218272d4dc7805320d539c481664) · bootstrap: add Julia project, runtime context and durable sessions | 创建 Julia 包结构、运行时上下文和可持久化的会话基础。 |
| 2 | [599d3a9](https://github.com/SurviveAIEra/ShenScope/commit/599d3a9565f16fffe9bb02e3c80e542b2a14fafb) · feat(core): add streaming model providers and permissioned tool-calling agent | 实现五类模型流式协议、权限工具调用、agent 循环、进程与编辑工具；验证使用离线/回环样例。 |
| 3 | [9c1cb4b](https://github.com/SurviveAIEra/ShenScope/commit/9c1cb4b53701f071de5c123edc767aceab071830) · feat(ide): add shared Core protocol, terminal UI and editor clients | 建立 Julia Core 的 stdio RPC、CLI/TUI、VSIX 和 CodeOSS 原生客户端。 |
| 4 | [5b3c8b2](https://github.com/SurviveAIEra/ShenScope/commit/5b3c8b23babb9d4fe7e3299317d223e6b1e2e057) · build: add reproducible Julia and editor environment setup | 添加共享工具链、依赖、后端和编辑器的可重复环境安装流程。 |
| 5 | [25d75e6](https://github.com/SurviveAIEra/ShenScope/commit/25d75e66a92f330754e01334c958711073dfc953) · fix(storage): preserve atomic snapshots and bound journal reads | 强化原子文件替换、刷盘、有限长度 journal 读取和有限数值校验。 |
| 6 | [22323c5](https://github.com/SurviveAIEra/ShenScope/commit/22323c5877315bbf0e3cdf7f6de07f73068127c5) · feat(core): add scoped versioned memory and atomic imports | 实现 workspace/session/user 记忆、版本/CAS、删除、期限、词法搜索和原子导入导出。 |
| 7 | [63448dc](https://github.com/SurviveAIEra/ShenScope/commit/63448dc5d275c5469596595ab21e90def56cda56) · feat(ide): redesign conversation UI and render safe Markdown | 改进聊天导航、输入区、历史管理、设置、审批卡片与安全 Markdown/代码展示。 |
| 8 | [db81953](https://github.com/SurviveAIEra/ShenScope/commit/db81953cbd01a4fcce06eceb102319afac343850) · feat(core): add real project backends and shared editor intelligence | 接入真实 Go AST、Tree-sitter、CodeGraphContext/Ladybug，建立稳定事实、增量图及双客户端 Project 操作。 |
| 9 | [e68381d](https://github.com/SurviveAIEra/ShenScope/commit/e68381d072c60c22a135712590c96e99cdea49c0) · feat(core): add Julia contract reflection and compiler diagnostics | 增加 Julia 接口契约反射、方法歧义、World Age/invokelatest 边界和固定目标编译诊断。 |
| 10 | [7d369fb](https://github.com/SurviveAIEra/ShenScope/commit/7d369fbbe7e053752f657d575025351b2483249b) · feat(core): add durable task graphs and leased worker execution | 实现持久化任务 DAG、依赖、租约、执行结果、重试、对账和作用域消息。 |
| 11 | [44e194a](https://github.com/SurviveAIEra/ShenScope/commit/44e194af4bcb7b401d0c8c02b19a51e9c900878f) · feat(core): add scoped MCP clients and shared editor controls | 实现 MCP stdio/Streamable HTTP、发现/分页、资源/提示词、权限与客户端控制。 |
| 12 | [92eca98](https://github.com/SurviveAIEra/ShenScope/commit/92eca98bafd9a160d58c5c1d082ee80076c9c7f7) · feat(core): add scoped skills and shared instruction controls | 实现项目/用户作用域 skills 发现、元数据、惰性资源和双客户端指令控制。 |
| 13 | [dc85c33](https://github.com/SurviveAIEra/ShenScope/commit/dc85c33bebffd08fd4d25b7a1fd7b13e6a7e8adf) · feat(core): add permissioned lifecycle hooks and durable effect fences | 增加受权限管理的生命周期 hooks、配置/执行结果以及持久化副作用防重复边界。 |
| 14 | [fa941c8](https://github.com/SurviveAIEra/ShenScope/commit/fa941c8ec0b04211174b04e963850cba72b47dc1) · feat(core): add durable context projections and bounded recovery | 实现持久化上下文投影、引用校验、裁剪、检查点和有限恢复流程。 |
| 15 | [6a32363](https://github.com/SurviveAIEra/ShenScope/commit/6a3236369f057960c802f7a9afb7b25ea80c5171) · feat(project): add compiler semantic indexing and navigation | 接入真实 TypeScript 编译器语义事实、坐标转换、类型/引用/调用导航和更新验证。 |
| 16 | [0a8fae0](https://github.com/SurviveAIEra/ShenScope/commit/0a8fae0fb8faab202ff5e831765265dc0686d2ec) · feat(project): compact index history with streaming replay | 压缩项目索引 journal 历史，流式重放，保留当前事实和事务一致性。 |
| 17 | [c0fe93d](https://github.com/SurviveAIEra/ShenScope/commit/c0fe93deffabb5a0ef5acc6bf3c1b41de57c6efe) · feat(project): watch source and configuration changes | 监听源文件及配置，合并变更批次、递归核对并驱动多后端增量更新。 |
| 18 | [93898f0](https://github.com/SurviveAIEra/ShenScope/commit/93898f06cd79e2cfea8cf1f919133e4e0c7aad53) · feat(analysis): isolate and validate Julia analyzer candidates | 增加 Linux 限制进程中的动态 Julia analyzer 执行、自测、资源和系统调用检查。 |
| 19 | [bff3199](https://github.com/SurviveAIEra/ShenScope/commit/bff3199c4acb0c6c639067b1ccd14330f9ded351) · feat(analysis): integrate graph analyzers and version archives | 接入图分析器与 analyzer 版本归档、晋升、回滚和双客户端管理。 |
| 20 | [430af97](https://github.com/SurviveAIEra/ShenScope/commit/430af97ec7d033982058489476ea293f300a94d5) · feat(models): discover provider directories and measure requests | 增加模型目录、能力信息、请求计数和使用量测量。 |
| 21 | [86094f5](https://github.com/SurviveAIEra/ShenScope/commit/86094f574c94f37f67d0fbddcc7267db1c1d9bd2) · feat(models): enforce retry advice and scoped circuit health | 完善模型错误分类、重试建议、部分输出边界和作用域熔断健康状态。 |
| 22 | [c5a8789](https://github.com/SurviveAIEra/ShenScope/commit/c5a8789ab7cba549c20ae9b2fe35ff0869a2c4a2) · feat(models): route configured roles through immutable profiles | 实现不可变模型 profiles、角色路由、回退和主/worker 配置。 |
| 23 | [9b39379](https://github.com/SurviveAIEra/ShenScope/commit/9b3937964669835c62952dc04776f1f104f8cc68) · feat(analysis): add bounded Git co-change and review evidence | 从真实 Git 历史提取有限共变更和审查风险证据。 |
| 24 | [0238493](https://github.com/SurviveAIEra/ShenScope/commit/023849301102b508ffed9357fb7dea4fa94b2c0b) · feat(analysis): plan bounded graph migration batches | 根据图关系生成有限迁移计划和依赖/调用顺序批次，保留证据与置信限定。 |
| 25 | [4145112](https://github.com/SurviveAIEra/ShenScope/commit/41451123757e0f7d6e0519fcf783d22f44d7c19c) · feat(runtime): precompile common server startup paths | 预编译常用服务启动路径，记录实际启动相关证据。 |
| 26 | [048fd6a](https://github.com/SurviveAIEra/ShenScope/commit/048fd6a1d46bd7364d4c37251107b8594ea391e4) · feat(memory): add scoped retrieval evidence and note management | 增加记忆检索证据、筛选、分页和笔记管理界面。 |
| 27 | [eb8f894](https://github.com/SurviveAIEra/ShenScope/commit/eb8f8944373d2ad6c8610944cb6ef78cd083ca45) · feat(security): add fail-closed Linux execution policies | 增加遇到不支持情况即拒绝的 Linux 执行策略、资源和 seccomp 检查；普通 host 工具仍未全面 OS 隔离。 |
| 28 | [094aea3](https://github.com/SurviveAIEra/ShenScope/commit/094aea3dea0e755cf0c0f6f72d38c033ca94c6fc) · feat(project): add Julia syntax and dispatch evidence | 增加 JuliaSyntax 事实、Julia 方法/派发/结构证据；语法关系不等于运行时语义。 |
| 29 | [6f52e5b](https://github.com/SurviveAIEra/ShenScope/commit/6f52e5b784377b8ade39c4f005c35549aee8fd6e) · feat(project): combine versioned backend evidence | 组合有版本与来源的多后端证据，保留 provider 差异和启发式关系。 |
| 30 | [590d670](https://github.com/SurviveAIEra/ShenScope/commit/590d670a673c79c75abbc89e347f18c3b66bd392) · feat(extensions): add Julia package lifecycle and sparse evidence | 实现独立 Julia 包生命周期、源码/UUID/version 回执、激活/停用与 SparseArrays 可选扩展。 |
| 31 | [7c14c1d](https://github.com/SurviveAIEra/ShenScope/commit/7c14c1d3ef116ae40119894fdd74ad2d289525b2) · feat(runtime): add owned PTY terminals and native editor adapters | 实现有所有权的 Linux PTY、stdin/resize/取消，以及 VSIX/原生终端适配。 |
| 32 | [701c019](https://github.com/SurviveAIEra/ShenScope/commit/701c0196742128818d70745fb02892d54ca3aed0) · feat(distribution): verify Julia runtime images and compiler builds | 实现实际 Julia runtime image 构建及源码/依赖校验、构建回执与 image 运行测试。 |
| 33 | [808a756](https://github.com/SurviveAIEra/ShenScope/commit/808a7568c1da9fbcd1da5899faeb24d1e58d0395) · feat(compiler): add structured Julia IR and owned IDE diagnostics | 实现结构化 Julia 推断 IR、基本块/SSA/局部数据流/实验性 effects 和双客户端诊断。 |
| 34 | [dcf797a](https://github.com/SurviveAIEra/ShenScope/commit/dcf797a05f45b7bbeb93dc0392249370fbe30462) · chore(validation): preserve raw compiler verification output | 仅保存编译诊断的真实原始验证输出，未新增运行时功能。 |
| 35 | [3f634dc](https://github.com/SurviveAIEra/ShenScope/commit/3f634dc1be62047561367d5790e561963bf18bd5) · feat(compiler): archive and compare owned inference reports | 增加会话所有的编译报告归档、标签/CAS、比较、读取与显式孤立文件清理。 |
| 36 | [c97d68c](https://github.com/SurviveAIEra/ShenScope/commit/c97d68c85de3ccc3c0c0e37d3996f5f364726f94) · feat(runtime): preserve compiler publication receipts | 记录编译归档发布回执；提交成功后的通知/取消失败仍保留可核查的提交证据。 |
| 37 | [5f5fdc8](https://github.com/SurviveAIEra/ShenScope/commit/5f5fdc850e0449bc35fffeedf982f5a20a7af550) · feat(compiler): retain source positions and verify previews | 保留真实编译源码行位置，增加当前/历史源码哈希预览及有限比较；行号不证明执行路径。 |
| 38 | [446fc66](https://github.com/SurviveAIEra/ShenScope/commit/446fc66449419c1064c24be19757f515a60451af) · feat(runtime): measure fixed Core workloads and allocations | 实际执行固定 Core 样例，分开记录 warmup、时间/分配字节和 Profile.Allocs 样本，并接入 CLI/tool/两种 IDE。 |
| 39 | [fc200c1](https://github.com/SurviveAIEra/ShenScope/commit/fc200c15cc555d0c7f1e1a5570859d900a82bae5) · feat(analysis): associate runtime reports with source facts | 将拥有的推断/分配报告与当前 JuliaSyntax 声明事实关联，提供分页筛选和哈希源码预览；声明仍是候选。 |
| 40 | [217a0b1](https://github.com/SurviveAIEra/ShenScope/commit/217a0b182e6ee32d56af7bff167f104d2425b558) · feat(runtime): collect bounded periodic Core backtraces | 在固定样例运行时定时记录调用栈，显示采到的核心函数并连接前述报告和源码；修复窄侧栏标题和分页溢出。 |
| 41 | [efa2054](https://github.com/SurviveAIEra/ShenScope/commit/efa2054981df396b59c8d30e3f8548196471c546) · feat(agent): persist conversation plans and enforce execution modes | 可以先让 agent 只读项目、列计划，再由用户切换到实际操作；计划随聊天保存，并显示步骤、依赖和依据，但不会把自己填写的进度当作验证成功。 |
| 42 | [b55a079](https://github.com/SurviveAIEra/ShenScope/commit/b55a07926b61eb90271a6739e8330d7c1cc36d0d) · feat(testing): run project tests and retain failure evidence | 找出项目里声明的测试命令，经授权执行，记录退出状态、失败信息和输出中提到的文件；实际验证了 Python、JavaScript、Go、C、C++ 项目的“测试失败—改代码—再测成功”流程。 |
| 43 | [7885b2d](https://github.com/SurviveAIEra/ShenScope/commit/7885b2d26933c331769e57dcd9db45d321154349) · feat(testing): persist owned test execution receipts | 可以把本次测试结果保存下来，重启后再查看、改名字或删除；这些操作各自检查权限，并且不会重新运行测试命令。 |

## 大白话说明

一次提交就是保存一次进度，功能大小不同。前 1–4 次搭起程序、模型连接、工具、四个操作入口和安装流程；5–7 次加强保存、记忆和聊天界面；8–19 次增加代码分析、任务、外部工具连接、操作指南、自动检查、长聊天处理和分析程序管理；20–24 次完善模型选择及失败处理，并增加 Git 历史和改代码的分批计划；25–32 次完善启动、笔记、安全限制、Julia 分析、扩展包、交互终端和预编译运行文件；33–40 次主要完善 Julia 编译分析报告、保存和比较、源码查看，以及固定样例的耗时、内存分配和调用栈记录。第 34 次只保存测试记录，没有新增产品功能。

这 43 次提交不等于 43 个完整成熟功能。第 41 次增加跨语言项目通用的计划模式和持久化计划；第 42 次增加通用项目测试和失败记录；第 43 次增加测试结果的保存与重启后查看。项目还在早期；真实模型实际编程效果、完整桌面发行版、Windows 安装验证和约 25 万行 Core 门槛均未完成。
