> 这是两篇中的下篇。上篇写 R3G 怎么从半套固件和 1 秒复位里被 UART 救回来：[只刷了 kernel1](./uart-recovery.md)。

## 能开机，不等于能生活

11-07 深夜，R3G 重新跑起 OpenWrt 25.12.6。LAN、Wi-Fi、WAN、LuCI、重启都通过了。但“能上网”只是起点。一个宿舍网络要长期活着，还得回答三个问题：

- 广告和跟踪器怎么在 DNS 层拦掉；
- DNS 挂了怎么办；
- 人不在寝室，怎么把电脑开起来。

这一篇写的是把 R3G、ESP32-S3 和 mihomo 串成一条链之后，实际踩出来的坑。

## 目标链路

最终的系统大概是这样：

```text
校园网 WAN (DHCP)
      │
   R3G / OpenWrt 25.12.6
      ├─ Wi-Fi 2.4/5 + LAN ── 手机 / PC / ESP32
      ├─ dnsmasq :53 ── ESP32 192.168.1.53:53 ── mihomo 192.168.1.1:1053
      ├─ mihomo TUN + fake-IP ── 代理 / 国内直连
      └─ Tailscale ── 外网访问
```

关键点：客户端只认识 `192.168.1.1` 这个 DNS；R3G 把查询转给 ESP32；ESP32 做黑名单过滤；放行的查询再交给 mihomo 的 1053 端口。任何一段指错，都会变成“能上网但过滤失效”或者“DNS 环路”。

## 先把出口打通：mihomo

代理层用的是 mihomo v1.19.33（linux-mipsle-softfloat）。安装过程本身不复杂：`apk add kmod-tun`，放二进制和配置，启用 `S99mihomo`，TUN `utun` 起来，`198.18.0.1/30`，`auto-route` 和 `auto-redirect` 生效。分流规则是 `GEOIP,CN,DIRECT` 加 `MATCH,PROXY`。

但 MT7621 的性能边界很快就露出来了。实测（PC 强制绕过本机 Clash，确保走 R3G）：

| 项目 | 结果 |
|---|---|
| 代理下载（VLESS，GitHub 20 MB） | 20.4 / 9.5 / 8.4 Mbps |
| 代理上传 | 10.6 Mbps |
| 代理延迟 | TLS 815 ms，TTFB 1.045 s |
| 国内直连基线 | 122.3 Mbps |
| mihomo CPU | 约 1.25 个核 |
| mihomo RSS | 约 53 MiB |

结论很明确：**这台路由器适合浏览、手机和 IoT，不适合拿来做大流量下载。** 校园线路本身有 120 Mbps，瓶颈在 MT7621 的单连接处理能力。知道这一点之后，就不会再把“代理慢”误判成“VPS 慢”。

## ESP32 接管 DNS：211,465 条黑名单

DNS 过滤放在 ESP32-S3 N16R8 上：16 MB flash、8 MB OPI PSRAM，刷的是 Garionhk/ESP32-AdBlocker-N16R8 v1.0.3，静态地址 `192.168.1.53`。

设备启动日志：

```text
[blocklist] arena 4.7 MB, room for ~191,566 domains
[blocklist] restored 211,465 domains from flash in 2128 ms
[dns] serving on 192.168.1.53:53 (udp+v6, tcp+v6), 128-packet receive queue
[web] settings page at http://192.168.1.53
```

黑名单是 Hagezi Pro，211,465 条；重启后从 flash 快照恢复约 2.1 秒。R3G 侧的 dnsmasq 改成 `noresolv=1`，唯一上游 `192.168.1.53`；DHCP 仍然把 `192.168.1.1` 下发给客户端。

验证结果：

| 域名 | 返回 | 含义 |
|---|---|---|
| `pagead2.googlesyndication.com` | `0.0.0.0` / `::` | 黑名单拦截 |
| `www.baidu.com` | `198.18.0.83` | 放行，mihomo fake-IP |
| `example.com` | `198.18.1.4` | 放行，对照组 |
| `no-such-9f3a2b.invalid` | NXDOMAIN | 上游正常 |

直连 `.53` 和经 `192.168.1.1` 的结果一致。到这里，第一层“域名级去广告”就成立了。

## 坑一：谁在回答 DNS

这是整篇里最值得写的一个坑。

mihomo 开了 fake-IP：`198.18.0.1/16`，TUN `utun`，`dns-hijack: any:53`，并且用 nft 把本地源 `:53` DNAT 到 `198.18.0.2`。这意味着：**在 LAN 上向任何 DNS 服务器发查询，都可能被 mihomo 接管。**

