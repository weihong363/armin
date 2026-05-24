# tmux / Agent SSH Q&A

## Q: 手机 SSH 可以运行 tmux，但 Armin connection test 报 `command not found: tmux`？

A: Armin 通过非交互 SSH shell 执行命令，远端 PATH 可能只有：

```text
/usr/bin:/bin:/usr/sbin:/sbin
```

手机 SSH app 通常会进入 login/interactive shell，加载更多 shell 配置，所以两边表现不同。

对 Apple Silicon Mac，Host 配置建议：

```text
Host type: macOS Apple Silicon
tmux command path: /opt/homebrew/bin/tmux
PATH prepend: /opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.npm-packages/bin
```

## Q: tmux 可以用了，但手机连接远程主机后看到 `no server running on /private/tmp/tmux-501/default`？

A: 这通常不是 tmux 找不到，而是 tmux session 创建后里面的命令立即退出，tmux server 没有任何活着的 session。

当前最常见原因是 Agent CLI 在非交互环境里找不到。可以在远端验证 Codex：

```sh
ssh ironion@100.105.215.24 'export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.npm-packages/bin:$PATH"; command -v tmux; tmux -V; command -v codex; codex --version'
```

或验证 Qoder：

```sh
ssh ironion@100.105.215.24 'export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.npm-packages/bin:$PATH"; command -v tmux; tmux -V; command -v qodercli; qodercli --version'
```

如果返回：

```text
/opt/homebrew/bin/tmux
tmux 3.5a
zsh:1: command not found: codex
```

说明 tmux 已正常，失败点是 Agent CLI。

## Q: 怎么修复 `codex: command not found` 或 `qodercli: command not found`？

A: 找到远端 Agent CLI 的真实路径：

```sh
ssh ironion@100.105.215.24 'zsh -lic "command -v codex; echo PATH=$PATH"'
```

然后二选一：

```text
Agent command: $HOME/.npm-global/bin/codex
```

如果 Agent CLI 是通过 npm 全局安装的，常见位置可以通过下面的命令确认：

```sh
ssh ironion@100.105.215.24 'export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; npm prefix -g'
```

返回的 prefix 后面加 `/bin`，通常就是 Agent CLI 所在目录。然后把所在目录加入：

```text
PATH prepend: /opt/homebrew/bin:/usr/local/bin:/path/to/npm-prefix/bin
```

Armin 会在远端 shell 中展开 `$HOME`。如果你已经知道绝对路径，也可以直接填写绝对路径作为 `Agent command`。

## Q: Codex 和 Qoder 的项目路径参数有什么区别？

A: Armin 会按 Agent command 选择项目路径参数：

```text
Codex: codex -C projectPath
Qoder: qodercli -w projectPath
```

如果 `Agent command` 是绝对路径，Armin 仍会根据命令名识别，例如 `$HOME/.npm-global/bin/codex` 使用 `-C`，`$HOME/.qoder/bin/qodercli` 使用 `-w`。

## Q: Host type 做了什么？

A: Host type 只写入默认配置，不会动态探测远端系统。

```text
Generic / custom      -> tmux
macOS Apple Silicon   -> /opt/homebrew/bin/tmux, PATH /opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.npm-packages/bin
macOS Intel           -> /usr/local/bin/tmux, PATH /usr/local/bin
Linux                 -> /usr/bin/tmux, PATH /usr/bin
```

用户仍然可以手动覆盖 `tmux command path`、`PATH prepend` 和 `Agent command`。

## Q: connection test 现在检查什么？

A: 连接测试应同时验证：

```sh
tmux -V
command -v codex
codex --version
```

如果使用 Qoder，则验证：

```sh
tmux -V
command -v qodercli
qodercli --version
```

如果 tmux 通过但 Agent CLI 不可用，UI 会提示配置 `Agent command` 绝对路径，或把 Agent CLI 所在目录加入 `PATH prepend`。
