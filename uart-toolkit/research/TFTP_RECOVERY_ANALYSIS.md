# TFTP_RECOVERY_ANALYSIS — U-Boot TFTP 选项与恢复路径安全审查

分析日期：2026-11-04
适用：R3G v1，原厂 U-Boot 1.1.3 / Ralink 5.0.0.0（2018-11-09）
原则：**选项 2 当前为 BLOCKED，不得作为默认或回退方案；选项 1 必须实测确认无 NAND 写入副作用。**

> **第三轮流程边界**
> TFTP 传输成功只证明文件已送达，不等于 NAND 恢复成功；不得把 TFTP 成功描述为 Flash 恢复完成。
> - 选项 1：只作为 **RAM 临时加载候选**；不等于整个 initramfs 会话绝对只读。
> - 选项 2：继续 **BLOCKED**。
> - 选项 7/9（本机实测）：**永久禁止**。
> - 任何 Flash/NVRAM 写入都必须单独审查并获得新的明确授权。

---

## 1. U-Boot TFTP 交互（字符串证据）

选项 1/2 共用类似的网络参数提示（历史技术分析，不构成执行建议；菜单 2 为 BLOCKED）：

```text
Please Input new ones /or Ctrl-C to discard
Input device IP (…) ==:
Input server IP (…) ==:
Input Linux Kernel filename (…) ==:
```

- 设备自身 IP 来自 env `ipaddr`（默认 192.168.31.1）。
- 服务器 IP 来自 env `serverip`（编译默认 192.168.31.2；项目旧记录为 192.168.31.100）。
- 文件名默认 `uImage`；建议输入明确文件名。
- 字符串附近出现 `0x80A00000`，很可能是 TFTP 加载到 SDRAM 的默认地址；**以运行时屏幕显示为准**。
- 加载提示：`Load address: 0x%lx`、`## Booting image at %08lx ...`。

### 网络配置建议

- 电脑有线网卡设为 `192.168.31.100/24`，**不设默认网关**（避免影响 Wi-Fi/默认路由）。
- TFTP 服务器绑定到该有线网卡的 IP，不要绑定 Wi-Fi。
- 路由器与电脑直连或经交换机，确保 ARP 可达。
- 不要在 Windows 防火墙上做全局关闭；只为本次 Python 进程的 UDP 端口放行（需用户手动确认）。

---

## 2. 两个选项的本质区别

| 项 | 选项 1 | 选项 2 |
|---|---|---|
| 菜单原文 | `Load system code to SDRAM via TFTP.` | `Load system code then write to Flash via TFTP.` |
| 目标 | SDRAM | NAND Flash |
| 擦写警告 | 无 | `Warning!! Erase Linux in Flash then burn new one. Are you sure?(Y/N)` |
| 写入范围 | 按设计不写 | **0x200000 与 0x600000 两个内核槽**（官方提交 + 同系列实测） |
| 适用 | 临时启动 initramfs / 诊断 | 恢复内核槽，但会影响两个槽 |
| 本阶段 | 未授权 | 禁止作为默认；未来需单独授权 |

### 选项 2 的精确风险

1. 会把传输的镜像写到 **两个**内核分区。若镜像是 4 MiB 原厂内核，结果是两个槽都变成同一原厂内核；若镜像是 kernel+rootfs 拼接（>4 MiB），还会越过内核区进入 rootfs 区域。
2. **本机未实测**：擦除粒度、单次写入长度、坏块跳过行为、两槽写入顺序、失败后的可恢复性都不确定 → 具体擦除/写入范围 **UNVERIFIED**。
3. 它**不会**设置启动标志；写完后 U-Boot 仍按原标志选择系统。
4. 它**不会**修复 rootfs/UBI；如果 rootfs 已损坏，写回内核也未必能启动。
5. 用 `kernel1.bin` 写两个槽会让 system 1 变成“2019 内核 + rootfs0（2018）”，打破 kernel0↔rootfs0 / kernel1↔rootfs1 的配对。
6. **它会覆盖 kernel0**，破坏本机当前保留的原厂恢复能力。因此当前状态：**BLOCKED**。

---

## 3. 可用镜像与用途

