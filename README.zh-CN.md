# R3G 宿舍网络中枢

[English](README.md) | [简体中文](README.zh-CN.md)

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![OpenWrt 25.12.6](https://img.shields.io/badge/OpenWrt-25.12.6-00b5e2)
![ESP32-S3 N16R8](https://img.shields.io/badge/ESP32--S3-N16R8-e7352c)
![Release](https://img.shields.io/github/v/release/OrdoAbChao7/r3g-dorm-lab)

一套可复现的 **小米路由器 3G v1** 宿舍网络中枢：UART 救砖、OpenWrt 25.12.6、
ESP32-S3 DNS 过滤、mihomo fake-IP 分流、DNS 故障切换、WoL 与 Tailscale。

大多数文章写到 `sysupgrade successful` 就结束了。这里保留的是证据链：半套固件、
UBI `PEB 256`、11 字节 UART 探针、ESP32 PSRAM stub，以及一次 43 秒的全屋断网
演练。脚本和脱敏日志都在这里，方便你复现路径，或者避开这些坑。

## 目录

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
      ├─ Wi-Fi 2.4/5 + LAN ── 手机 / PC / ESP32-S3
      ├─ dnsmasq :53 ── ESP32 192.168.1.53:53 ── mihomo 192.168.1.1:1053
      ├─ mihomo TUN + fake-IP ── 代理 / 直连
      └─ Tailscale ── 外网访问
```

真正关键的是 DNS 链：客户端只认识路由器；路由器把查询转给 ESP32；ESP32 做黑名单
过滤；放行的查询再交给 mihomo 的独立 DNS 监听。每一跳都可以替换，各自的故障模式
见 [docs/troubleshooting.md](docs/troubleshooting.md)。

## 仓库内容

| 路径 | 是什么 | 入口 |
|---|---|---|
| [uart-toolkit/](uart-toolkit/) | 只读采集、固定 `printenv` 探针、TFTP initramfs、sysupgrade 工具 | [README](uart-toolkit/README.md) |
| [router/](router/) | mihomo 安装/回滚、DNS failover、黑名单更新、WoL CGI | [README](router/README.md) |
| [esp32/](esp32/) | 补丁、PlatformIO 构建、刷写与 DNS 验证工具 | [README](esp32/README.md) |
| [windows/](windows/) | 双网卡、WoL 发送/检查、代理模式计划任务 | [README](windows/README.md) |
| [docs/](docs/) | 复现指南、架构、故障排查、脱敏证据 | [reproduction.md](docs/reproduction.md) |
| [docs/blog/](docs/blog/) | 两篇长文：UART 救砖与 DNS 中枢 | [uart-recovery.md](docs/blog/uart-recovery.md) |

## 快速开始

1. 先读 [SECURITY.md](SECURITY.md) 和 [docs/reproduction.md](docs/reproduction.md)。
2. **写入前先备份。** 按 [docs/flash/UNLOCK_SSH.md](docs/flash/UNLOCK_SSH.md)
   解锁原厂 shell，再用 [router/flash/](router/flash/) 做整片 NAND 备份。
3. 如果路由器已经进入启动循环，从
   [uart-toolkit/START_HERE.md](uart-toolkit/START_HERE.md) 开始。
4. 用 sysupgrade 路径安装 OpenWrt。导致这次救砖的故障见
   [docs/blog/uart-recovery.md](docs/blog/uart-recovery.md)。
5. 配置 DNS 链：[router/README.md](router/README.md) 与
   [esp32/README.md](esp32/README.md)。
6. 加远程开机：[router/wol/](router/wol/) 与
   [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md)。
7. Windows 侧使用 [windows/proxy_setup/](windows/proxy_setup/)，让本机代理跟随
   当前网络。
8. 跑一遍[验收清单](docs/reproduction.md#10-acceptance-checklist)。

## 已验证状态

| 项目 | 状态 |
|---|---|
| R3G v1 UART 采集 | 实机验证：49,392 B 被动日志、U-Boot 1.1.3、System 2、UBI PEB 256 错误 |
| L4 `printenv` | 已验证：只发送 11 字节，取得启动标志 |
| L5 TFTP initramfs | 已验证：7,607,308 B 载入 RAM，未写 NAND |
| L7 OpenWrt 安装 | 已验证：`sysupgrade -n`、`ubiformat` 940 PEB、首次启动与断电重启 |
| ESP32 DNS 过滤 | 已验证：211,465 条域名、2.1 秒 flash 恢复、拦截域名返回 `0.0.0.0` / `::` |
| DNS 故障切换 | 演练验证：ESP32 断电造成 43.1 秒中断；mihomo 停服不影响 DNS |
| WoL 端点 | 口令拒绝/接受已验证；真实唤醒尚未测试 |
| Tailscale | 局域网侧 `wol.html` 可访问；手机外网测试待完成 |
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
- **DNS 链要显式。** ESP32 上游固定为 `192.168.1.1:1053`，绝不指回
  `192.168.1.1:53`；后者会经过 dnsmasq 形成环路。
- **单点要实测。** ESP32 是唯一的 DNS 单点；演练中停掉 mihomo 并没有中断 DNS
  或 HTTP。
- **只保留一个代理控制器。** 连路由器 Wi-Fi 时由路由器透明代理；Windows 脚本只在
  没有路由器代理时启用 Clash。

## 安全

- UART 只用 **3.3 V TTL**。不要接 VCC，也不要接疑似 VCC 的针脚。
- 没有完整备份、第二份物理副本和可验证的恢复路径，不要写 Flash。
- 路由器管理面只留在 LAN。不要把 SSH、HTTP、mihomo API 或 WoL 端点暴露到 WAN。
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
│   ├── blog/                 # 两篇长文
│   ├── flash/                # 解锁、USB 恢复、NAS 笔记
│   └── link-diagnosis/       # 网卡交叉测试方法
├── uart-toolkit/             # 脚本、测试、接线/决策树文档
├── router/                   # mihomo、DNS failover、黑名单、WoL
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
| [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md) | DNS 中枢与可靠性长文 |
| [docs/evidence/](docs/evidence/) | 脱敏的启动日志、`printenv`、UBI 与 PSRAM 证据 |
| [uart-toolkit/README.md](uart-toolkit/README.md) | UART 工具说明与离线自测 |
| [router/README.md](router/README.md) | mihomo、failover、黑名单与 WoL 脚本 |
| [esp32/README.md](esp32/README.md) | 补丁、PSRAM 构建、刷写与 DNS 验证 |
| [windows/README.md](windows/README.md) | 代理模式、WoL 发送与双网卡工具 |

## 致谢

- OpenWrt 与 R3G 设备支持
- Garionhk/ESP32-AdBlocker-N16R8（AGPL-3.0）：实际部署的 ESP32 固件；
  [esp32/patches/](esp32/patches/) 中的补丁按 AGPL-3.0 分发
- mihomo / Clash.Meta
- Hagezi DNS 黑名单
- Tailscale
- OpenWRTInvasion（用于原厂固件的初始 shell）

链接和许可证说明见 [NOTICE.md](NOTICE.md)。

## 许可证

原创代码与文档使用 MIT。`esp32/patches/` 下的补丁因为修改 AGPL-3.0 项目，
按 AGPL-3.0 分发。
