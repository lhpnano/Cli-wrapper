# 代理切换方案交接文档

## 问题

用户有两个代理工具，需要无缝切换，切换后 codex、claude、agy 三个工具都能正常工作：

| 工具 | 端口 | 机制 |
|------|------|------|
| **v2rayN** | `127.0.0.1:10808` | 本地 HTTP 代理，需要 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量 |
| **Surfshark** | 无本地端口 | 系统级 VPN 隧道（WireGuard/OpenVPN），所有流量走隧道，不需要也不能设 `HTTP_PROXY` |

**核心矛盾：** HKCU 环境变量写死 `http://127.0.0.1:10808`。v2rayN 开着时一切正常；切到 Surfshark 时 10808 没人监听，`HTTP_PROXY` 指向死端口，所有依赖该变量的工具全挂。

## 三个消费者的代理需求

| 消费者 | 怎么用代理 | v2rayN 时 | Surfshark 时 |
|--------|-----------|-----------|-------------|
| **agy CLI** | Go 的 `ProxyFromEnvironment`，读 `HTTP_PROXY`/`HTTPS_PROXY` | 需要 env vars 指向 10808 | env vars 必须清空，走隧道直连 |
| **Claude Code** | Node.js `proxy-agent` + `GLOBAL_AGENT`，读同样 env vars | 需要（在中国大陆） | env vars 必须清空，走隧道直连 |
| **Codex** | 同理读 env vars | 需要 | env vars 必须清空，走隧道直连 |

**用户原话（关键纠正）：** "错！codex、claude、agy都需要代理" — 三个都需要，不能只管 agy。

## 已完成的工作

### 1. agy-run.ps1 进程级代理探测（已上线）
`C:\Users\haipe\AppData\Local\agy-shim\agy-run.ps1` 第 333-351 行：TCP 探测 10808 端口，通则注入 `HTTP_PROXY`，不通则清空（让 agy 直连走 Surfshark 隧道）。**仅覆盖 agy，不覆盖 claude/codex。**

### 2. AM API 自动换号（已上线）
`agy-run.ps1` 的 `Invoke-AmAccountSwitch` 函数：auth 失败时调 Antigravity-Manager HTTP API (`localhost:8045`) 切到另一个 Google Pro 账号，拿新 token 重试。

### 3. Claude Code settings.json 代理已移除（已完成）
`~/.claude/settings.json` 的 `env` 段不再包含 `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`。避免写死端口导致换 VPN 时 Claude 登不上。

### 4. proxy-watchdog.ps1（已写好，未注册计划任务）
`C:\Users\haipe\AppData\Local\agy-shim\proxy-watchdog.ps1`：
- TCP 探测 `127.0.0.1:10808`
- 端口活着 → 设 HKCU `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`
- 端口死了 → 清空这三个 HKCU 变量
- **局限：** HKCU 变更不会传播到已运行的进程，只影响新启动的进程

## 未完成

### 注册 Windows 计划任务
需要把 `proxy-watchdog.ps1` 注册为计划任务，每 60 秒运行一次：
```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -File "C:\Users\haipe\AppData\Local\agy-shim\proxy-watchdog.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Seconds 60)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 30)
Register-ScheduledTask -TaskName 'proxy-watchdog' -Action $action -Trigger $trigger -Settings $settings -Description 'Auto-toggle HTTP_PROXY based on v2rayN port 10808 availability'
```

### NO_PROXY 列表恢复
当前 watchdog 只设简单的 `127.0.0.1,localhost`。用户原来的 HKCU NO_PROXY 还包含学术 API 域名：
```
127.0.0.1,localhost,api.semanticscholar.org,api.clarivate.com,api.openalex.org,api.crossref.org,eutils.ncbi.nlm.nih.gov,export.arxiv.org,api.unpaywall.org,api.eia.gov,api.iea.org,api.imf.org,www.imf.org,api.materialsproject.org,next-gen.materialsproject.org
```
watchdog 的 `$noProxy` 变量需要更新为完整列表。

### 已运行进程的处理
HKCU 变更不影响已启动的 Claude Code / Codex。可能的对策：
1. 接受现实：切 VPN 后重启 Claude Code / Codex（最简单）
2. 用 `WM_SETTINGCHANGE` 广播通知（对 Node.js/Go 进程无效）
3. Claude Code settings.json 也加探测逻辑（过度工程）

建议选方案 1：用户切 VPN 本来就是主动行为，重启一下可以接受。

## 用户被拒绝过的方案

- **删除 HKCU 环境变量** — 用户明确拒绝："错！codex、claude、agy都需要代理"
- **只管 agy 不管 claude/codex** — 用户纠正：三个都要管

## 关键文件清单

| 文件 | 作用 |
|------|------|
| `C:\Users\haipe\AppData\Local\agy-shim\agy-run.ps1` | agy 自愈 wrapper（代理探测+AM换号+重试） |
| `C:\Users\haipe\AppData\Local\agy-shim\agy-batch.ps1` | 批量运行器 |
| `C:\Users\haipe\AppData\Local\agy-shim\proxy-watchdog.ps1` | 代理看门狗（已写好未注册任务） |
| `C:\Users\haipe\.claude\settings.json` | Claude Code 设置（已移除代理 env） |
| `C:\Users\haipe\.antigravity_tools\gui_config.json` | AM 配置（端口/API key） |
| `C:\Users\haipe\.claude\skills\agy-long-task\SKILL.md` | 长任务 skill |