| 镜像 | 大小 | 用途 | 选项 | 风险 |
|---|---:|---|---|---|
| `firmware/tftp_stock/kernel0.bin` | 4,194,304 | 原厂 2018 内核（system 1 备份） | **仅 1**（2=BLOCKED） | 2018 内核与当前 rootfs0/rootfs1 的配对未验证 |
| `firmware/tftp_stock/kernel1.bin` | 4,194,304 | 原厂 2019 内核（system 2 备份，匹配 2.28.24） | **仅 1**（2=BLOCKED） | 与 rootfs1 配对；选项 2 会把它写到 system 1，破坏配对 |
| `firmware/openwrt/...-initramfs-kernel.bin` | 7,607,308 | OpenWrt 25.12.6 RAM 救援系统 | **仅选项 1** | U-Boot 加载阶段按设计不写 NAND；内核/用户态是否 attach UBI 需实测 |
| `firmware/openwrt/...-kernel1.bin` | 3,331,950 | OpenWrt 首次安装内核 | **不得用于选项 2** | 只写一个槽的假设不成立；会破坏 kernel0 |
| `firmware/openwrt/...-rootfs0.bin` | 5,636,096 | OpenWrt UBI rootfs | 不可经 U-Boot TFTP 直接写 | 必须从 Linux 写 rootfs0 |
| `firmware/stock/miwifi_...2.28.46.bin` | 24,482,204 | 原厂 U 盘恢复包 | 不可经 U-Boot TFTP | 由原厂内核 initramfs 读取 U 盘 |

所有文件在 `firmware/` 内均有 SHA-256 校验；TFTP 服务器可对文件做 SHA-256 pin，失败拒绝发送。

---

## 4. 候选恢复路径（全部为未来授权项）

### 路径 A：选项 1 启动 OpenWrt initramfs（诊断优先）

- 前提：UART 可用；TFTP 可达；initramfs 哈希校验通过。
- 操作：菜单 1 → 输入 IP/文件名 → 加载 → 启动。
- 预期：进入 OpenWrt RAM 系统，可读取 `/proc/mtd`、`ubinfo -a`、`dmesg`、`fw_printenv`（若镜像含 envtools）。
- 优点：U-Boot 加载阶段按设计不写 NAND；可用于只读确认真实分区、坏块、UBI 状态。内核/用户态是否 attach 或写入仍需实测。
- 风险：initramfs 是否包含所需工具未验证；启动失败只会复位；需全程日志确认无擦除输出。
- 结论：**最合理的第一项 L5 操作候选**，但仍需单独授权。

### 路径 B：选项 1 启动原厂 kernel1.bin（RAM 启动原厂系统）

- 前提：同上；使用 2019 原厂内核（`ab893d6c…`）。
- 预期：内核从 SDRAM 启动，挂载原厂 rootfs，恢复一个可用的原厂系统（运行在 RAM 内核 + NAND rootfs）。
- 优点：不写内核槽；若成功，可从原厂用户态用 `mtd write` 精确修复 kernel1。
- 风险：原厂系统启动过程可能写入 overlay/NVRAM（不是恢复写入，但仍是 NAND 写）；rootfs 匹配性未知；U-Boot 传给 RAM 内核的 bootargs 是否与正常启动一致未验证。
- 结论：有价值但**未验证**；必须在日志中确认 rootfs 挂载与写入行为。

### 路径 C（BLOCKED）：选项 2 写入 4 MiB 原厂内核（双槽恢复）

- 状态：**BLOCKED**。本机未实测擦除范围、单次写入长度、坏块处理与两槽写入顺序；且会覆盖 kernel0。
- 前提（即使满足也不自动授权）：已取得本机实测证据；TFTP 稳定；文件哈希正确；电源可靠；明确接受双槽写入。
- 预期：kernel0 与 kernel1 都变成同一原厂内核；配对关系被打破。
- 风险：双槽写入；中断即双槽损坏；不修复 rootfs；破坏 kernel0 的原厂恢复能力。
- 结论：**不得作为普通回退；不得写成“RAM 启动失败就自动用菜单 2”。**

### 路径 D：从 OpenWrt initramfs 精确写回

- 历史技术分析：路径 A 成功后，可从 RAM 系统用 `mtd write` 精确写 kernel1（3,331,950 B 或 4 MiB 原厂镜像），必要时写 rootfs0；本文件不提供执行步骤，禁止执行。
- 优点：单分区写入，范围可控；可在写入前再次校验。
- 风险：写入命令与分区标签必须在 initramfs 的 `/proc/mtd` 中确认；错误标签会写错分区。
- 结论：**最精确的修复路径**，但依赖路径 A 成功。

---

