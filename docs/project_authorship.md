# 作者、设计来源与开源许可

ShenScope 由 **SurviveAIEra** 发起，项目地址是
[github.com/SurviveAIEra/ShenScope](https://github.com/SurviveAIEra/ShenScope)。
原创源码采用 [Apache-2.0](../LICENSE)，项目署名见 [NOTICE](../NOTICE)。

## 这份许可证允许什么

Apache-2.0 是宽松的开源许可证。别人可以使用、复制、修改和商用代码，
也可以发布衍生版本，包括符合许可条件的闭源产品。

分发时，许可证第 4 条要求附上许可证、标明修改，并保留适用的版权、
专利、商标和署名声明。因为本项目带有 `NOTICE`，衍生作品分发时还应按
第 4(d) 条保留其中适用的署名内容；可放在随附的 NOTICE、文档或通常展示
第三方声明的位置。它并不要求每个界面都显示作者姓名。

所以，按许可证保留声明并复用代码属于允许的行为。
删除必须保留的声明、冒称原作者，需要分别判断是否违反许可或其他法律。
许可证第 6 条也没有授予将 ShenScope 品牌用于产品背书的普遍商标许可。

## 代码的原创与想法的原创有什么区别

版权通常保护代码、文档等具体表达，不保护抽象想法、算法或开发语言的选择。
仅靠一份代码许可证，不能禁止别人独立编写一个 Julia Agent，或独立实现相似思路。

ShenScope 明确记录自己的具体设计：常驻项目数据、可替换的数据后端、
本地 Julia 分析、隔离分析器的验证与版本管理，以及独立扩展的接口与生命周期。
[架构记录](architecture/product_readme_basis.md)和公开提交历史可以帮助说明
这些内容在本项目中的来源与演进；它们不自动证明全球范围内的优先权。

“全球首个 Julia Agent”目前没有经过足够的先前项目调查，因而不作为产品声明。
已有 [AgentREPL.jl](https://github.com/samtalki/AgentREPL.jl)、
[Kaimon.jl](https://github.com/kahliburke/Kaimon.jl) 等 Julia 与 Agent 集成项目。
它们的定位与 ShenScope 不同，也不能仅凭这些例子判定某种更具体的架构是否首创。
确认某项设计是否首创，需要比较其具体内容与公开时间；目前的署名说明记录
本项目的作者和设计来源。

研究其他项目的设计，不等于使用其源码。ShenScope 的 Agent Core 独立实现；
实际依赖和 Code-OSS 编辑器基座保留上游许可。对应资料见
[参考版本](architecture/reference_lockfile.json)、
[源码研究](architecture/reference_synthesis.md)和
[第三方说明](../THIRD_PARTY_NOTICES.md)。

## 如果希望限制衍生项目

- **保留 Apache-2.0：** 允许广泛使用，包括商用和闭源衍生；通过版权声明、NOTICE 和公开记录保留适用的项目署名。
- **GPL / AGPL：** 在各自适用条件下要求提供对应源码；AGPL 对修改版的网络交互还有相应要求。它们仍允许商用，也不会让作者独占某个想法。
- **限制商用、复制或竞争的自定义许可：** 可以考虑只公开源码、限定使用范围，但这类限制通常不符合标准开源定义，也不能简单加在 Apache-2.0 后面却继续宣称是原来的许可。

本项目当前仍使用 Apache-2.0。未来版本是否改变许可，需要单独决定，
核对相关版权与第三方义务；已经合法授出的 Apache-2.0 权利不能通过后续改许可追溯撤回。

参考原文：[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)、
[WIPO 版权常见问题](https://www.wipo.int/en/web/copyright/faq-copyright)、
[OSI 开源定义](https://opensource.org/osd)。
