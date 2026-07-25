# GitHub 备份工作流

本文记录当前一键备份要覆盖的仓库和文件夹。

## 仓库映射

| 内容 | 本地路径 | GitHub 仓库 |
| --- | --- | --- |
| Claude skills | `C:\Users\haipe\.claude\skills` | `https://github.com/lhpnano/claude-skills.git` |
| Codex skills | `C:\Users\haipe\.codex\skills` | `https://github.com/lhpnano/codex-skills.git` |
| CLI wrappers | `C:\Users\haipe\AppData\Local\Cli-wrapper` | `https://github.com/lhpnano/Cli-wrapper.git` |

CLI wrappers 仓库会同步两个实时目录：

```text
C:\Users\haipe\AppData\Local\agy-shim
C:\Users\haipe\AppData\Local\AI-Network-Panel\cli-auto
```

同步到仓库内：

```text
agy-shim\
cli-auto\
docs\
```

## 面板按钮

主面板 `GitHub Backup` 区域包含：

- `Backup all`：先同步 CLI wrapper，再检查三个仓库变更，弹窗确认后统一 commit/push。
- `Claude skills`：只推送 Claude skills。
- `Codex skills`：只推送 Codex skills。
- `CLI wrappers`：只同步并推送 CLI wrappers。

## 安全过滤

CLI wrapper 同步使用 robocopy，并排除：`.git`、`__pycache__`、`cache`、`logs`、`node_modules`、`plugins`、`ai-cli-runs`、`*.pyc`、`*.pyo`、`*.log`、`*.tmp`、`*.bak`、`auth.json`、`.env`、`.env.*`、`*.key`、`*.token`、`run_state*.json`。

## 回滚方式

在 GitHub Desktop 或命令行中查看 History，选择旧 commit 后可以：

- 创建分支：保留当前版本，另开一条旧版本分支用于对比。
- Revert commit：生成一个新的反向提交，撤销某次修改。
- Checkout 旧版本文件：只恢复某个文件或文件夹。

建议优先用 Revert，而不是硬重置历史。这样远端历史完整，回滚也可再次撤销。
