# R3G 宿舍网络中枢

[English](README.en.md) | 简体中文

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![OpenWrt 25.12.6](https://img.shields.io/badge/OpenWrt-25.12.6-00b5e2)
![mihomo 1.19.33](https://img.shields.io/badge/mihomo-1.19.33-4b5563)
![Release](https://img.shields.io/github/v/release/OrdoAbChao7/r3g-dorm-lab)

一套可复现的 **小米路由器 3G v1** 宿舍网络中枢：UART 救砖、OpenWrt 25.12.6、
mihomo fake-IP 全局代理、anti-AD 去广告、DNS 自动回退、WoL 与 Tailscale。

大多数文章写到 `sysupgrade successful` 就结束了。这里保留的是证据链：半套固件、
UBI `PEB 256`、11 字节 UART 探针、ESP32 PSRAM stub、一次 43 秒的全屋断网演练，
以及后来把 DNS 链路从 ESP32 收敛到 mihomo 的取舍。脚本和脱敏日志都在这里，
方便你复现路径，或者避开这些坑。

## 它能做到什么

一台 R3G 把宿舍网络变成：

- 所有连上 Wi-Fi 的设备自动走全局代理：国内直连、国外走代理，Windows 不再手动切系统代理；
- 广告和跟踪域名在 mihomo 规则层被 `REJECT`，不需要每台设备装软件；
- mihomo DNS 故障时自动回退校园 DNS，恢复后自动切回；
- 人不在寝室，也能通过 Tailscale 打开 WoL 页面把电脑唤醒；
- 路由器断电重启后，Wi-Fi、WAN、DNS 和代理自动恢复；
- ESP32-S3 可选保留为独立 DNS 回退，但已不在客户端 DNS 链路上。

```text
手机 / 平板 / 电脑 / 电视
        │  Wi-Fi / LAN
        ▼
   R3G (DHCP DNS = 192.168.1.1)
        ├─ 广告/跟踪域名 ──> mihomo anti-AD REJECT
        ├─ 国内域名 ──> 直连
        └─ 国外域名 ──> 代理
```

```text
$ nslookup pagead2.googlesyndication.com 192.168.1.1
Name:    pagead2.googlesyndication.com
Address: 198.18.0.x        # fake-IP；真正拦截在连接层
$ curl -I http://pagead2.googlesyndication.com
curl: (52) Empty reply from server

$ nslookup www.baidu.com 192.168.1.1
Name:    www.baidu.com
Address: 198.18.0.83
```

| 场景 | 没有这套系统 | 现在 |
|---|---|---|
| 手机 / 平板广告 | 每台装去广告 App | 连上 Wi-Fi 即在连接层拦截 |
| Windows 代理 | 手动开关 Clash / 系统代理 | 跟随当前网络自动切换 |
| 室友设备 | 各自配置 DNS / 代理 | DHCP 统一下发 `192.168.1.1` |
| 人不在寝室 | 电脑关机后无法开机 | Tailscale + WoL 页面 |
| mihomo DNS 故障 | 全屋 DNS 中断 | watchdog 自动回落校园 DNS |
| 路由器重启 | 需要手动逐项检查 | Wi-Fi / WAN / DNS / 代理自动恢复 |

> 这是目标状态。DNS/规则过滤只覆盖域名级广告；同域信息流、App 内广告、DoH 和手机
> Private DNS 不保证被拦。真实 WoL 唤醒和手机外网 Tailscale 仍待实测。哪些已经
> 实测、哪些还没验证，见下面的[已验证状态](#已验证状态)。

## 目录

- [它能做到什么](#它能做到什么)
- [架构](#架构)
- [仓库内容](#仓库内容)
- [快速开始](#快速开始)
- [已验证状态](#已验证状态)
- [设计决策](#设计决策)
- [安全](#安全)
- [仓库结构](#仓库结构)
- [文档](#文档)
- [致谢](#致谢)
- [许可证](#许可证)

## 架构

```text
校园网 WAN (DHCP)
      │
   R3G v1 / OpenWrt 25.12.6
      ├─ Wi-Fi 2.4/5 + LAN ── 手机 / PC / IoT
      ├─ dnsmasq :53 ── 127.0.0.1#1053 ── mihomo DNS (fake-IP)
      │                        ├─ RULE-SET,antiad,REJECT
      │                        ├─ GEOIP,CN,DIRECT
      │                        └─ MATCH,PROXY
      ├─ mihomo TUN + fake-IP ── 代理 / 直连
      ├─ dns_failover_mihomo.sh ── 校园 DNS 回退
      ├─ Tailscale ── 外网访问
      └─ ESP32-S3 192.168.1.53 (off-chain，可选回退)
```

真正关键的是 DNS 链：客户端只认识路由器；dnsmasq 把查询交给 mihomo 的独立
DNS 监听 `1053`；mihomo 返回 fake-IP 并在连接层应用 anti-AD 规则；放行的流量
再按 `GEOIP,CN` 和 `MATCH` 分流。

为什么不是 `dnsmasq → ESP32 → mihomo`？早期确实是这条链，也跑通过 211,465 条
Hagezi Pro。但 ESP32 是单点：断电演练造成 43.1 秒全屋 DNS 中断。把过滤迁到
mihomo 后少了一跳，规则从 103k 扩到 177k，更新可以热重载而不重启。ESP32 仍
保留为独立设备，直连 `.53` 可作为回退。

每一跳的故障模式见 [docs/architecture.md](docs/architecture.md) 和
[docs/troubleshooting.md](docs/troubleshooting.md)。

## 仓库内容

| 路径 | 是什么 | 入口 |
|---|---|---|
| [uart-toolkit/](uart-toolkit/) | 只读采集、固定 `printenv` 探针、TFTP initramfs、sysupgrade 工具 | [README](uart-toolkit/README.md) |
| [router/](router/) | mihomo 安装/回滚、DNS failover、anti-AD 更新、WoL CGI | [README](router/README.md) |
| [esp32/](esp32/) | 补丁、PlatformIO 构建、刷写与 DNS 验证工具（可选回退设备） | [README](esp32/README.md) |
| [windows/](windows/) | 双网卡、WoL 发送/检查、代理模式计划任务 | [README](windows/README.md) |
| [docs/](docs/) | 复现指南、架构、故障排查、脱敏证据 | [reproduction.md](docs/reproduction.md) |
| [docs/blog/](docs/blog/) | 三篇长文：UART 救砖、DNS 中枢、项目复盘 | [retrospective.md](docs/blog/retrospective.md) |

## 快速开始

1. 先读 [SECURITY.md](SECURITY.md) 和 [docs/reproduction.md](docs/reproduction.md)。
2. **写入前先备份。** 按 [docs/flash/UNLOCK_SSH.md](docs/flash/UNLOCK_SSH.md)
   解锁原厂 shell，再用 [router/flash/](router/flash/) 做整片 NAND 备份。
3. 如果路由器已经进入启动循环，从
   [uart-toolkit/START_HERE.md](uart-toolkit/START_HERE.md) 开始。
4. 用 sysupgrade 路径安装 OpenWrt。导致这次救砖的故障见
   [docs/blog/uart-recovery.md](docs/blog/uart-recovery.md)。
5. 配置 mihomo 与 DNS 链：[router/README.md](router/README.md)。
6. 可选：把 ESP32 作为独立 DNS 回退，见 [esp32/README.md](esp32/README.md)。
7. 加远程开机：[router/wol/](router/wol/) 与
   [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md)。
8. Windows 侧使用 [windows/proxy_setup/](windows/proxy_setup/)，让本机代理跟随
   当前网络。
9. 跑一遍[验收清单](docs/reproduction.md#10-acceptance-checklist)。

## 已验证状态

| 项目 | 状态 |
|---|---|
| R3G v1 UART 采集 | 实机验证：49,392 B 被动日志、U-Boot 1.1.3、System 2、UBI PEB 256 错误 |
| L4 `printenv` | 已验证：只发送 11 字节，取得启动标志 |
| L5 TFTP initramfs | 已验证：7,607,308 B 载入 RAM，未写 NAND |
| L7 OpenWrt 安装 | 已验证：`sysupgrade -n`、`ubiformat` 940 PEB、首次启动与断电重启 |
| mihomo 全局代理 | 已验证：TUN + fake-IP、4 节点、`PROXY` 手动 + `AUTO` 故障转移 |
| anti-AD 去广告 | 已验证：177,307 条 MRS，连接层 `REJECT`，加载 4–7 秒 |
| anti-AD 日更 | 已验证：`mihomo -t` + `PUT /providers/rules/antiad` 热重载，204，零重启 |
| DNS 自动回退 | 受控演练验证：1 次失败切校园 DNS，3 次成功回切；真实 kill 未演练 |
| NCSI 直连 | 已验证：Windows 检测端点 200，PC 显示 Internet |
| ESP32 DNS 过滤 | 历史验证：211,465 条、2.1 秒 flash 恢复；现已 off-chain |
| WoL 端点 | 口令拒绝/接受已验证；真实唤醒尚未测试 |
| Tailscale | 本机侧 `wol.html` 可访问；手机外网测试待完成 |
| 手机 DoH / Private DNS | 未验证 |
| 长期稳定性 | 观察中 |

私有实验记录保存了完整证据链，其中包含不公开的原始日志。

## 设计决策

- **双系统不要只刷一半。** R3G 有 kernel0/kernel1 和两个 rootfs 槽；`mtd verify`
  成功不代表这一对内核和 rootfs 能启动。
- **`mtd verify`、链路速率、ping 是不同层次。** 1 Gbps 只是 PHY；单次 ping 可能
  从错误的接口出去。
- **先只读，最后才写。** L4 探针只发 11 字节；L5 把 initramfs 载入 RAM；L7 是
  单独、明确的 `sysupgrade`。
- **DNS 链要显式。** 客户端 DNS 是 dnsmasq `:53`，上游是 mihomo `127.0.0.1#1053`；
  ESP32 若参与，只能指向 `1053`，绝不指回 `192.168.1.1:53`。
- **单点要实测。** ESP32 曾造成 43.1 秒中断；迁移后 mihomo DNS 成为新的单点，
  由 `dns_failover_mihomo.sh` 自动回退校园 DNS。
- **更新不要重启。** anti-AD 日更先 `mihomo -t`，再通过 API 热重载 provider；
  失败保留旧 MRS。
- **只保留一个代理控制器。** 连路由器 Wi-Fi 时由路由器透明代理；Windows 脚本只在
  没有路由器代理时启用 Clash。

## 安全

- UART 只用 **3.3 V TTL**。不要接 VCC，也不要接疑似 VCC 的针脚。
- 没有完整备份、第二份物理副本和可验证的恢复路径，不要写 Flash。
- 路由器管理面只留在 LAN。不要把 SSH、HTTP、mihomo API 或 WoL 端点暴露到 WAN。
- **给 mihomo 控制 API 设置非空 `secret`。** `secret: ""` 会让同一 LAN 内任何
  客户端都能无认证控制 API；即使只绑 LAN，也不要把认证边界去掉。
- 把 WoL 口令和黑名单 URL 当秘密处理；泄露后立即轮换。
- 把占位符（`<repo-root>`、`COMx`、`AA:BB:CC:DD:EE:FF`、`192.0.2.x`、
  `198.51.100.x`、`203.0.113.x`）换成你自己的值。
- 原始 UART 日志可能包含 SN、MAC、Wi-Fi PSK 和管理员密码哈希；发布前必须脱敏。

## 仓库结构

```text
.
├── docs/
│   ├── architecture.md
│   ├── reproduction.md
│   ├── troubleshooting.md
│   ├── evidence/             # 脱敏后的启动日志、flags、PSRAM 日志
│   ├── blog/                 # 三篇长文
│   ├── flash/                # 解锁、USB 恢复、NAS 笔记
│   └── link-diagnosis/       # 网卡交叉测试方法
├── uart-toolkit/             # 脚本、测试、接线/决策树文档
├── router/                   # mihomo、DNS failover、anti-AD、WoL
├── esp32/                    # 补丁、构建、刷写与 DNS 工具
├── windows/                  # 代理模式、WoL、双网卡脚本
├── SECURITY.md
├── NOTICE.md
└── LICENSE
```

## 文档

| 文档 | 回答什么问题 |
|---|---|
| [docs/reproduction.md](docs/reproduction.md) | 从原厂备份到验收的完整路径 |
| [docs/architecture.md](docs/architecture.md) | 组件、数据流与故障域 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 现象 → 原因 → 处理 |
| [docs/blog/uart-recovery.md](docs/blog/uart-recovery.md) | UART 救砖长文 |
| [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md) | DNS 中枢与可靠性长文（含历史架构说明） |
| [docs/blog/retrospective.md](docs/blog/retrospective.md) | 项目复盘：决策、指标、问题与下一步 |
| [docs/evidence/](docs/evidence/) | 脱敏的启动日志、`printenv`、UBI 与 PSRAM 证据 |
| [uart-toolkit/README.md](uart-toolkit/README.md) | UART 工具说明与离线自测 |
| [router/README.md](router/README.md) | mihomo、failover、anti-AD 与 WoL 脚本 |
| [esp32/README.md](esp32/README.md) | 补丁、PSRAM 构建、刷写与 DNS 验证 |
| [windows/README.md](windows/README.md) | 代理模式、WoL 发送与双网卡工具 |

## 致谢

- OpenWrt 与 R3G 设备支持
- mihomo / Clash.Meta
- Anti-AD 与 Hagezi DNS 黑名单
- Garionhk/ESP32-AdBlocker-N16R8（AGPL-3.0）：ESP32 实验固件；
  [esp32/patches/](esp32/patches/) 中的补丁按 AGPL-3.0 分发
- Tailscale
- OpenWRTInvasion（用于原厂固件的初始 shell）

链接和许可证说明见 [NOTICE.md](NOTICE.md)。

## 许可证

原创代码与文档使用 MIT。`esp32/patches/` 下的补丁因为修改 AGPL-3.0 项目，
按 AGPL-3.0 分发。