于是出现了一个很容易误判的现象：从 LAN 查校园 DNS `192.0.2.x`，返回的也是 `198.18.x`。如果只看结果，会以为“校园 DNS 被污染了”。实际上查询在离开网卡前就被劫持了，校园 DNS 根本没回答。

更危险的是环路。ESP32 的上游如果指回 `192.168.1.1:53`，链路就变成：

```text
dnsmasq → ESP32 → dnsmasq → ...
```

最终把 ESP32 的上游显式固定为 `192.168.1.1:1053`（mihomo 的 DNS 监听），Secondary 清空，DoT 关闭（校园网封 853）。这样 ESP32 查的是 mihomo 的独立端口，不经过 dnsmasq，环路被切断。

后来还发现 Tailscale 的控制面也被 fake-IP 了，日志里卡在 `SYN_SENT`。在 mihomo 的 `fake-ip-filter` 里加上：

```text
+.tailscale.com
+.tailscale.io
+.ts.net
```

控制面才恢复正常。**DNS 排障的第一步不是看答案，而是问“这个答案是谁给的”。**

## 坑二：PSRAM 的 7 字节 stub

因为需要把 ESP32 的上游端口改成可配置，我基于 v1.0.3 打了一个小补丁，自己编译了一版候选固件。工具链是 PlatformIO 6.2.0 + pioarduino 55.03.312-1（Arduino core 3.3.12 / ESP-IDF 5.5.5 / GCC 14.2.0）。

第一版编译、链接、刷写全部成功：

```text
应用镜像 1,306,384 B
write-flash 0x10000
Hash of data verified
```

但设备起来之后，日志是：

```text
[log] PSRAM allocation failed -- query log off
[cache] PSRAM allocation failed -- caching off
[blocklist] no PSRAM -- build with PSRAM=opi for an N16R8
[dns] no memory for the pending table or receive pool
```

设备能 ping，Web 返回 401，但 DNS 53 端口没有响应。全屋 DNS 断了大约 6 分钟（04:18–04:25），直到修正版刷回去。

根因不是硬件，是构建配置：`esp32-hal-psram.c` 被编成了 stub，`ps_malloc`/`ps_calloc` 各只有 7 字节，直接返回 NULL；`psramInit()` 没有调用已经链接的 `esp_psram_init()`。map 里有 `qio_opi` 引用，但仅凭库变体不能保证核心文件的 PSRAM 分支被编译。

修复两步：

1. `platformio.ini` 增加 `-DBOARD_HAS_PSRAM`（等价于发布版的 `PSRAM=opi`）；
2. `pio run -t clean` 后干净重建，确保核心文件使用 `qio_opi` 的 `sdkconfig.h`。

修正版 1,306,464 B，运行日志：

```text
[log] 6000 entries, 585 KB PSRAM
[cache] 768 replies, 540 KB PSRAM
[blocklist] arena 4.7 MB, room for ~191,566 domains
[blocklist] restored 211,465 domains from flash in 2128 ms
[dns] serving on 192.168.1.53:53
```

还有一个工具链的坑：构建必须在原生 PowerShell 里做。Git Bash 会向子进程重新注入 `MSYSTEM=MINGW64`，pioarduino 的 `idf_tools.py` 会因此拒绝安装工具链。窗口一换，构建就“莫名其妙”失败。

**编译通过、链接通过、刷写通过，都不等于运行时能力成立。** 要看 allocator、arena、DNS 是否真的 serving。

## 坑三：43.1 秒与“以为的单点”

DNS 链串起来之后，下一个问题是：它到底有多脆？

先做了一次真实的断电演练：PC 每秒向 `192.168.1.1:53` 查 `example.com`，持续 10 分钟，共 532 个样本。03:55:57.196 第一次超时，03:56:40.326 恢复，**中断 43.1 秒**，15 个连续失败样本，全程 31/532 失败。中断期间每个查询都是 2 秒超时——dnsmasq 还在监听，只是唯一上游 ESP32 不可达。

然后做了 mihomo 停服演练。结果和直觉相反：

| 阶段 | DNS | HTTP |
|---|---|---|
| 停止前 | OK | OK |
| 停止后 +3 s | OK | OK |
| 停止后 +18 s | OK | OK |
| 启动后 +5 s | OK | FAIL |
| 启动后 +10 s | OK | OK |

