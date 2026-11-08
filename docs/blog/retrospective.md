# 从救砖到托管：一台 R3G 的项目复盘

> 这是系列的第三篇。上篇写 UART 救砖：[只刷了 kernel1](./uart-recovery.md)；中篇写 DNS 中枢与可靠性：[从能开机到能生活](./dorm-hub.md)。这一篇不再讲单个坑，而是复盘整个项目：哪些决策是对的，哪些数字是真的，哪些问题被测量纠正，以及现在还剩什么。

## 一句话结论

项目从一次“半套刷机”事故开始，靠备份、只读证据和及时停手恢复；随后把一台家用路由器逐步做成宿舍的 DNS、去广告、全局代理和远程开机中枢。

真正可复用的经验不是某个命令，而是四条：

1. 备份不是形式，是恢复的前提；
2. 证据要分层，`mtd verify`、1 Gbps、ping、HTTP 200 各自只证明一层；
3. 改动要可回滚，更新要尽量不中断；
4. 架构要随测量演进，而不是一开始就过度设计。

## 时间线

| 时间 | 阶段 | 关键动作 | 结果 |
|---|---|---|---|
| 11-03 | 立项与备份 | 校验镜像、解锁原厂 shell、整片 NAND 备份 | 133,693,440 B，两份物理副本 |
| 11-04 00:42–01:14 | 半套刷机 | 只写 kernel1，`mtd verify` 成功 | 几分钟后失联 |
| 11-04 | 误诊与停手 | 双网卡诊断、假 ping、rootfs0 写入中止 | 没有在无 root shell 时继续写 |
| 11-04–11-06 | 只读工具链 | v5 → v5.2.1；TFTP/UART/NIC/扫描器离线测试 | 工具先离线验证，再上硬件 |
| 11-07 | UART 定位 | 49,392 B 被动日志；11 B `printenv`；TFTP initramfs | System 2 + UBI PEB 256 |
| 11-07 夜 | L7-A 恢复 | 第二份备份到 USB；`sysupgrade -n`；ubiformat 940 PEB | OpenWrt 写入 NAND |
| 11-08 白天 | 安装后配置 | Wi-Fi 2.4/5、WAN、LuCI、root 密码、软重启 | 全部通过 |
| 11-08 | 全局代理 | mihomo、TUN、fake-IP、4 节点、面板 | 全屋透明代理可用 |
| 11-08 | DNS 去广告 | ESP32 DNS → mihomo anti-AD MRS | 177,307 条；ESP32 退出链路 |
| 11-08 晚 | 稳定性 | NCSI 直连、DNS watchdog、热重载 | 受控演练通过，mihomo 不重启 |
| 11-08 晚 | 远程与复盘 | Tailscale、WoL、性能对比、本文 | 远程入口就绪 |

## 关键决策

### 1. 事故后停止写 Flash

失联后的第一反应是怀疑链路，第二反应是准备写 rootfs0。但写入的授权条件是“能通过正常 root shell 访问”，实际 21/22/23/80 全不可达。没有 DHCP 租约、没有 ARP、没有邻居记录，于是停手。

这是整次事故里最重要的一个“没有执行”。

### 2. 用 initramfs + sysupgrade，而不是动 Bootloader

UART 已经证明：U-Boot 选 System 2，OpenWrt 内核 CRC 正常，UBI 在 PEB 256 拒绝 attach，VFS panic，1 秒复位。

恢复没有去改 `flag_*`，也没有用 U-Boot 菜单 2，而是：

1. 菜单 1 从 TFTP 加载 initramfs 进 RAM；
2. 只读检查 mtd9 的 PEB 头；
3. 第二份整片备份到 USB 并校验；
4. `sysupgrade -n` 完整格式化 mtd9（940 PEB）；
5. 首次启动和断电重启验证。

**结论：恢复路径不一定要动 Bootloader；官方 sysupgrade 整片格式化，风险更低、可复现性更好。**

### 3. DNS 链路收敛：从 ESP32 到 mihomo

早期链路是：

```text
client → dnsmasq :53 → ESP32 .53:53 → mihomo 1053
```

