# 逐提交实现记录

已核对的范围：前 46 个提交及本次第 47 个提交；历史链接使用当前 Git 历史的 SHA。
本表说明每次提交的实际修改；局部测试通过不代表整个产品已经完成。详细验证及平台限制见 `WORK_STATUS.md` 和 `docs/validation/`。当前阶段的 Core 目标为 32,000 行，完整产品仍有独立验收事项。

| 顺序 | 提交 | 本次实现 |
|---:|---|---|
| 1 | [ad82cf7](https://github.com/SurviveAIEra/ShenScope/commit/ad82cf7df9e14c02262a2cedc702f81fbeae3de4) · bootstrap: add Julia project, runtime context and durable sessions | 创建 Julia 包结构、运行时上下文和可持久化的会话基础。 |
| 2 | [3c242f1](https://github.com/SurviveAIEra/ShenScope/commit/3c242f189de198e12818d8000b885b59d5bb0dfe) · feat(core): add streaming model providers and permissioned tool-calling agent | 实现五类模型流式协议、权限工具调用、agent 循环、进程与编辑工具；验证使用离线/回环样例。 |
| 3 | [d783f39](https://github.com/SurviveAIEra/ShenScope/commit/d783f39841792392d9c6725fdd415c0e06a02977) · feat(ide): add shared Core protocol, terminal UI and editor clients | 建立 Julia Core 的 stdio RPC、CLI/TUI、VSIX 和 CodeOSS 原生客户端。 |
| 4 | [1c40ed3](https://github.com/SurviveAIEra/ShenScope/commit/1c40ed396d9b155e9748922819d798f28f7acde3) · build: add reproducible Julia and editor environment setup | 添加共享工具链、依赖、后端和编辑器的可重复环境安装流程。 |
| 5 | [a8364f5](https://github.com/SurviveAIEra/ShenScope/commit/a8364f503be485c479784c2da3edfeab18c8e5f0) · fix(storage): preserve atomic snapshots and bound journal reads | 强化原子文件替换、刷盘、有限长度 journal 读取和有限数值校验。 |
| 6 | [584914b](https://github.com/SurviveAIEra/ShenScope/commit/584914ba9f5e7d5d24ab50799a644fb2407e6b29) · feat(core): add scoped versioned memory and atomic imports | 实现 workspace/session/user 记忆、版本/CAS、删除、期限、词法搜索和原子导入导出。 |
| 7 | [7c1a618](https://github.com/SurviveAIEra/ShenScope/commit/7c1a6185df14929917da32e73fddb472fda8bac7) · feat(ide): redesign conversation UI and render safe Markdown | 改进聊天导航、输入区、历史管理、设置、审批卡片与安全 Markdown/代码展示。 |
| 8 | [7cb4071](https://github.com/SurviveAIEra/ShenScope/commit/7cb4071cb60af1a3f391952fecc1494ba5566162) · feat(core): add real project backends and shared editor intelligence | 接入真实 Go AST、Tree-sitter、CodeGraphContext/Ladybug，建立稳定事实、增量图及双客户端 Project 操作。 |
| 9 | [ad31cf7](https://github.com/SurviveAIEra/ShenScope/commit/ad31cf70d43dd709bc9256a5c4e78c72e08aa6ab) · feat(core): add Julia contract reflection and compiler diagnostics | 增加 Julia 接口契约反射、方法歧义、World Age/invokelatest 边界和固定目标编译诊断。 |
| 10 | [6ae2829](https://github.com/SurviveAIEra/ShenScope/commit/6ae2829b176a1894a20f1416e5db0e51fe59d6bc) · feat(core): add durable task graphs and leased worker execution | 实现持久化任务 DAG、依赖、租约、执行结果、重试、对账和作用域消息。 |
| 11 | [2754431](https://github.com/SurviveAIEra/ShenScope/commit/27544310a4236503c0fd4d6c4586581e7701a3ed) · feat(core): add scoped MCP clients and shared editor controls | 实现 MCP stdio/Streamable HTTP、发现/分页、资源/提示词、权限与客户端控制。 |
| 12 | [05ec629](https://github.com/SurviveAIEra/ShenScope/commit/05ec62939b23dac28987c87be3aa5c0d175a0f40) · feat(core): add scoped skills and shared instruction controls | 实现项目/用户作用域 skills 发现、元数据、惰性资源和双客户端指令控制。 |
| 13 | [0e525b3](https://github.com/SurviveAIEra/ShenScope/commit/0e525b3cab0015e5284f8ae348111107403089db) · feat(core): add permissioned lifecycle hooks and durable effect fences | 增加受权限管理的生命周期 hooks、配置/执行结果以及持久化副作用防重复边界。 |
| 14 | [e192374](https://github.com/SurviveAIEra/ShenScope/commit/e192374853cf78a10a032562b745ddc377c0dd65) · feat(core): add durable context projections and bounded recovery | 实现持久化上下文投影、引用校验、裁剪、检查点和有限恢复流程。 |
| 15 | [19c1959](https://github.com/SurviveAIEra/ShenScope/commit/19c1959c2804e47f56d1cc956ea53248b0143275) · feat(project): add compiler semantic indexing and navigation | 接入真实 TypeScript 编译器语义事实、坐标转换、类型/引用/调用导航和更新验证。 |
| 16 | [c9a69e0](https://github.com/SurviveAIEra/ShenScope/commit/c9a69e0419833add473d792bf8dee690b143bd01) · feat(project): compact index history with streaming replay | 压缩项目索引 journal 历史，流式重放，保留当前事实和事务一致性。 |
| 17 | [27e213e](https://github.com/SurviveAIEra/ShenScope/commit/27e213e8046160676d567b91c1d4c3e15aabe435) · feat(project): watch source and configuration changes | 监听源文件及配置，合并变更批次、递归核对并驱动多后端增量更新。 |
| 18 | [84988e9](https://github.com/SurviveAIEra/ShenScope/commit/84988e9976d02d76c7a04b8a143ebb88489bf377) · feat(analysis): isolate and validate Julia analyzer candidates | 增加 Linux 限制进程中的动态 Julia analyzer 执行、自测、资源和系统调用检查。 |
| 19 | [de6132d](https://github.com/SurviveAIEra/ShenScope/commit/de6132d7f4624cea0bbf757606378e4b01317a51) · feat(analysis): integrate graph analyzers and version archives | 接入图分析器与 analyzer 版本归档、晋升、回滚和双客户端管理。 |
| 20 | [c4c886c](https://github.com/SurviveAIEra/ShenScope/commit/c4c886c00bf06b93bab34956d880e214c4652920) · feat(models): discover provider directories and measure requests | 增加模型目录、能力信息、请求计数和使用量测量。 |
| 21 | [a06ae7c](https://github.com/SurviveAIEra/ShenScope/commit/a06ae7c174cc9633e406f159493d1e63c4dae1b8) · feat(models): enforce retry advice and scoped circuit health | 完善模型错误分类、重试建议、部分输出边界和作用域熔断健康状态。 |
| 22 | [c74c04f](https://github.com/SurviveAIEra/ShenScope/commit/c74c04fb8955b9eeda5a4c508f0fbf7390ccfa04) · feat(models): route configured roles through immutable profiles | 实现不可变模型 profiles、角色路由、回退和主/worker 配置。 |
| 23 | [b001f5b](https://github.com/SurviveAIEra/ShenScope/commit/b001f5b691c888b95e7d6c369f0a278fb3c8b4bb) · feat(analysis): add bounded Git co-change and review evidence | 从真实 Git 历史提取有限共变更和审查风险证据。 |
| 24 | [c0cc341](https://github.com/SurviveAIEra/ShenScope/commit/c0cc341da451e531ca9c68fb586ae465e0f31112) · feat(analysis): plan bounded graph migration batches | 根据图关系生成有限迁移计划和依赖/调用顺序批次，保留证据与置信限定。 |
| 25 | [205e6a5](https://github.com/SurviveAIEra/ShenScope/commit/205e6a56ed52c06e1d00762dda1a412731900ee5) · feat(runtime): precompile common server startup paths | 预编译常用服务启动路径，记录实际启动相关证据。 |
| 26 | [9af2212](https://github.com/SurviveAIEra/ShenScope/commit/9af221203dc12862c85b62485f99c21ecd89a787) · feat(memory): add scoped retrieval evidence and note management | 增加记忆检索证据、筛选、分页和笔记管理界面。 |
| 27 | [f18df1d](https://github.com/SurviveAIEra/ShenScope/commit/f18df1dcc2b33bb0a1f34398cbdb456a830794eb) · feat(security): add fail-closed Linux execution policies | 增加遇到不支持情况即拒绝的 Linux 执行策略、资源和 seccomp 检查；普通 host 工具仍未全面 OS 隔离。 |
| 28 | [222d319](https://github.com/SurviveAIEra/ShenScope/commit/222d319fcdbda0601e095a37a8c64362ac92ea64) · feat(project): add Julia syntax and dispatch evidence | 增加 JuliaSyntax 事实、Julia 方法/派发/结构证据；语法关系不等于运行时语义。 |
| 29 | [8e3d0a7](https://github.com/SurviveAIEra/ShenScope/commit/8e3d0a7f0c77ee026d85d651f10201826bdb5091) · feat(project): combine versioned backend evidence | 组合有版本与来源的多后端证据，保留 provider 差异和启发式关系。 |
| 30 | [64d545e](https://github.com/SurviveAIEra/ShenScope/commit/64d545eac286ff6c0a2a571beea74e08463ae96c) · feat(extensions): add Julia package lifecycle and sparse evidence | 实现独立 Julia 包生命周期、源码/UUID/version 回执、激活/停用与 SparseArrays 可选扩展。 |
| 31 | [8638100](https://github.com/SurviveAIEra/ShenScope/commit/8638100ce30553f4dc213fb46cd39be315dc0342) · feat(runtime): add owned PTY terminals and native editor adapters | 实现有所有权的 Linux PTY、stdin/resize/取消，以及 VSIX/原生终端适配。 |
| 32 | [e24d2e6](https://github.com/SurviveAIEra/ShenScope/commit/e24d2e61f7780f6f47fdb937ad8bf5448061c30a) · feat(distribution): verify Julia runtime images and compiler builds | 实现实际 Julia runtime image 构建及源码/依赖校验、构建回执与 image 运行测试。 |
| 33 | [6d3af4c](https://github.com/SurviveAIEra/ShenScope/commit/6d3af4c2ab415b9a1e42abb20c4afd5229ac75fa) · feat(compiler): add structured Julia IR and owned IDE diagnostics | 实现结构化 Julia 推断 IR、基本块/SSA/局部数据流/实验性 effects 和双客户端诊断。 |
| 34 | [42913f7](https://github.com/SurviveAIEra/ShenScope/commit/42913f7b5049ed3a7d38b039562429bf75708401) · chore(validation): preserve raw compiler verification output | 仅保存编译诊断的真实原始验证输出，未新增运行时功能。 |
| 35 | [5642d50](https://github.com/SurviveAIEra/ShenScope/commit/5642d50903b4f03952a9aca9756907c84435e8df) · feat(compiler): archive and compare owned inference reports | 增加会话所有的编译报告归档、标签/CAS、比较、读取与显式孤立文件清理。 |
| 36 | [23f9be3](https://github.com/SurviveAIEra/ShenScope/commit/23f9be3e0b85294c7101ecc06017499b499b6a91) · feat(runtime): preserve compiler publication receipts | 记录编译归档发布回执；提交成功后的通知/取消失败仍保留可核查的提交证据。 |
| 37 | [40798ba](https://github.com/SurviveAIEra/ShenScope/commit/40798ba17e591d56ecebacb7873d468f1e1e0462) · feat(compiler): retain source positions and verify previews | 保留真实编译源码行位置，增加当前/历史源码哈希预览及有限比较；行号不证明执行路径。 |
| 38 | [ce88f0e](https://github.com/SurviveAIEra/ShenScope/commit/ce88f0e1a9ef58519254cbe7324acaf6e3a16a68) · feat(runtime): measure fixed Core workloads and allocations | 实际执行固定 Core 样例，分开记录 warmup、时间/分配字节和 Profile.Allocs 样本，并接入 CLI/tool/两种 IDE。 |
| 39 | [674acd6](https://github.com/SurviveAIEra/ShenScope/commit/674acd6f2e897256516f386684fb926e329cad9c) · feat(analysis): associate runtime reports with source facts | 将拥有的推断/分配报告与当前 JuliaSyntax 声明事实关联，提供分页筛选和哈希源码预览；声明仍是候选。 |
| 40 | [74d8864](https://github.com/SurviveAIEra/ShenScope/commit/74d8864c668a492f50ab2d79967fb6ef2ee0e3ed) · feat(runtime): collect bounded periodic Core backtraces | 在固定样例运行时定时记录调用栈，显示采到的核心函数并连接前述报告和源码；修复窄侧栏标题和分页溢出。 |
| 41 | [3a82525](https://github.com/SurviveAIEra/ShenScope/commit/3a82525e2801768e17505dc11f59e3aef3d46cdf) · feat(agent): persist conversation plans and enforce execution modes | 可以先让 agent 只读项目、列计划，再由用户切换到实际操作；计划随聊天保存，并显示步骤、依赖和依据，但不会把自己填写的进度当作验证成功。 |
| 42 | [e20887f](https://github.com/SurviveAIEra/ShenScope/commit/e20887ff8e638e993f2270c50697ce2179a255b4) · feat(testing): run project tests and retain failure evidence | 找出项目里声明的测试命令，经授权执行，记录退出状态、失败信息和输出中提到的文件；实际验证了 Python、JavaScript、Go、C、C++ 项目的“测试失败—改代码—再测成功”流程。 |
| 43 | [d6c6ca4](https://github.com/SurviveAIEra/ShenScope/commit/d6c6ca4a7acbdc2dfd74f6ca186568c86dde8a42) · feat(testing): persist owned test execution receipts | 可以把本次测试结果保存下来，重启后再查看、改名字或删除；这些操作各自检查权限，并且不会重新运行测试命令。 |
| 44 | [574b7aa](https://github.com/SurviveAIEra/ShenScope/commit/574b7aa49580adb98b37303ed453f62d3e5c7807) · feat(testing): integrate native editor test controllers | 两种编辑器都能在原生测试界面运行项目测试、查看失败、再测及取消；按命令分别授权，并防止通信故障导致同一命令重复执行。 |

| 45 | [ed107ab](https://github.com/SurviveAIEra/ShenScope/commit/ed107aba850604d53d59bbc1489cbf235290593b) · feat(problems): collect source-verified project diagnostics | 把项目错误关联到确切源码版本；代码变化后撤回旧标记，提供筛选、比较与源码查看，并检查会话和读取权限。 |
| 46 | [6c9bcb5](https://github.com/SurviveAIEra/ShenScope/commit/6c9bcb56d76fc26bd3f0ab618aa72978b70f72bc) · feat(workspace): add reviewed edits and project language services | 可以连接语言服务器查代码、准备重命名和格式化修改；多文件改动先看差异再应用，检查源码是否已变，并把实际测试、编译结果和改动关联起来。中英文 README 说明项目设计及各入口的实际状态。 |
| 47 | 本次提交 · feat(diagnostics): verify project checks and publish native Problems | 能导入指定源码版本的 SARIF 检查报告，比较前后报告，把编译检查与已应用的改动关联；两种编辑器都能在 Problems 里查看错误、打开文件，修改文件或撤销读取权限后清除旧标记。 |

## 大白话说明

一次提交就是保存一次进度，功能大小不同。前 1–4 次搭起程序、模型连接、工具、四个操作入口和安装流程；5–7 次加强保存、记忆和聊天界面；8–19 次增加代码分析、任务、外部工具连接、操作指南、自动检查、长聊天处理和分析程序管理；20–24 次完善模型选择及失败处理，并增加 Git 历史和改代码的分批计划；25–32 次完善启动、笔记、安全限制、Julia 分析、扩展包、交互终端和预编译运行文件；33–40 次主要完善 Julia 编译分析报告、保存和比较、源码查看，以及固定样例的耗时、内存分配和调用栈记录。第 34 次只保存测试记录，没有新增产品功能。

这些提交不等于同等数量的完整成熟功能。第 41 次增加跨语言项目通用的计划模式和持久化计划；第 42 次增加通用项目测试和失败记录；第 43 次增加测试结果的保存与重启后查看；第 44 次接入两种编辑器的原生测试界面；第 45 次关联诊断与源码版本；第 46 次增加语言服务器和审阅后修改代码的流程；第 47 次补充检查报告导入、修改后编译检查及两种编辑器的 Problems。当前 32,000 行阶段的代码和相关功能检查已完成。真实模型实际编程效果、完整桌面发行版和 Windows 安装验证仍未完成。
