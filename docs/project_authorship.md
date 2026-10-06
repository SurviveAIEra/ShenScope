# 作者、设计来源与许可

ShenScope 由 **SurviveAIEra** 发起，项目地址是
[github.com/SurviveAIEra/ShenScope](https://github.com/SurviveAIEra/ShenScope)。
原创部分采用 [ShenScope Contribution-Only License 1.0](../LICENSE)，
项目署名见 [NOTICE](../NOTICE)。这是一份受限许可，不是标准开源许可证。

## 允许为本项目做什么

默认许可仅用于准备、审阅、测试和向 ShenScope 提交贡献。可以为此复制源码、
建立分支、修改、构建和运行相关测试，再向指定仓库提交 PR。

它不授权把 ShenScope 用于无关的个人或业务项目，不授权独立商业部署、
改名发行、安装包发布、源码镜像或其他衍生产品。这些使用需要另行书面授权。
不收费或保留作者姓名，都不会自动产生额外权限。

法律、托管平台和既有合法授权的权利仍然保留。将来公开 GitHub 仓库时，
不能取消平台条款允许的查看和服务内 fork，也不能要求所有查看或 fork
行为都必须先提交 PR。平台允许的复制，与本许可额外授予的本地开发权限不同。

## 作者与贡献者

源码副本和贡献分支须保留适用的许可证、版权和 NOTICE，不得冒称原作者。
贡献者保留自己原创贡献的版权；维护方接收贡献需要明确的授权。

LICENSE 第 5 条要求明确同意贡献授权，授予维护方整合、修改、发行和再许可
贡献的权利，包括不同许可和商业发行。仅打开 PR 或 Issue 不表示转让版权。
提交方式和授权声明见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 具体设计与抽象想法

版权通常保护代码、文档等具体表达，不保护抽象想法、算法或开发语言的选择。
本许可不能禁止别人不使用受限代码而独立编写一个 Julia Agent。

ShenScope 记录自己的具体设计：常驻项目数据、可替换的数据后端、本地 Julia
分析、隔离分析器的验证与版本管理，以及独立扩展的接口与生命周期。
[架构记录](architecture/product_readme_basis.md)和提交历史帮助说明这些内容的来源。
目前不使用未经充分调查的“全球首个 Julia Agent”声明。

研究其他项目的设计不等于使用其源码。Agent Core 独立实现；实际依赖、
Code-OSS 和其他第三方材料继续使用各自许可。资料见
[参考版本](architecture/reference_lockfile.json)、
[源码研究](architecture/reference_synthesis.md)和[第三方说明](../THIRD_PARTY_NOTICES.md)。

## 现在私有，将来公开

仓库目前仍为私有，未对外发布，计划以后公开源码。
推送到私有 GitHub 仓库不等于公开发行；是否存在已授出的权利还取决于实际接收者和授权。
新许可不追溯撤回任何已经合法授出的权利。

私有开发历史中仍有 Apache-2.0 版本。**不能只改最新 LICENSE，就把带有旧许可
的完整历史一起公开，然后声称所有旧源码都禁止商用。**
公开前要处理历史和发行范围；当前许可切换没有执行公开操作。

许可选择、历史检查与公开步骤见[公开源码前的许可安排](licensing/license_decision.md)。
正式对外发行前，建议由熟悉软件许可的法律专业人士审阅自定义条款和贡献授权。

参考：[GitHub 服务条款](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)、
[WIPO 版权常见问题](https://www.wipo.int/en/web/copyright/faq-copyright)、
[OSI 开源定义](https://opensource.org/osd)。
