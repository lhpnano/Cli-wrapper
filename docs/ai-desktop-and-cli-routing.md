# AI Desktop 与 CLI 自动路由说明

本文记录当前机器上 Claude、Codex、Antigravity、CodeBuddy 与 agy 的启动入口、CLI 包装器和网络适配逻辑。用途是以后更新客户端、代理软件或 CLI 后，快速判断问题在入口、凭据、代理还是节点本身。

## 已确认的事实

- 主面板源码：`D:\8. AI\AI-CLI-Backup\panel\AI-Control-Dashboard.cs`
- 主面板程序：`C:\Users\haipe\Desktop\AI\AI-Control-Dashboard.exe`
- 旧网络面板程序：`C:\Users\haipe\Desktop\AI\AI-Network-Panel.exe`
- CLI 自动入口目录：`C:\Users\haipe\AppData\Local\AI-Network-Panel\cli-auto`
- agy 兼容封装目录：`C:\Users\haipe\AppData\Local\agy-shim`
- CLI wrapper 备份仓库：`C:\Users\haipe\AppData\Local\Cli-wrapper`
- 默认代理端口：Clash `127.0.0.1:10809`，v2rayN `127.0.0.1:10808`

## 核心原则

桌面客户端和 CLI 的网络路径不完全相同，因此不能只看“浏览器能不能打开网页”。

- Node 类 CLI 通常优先看进程环境变量：`HTTP_PROXY`、`HTTPS_PROXY`、`NO_PROXY`。
- Rust/部分 Electron 客户端可能读取 Windows WinINET 系统代理。
- Surfshark 是系统路由/VPN 层，不是本地 HTTP 代理端口。
- Clash/v2rayN 是本地 HTTP/SOCKS 代理端口，CLI 需要拿到对应环境变量才会稳定走它。
- Codex Desktop 是 Store 包，启动参数可能被系统壳层吞掉，因此面板会在启动前同步 WinINET。

## Auto 路由的实际含义

`Auto` 不是切换 VPN 软件本身，而是“检测当前可用出口，然后给子进程注入最合适的代理环境”。

流程：

1. CLI wrapper 启动，例如 `cli-auto\claude.cmd`。
2. wrapper 调用 `agy-shim\cli-network-sync.ps1 -Network Auto`。
3. `cli-network-sync.ps1` 再调用 `agy-mode.ps1` 进行检测。
4. 检测 Clash `10809`、v2rayN `10808`、Surfshark 路由或直连状态。
5. 返回 `http://127.0.0.1:10809`、`http://127.0.0.1:10808` 或 `DIRECT`。
6. wrapper 根据结果设置或清空 `HTTP_PROXY` / `HTTPS_PROXY`，再调用真正的 CLI。

如果返回 `DIRECT`，含义是“不注入 HTTP 代理变量”，实际流量会走 Windows 当前网络栈，可能是本地直连，也可能是 Surfshark 的 VPN 路由。

## 桌面客户端入口

### Claude Desktop

稳定入口：`C:\Users\haipe\AppData\Local\AnthropicClaude\claude.exe`

面板每次启动前会重新解析路径。如果稳定入口不存在，会扫描 `C:\Users\haipe\AppData\Local\AnthropicClaude\app-*\claude.exe`。

启动时会先停止旧进程，再用 Auto 路由注入 `--proxy-server` 或 `--no-proxy-server`。更新后如果版本目录变化，面板应能自动扫描新版本。

### Codex Desktop

Codex Desktop 是 Microsoft Store/AppX 包。面板通过 `Get-AppxPackage OpenAI.Codex` 定位当前包内的 `app\ChatGPT.exe`。

限制：Store 壳层可能丢弃 `--proxy-server` 参数。因此面板启动 Codex Desktop 前会同步 WinINET 到当前 Auto 路由。这是兼容限制，不是普通 CLI wrapper 能解决的问题。

### Antigravity IDE

优先入口：`C:\Users\haipe\AppData\Local\Programs\antigravity\Antigravity.exe`

如果不存在，面板会扫描 `C:\Users\haipe\AppData\Local\Programs\**\Antigravity.exe`。Antigravity IDE 可以接收进程级 `--proxy-server`，也会通过环境变量继承 Auto 路由。

## CLI 包装器

### Claude CLI

- 入口：`C:\Users\haipe\AppData\Local\AI-Network-Panel\cli-auto\claude.cmd`
- 真正调用：`C:\Users\haipe\AppData\Roaming\npm\claude.cmd`

### Codex CLI

- 入口：`C:\Users\haipe\AppData\Local\AI-Network-Panel\cli-auto\codex.cmd`
- 真正调用：`C:\Users\haipe\AppData\Roaming\npm\codex.cmd`

Codex 的 API/provider 凭据由 Codex++ 管理时，wrapper 不缓存凭据，只在每次调用时转发到当前 npm shim，因此切换 API 后通常不需要重写 wrapper。已打开的长驻客户端可能仍需重启，原因是它们缓存了旧进程环境。

### CodeBuddy CLI

- 入口：`C:\Users\haipe\AppData\Local\AI-Network-Panel\cli-auto\codebuddy.cmd`
- 真正调用路径运行时扫描：`C:\Users\haipe\.workbuddy\binaries\node\versions\*\codebuddy.cmd`

CodeBuddy 可能读取 Windows 系统代理。如果 WinINET 指向 `127.0.0.1:10808`，但 v2rayN 未运行，就会出现 `ECONNREFUSED 127.0.0.1:10808`。

### agy CLI

- 入口：`C:\Users\haipe\AppData\Local\agy-shim\agy.cmd`
- 优先调用：`C:\Users\haipe\AppData\Local\agy\bin\agy.exe`

如果不存在，会扫描 `%LOCALAPPDATA%\agy` 和 `%LOCALAPPDATA%\Programs` 下最新的 `agy.exe`。这样更新 agy 后不需要手动改路径。

## 快速排查命令

```powershell
& "$env:LOCALAPPDATA\agy-shim\agy-mode.ps1" -Network Auto

$p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
"ProxyEnable=$($p.ProxyEnable) ProxyServer=$($p.ProxyServer)"

Get-Item "$env:LOCALAPPDATA\AI-Network-Panel\cli-auto\claude.cmd"
Get-Item "$env:LOCALAPPDATA\AI-Network-Panel\cli-auto\codex.cmd"
Get-Item "$env:LOCALAPPDATA\AI-Network-Panel\cli-auto\codebuddy.cmd"
Get-Item "$env:LOCALAPPDATA\agy-shim\agy.cmd"
```

## 常见故障判断

- 路由显示可达，但 CLI 失败：说明端口连通不等于真实模型请求可用，需要运行面板的 `Run live test`。
- `401` 或提示登录：优先检查 CLI 凭据或 OAuth token。
- `403 Request not allowed`：通常是服务端策略、地区、账号权限或 Code/Cowork 功能限制，需要结合 Chat/CLI 是否可用判断。
- `ECONNREFUSED 127.0.0.1:10808`：WinINET 或进程环境指向 v2rayN，但 v2rayN 没运行。
- `stream disconnected`：可能是节点、代理、上游中转、系统代理或 CLI 客户端行为，需要用 curl/真实 CLI 测试区分。
