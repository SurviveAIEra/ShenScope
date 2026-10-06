# ShenScope

**深入代码，看清改动。**

简体中文 · [English](README.en.md) · [使用文档](#文档) · [作者与许可](#作者与许可)

ShenScope 是由 [SurviveAIEra](https://github.com/SurviveAIEra) 发起的 AI 编程助手，核心用 Julia 编写。它可以帮你读懂项目、排查问题、修改代码和运行测试，提供命令行、终端交互界面、VS Code 扩展和独立 IDE 开发版。

项目计划公开源码，采用[仅限项目贡献的受限许可](LICENSE)，不属于标准开源。默认允许为 ShenScope 准备、测试和提交改进；在其他项目中使用或独立发行，需要另行授权。

它面向各种语言的项目，包括 Python、JavaScript/TypeScript、Go、C/C++ 等。你不用把项目改成 Julia，也不用为了日常使用学习 Julia。

维护已有项目，难的往往是弄清改动范围。**改一个接口，哪些地方会受影响？应该先看哪些文件、跑哪些测试？项目自己的分层规则，又该怎么检查？** ShenScope 把代码关系保存在本地，用 Julia 函数查找、遍历和筛选，再把相关代码与分析结果交给模型。

- **项目索引可以反复用。** 符号、依赖和调用关系保留在运行中的 Core 里，支持缓存、持久化和文件保存后的增量更新。
- **分析方法可以自己写。** 通用分析之外，可以为项目编写专用 Julia 分析器，也可以让模型生成分析器，验证后再使用。
- **代码后端可以换。** Go AST、Tree-sitter、CodeGraphContext 和 TypeScript 编译器通过统一接口提供数据，分析器不必跟着某个图数据库的格式走。
- **模型和工具可以自己接。** 使用现有模型协议、MCP、Skills、Hooks，或用独立 Julia 扩展包接入内部工具。

*Born in Shenzhen. Built with Julia.*

## 从深圳人才公园的一次散步说起

ShenScope 的灵感，来自作者 SurviveAIEra 在深圳南山人才公园的一次散步。眼前是山海连城的景色，高楼大厦与山海相映。看着这样的深圳，一个关于编程工具的念头渐渐清晰起来。

在使用现有 Agent 工具时，作者常常看到它们反复调用 `grep` 等文本搜索工具：找到一段代码，再搜索另一处，接着继续翻文件。搜索很有用，但找到文字之后，还要弄清函数如何调用、模块如何依赖、修改会传到哪里。熟悉项目的人，脑中通常已经有这些关系；助手每次接手任务，也应该能用上对项目的这种认识。

于是有了 ShenScope 的出发点：**让 Agent 持续掌握项目内部的关系，并能围绕这些关系做分析。** 代码索引留在本地，文件变化后更新；查调用、追依赖、筛测试这些计算由本地程序完成。模型拿到相关代码和分析结果，再判断问题、提出修改。遇到项目特有的规则，还可以写一段专用分析程序，验证后反复使用。这也是常驻项目数据、可切换代码后端和可编程分析器这套架构的由来。

语言的选择则来自另一份喜欢。作者以前用过 Julia，很喜欢这门兼顾表达力与高性能的语言。用 Julia 实现 Agent，可以把项目数据、图计算和自定义分析放在同一个运行时里；分析方法写成普通函数，也能使用多重分派、动态加载和 JIT。对 Agent 工作方式的思考，与对 Julia 的熟悉和喜爱碰在一起，最终变成了这个项目。它用 Julia 构建，服务的则是各种语言的代码库。

名字也留下了这份来处：**Shen** 取自深圳，也有深入代码的意思；**Scope** 指向看清项目结构与改动范围。

深圳让人着迷的地方，就在于这些景象能同时存在：高楼之间有忙碌的研发团队，城市身边有山、有海，也有可以慢慢走一走的公园。这里有把想法做成东西的热情，也有让人停下来、冒出新想法的风景。欢迎大家来了解深圳；有机会也来南山人才公园走走，沿着深圳湾看看这座城。ShenScope 的故事，就从这里开始。

## 快速开始

目前从源码运行。先安装 **Julia 1.11 或更新的兼容版本**；下面的命令使用 Bash，适用于 Linux/macOS。

### 1. 准备 Core 并安装命令

```bash
git clone https://github.com/SurviveAIEra/ShenScope.git
cd ShenScope
export SHENSCOPE_JULIA="$(command -v julia)"
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-$HOME/.julia}"
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
bash scripts/install_cli.sh
export PATH="$HOME/.local/bin:$PATH"
shenscope --help
```

安装脚本在 `~/.local/bin` 创建一个指向本仓库的 `shenscope` 链接，不会复制项目。上面的 `export` 让当前终端立即生效；将它加入 Bash 的 `~/.bashrc` 或 Zsh 的 `~/.zshrc`，以后打开终端就能直接使用 `shenscope`。

安装只需做一次。之后可以从任意目录启动，请保留这份仓库，更新代码时在这里执行 `git pull`。`bin/shenscope` 是直接运行仓库文件的写法，安装到 `PATH` 后就不必加 `bin/`。指定安装位置、选择 Julia 和排查“找不到命令”的方法见[命令安装说明](docs/cli-installation.md)。

### 2. 配置模型

把下面的内容保存为你自己的 `shenscope.toml`。这里以 OpenAI Chat 接口为例，地址和模型名称按实际服务修改：

```toml
[provider]
protocol = "openai_chat"
name = "my-service"
endpoint = "https://api.openai.com/v1"
model = "gpt-4.1"
key_env = "SHENSCOPE_MODEL_KEY"

[permissions]
read = "allow"
edit = "ask"
process = "ask"
network = "ask"
mcp = "ask"
dynamic = "ask"
persistence = "ask"
```

API Key 放在 `SHENSCOPE_MODEL_KEY` 环境变量中，配置文件只记录变量名。在 Bash 中可以这样输入，密钥不会显示在屏幕上，也不会写进这条命令的历史记录：

```bash
read -r -s -p '模型 API Key: ' SHENSCOPE_MODEL_KEY
export SHENSCOPE_MODEL_KEY
```

也支持 OpenAI Responses、Anthropic、Gemini 和 Ollama。其他服务可以按其兼容协议接入；配置说明见[模型服务](docs/core/models.md)。

### 3. 打开自己的项目

安装命令后，在任意目录执行，将路径换成你的项目与配置文件：

```bash
shenscope doctor --root /path/to/project --config /path/to/shenscope.toml
shenscope tui --root /path/to/project --config /path/to/shenscope.toml
```

进入 TUI 后，可以先试试：

```text
帮我梳理这个项目的目录结构，找到主要入口和测试入口。
```

也可以直接发起命令行任务。下面使用 Plan 模式，先调查并提出方案：

```bash
shenscope chat "查找这个接口的使用位置，说明修改它可能影响哪些代码" \
  --root /path/to/project --config /path/to/shenscope.toml --agent-mode plan
```

项目图分析需要安装相应后端并建立索引，见[项目数据与索引](docs/core/project_data.md)。普通文件搜索、代码修改和测试命令不要求先建立代码图。

## 在 VS Code 和独立 IDE 中使用

| 入口 | 适合怎么用 |
|---|---|
| CLI | 在终端发起任务，或放进自己的脚本中 |
| TUI | 在终端里连续对话，查看工具执行并处理授权 |
| VS Code 扩展 | 安装独立 VSIX，在现有 VS Code 中使用 ShenScope 侧栏 |
| ShenScope IDE | 从源码启动基于 Code-OSS 的独立编辑器开发版；侧栏直接集成在编辑器中，禁用扩展后仍可使用 |

四个入口共用 Julia Core。模型配置、会话、权限和项目分析由 Core 管理。VS Code 扩展与独立 IDE 共用面板，并接入编辑器的 Terminal、Testing 和 Problems：测试可以从测试视图运行，项目诊断可以显示在问题列表中。

### 构建 VS Code 扩展

完成上面的 Core 准备后，安装 Node.js、npm 和 Python 3，在仓库根目录执行：

```bash
npm --prefix editors ci --ignore-scripts --no-audit --no-fund
npm --prefix editors run check
npm --prefix editors run build
python scripts/package_vsix.py
code --install-extension dist/shenscope-0.1.0.vsix
```

在可信本地工作区打开 ShenScope 侧栏。用 `shenscope.juliaPath` 设置 Julia 可执行文件，`shenscope.corePath` 指向已准备好的 ShenScope 仓库绝对路径。模型密钥也可以保存在 VS Code 安全存储中。

VSIX 附带 Core 源码，不附带 Julia。要使用包内的 Core，需要另行安装其 Julia 依赖，见[扩展说明](editors/vscode/README.md)。

### 独立 IDE

**目前没有可直接下载安装的完整 ShenScope IDE 安装包。** 已有可运行的源码开发版和原生侧栏集成；安装程序、内置 Julia、升级与卸载流程还未完成。源码构建步骤见 [IDE 说明](ide/README.md)。

## Julia 核心的设计

### 把项目关系留在本地

假设你准备修改一个公共接口。ShenScope 可以从索引中沿调用关系向上查找，列出可能受影响的位置，再筛选相关测试、查看这些文件过去是否经常一起修改。模型据此阅读相关代码、制定方案；图遍历和筛选由本地函数完成。

文件、符号、关系和双向索引保存在常驻的 `ProjectState` 中，同一轮任务里的多次查询可以复用它们。索引支持持久化；监测已保存文件的变化后，可以增量更新。结果记录对应的源码版本，便于判断分析是否已经过时。

这种安排把重复查询和确定性计算留在本地，让模型集中处理需求、代码生成和工程判断。相关实现见[项目数据](docs/core/project_data.md)、[文件监测](docs/core/project_watch.md)和 [Git 历史分析](docs/core/git_history.md)。

### 代码后端与分析方法分开

不同项目可以使用不同的数据来源。后端负责提取代码信息，Core 统一表示符号、关系和源码位置，分析器负责计算。

| 数据来源 | 当前能做什么 |
|---|---|
| Go AST | 使用 Go 官方解析器提取声明、导入和调用候选；调用关系尚未经过 Go 类型检查 |
| Tree-sitter | 提取多语言语法结构，支持部分声明和关系分析 |
| CodeGraphContext | 通过实际 SDK 与 Ladybug 图存储读取代码图，转换为 Core 的统一数据 |
| TypeScript 编译器 | 提供 JS/TS 类型、定义、引用、调用、实现关系和诊断 |
| JuliaSyntax | 为 Julia 项目补充语法结构分析 |
| 外部 LSP | 连接配置好的语言服务器，按其能力提供导航、补全、签名和调用层次 |

同一套影响分析和测试筛选可以使用不同后端。接入内部代码图时，也可以只实现后端适配器，继续使用现有分析方法。

多个后端保存的数据还可以联合查询，并保留各自来源。语法解析给出的调用候选、编译器确认的引用、运行采样得到的记录，含义各不相同。外部 LSP 当前同步磁盘文件，未保存编辑器内容的同步尚未完成。详细覆盖范围见[联合查询](docs/core/combined_evidence.md)、[TypeScript 语义](docs/core/semantic.md)和[语言服务](docs/core/language_services.md)。

### 项目有特殊规则，就写专用分析器

“禁止业务层直接调用存储层”“改这个接口前，先检查哪些模块”——这类规则因项目而异。ShenScope 的内置分析覆盖修改影响、测试筛选、Git 共同修改记录、架构依赖、迁移顺序和风险；更具体的规则可以写成普通 Julia 函数。

也可以让模型生成一个临时分析器。Core 把选定的项目数据传给独立进程，运行外部测试样例，并检查结果里引用的符号和关系。验证通过后，用它处理本次任务；值得复用的方法可以归档，选为项目或用户范围的活动版本，之后再更新或回滚。

Julia 的函数、动态加载和 JIT 让这些分析方法可以用同一种语言编写和运行。生成的分析代码在独立进程里执行；目前已验证 Linux x86_64 的 seccomp 限制，禁止打开文件、访问网络和创建子进程，并限制执行时间与输出。其他平台的隔离执行尚未完成。入口和完整流程见[自定义分析器](docs/core/isolated_analyzers.md)。

### 用独立扩展接入自己的工具

模型服务、工具、代码后端和分析器使用 Julia 类型与多重分派接口。扩展可以放在独立 Julia 包中，为自己的类型实现相应方法，再由 Core 检查和启用。可选功能还可以通过 Julia package extensions 按需加载。

Core 会检查缺失方法、方法签名和分派歧义；启用失败会保留失败状态，停用时先停止新调用，再等待已有调用结束。这些机制方便接入内部模型、代码索引和专用工具，也方便定位扩展之间的冲突。

独立扩展属于可信代码，在 Core 进程内运行。自定义分析器则走上面的隔离执行流程。接口和生命周期见 [Julia 扩展](docs/core/julia_extension_lifecycle.md)。

### 后台工作与交互共用一个运行时

模型输出、工具调用、索引和后台任务通过 Julia 的 `Task`、`Channel` 与受限工作池协调。`ScopedValue` 传递当前执行环境，权限、预算和取消由 Core 统一管理。后台任务可以记录依赖、领取状态和执行结果，交互端可以查询进度或取消工作。实现与限制见[任务调度](docs/core/tasks.md)。

### 直接查看 Core 的编译和运行情况

开发本地分析功能时，可以查看受支持 Core 函数的编译器 IR、类型推断、内存分配和采样调用栈，找到计算耗时或分配较多的位置。Julia 的反射和编译器接口使这类检查可以直接放进工具中。

这部分检查面向 Julia Core 自身。用户的 Python、Go、C++ 等项目使用各自的解析器、语言服务、测试和检查命令。相关文档见[运行时检查](docs/core/julia_diagnostics.md)、[编译器 IR](docs/core/compiler_ir.md)和[性能采样](docs/core/runtime_profiling.md)。

## 已有功能

上述设计之外，ShenScope 也提供日常编程所需的工作流：

- **模型连接：** 五种模型协议、流式输出、原生推理信息、模型发现、预算、路由和失败处理。
- **调查与规划：** 文件搜索、源码读取、Plan/Act、可更新任务计划、上下文裁剪与摘要。
- **修改与验证：** 多文件修改方案、差异预览、应用前检查源码是否变化、冲突处理与失败回滚；支持把语言服务器的重命名、格式化和代码动作转为待审阅方案。
- **测试与诊断：** 执行项目自己的测试、编译和检查命令，运行与取消测试，保存结果，导入 SARIF 报告，并将诊断关联到源码版本。
- **连续工作：** 会话保存与分支、版本化记忆、带依赖关系的持久任务和执行结果记录。
- **外部工具：** MCP stdio / Streamable HTTP、项目与用户 Skills、生命周期 Hooks。
- **权限管理：** 读取、修改、进程、网络、MCP、动态代码和持久化分别设置允许、询问或拒绝。

项目仍在开发中。真实模型的任务表现、大型代码库性能和跨平台发行还需要进一步验证；部分 Core 功能目前通过工具或 RPC 使用，尚无单独的图形页面。

## 开源参考

ShenScope 研究不同 Agent 的设计与使用体验，再用 Julia 独立实现自己的 Core。主要参考项目如下：

| 项目 | 主要参考内容 |
|---|---|
| [Codex](https://github.com/openai/codex) | 工具执行与审批、取消、请求边界、app-server 和终端交互 |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) | 插件化设计、事件与持久状态、调度、独占执行和任务生命周期 |
| [OpenCode](https://github.com/anomalyco/opencode) | 模型适配、会话与上下文压缩、MCP/LSP、客户端与服务端分工 |
| [Pi](https://github.com/badlogic/pi-mono) | 原始消息与模型上下文分离、任务引导、会话分支、Skills 和扩展接口 |
| [Kimi Code](https://github.com/MoonshotAI/kimi-code) | 推理信息处理、请求保护、信任与取消、插件和终端交互 |
| [ZCode](https://github.com/zai-org/ZCode) | 对话回合、任务引导与队列、上下文压缩、CLI 和桌面工作流 |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | 多模型服务、Plan/Act、MCP/Hooks/Skills/LSP，以及 CLI/IDE/SDK 的接口组织 |

针对具体模块，还参考了以下项目：

- **代码理解：** [Aider](https://github.com/Aider-AI/aider) 的仓库地图与修改反馈、[Serena](https://github.com/oraios/serena) 的语义导航、[CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext) 的代码图。CodeGraphContext 也是当前实际使用的数据后端。
- **执行与长期任务：** [Cline](https://github.com/cline/cline)、[OpenHands](https://github.com/All-Hands-AI/OpenHands)、[Software Agent SDK](https://github.com/OpenHands/software-agent-sdk)、[Hermes Agent](https://github.com/NousResearch/hermes-agent)、[Goose](https://github.com/block/goose)。
- **常驻计算与 Julia 工具：** [Aries CLI](https://github.com/aayoawoyemi/Aries-cli)、[AgentREPL.jl](https://github.com/samtalki/AgentREPL.jl)、[JuliaMCP.jl](https://github.com/julia-vscode/JuliaMCP.jl)、[Kaimon.jl](https://github.com/kahliburke/Kaimon.jl)、[PromptingTools.jl](https://github.com/svilupp/PromptingTools.jl)。
- **编辑器与发行：** [Code-OSS](https://github.com/microsoft/vscode)、[VSCodium](https://github.com/VSCodium/vscodium)、[PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl)。独立 IDE 基于 Code-OSS；其代码与许可证单独保留。

这些项目各有侧重。参考列表说明设计来源，具体研究和实现范围见[能力对照](docs/architecture/capability_matrix.md)、[源码研究记录](docs/architecture/reference_synthesis.md)和[参考版本](docs/architecture/reference_lockfile.json)。

## 文档

| 想了解什么 | 从这里开始 |
|---|---|
| 模型连接、选择与失败处理 | [模型服务](docs/core/models.md) · [模型路由](docs/core/model_routing.md) · [重试策略](docs/core/model_policy.md) |
| 项目索引与分析 | [项目数据](docs/core/project_data.md) · [联合查询](docs/core/combined_evidence.md) · [修改与迁移分析](docs/core/migration.md) |
| 修改代码、运行测试、检查错误 | [修改方案](docs/core/workspace_edits.md) · [项目测试](docs/core/project_testing.md) · [检查诊断](docs/core/project_validation.md) |
| 自定义分析与扩展 | [隔离分析器](docs/core/isolated_analyzers.md) · [Julia 扩展](docs/core/julia_extension_lifecycle.md) |
| 接入外部能力 | [MCP](docs/core/mcp.md) · [Skills](docs/core/skills.md) · [Hooks](docs/core/hooks.md) |
| 连续任务与记忆 | [上下文](docs/core/context.md) · [记忆](docs/core/memory.md) · [任务](docs/core/tasks.md) |
| 编辑器与构建 | [VS Code 扩展](editors/vscode/README.md) · [独立 IDE](ide/README.md) |

## 参与开发

Core 源码在 `src/`，CLI/TUI 在 `src/CLI/`，可选 Julia 扩展在 `ext/`；`editors/` 包含共享面板和 VS Code 扩展，`ide/` 包含独立编辑器集成。

```bash
julia --startup-file=no --threads=4 --project=. test/runtests.jl
npm --prefix editors run check
npm --prefix editors test
```

后端、语言服务器和 GUI 检查需要对应依赖，按模块文档准备。已有检查记录保存在 [docs/validation](docs/validation/)。问题与建议可以提交到 [GitHub Issues](https://github.com/SurviveAIEra/ShenScope/issues)。

## 作者与许可

ShenScope 由 **SurviveAIEra** 发起。常驻项目数据、可替换后端、可编程分析及 Julia 扩展机制的具体设计与实现，记录在本仓库的文档和提交历史中。

原创源码采用 [ShenScope Contribution-Only License 1.0](LICENSE)，项目署名见 [NOTICE](NOTICE)。它允许为本项目贡献所需的复制、修改、构建和测试，不授权无关的个人或业务使用、商用、独立发行及衍生产品。法律、平台及既有合法授权的权利仍然保留。

贡献方式与明确的贡献授权见 [CONTRIBUTING.md](CONTRIBUTING.md)。第三方组件保留各自许可证，见[第三方说明](THIRD_PARTY_NOTICES.md)。许可范围和未来公开仓库的安排，见[作者与许可说明](docs/project_authorship.md)。
