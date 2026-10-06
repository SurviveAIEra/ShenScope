# 安装 `shenscope` 命令 / Installing the command

`bin/shenscope` 是仓库中的启动脚本。终端输入 `shenscope` 时，会在 `PATH` 中列出的目录寻找这个名字；安装脚本把启动入口放到其中一个目录里，就可以省去 `bin/`。

The shell finds `shenscope` by searching the directories in `PATH`. The installer places a link to the checkout's launcher in one of those directories.

## 安装一次，从任意目录使用

先按 [README](../README.md#快速开始) 安装 Julia 和 Core 的依赖，然后在仓库根目录执行：

```bash
bash scripts/install_cli.sh
export PATH="$HOME/.local/bin:$PATH"
command -v shenscope
shenscope --version
```

把 `export PATH="$HOME/.local/bin:$PATH"` 加入自己的 `~/.bashrc`（Bash）或 `~/.zshrc`（Zsh），以后新开终端即可使用。安装脚本不修改这些文件，不需要管理员权限。上面的 `export` 只影响当前终端；Bash 登录终端还需要由 `~/.bash_profile` 或 `~/.profile` 加载相应设置。

安装后可以切换到自己的项目目录：

```bash
cd /path/to/project
shenscope doctor --root "$PWD" --config /path/to/shenscope.toml
shenscope tui --root "$PWD" --config /path/to/shenscope.toml
```

`--root` 选择要处理的项目，`--config` 选择配置文件；路径含空格时请加引号。两者与 ShenScope 自己的源码目录可以不同。未指定 `--root` 时使用当前目录，因此请从目标项目启动或显式传入它。

After preparing Julia and Core dependencies, run the installer from the checkout and put `~/.local/bin` on `PATH`. Add the export to your shell's configuration for future terminals; the installer does not edit shell configuration or require administrator access. Bash login shells must also load it through `~/.bash_profile` or `~/.profile`. You can then invoke the command from any directory. `--root` selects the target project and defaults to the working directory. `--config` selects its configuration; quote paths containing spaces.

## 自定义位置与更新

```bash
bash scripts/install_cli.sh --bin-dir "$HOME/bin"
export PATH="$HOME/bin:$PATH"
```

安装只创建一个符号链接，保留仓库里的启动脚本和 Core，不复制任何目录。同一个位置可以重复安装；如果已有其他 `shenscope` 文件或链接，脚本会报错并保留原文件。

更新时在 ShenScope 仓库运行 `git pull`，依赖变化后重新执行 README 中的 Julia 依赖安装命令。链接随即使用更新后的代码，无需重装。请保留这份源码仓库；如果搬动了它，先确认旧链接指向自己的旧仓库，再删除那个链接并重新安装。卸载命令时，也只删除安装位置的 `shenscope` 链接即可，仓库、配置和会话仍然保留。

Use `--bin-dir` to choose another directory and add it to `PATH`. Reinstalling the same link is safe; an existing unrelated command is preserved and reported as a conflict. Update this checkout with `git pull` and refresh Julia dependencies when needed. Keep the checkout: the command uses its current files. If you move it, remove the confirmed old link and reinstall. To uninstall the command, remove only its link; project files, configuration and sessions remain.

## Julia 与启动排查

启动脚本优先使用 `SHENSCOPE_JULIA` 指定的可执行文件，否则寻找 `PATH` 中的 `julia`。找不到时，当前托管云环境还可以使用已准备好的 `/workspace/toolchains/julia-1.11.7/bin/julia`。明确设置了无效的 `SHENSCOPE_JULIA` 会报错，不会悄悄换成另一个版本。

```bash
export SHENSCOPE_JULIA="/path/to/julia/bin/julia"
shenscope --version
```

普通安装使用 Julia 默认的依赖目录；设置 `JULIA_DEPOT_PATH` 可以选择自己的目录。使用上面的云环境工具链且未设置该变量时，启动脚本复用已有的 `/workspace/julia-depot`。如果安装依赖时指定了其他目录，运行时也要使用相同设置。

| 遇到的问题 | 怎么检查 |
|---|---|
| `shenscope: command not found` | 用 `command -v shenscope` 检查，确认安装目录已加入当前终端的 `PATH` |
| 启动了另一个同名程序 | 用 `type -a shenscope` 查看顺序，把本次安装目录放到 `PATH` 前面；Bash 可运行 `hash -r` 清除旧缓存 |
| 提示找不到 Julia | 安装 Julia 1.11 或更新的兼容版本，将它加入 `PATH`，或设置 `SHENSCOPE_JULIA` |
| Julia 提示缺少包 | 回到 ShenScope 仓库执行 `julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'`，检查依赖目录设置是否一致 |

The launcher uses an explicit `SHENSCOPE_JULIA` first, then `julia` on `PATH`, then the prepared managed-cloud toolchain if available. Invalid explicit choices fail with a clear message. Ordinary installations use Julia's default depot; the managed toolchain reuses its cloud depot when no override is set. If dependency installation uses `JULIA_DEPOT_PATH`, keep the same setting at runtime. For command lookup problems, check `command -v shenscope`, `type -a shenscope` and your `PATH`; Bash can clear its command cache with `hash -r`.

这些脚本面向 Linux/macOS 的 Bash。Windows 的原生命令安装流程尚未提供。

These Bash scripts target Linux/macOS. Native Windows command installation is not available yet.
