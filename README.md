# Claude Webnovel Auto Reset

一个运行在 macOS Terminal.app 里的自动化工具，用于配合 `Claude Code` 和 `webnovel-writer` 按章节连续写作。

它的核心能力：

- 监听当前小说目录下 `.webnovel` 的工作流状态
- 在章节真正完成后等待 60 秒
- 在同一个 Terminal 窗口里重启 Claude Code，清空上下文
- 新会话里自动执行 `/webnovel-write`
- 支持按成功章节数限制循环次数
- 支持多个小说目录分别运行，各自监听自己的项目状态

主要文件：

- `webnovel_auto_reset.zsh`：主入口脚本
- `webnovel_completion_watcher.py`：章节完成检测器
- `claude_reset_loop.zsh`：早期 15 秒重启原型
- `使用说明.md`：中文详细使用说明

快速开始：

```zsh
cd /你的小说项目根目录
zsh /Users/cipher/AI/连续写作方案测试/webnovel_auto_reset.zsh
```

限制成功章节循环次数：

```zsh
cd /你的小说项目根目录
zsh /Users/cipher/AI/连续写作方案测试/webnovel_auto_reset.zsh 3
```

前提条件：

- macOS
- Terminal.app
- 已安装 `claude`
- 小说项目目录里存在 `.webnovel/state.json`
- 已为 Terminal 和 System Events 打开辅助功能权限

更详细的中文说明见：

- [使用说明.md](./使用说明.md)