ESP32 跑 Hagezi Pro 211,465 条，flash 恢复 2.1 秒。它工作得很好，直到做了一次断电演练：**43.1 秒全屋 DNS 中断**。

于是把客户端 DNS 直接切到 mihomo：

```text
client → dnsmasq :53 → mihomo 127.0.0.1#1053
```

ESP32 退出链路，只保留直连 `.53` 作为可选回退。去广告改由 mihomo anti-AD 在连接层完成：

- Anti-AD + Hagezi Light，去重 177,307 条；
- 带 `+.` 前缀的 YAML → `mihomo convert-ruleset` → MRS；
- MRS 1,496,604 B，加载 4–7 秒（YAML 177k 条约 83 秒）；
- 每日 02:45 更新，`mihomo -t` 校验后 API 热重载，返回 204，进程不重启。

**这是一个典型的“测量推翻直觉”：以为多一层更稳，实测发现多一层就是多一个单点。**

### 4. 更新不要重启

anti-AD 更新最初直接重启 mihomo，造成两次断网窗口。后来改成：

1. 下载、合并、转换一次性完成；
2. `mihomo -t` 校验；
3. `PUT /providers/rules/antiad` 热重载；
4. 失败保留旧 MRS。

实测 204、`updatedAt` 更新、`ruleCount` 177,307，断网窗口为 0。

### 5. DNS 回退要设计滞回

`dns_failover_mihomo.sh` 每分钟巡检：

- 主 `127.0.0.1#1053`，用 API `/version` + `/dns/query` 双检；
- 单次失败 2 秒复查，避免热重载瞬间误判；
- 回退校园 DNS，拒绝 `198.18/16` fake-IP 应答；
- 1 次失败切换，3 次成功回切；
- 只 reload dnsmasq，不重启 mihomo。

受控双向往返演练 PASS，mihomo PID 全程不变。真实 kill mihomo 演练按稳定性优先没有做，这是已知的未验证项。

### 6. NCSI 直连

Windows 的连接性检测域名被代理转发时，代理重启会让 PC 误报“无 Internet”。在 mihomo `rules` 顶部加：

```yaml
- DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
- DOMAIN-SUFFIX,msftncsi.com,DIRECT
```

PC 实测两个端点 200，连接配置文件显示 Internet；代理控制组 `gstatic` 仍为 204。

## 数字

| 指标 | 值 |
|---|---|
| 整片备份 | 133,693,440 B；两份物理副本 |
| UART 被动日志 | 49,392 B |
| L4 TX | 11 B |
| L5 initramfs | 7,607,308 B |
| sysupgrade 镜像 | 7,813,734 B |
| ubiformat | 940 PEB；rootfs 4.3 MiB + rootfs_data 106.5 MiB |
| 代理吞吐 | 8.4–20.4 Mbps 下行；10.6 Mbps 上行 |
| 国内直连 | 122.3 Mbps |
| mihomo CPU/RSS | 约 1.25 核 / 约 53 MiB |
| anti-AD 规则 | 177,307 条；MRS 1,496,604 B |
| MRS 加载 | 4–7 秒 |
| 每日更新 | 02:45；热重载 204；零重启 |
| ESP32 历史 | 211,465 条；flash 恢复 2.1 秒；断电演练 43.1 秒 |
| 校园 vs R3G | 校园 117.7–132.2 Mbps；R3G 103.4–108.9 Mbps |

测速有一个坑：PC 的环境变量里带着 `HTTPS_PROXY=http://127.0.0.1:7897`，早期测到的“106 Mbps”其实是 Clash，不是路由器。必须用 `curl --noproxy '*'` 才能真正测到 R3G 路径。

## 出了什么问题

