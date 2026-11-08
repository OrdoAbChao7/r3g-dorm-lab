# WifiProxyMode：路由器（WiFi）优先，Clash Verge 备用

## 目标

- 连 **R3G-OpenWrt-5G** 时，所有流量由 R3G 路由器上的透明代理分流，本机不再叠一层代理。
- 连其他网络（校园网、别处的 WiFi）时，自动改用本机 Clash Verge 的 `127.0.0.1:7897`。
- 两边都“开着”时不冲突：路由器代理存在时，本机 Clash 只作为进程待命，不接管任何流量。
- 切换网络不需要重启程序；已有的长连接不受影响，新连接走新路径。

## 工作方式

计划任务 `WifiProxyMode` 每分钟运行一次，`WifiProxyMode-Net` 在网络连接/断开事件触发时运行，
两者都调用 `proxy-mode.ps1`（登录后一分钟内也会被定时任务接管），它按顺序判断：

1. **路由器透明代理探测**：向系统 DNS 查询一个随机子域名（`probe-xxxx.example.com`）。
   如果返回 `198.18.0.0/15` 的 fake-IP，说明当前网络的路由器正在接管 DNS 和流量
   → 关闭 Windows 系统代理，删除本机代理环境变量。
2. **本机 Clash 探测**：`127.0.0.1:7897` 有进程监听
   → 打开系统代理 `127.0.0.1:7897`，并写入 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY`（用户级环境变量）。
3. **都没有** → 直连，不留任何代理配置。

## 行为对照

| 当前网络 | 系统代理 | 终端代理变量 | 出口 |
|---|---|---|---|
| R3G-OpenWrt-5G（路由器代理正常） | 关 | 不设置 | 路由器按规则分流 |
| 其他 WiFi，Clash 正在运行 | 开 | 设置 | Clash 按规则分流 |
| 其他 WiFi，Clash 没运行 | 关 | 不设置 | 直连 |
| R3G，但路由器代理失灵 | 关→开 | 设置 | Clash 兜底（1 分钟内生效） |

## 文件

| 文件 | 作用 |
|---|---|
| `proxy-mode.ps1` | 核心切换逻辑，计划任务调用它 |
| `install.ps1` | 备份现有配置、清理写死的代理、注册计划任务、立即执行一次 |
| `uninstall.ps1` | 删除计划任务并恢复安装前的代理设置 |
| `status.ps1` | 只读查看当前模式、系统代理、环境变量、探测结果、任务状态 |

运行状态保存在 `%LOCALAPPDATA%\WifiProxyMode\`：

- `mode.txt`：`router` / `clash` / `direct`
- `proxy-mode.log`：切换记录

## 常用命令

查看状态：

```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo-root>\windows\proxy_setup\status.ps1
```

临时强制使用本机 Clash（忽略路由器代理）：

```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo-root>\windows\proxy_setup\proxy-mode.ps1 -Mode clash
```

恢复自动判断：

```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo-root>\windows\proxy_setup\proxy-mode.ps1 -Mode auto
```

## 验证

在连 R3G 的情况下：

```
curl --noproxy '*' https://myip.ipip.net
```
应显示联通的真实出口（当前是 `203.0.113.20`，走国内直连）。

```
curl --noproxy '*' https://ipinfo.io/ip
```
应显示 `203.0.113.10`（Vultr 洛杉矶，走路由器代理）。

如果后者显示联通的 IP，说明路由器代理没生效，检查 R3G 上的代理服务。

## 注意事项

- **Clash Verge 界面里的“系统代理”开关请保持关闭**，由本脚本统一管理；**TUN 模式也保持关闭**，
  否则会和路由器透明代理双重接管。
  安装脚本会尝试把 `verge.yaml` 里的 `enable_system_proxy` 改为 `false`；
  如果你安装时 Clash Verge 正在运行，建议**重启一次 Verge**（或在其界面里手动把“系统代理”关一次），
  让它运行中的状态与配置文件一致。即使没重启，脚本也会每分钟把系统代理纠正回来，
  只是中间可能短暂出现双重代理（能上网，但多绕一跳）。
- 本方案依赖 `<repo-root>\windows\proxy_setup` 目录存在（计划任务直接调用其中的脚本）；
  如果移动或删除这个目录，需要重新运行 `install.ps1`。
- 计划任务的注册不需要管理员权限；回滚用 `uninstall.ps1`。
- 用户级环境变量只影响**新启动**的进程。切换网络后，已经开着的终端不会自动改变；
  需要新开终端（或在旧终端里手动 `unset HTTP_PROXY HTTPS_PROXY ALL_PROXY`）。
- 切换网络时，浏览器（Chrome/Edge，走 Windows 系统代理）会自动跟随；Firefox 若手动设过代理，
  需要在它的设置里选“使用系统代理”。
- 已有的 SSH、下载等长连接不会因为代理开关而中断。
- 当前网络没有 IPv6 出口，方案未处理 IPv6 代理；如果以后启用，需要单独验证 IPv6 是否绕过代理。
- 计划任务最多会在网络变化后 1 分钟内纠正（另有网络事件触发，通常几秒内）。

## 回滚

```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo-root>\windows\proxy_setup\uninstall.ps1
```

会删除计划任务，并把环境变量、git 代理、Verge 系统代理开关恢复为安装前的值
（备份在 `proxy_setup\backup\`）。
