# 逐提交实现记录

已核对的范围：前 48 个提交及本次第 49 个提交；历史链接使用当前 Git 历史的 SHA。
本表说明每次提交的实际修改；局部测试通过不代表整个产品已经完成。详细验证及平台限制见 `WORK_STATUS.md` 和 `docs/validation/`。当前阶段的 Core 目标为 32,000 行，完整产品仍有独立验收事项。

| 顺序 | 提交 | 本次实现 |
|---:|---|---|
| 1 | [e3c852c](https://github.com/SurviveAIEra/ShenScope/commit/e3c852c3c5f8d81dd81c67b592ff2a6507c4ead7) · bootstrap: add Julia project, runtime context and durable sessions | 创建 Julia 包结构、运行时上下文和可持久化的会话基础。 |
| 2 | [1353c0d](https://github.com/SurviveAIEra/ShenScope/commit/1353c0d3735ef7a15dc78ae5548e39738f60e904) · feat(core): add streaming model providers and permissioned tool-calling agent | 实现五类模型流式协议、权限工具调用、agent 循环、进程与编辑工具；验证使用离线/回环样例。 |
| 3 | [b589934](https://github.com/SurviveAIEra/ShenScope/commit/b589934e232486f31ebaa20108ca10d55e41969c) · feat(ide): add shared Core protocol, terminal UI and editor clients | 建立 Julia Core 的 stdio RPC、CLI/TUI、VSIX 和 CodeOSS 原生客户端。 |
| 4 | [c47b5ac](https://github.com/SurviveAIEra/ShenScope/commit/c47b5ac2fb93a874876d418baac7bb7fb818a2db) · build: add reproducible Julia and editor environment setup | 添加共享工具链、依赖、后端和编辑器的可重复环境安装流程。 |
| 5 | [3cc9932](https://github.com/SurviveAIEra/ShenScope/commit/3cc9932d0baf1c47c442a0758642163eac02e9bc) · fix(storage): preserve atomic snapshots and bound journal reads | 强化原子文件替换、刷盘、有限长度 journal 读取和有限数值校验。 |
| 6 | [7745ec5](https://github.com/SurviveAIEra/ShenScope/commit/7745ec53ce839ff55187790ef9d05952208728a7) · feat(core): add scoped versioned memory and atomic imports | 实现 workspace/session/user 记忆、版本/CAS、删除、期限、词法搜索和原子导入导出。 |
| 7 | [96afecc](https://github.com/SurviveAIEra/ShenScope/commit/96afecc9c6074228881ed07ac178d37f53b48d24) · feat(ide): redesign conversation UI and render safe Markdown | 改进聊天导航、输入区、历史管理、设置、审批卡片与安全 Markdown/代码展示。 |
| 8 | [c32459b](https://github.com/SurviveAIEra/ShenScope/commit/c32459bb141bc022166eb8de32866ba0fc701847) · feat(core): add real project backends and shared editor intelligence | 接入真实 Go AST、Tree-sitter、CodeGraphContext/Ladybug，建立稳定事实、增量图及双客户端 Project 操作。 |
| 9 | [aad646b](https://github.com/SurviveAIEra/ShenScope/commit/aad646b2f0faa47b0d39ff7b9bb2b0136858e2b8) · feat(core): add Julia contract reflection and compiler diagnostics | 增加 Julia 接口契约反射、方法歧义、World Age/invokelatest 边界和固定目标编译诊断。 |
| 10 | [c61ba1e](https://github.com/SurviveAIEra/ShenScope/commit/c61ba1e64362ba31fbb148a7df43f2d17be66887) · feat(core): add durable task graphs and leased worker execution | 实现持久化任务 DAG、依赖、租约、执行结果、重试、对账和作用域消息。 |
| 11 | [48c5847](https://github.com/SurviveAIEra/ShenScope/commit/48c5847eb3bd412661cd030fba9d19c8225202ef) · feat(core): add scoped MCP clients and shared editor controls | 实现 MCP stdio/Streamable HTTP、发现/分页、资源/提示词、权限与客户端控制。 |
| 12 | [70bca7f](https://github.com/SurviveAIEra/ShenScope/commit/70bca7fda7ca2aa1ee4975bc0004b01189854cd8) · feat(core): add scoped skills and shared instruction controls | 实现项目/用户作用域 skills 发现、元数据、惰性资源和双客户端指令控制。 |
| 13 | [977dfaf](https://github.com/SurviveAIEra/ShenScope/commit/977dfaf9f81ae3934602a975c8251ca6ef05197d) · feat(core): add permissioned lifecycle hooks and durable effect fences | 增加受权限管理的生命周期 hooks、配置/执行结果以及持久化副作用防重复边界。 |
| 14 | [2483265](https://github.com/SurviveAIEra/ShenScope/commit/24832658ab55d18dcea6fd5a7b0554158173d9a2) · feat(core): add durable context projections and bounded recovery | 实现持久化上下文投影、引用校验、裁剪、检查点和有限恢复流程。 |
| 15 | [eb56f54](https://github.com/SurviveAIEra/ShenScope/commit/eb56f5409f3e0840fd24424589d1c398274e90fa) · feat(project): add compiler semantic indexing and navigation | 接入真实 TypeScript 编译器语义事实、坐标转换、类型/引用/调用导航和更新验证。 |
| 16 | [f55797d](https://github.com/SurviveAIEra/ShenScope/commit/f55797dcdabb1bc1a1b2d30895acc4baf57737b1) · feat(project): compact index history with streaming replay | 压缩项目索引 journal 历史，流式重放，保留当前事实和事务一致性。 |
| 17 | [f13ad8d](https://github.com/SurviveAIEra/ShenScope/commit/f13ad8d7fc71eea9b640de227deb49b6f70c47c6) · feat(project): watch source and configuration changes | 监听源文件及配置，合并变更批次、递归核对并驱动多后端增量更新。 |
| 18 | [c547dff](https://github.com/SurviveAIEra/ShenScope/commit/c547dffebda9d701c17c91af6c9e8e39f0bec6a6) · feat(analysis): isolate and validate Julia analyzer candidates | 增加 Linux 限制进程中的动态 Julia analyzer 执行、自测、资源和系统调用检查。 |
| 19 | [c63e312](https://github.com/SurviveAIEra/ShenScope/commit/c63e3129a150b9bc4a0e52b500414f0967e20c99) · feat(analysis): integrate graph analyzers and version archives | 接入图分析器与 analyzer 版本归档、晋升、回滚和双客户端管理。 |
| 20 | [60eaba5](https://github.com/SurviveAIEra/ShenScope/commit/60eaba5a852191c48609b80dff5793ef1b67bf10) · feat(models): discover provider directories and measure requests | 增加模型目录、能力信息、请求计数和使用量测量。 |
| 21 | [45a51b9](https://github.com/SurviveAIEra/ShenScope/commit/45a51b914557249631d52ccdc710c33e16c49cfd) · feat(models): enforce retry advice and scoped circuit health | 完善模型错误分类、重试建议、部分输出边界和作用域熔断健康状态。 |
| 22 | [768422b](https://github.com/SurviveAIEra/ShenScope/commit/768422bf6c86b698c08d8f98cecb1b5817a6748d) · feat(models): route configured roles through immutable profiles | 实现不可变模型 profiles、角色路由、回退和主/worker 配置。 |
| 23 | [173a76c](https://github.com/SurviveAIEra/ShenScope/commit/173a76c21ea829622b19919581c18835151aabf2) · feat(analysis): add bounded Git co-change and review evidence | 从真实 Git 历史提取有限共变更和审查风险证据。 |
| 24 | [a179c97](https://github.com/SurviveAIEra/ShenScope/commit/a179c9794154b68d02157b6adc2290f48f4f1bef) · feat(analysis): plan bounded graph migration batches | 根据图关系生成有限迁移计划和依赖/调用顺序批次，保留证据与置信限定。 |
| 25 | [6c9e469](https://github.com/SurviveAIEra/ShenScope/commit/6c9e469440c7b41c00063bf9845351a9008eb414) · feat(runtime): precompile common server startup paths | 预编译常用服务启动路径，记录实际启动相关证据。 |
| 26 | [9d35ca1](https://github.com/SurviveAIEra/ShenScope/commit/9d35ca10b1cc591932db5fec28bcff1b65e8519c) · feat(memory): add scoped retrieval evidence and note management | 增加记忆检索证据、筛选、分页和笔记管理界面。 |
| 27 | [99bb785](https://github.com/SurviveAIEra/ShenScope/commit/99bb7855cf9966334cee64fe347f72ef87175fde) · feat(security): add fail-closed Linux execution policies | 增加遇到不支持情况即拒绝的 Linux 执行策略、资源和 seccomp 检查；普通 host 工具仍未全面 OS 隔离。 |
| 28 | [3d8aef9](https://github.com/SurviveAIEra/ShenScope/commit/3d8aef91017b87c1320a0708e8c6d3af3b4e790a) · feat(project): add Julia syntax and dispatch evidence | 增加 JuliaSyntax 事实、Julia 方法/派发/结构证据；语法关系不等于运行时语义。 |
| 29 | [9acfb11](https://github.com/SurviveAIEra/ShenScope/commit/9acfb115d7711e925b0731ad9a0947cda4f2b7d7) · feat(project): combine versioned backend evidence | 组合有版本与来源的多后端证据，保留 provider 差异和启发式关系。 |
| 30 | [e2823d8](https://github.com/SurviveAIEra/ShenScope/commit/e2823d88bdc2cbc8fc55c90529d825280666bb8a) · feat(extensions): add Julia package lifecycle and sparse evidence | 实现独立 Julia 包生命周期、源码/UUID/version 回执、激活/停用与 SparseArrays 可选扩展。 |
| 31 | [091fb2d](https://github.com/SurviveAIEra/ShenScope/commit/091fb2db22753e6645a3cddea16ebddd89470b3d) · feat(runtime): add owned PTY terminals and native editor adapters | 实现有所有权的 Linux PTY、stdin/resize/取消，以及 VSIX/原生终端适配。 |
| 32 | [0245975](https://github.com/SurviveAIEra/ShenScope/commit/02459755ec63a5d2d549133ac0d06b1d8bf15967) · feat(distribution): verify Julia runtime images and compiler builds | 实现实际 Julia runtime image 构建及源码/依赖校验、构建回执与 image 运行测试。 |
| 33 | [8b439d6](https://github.com/SurviveAIEra/ShenScope/commit/8b439d6023e17c857964c64e2804607c17700af5) · feat(compiler): add structured Julia IR and owned IDE diagnostics | 实现结构化 Julia 推断 IR、基本块/SSA/局部数据流/实验性 effects 和双客户端诊断。 |
| 34 | [2c92e51](https://github.com/SurviveAIEra/ShenScope/commit/2c92e51bb1112863e3c80396128a62a114217b9b) · chore(validation): preserve raw compiler verification output | 仅保存编译诊断的真实原始验证输出，未新增运行时功能。 |
| 35 | [1403ed8](https://github.com/SurviveAIEra/ShenScope/commit/1403ed8ae2786fae5a9c303b889250459a1f3105) · feat(compiler): archive and compare owned inference reports | 增加会话所有的编译报告归档、标签/CAS、比较、读取与显式孤立文件清理。 |
| 36 | [0ddb0d3](https://github.com/SurviveAIEra/ShenScope/commit/0ddb0d341a18863f942db07a410b59fbef875c23) · feat(runtime): preserve compiler publication receipts | 记录编译归档发布回执；提交成功后的通知/取消失败仍保留可核查的提交证据。 |
| 37 | [15df1ba](https://github.com/SurviveAIEra/ShenScope/commit/15df1badb8057bb50cc8bad7ea1266db9362ce45) · feat(compiler): retain source positions and verify previews | 保留真实编译源码行位置，增加当前/历史源码哈希预览及有限比较；行号不证明执行路径。 |
| 38 | [2e2ba2a](https://github.com/SurviveAIEra/ShenScope/commit/2e2ba2af2bca96fa64e39774b8b27d7725289735) · feat(runtime): measure fixed Core workloads and allocations | 实际执行固定 Core 样例，分开记录 warmup、时间/分配字节和 Profile.Allocs 样本，并接入 CLI/tool/两种 IDE。 |
| 39 | [b97b139](https://github.com/SurviveAIEra/ShenScope/commit/b97b139489f0193fb3929fc194103b3c78f8b455) · feat(analysis): associate runtime reports with source facts | 将拥有的推断/分配报告与当前 JuliaSyntax 声明事实关联，提供分页筛选和哈希源码预览；声明仍是候选。 |
| 40 | [a338c9b](https://github.com/SurviveAIEra/ShenScope/commit/a338c9b85ae731687285099ff3de7d548dec65c1) · feat(runtime): collect bounded periodic Core backtraces | 在固定样例运行时定时记录调用栈，显示采到的核心函数并连接前述报告和源码；修复窄侧栏标题和分页溢出。 |
| 41 | [5e91c7f](https://github.com/SurviveAIEra/ShenScope/commit/5e91c7fd18bd2faf83306abc2135edc08f514caa) · feat(agent): persist conversation plans and enforce execution modes | 可以先让 agent 只读项目、列计划，再由用户切换到实际操作；计划随聊天保存，并显示步骤、依赖和依据，但不会把自己填写的进度当作验证成功。 |
| 42 | [1c2b28a](https://github.com/SurviveAIEra/ShenScope/commit/1c2b28a030053da57e6a4e226cb79c475b0547a4) · feat(testing): run project tests and retain failure evidence | 找出项目里声明的测试命令，经授权执行，记录退出状态、失败信息和输出中提到的文件；实际验证了 Python、JavaScript、Go、C、C++ 项目的“测试失败—改代码—再测成功”流程。 |
| 43 | [94246a4](https://github.com/SurviveAIEra/ShenScope/commit/94246a4e7def8df72d278451f454e3012d435a22) · feat(testing): persist owned test execution receipts | 可以把本次测试结果保存下来，重启后再查看、改名字或删除；这些操作各自检查权限，并且不会重新运行测试命令。 |
| 44 | [399b3be](https://github.com/SurviveAIEra/ShenScope/commit/399b3bed1085d7c7420b161bf8dcdc395dd5b3a5) · feat(testing): integrate native editor test controllers | 两种编辑器都能在原生测试界面运行项目测试、查看失败、再测及取消；按命令分别授权，并防止通信故障导致同一命令重复执行。 |

| 45 | [8382cc2](https://github.com/SurviveAIEra/ShenScope/commit/8382cc292cf5546c0766c2ab3896ca59f024d14a) · feat(problems): collect source-verified project diagnostics | 把项目错误关联到确切源码版本；代码变化后撤回旧标记，提供筛选、比较与源码查看，并检查会话和读取权限。 |
| 46 | [eeae68e](https://github.com/SurviveAIEra/ShenScope/commit/eeae68e07ac4c2c500e4caeda4a028e5cee95ecb) · feat(workspace): add reviewed edits and project language services | 可以连接语言服务器查代码、准备重命名和格式化修改；多文件改动先看差异再应用，检查源码是否已变，并把实际测试、编译结果和改动关联起来。中英文 README 说明项目设计及各入口的实际状态。 |
| 47 | [6de40fe](https://github.com/SurviveAIEra/ShenScope/commit/6de40fed75742a2df627e5dabeff57a239016d91) · feat(diagnostics): verify project checks and publish native Problems | 能导入指定源码版本的 SARIF 检查报告，比较前后报告，把编译检查与已应用的改动关联；两种编辑器都能在 Problems 里查看错误、打开文件，修改文件或撤销读取权限后清除旧标记。 |
| 48 | [a3c021e](https://github.com/SurviveAIEra/ShenScope/commit/a3c021edcd01f59ab583e92d3a794c11bd1a700b) · docs: explain ShenScope workflows and project authorship | 参考开源项目的 README 写法重写中英文介绍，用实际例子说明 Julia 核心的设计；补充作者、署名和许可证说明，并更新历史提交链接。功能代码没有变化。 |
| 49 | [e52f72d](https://github.com/SurviveAIEra/ShenScope/commit/e52f72d72e3659a1014c4dde28c0e4cdbc1bec2a) · license: restrict original source to project contributions | 原创部分改为仅贡献许可，补充明确的 PR 授权，更新双语 README、插件许可与署名；保留私有历史，新增公开前的旧许可检查。没有更改仓库可见性或 Agent 功能。 |
| 50 | 本次提交 · feat(cli): install shenscope on PATH | 安装一次即可在任意目录直接输入 shenscope；仅创建链接，保留已有同名文件，启动器支持带空格的路径和指定 Julia。实测 CLI 与 TUI，并在中英文 README 讲述深圳人才公园的诞生灵感。 |

## 大白话说明

一次提交就是保存一次进度，功能大小不同。前 1–4 次搭起程序、模型连接、工具、四个操作入口和安装流程；5–7 次加强保存、记忆和聊天界面；8–19 次增加代码分析、任务、外部工具连接、操作指南、自动检查、长聊天处理和分析程序管理；20–24 次完善模型选择及失败处理，并增加 Git 历史和改代码的分批计划；25–32 次完善启动、笔记、安全限制、Julia 分析、扩展包、交互终端和预编译运行文件；33–40 次主要完善 Julia 编译分析报告、保存和比较、源码查看，以及固定样例的耗时、内存分配和调用栈记录。第 34 次只保存测试记录，没有新增产品功能。

这些提交不等于同等数量的完整成熟功能。第 41 次增加跨语言项目通用的计划模式和持久化计划；第 42 次增加通用项目测试和失败记录；第 43 次增加测试结果的保存与重启后查看；第 44 次接入两种编辑器的原生测试界面；第 45 次关联诊断与源码版本；第 46 次增加语言服务器和审阅后修改代码的流程；第 47 次补充检查报告导入、修改后编译检查及两种编辑器的 Problems。当前 32,000 行阶段的代码和相关功能检查已完成。真实模型实际编程效果、完整桌面发行版和 Windows 安装验证仍未完成。
