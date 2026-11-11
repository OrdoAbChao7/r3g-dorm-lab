# R3G 宿舍网络系列

四篇长文，按阶段递进。每个阶段只回答一个问题，前一篇的结论是后一篇的起点。

| 阶段 | 文章 | 时间 | 回答的问题 | 关键产出 |
|---|---|---|---|---|
| **1 救砖** | [只刷了 kernel1](uart-recovery.md) | 11-03–11-07 | 设备还能不能回来？ | 整片备份、只读 UART、`sysupgrade -n` |
| **2 中枢** | [从能开机到能生活](dorm-hub.md) | 11-08 | 网络能不能自己活着？ | mihomo、anti-AD、DNS 回退、WoL、Tailscale |
| **3 复盘** | [从救砖到托管](retrospective.md) | 11-08 晚 | 哪些决策是对的，哪些数字是真的？ | 测量推翻直觉：ESP32 off-chain |
| **4 运维** | [从托管到日常](operations.md) | 11-09–11-11 | 谁在解析、谁在认证、应用连哪里？ | DNS 泄露修复、门户自动登录、PC facade |

## 阶段之间发生了什么

```text
阶段 1  半套固件 → UART 定位 PEB 256 → 完整 sysupgrade
   │
阶段 2  OpenWrt 安装后配置 → mihomo TUN/fake-IP → ESP32 DNS → 回退/WoL
   │
阶段 3  43.1 秒断网演练 → 把 ESP32 移出链路 → DNS 收敛到 mihomo → 复盘
   │
阶段 4  DNS 泄露修复（DoH #PROXY）→ 门户自动重登录（nasId=52）
        → PC 稳定入口 17890（facade + 端口登记表）
```

## 怎么读

- **想复现救砖**：从阶段 1 开始，配合 [reproduction.md](../reproduction.md) 和 [uart-toolkit/](../../uart-toolkit/)。
- **想搭一台宿舍中枢**：阶段 2 给架构，阶段 3 给取舍，阶段 4 给日常运维。
- **只关心某个坑**：直接看 [troubleshooting.md](../troubleshooting.md)，再回到对应阶段。

## 状态口径

文章里的“已验证 / 待观察 / 未演练”是严格区分的。阶段 4 结束时仍未闭合的项目集中在两处：

- [operations.md#六阶段四的边界](operations.md#六阶段四的边界)；
- [retrospective.md#还剩什么](retrospective.md#还剩什么)。