## 5. TFTP 失败模式与排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Loading T T T T ... Retry count exceeded` | 服务器没有真正响应 RRQ；文件名/目录不对；防火墙拦截 | 用本工具日志确认收到 RRQ；检查 allowlist/文件名；只放行本次进程 |
| `GOT ARP REPLY` 后无进展 | IP 不在同一网段/网线不通 | 确认电脑为 192.168.31.100/24，路由器 ipaddr 为 192.168.31.1 |
| 传输到一半停止 | 链路不稳定/电源/MTU | 换网线/端口；降低 blksize（本工具默认 512） |
| 文件传输完成但启动失败 | 镜像格式/地址不对 | 校验 uImage magic/load；确认是 4 MiB 分区镜像或 initramfs |
| Windows 防火墙弹窗 | Python 监听 UDP | 仅允许“专用网络”，不要关闭全局防火墙 |

本工具 `tftp_server.py` 的特性（第二轮整改后）：

- 只读 RRQ；拒绝 WRQ。
- 目录越界/绝对路径/盘符拒绝；符号链接逃逸拒绝。
- ACK 严格匹配：只有 ACK 块号等于当前期待块号才确认；上一块重复 ACK 不会推进传输。
- 数据 socket 绑定到与监听 socket 相同的具体 IPv4 地址，避免走 Wi-Fi 默认路由。
- 拒绝 `0.0.0.0` 通配绑定。
- 对外（非 loopback）服务强制 `--allow` 白名单；每个允许文件必须有 `--expect-sha256` pin；启动时校验实际文件哈希。
- 默认绑定 `127.0.0.1`，必须显式 `--bind 192.168.31.100` 才对路由器提供服务。
- 记录每个 RRQ、字节数、SHA-256、ACK 异常、重传、完成/失败。

---

## 6. 证据表

| 项目 | 内容 |
|---|---|
| 结论 | 选项 1 只把镜像加载到 SDRAM 并启动，按设计不写 NAND |
| 来源 | OpenWrt 提交 f2107fc + 本机菜单字符串（无擦除警告） |
| URL | https://github.com/openwrt/openwrt/commit/f2107fc328ff7f9817fe9ca64f84bba9e32abfc6 |
| 设备 | R3G v1 |
| 固件版本 | 原厂 2.28.24 / OpenWrt 25.12.6 |
| U-Boot 版本 | 5.0.0.0 |
| 验证程度 | 官方描述 + 字符串；本机未实测 |
| 风险 | 地址/格式错误导致启动失败；无法完全排除固件在启动后自行写 NAND |
| 是否可以用于我的设备 | 有条件：第一次必须在 UART 全日志下执行 |

| 项目 | 内容 |
|---|---|
| 结论 | 选项 2 将镜像写入 0x200000 与 0x600000 两个内核槽 |
| 来源 | OpenWrt 提交 + ysc3839 实测 |
| URL | 提交；https://blog.ysc3839.com/post/miwifi-r3-ttl-recovery.html |
| 设备 | R3G（官方）；小米路由器 3（实测） |
| 固件版本 | 2018 原厂 |
| U-Boot 版本 | 5.0.0.0 系列 |
| 验证程度 | 官方 + 同系列实测；本机未实测 |
| 风险 | 双槽覆盖；中断导致双槽损坏；不修复 rootfs |
| 是否可以用于我的设备 | **BLOCKED**：官方/同系列证明双槽，但本机未实测擦除/写入细节；且覆盖 kernel0 |

| 项目 | 内容 |
|---|---|
| 结论 | 原厂 U 盘恢复依赖原厂内核 initramfs，且通常需要两个 failed 标志为 1 |
| 来源 | ysc3839 + OpenWrt 设备页 |
| URL | https://blog.ysc3839.com/post/miwifi-r3-ttl-recovery.html |
| 设备 | 小米路由器 3 / R3G |
| 固件版本 | 原厂 2.x |
| U-Boot 版本 | 5.0.0.0 |
| 验证程度 | 同系列实测 + 官方流程 |
| 风险 | 原厂内核被覆盖后 U 盘恢复不可用；改标志是 NVRAM 写入 |
| 是否可以用于我的设备 | 有条件：本机 kernel0 未写，理论可用 |

---

## 7. 结论

1. 选项 1 是唯一有官方依据的“临时启动、不写 Flash”路径；本机仍需实测确认。
2. 选项 2 是双槽写入，绝不能被描述为“只写 kernel1”；它当前是 **BLOCKED**，不是回退方案。
3. 最安全的恢复顺序是：UART 只读日志 → 选项 1 启动 initramfs（或原厂内核）→ 在 RAM 系统中确认分区/标志 → 再决定单分区写入。
4. 所有写入动作都需要新的明确授权；本工具链只准备到“可以安全观察和传输文件”为止。