mihomo 停服并不会中断局域网 DNS 和上网：服务退出后 nft DNAT 和 utun 失效，ESP32 的查询转去直连校园 DNS，返回真实 IP；流量回到普通路由。重启瞬间有 5–10 秒 HTTP 抖动，DNS 不受影响。

这纠正了之前的一个判断：**真正的单点只有 ESP32，mihomo 不是。** 之前报告里写“两个单点”，实测之后改掉了。

演练后还有两次短暂掉线，一度以为是设备不稳；后来用户确认是那段时间自己反复拔插电源。信号是 -16 dBm，链路质量其实很好。这也是个教训：**不要把人为操作读成设备故障。**

针对 ESP32 单点，部署了 `dns_failover.sh`，cron 每分钟跑一次：

- ESP32 连续 2 次无响应（`FAIL_N=2`）→ dnsmasq 上游切到校园 DNS，暂停过滤但保留上网；
- 连续 3 次成功（`OK_N=3`）→ 切回 ESP32；
- 日志 `/www/dns_failover.log`，支持 `force-primary` / `force-fallback` 手动切换。

2/3 的滞回是为了避免上游在边界上反复横跳。**故障切换不是“加个备用 DNS”就完了，抖动和回切条件同样要设计。**

## 自动化：黑名单与兜底

黑名单每天更新一次。路由器上跑 `/usr/bin/update_blocklist.sh`，cron `40 18 * * *`（UTC，等于北京时间 02:40），日志 `/www/blocklist_update.log`，更新前保留 `/www/blocklist.txt.bak`。第一次执行结果：

```text
domains=211469 size=4865462 prev=211469
```

回滚命令是 `sh /usr/bin/update_blocklist.sh rollback`。ESP32 从 R3G 的 `/www/blocklist.txt` 拉取快照，所以路由器侧更新完，设备侧按自己的节奏刷新。

DNS 兜底和黑名单更新都放在 cron 里，不依赖某个交互式会话。这是“能生活”的一部分：**系统要能自己照顾自己，而不是每次都要人登录上去点一下。**

## 从局域网到外网：WOL 与 Tailscale

远程开机分两层：内网唤醒和外网入口。

内网这一层用路由器的 `etherwake 1.09-r5`，脚本 `/usr/bin/wol-pc.sh`，MAC 列表 `/etc/wol.macs`（板载 `AA:BB:CC:xx:xx:xx`、USB 网卡 `AA:BB:CC:xx:xx:xx`）。网页入口是 `http://192.168.1.1/wol.html`，POST 到 `/cgi-bin/wol?k=<token>`，口令在 `/etc/wol.token`（600），只允许 LAN 访问。

验证过：错误口令返回 `unauthorized`，正确口令返回 `{"ok":true}`，脚本输出 `sent=2 rc=0`。但**真实唤醒还没测**——需要台式机网线接入 R3G LAN 后才能验证。文章里不能把“发包成功”写成“唤醒成功”。

外网入口用 Tailscale 1.104.1，节点 `r3g-dorm`（Tailscale 地址），参数 `--accept-dns=false --accept-routes=false`。防火墙加了一个独立的 `tailscale` zone（input ACCEPT / forward REJECT），mihomo 的 fake-ip-filter 加上 Tailscale 域名。本机验证 `http://<tailscale-ip>/wol.html` 可访问；手机端外网实测还没完成。

前提是 Windows 侧已经打开网卡的 `Wake on Magic Packet` 和 `Shutdown Wake-On-Lan`，并且关闭快速启动（`HiberbootEnabled=0`）。完全断电（拔插头）后无法唤醒，这是硬件限制，不是脚本问题。

## Windows 侧的代理编排

路由器接管透明代理之后，本机代理不能叠加。为此写了一个 `WifiProxyMode`：