| 问题 | 根因 | 现状 |
|---|---|---|
| 半套刷机 | 只写 kernel1，活动槽是 System 2 | 整片 sysupgrade 修复 |
| 假阳性诊断 | PHY 层成功≠数据路径 | 看 RX 字节、路由表、UART |
| CH340 掉线 | 上电瞬间 USB 重新枚举 | 先启动路由器再开探针 |
| PSRAM stub | 缺 `-DBOARD_HAS_PSRAM` | 干净重建；曾中断约 6 分钟 |
| YAML 加载慢 | 177k 条 YAML 在 MT7621 解析 | 转 MRS，4–7 秒 |
| 更新重启断网 | 用重启应用列表 | 改 API 热重载，零重启 |
| 误判 mihomo 单点 | 没实测 | 演练证明停服不影响 DNS/HTTP |
| 控制面认证 | 配置重建时容易把 `secret` 丢掉 | 生产环境必须默认非空并纳入校验清单 |
| 测速污染 | PC 环境变量代理走了 Clash | `--noproxy '*'` 重测 |
| 文档漂移 | 多次快速迭代 | 本次统一更新 |

## 现在是什么样

```text
校园网 WAN (DHCP)
        │
   R3G v1 / OpenWrt 25.12.6
        ├─ Wi-Fi 2.4/5 + LAN ── 手机 / PC / IoT
        ├─ dnsmasq 192.168.1.1:53
        │      └─ 127.0.0.1#1053  (mihomo DNS, fake-IP 198.18.0.1/16)
        │             ├─ RULE-SET,antiad,REJECT   (177,307)
        │             ├─ GEOIP,CN,DIRECT
        │             └─ MATCH,PROXY              (4 nodes, AUTO fallback)
        ├─ mihomo TUN / auto-route / auto-redirect / dns-hijack any:53
        ├─ dns_failover_mihomo.sh (cron 每分钟；主 1053，回退校园 DNS)
        ├─ Tailscale ── 外网 WoL 页面
        └─ ESP32-S3 192.168.1.53 (off-chain，可选直连回退)
```

### 故障域

| 组件 | 故障影响 | 现有缓解 |
|---|---|---|
| mihomo DNS | 新查询失败 | watchdog 约 1 分钟切校园 DNS；代理/去广告暂停 |
| mihomo 进程 | TUN/DNAT 消失，代理丢失 | watchdog 回退；重启后 5–10 秒恢复代理 |
| dnsmasq | LAN DNS/DHCP 中断 | LuCI/SSH/UART 恢复 |
| R3G | 全屋断网 | 整片备份 + UART 恢复路径 |
| Tailscale | 外网入口丢失 | 局域网管理/WoL 仍可用 |
| ESP32 | 对客户端无影响（已 off-chain） | 可选直连 `.53` 回退 |

## 还剩什么

按优先级：

1. **控制面认证**：mihomo API 必须设置非空 `secret`，并纳入每次配置重建的校验清单；LAN-only 不能替代认证。
2. **真实 kill mihomo 演练**：低峰期约 30 秒，验证 watchdog 回退与回切。
3. **文档统一**：明确 ESP32 已 off-chain，旧契约/设计文档标注历史阶段。
4. **性能**：节点协议基准、`log-level: warning`、就近 VPS，或把重流量代理移到 PC/ARM。
5. **闭环**：真实 WoL 唤醒、手机端 Tailscale 外网、24h+ 稳定性、IPv6/DoH 过滤验证。

## 五条教训

1. **双系统设备不要只刷一半。** 先确认活动槽，再决定写哪个分区。
2. **verify、link、ping 是三种不同层次的证据。** 不要拿一层的结果推断下一层。
3. **写入前先证明能恢复。** 备份至少两份、跨物理盘、重新校验。
4. **只读优先，工具先离线测试。** TX 字节数、命令白名单、PASS 分级都要可审计。
5. **架构随测量演进。** 多一层不一定更稳；如果它带来新的单点，就把它拿掉。

这套系统的目标不是“永不断网”，而是**每种断法都有边界**：mihomo DNS 挂了能回落校园 DNS，mihomo 进程挂了不影响普通上网，外网进不来但 Tailscale 能进，配置改了能回滚。

代码与复现：[github.com/OrdoAbChao7/r3g-dorm-lab](https://github.com/OrdoAbChao7/r3g-dorm-lab)

上篇：[只刷了 kernel1](./uart-recovery.md) · 中篇：[从能开机到能生活](./dorm-hub.md)
