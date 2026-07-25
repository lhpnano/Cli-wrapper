# claude-mem 设置与排查

本文记录当前 Claude Desktop 的 `claude-mem` 插件如何接入认证、网络和健康检查。文档不保存任何 token、refresh token 或密钥值。

## 已确认的事实

- 插件缓存目录：`C:\Users\haipe\.claude\plugins\cache\thedotmack\claude-mem\13.12.4`
- worker 脚本：`C:\Users\haipe\.claude\plugins\cache\thedotmack\claude-mem\13.12.4\scripts\worker-service.cjs`
- 日志目录：`C:\Users\haipe\.claude-mem\logs`
- 设置文件：`C:\Users\haipe\.claude-mem\settings.json`
- 常用 health 端口：`37782`
- 常用 health 接口：`http://127.0.0.1:37782/health`

## 当前修复点

早期故障是 `claude-mem` worker 只尝试从 Windows Credential Manager 读取 Claude Code OAuth 凭据，但当前 Claude Desktop/Claude Code 的有效凭据可能在本地 token cache 或 `.credentials.json` 一类文件存储中。

当前修复方向是让 worker 在启动子进程前注入有效的 Claude Desktop token cache fallback。成功日志应包含类似信息：

```text
[OAUTH] Using Claude Desktop Windows token cache fallback
[OAUTH] Injected fresh CLAUDE_CODE_OAUTH_TOKEN at spawn-time
```

真正写入记忆时，日志应出现：

```text
[DB] STORING
[DB] STORED
```

## 网络关系

`claude-mem` 不是浏览器网页，它是 Claude Desktop/Claude Code 插件拉起的 worker 子进程。它需要和 Claude 子进程一样拿到可用网络环境。

- 如果使用 Clash/v2rayN，子进程需要可用的 `HTTP_PROXY` / `HTTPS_PROXY` 或等效注入。
- 如果使用 Surfshark，子进程通常不需要本地代理端口，但要确认系统路由真的由 Surfshark 接管。
- 如果认证页面显示 `App unavailable` 或地区不可用，优先判断该认证流程是否没有走代理。

## 验证步骤

```powershell
Get-ChildItem "$env:USERPROFILE\.claude-mem\logs" -Filter 'claude-mem-*.log' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

Select-String "$env:USERPROFILE\.claude-mem\logs\claude-mem-*.log" `
  -Pattern 'OAUTH|CLAUDE_CODE_OAUTH_TOKEN|STORED|401|expired|token cache fallback' |
  Select-Object -Last 40

curl.exe --max-time 5 http://127.0.0.1:37782/health
```

## 常见故障

### 持续 401

日志：`API Error: 401 OAuth access token has expired`

判断：worker 没拿到有效 token，或拿到的是旧 token。先确认 Claude Desktop 是否已重新登录，再确认 worker 日志是否出现 token cache fallback。

### worker 活着但数据库为空

可能原因：hook 能收到事件，但解析阶段认证失败；或者模型判断当前操作没有值得记录的 observation。区分方法是看日志是否出现 `[DB] STORED`。

### health 端口不可访问

可能原因：worker 未启动、端口/PID 残留错位、端口改动。先查看 `.claude-mem\settings.json` 中的端口，再重启 Claude Desktop。

### 更新后失效

Claude Desktop 或 claude-mem 插件更新后，插件缓存目录版本号可能变化。需要检查新版本的 `worker-service.cjs` 是否仍包含 token fallback 修复。若丢失，应从备份仓库或旧版本补回同等逻辑。

## 不应写入 GitHub 的内容

- OAuth access token
- refresh token
- `.credentials.json` 内容
- Windows Credential Manager 导出的明文凭据
- 任何 `.env`、`*.token`、`auth.json`