- 计划任务每分钟跑一次，另有网络连接/断开事件触发；
- 向系统 DNS 查询随机子域名 `probe-xxxx.example.com`；
- 如果返回 `198.18.0.0/15` 的 fake-IP，说明当前网络的路由器在接管 DNS 和流量 → 关闭 Windows 系统代理，删除代理环境变量；
- 否则，如果 `127.0.0.1:7897` 有进程监听 → 打开系统代理，写入 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY`；
- 都没有 → 直连，不留配置。

坑在于 Windows 的代理有三层：

1. **WinINET 系统代理**（浏览器/大部分桌面应用）；
2. **环境变量**（终端、git、curl 等）；
3. **Clash Verge 自己的系统代理/TUN**。

三者会互相打架。脚本修改 WinINET 后要调用 `InternetSetOption(39/37)` 通知系统，否则浏览器不会立刻感知；环境变量只影响新启动的进程，切换网络后旧终端不会自动改变；Clash Verge 的“系统代理”和 TUN 必须保持关闭，否则和路由器透明代理双重接管。

安装脚本会先备份环境变量、git 全局代理、WinINET 设置和 `verge.yaml`，再删掉写死的代理变量，注册计划任务；回滚用 `uninstall.ps1`。**自动化的前提是可回滚，不然只是把手工错误变成自动错误。**

## DNS 去广告的边界

最后要说清楚 DNS 过滤能做什么、不能做什么。

| 返回 | 含义 |
|---|---|
| `0.0.0.0` / `::` | 命中黑名单，被拦截 |
| `198.18.x.x` | 放行，mihomo fake-IP |
| NXDOMAIN | 上游不存在 |

`doubleclick.net` 没有被拦，不是部署失败：Hagezi Pro 没有这个裸域名，只有 131 条相关子域。DNS 过滤是域名级的：

- X（Twitter）信息流广告和正文同域，DNS 分不出来；
- App 开屏广告可能来自自有域名、CDN、IP 直连或缓存；
- App 自带 DoH、手机“私人 DNS”、浏览器安全 DNS 都会绕过网络 DNS。

所以“还能看到少量广告”不代表系统没工作。要看 ESP32 的 Query Log 里的实际拦截量，而不是用某一个广告有没有消失来判断。

IPv6 也一样：当前 `wan6` 没有全局地址，AAAA 查询为空，RA/DHCPv6 只通告 ULA；但这不等于“永远不会有 IPv6 绕过”，后续启用 IPv6 时要重新验证。

## 坑位总表

| 坑 | 现象 | 处理 |
|---|---|---|
| fake-IP 劫持所有 `:53` | 查校园 DNS 也返回 `198.18.x`，误判为污染 | 显式指定上游 `192.168.1.1:1053`，禁止指回 dnsmasq |
| DNS 环路 | dnsmasq → ESP32 → dnsmasq | 上游独立端口，Secondary 清空 |
| Tailscale 控制面被 fake-IP | 登录卡 `SYN_SENT` | `fake-ip-filter` 加 `+.tailscale.com` 等 |
| PSRAM 7 字节 stub | 编译/刷写成功，`[dns] no memory` | `-DBOARD_HAS_PSRAM` + `pio run -t clean` |
| MSYSTEM 注入 | Git Bash 下构建失败 | 原生 PowerShell，清除 `MSYSTEM` |
| ESP32 单点 | 断电后全屋 DNS 中断 43.1 s | `dns_failover.sh`，2 次失败切换、3 次成功回切 |
| 误判 mihomo 为第二单点 | 以为停服会全断 | 实测 DNS/HTTP 不受影响，只失去代理/fake-IP |
| 人为拔插被当成故障 | 演练后两次掉线 | 看信号、看日志、问操作者 |
| Windows 三重代理 | 双重代理、终端不走代理 | WinINET + 环境变量 + Verge 统一由脚本管理 |
| DNS 过滤边界 | 同域广告/DoH/Private DNS 仍可见 | 用 Query Log 判断，不用单条广告判断 |

## 现状与未完成

现在能工作的部分：

- R3G 跑 OpenWrt 25.12.6，WAN/LAN/Wi-Fi/SSH/LuCI 正常；
- dnsmasq → ESP32 → mihomo 的 DNS 链正常，211,465 条黑名单生效；
- ESP32 断电后自动回落到校园 DNS，恢复后自动切回；
- 黑名单每日更新，带 `.bak` 和回滚；
- WOL 网页入口、Tailscale 外网入口、Windows 代理自动切换都已就位。

还没验证的部分：

- 手机“私人 DNS”和浏览器 DoH 是否关闭；
- ntfy 消息是否真的送达手机；
- 真实 WOL 唤醒（需要台式机接回 LAN）；
- 手机端 Tailscale 外网开机；
- mihomo 重启恢复、上游超时注入、24 小时以上稳定性；
- 启用 IPv6 后是否会绕过过滤。

这套系统的目标不是“永不断网”，而是**每种断法都有边界**：ESP32 挂了能回落，mihomo 挂了不影响 DNS，外网进不来但 Tailscale 能进，配置改了能回滚。做到这一步，它才算从“能开机”变成了“能生活”。

上篇在这里：[只刷了 kernel1](./uart-recovery.md)。
