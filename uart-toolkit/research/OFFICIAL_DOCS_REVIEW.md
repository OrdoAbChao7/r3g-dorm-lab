# OFFICIAL_DOCS_REVIEW — OpenWrt 官方资料审查

审查日期：2026-11-04
来源：OpenWrt 设备页（2026 存档快照）+ 提交 f2107fc + 25.12 源码/发布清单
限制：`openwrt.org` 实时页被 Anubis 拦截；存档页正文中仍出现 22.03 示例，**不能当作 25.12.6 的逐字安装说明**。25.12.6 的镜像类型与哈希以 `profiles.json` / `sha256sums` 为准。

---

## 1. 官方设备页关键内容（逐字要点）

### 1.1 设备识别

- 目标：Xiaomi Mi WiFi R3G（Mi Router 3G / MIR3G），MT7621A，128 MiB NAND，256 MiB RAM，USB 3.0。
- 明确警告：**R3G v2（无 USB、16 MiB SPI Flash、128 MiB RAM，即 4A Gigabit）与本机不是同一设备**；另有 Mi Router 3（MIR3，无 G）也不是同一设备。
- 官方页提醒：USB 3.0 可能干扰 2.4 GHz Wi-Fi（与本项目故障判断无关，但记录）。

### 1.2 安装（来自原厂、SSH 方式）

存档页给出的命令（示例版本是 22.03.0，机制与 25.12.6 相同）：

```text
// 历史记录；禁止执行
mtd write openwrt-...-squashfs-kernel1.bin kernel1
mtd write openwrt-...-squashfs-rootfs0.bin rootfs0
nvram set flag_try_sys1_failed=1
nvram commit
reboot
```

含义：从**原厂系统**运行时写入 `kernel1`（system 2）与 `rootfs0`（从 0xA00000 起的 UBI 区域），然后设置 `flag_try_sys1_failed=1`，让 U-Boot 跳过原厂 system 1，改为启动 system 2 的 OpenWrt 内核。

### 1.3 安装（UART + USB 盘方式）

存档页原文要点：

- 3.3 V UART，**115200 baud，8 data bits，no parity，1 stop bit**。
- 上电，在串口菜单出现时选择 **`4: Enter boot command line interface`**；**可能需要在数字后不发送换行**。
- 历史记录（禁止执行）：`setenv uart_en 1`（可选 `setenv ssh_en 1`），`saveenv`，`boot`。
- 之后步骤与 SSH 安装相同（把 kernel1/rootfs0 放到 FAT32 U 盘，在 UART 控制台执行 mtd 命令）。

### 1.4 拆砖（Debricking，串口方式）

存档页原文要点：

- 需要：3.3 V USB-TTL、TFTP 服务器（最好在 `192.168.31.100`）、`kernel0.bin`、FAT32 U 盘上的官方固件并重命名为 `miwifi.bin`。
- 进入串口，**用 U-Boot 菜单选项 2（TFTP 写 Flash）刷 `kernel0.bin`**。
- 然后插入 U 盘、按 Reset，路由器从原厂内核的恢复模式自行刷入官方固件。

### 1.5 恢复原厂（Recovery to stock）

前提：system 1 仍保留原厂内核。

- 仅 Failsafe 时：`mount_root`，`sh /etc/uci-defaults/30_uboot-envtools`。
- 历史记录（禁止执行）：`fw_setenv flag_try_sys2_failed 1`，`reboot`。
- 板子会启动 system 1 的原厂内核，红灯慢闪等待 FAT32 U 盘中的恢复镜像；按住 Reset 约 1 秒，恢复时黄灯、完成后蓝灯。

### 1.6 官方提交对启动逻辑的说明（f2107fc）

原文（节选）：

- “uboot expects to find bootable kernels at nand addresses 0x200000 & 0x600000 known by uboot as "system 1" and "system 2" respectively.”
- 选择依据：`flag_last_success`、`flag_try_sys1_failed`、`flag_try_sys2_failed`。
- `flag_last_success`：0 = 偏好 system 1，1 = 偏好 system 2；**只有两个 failed 标志都为 0 时才考虑它**。
- 任一 failed 被置位 → 启动另一个未失败的系统。
- 两个 failed 都置位 → 检查 system 1 的 uImage CRC；OK 则启动 system 1，否则**无条件启动 system 2**（即使 system 2 CRC 不对）。
- **U-Boot 只会设置 failed 标志，永远不会清除它们**。
- 当选中的系统 uImage CRC 不正确时，U-Boot 设置该系统的 failed 标志。
- **“Note uboot's tftp flash install writes the transferred image to both kernel partitions.”**
- 官方提交内的历史安装记录（禁止执行）：`mtd write ... kernel1`、`mtd write ... rootfs0`、`nvram set flag_try_sys1_failed=1`、`nvram commit`、`reboot`。
- 恢复原厂的历史记录（禁止执行）：`fw_setenv flag_try_sys2_failed 1`、`reboot`（依赖 system 1 的原厂内核）。

---

## 2. 结论证据表

| 项目 | 内容 |
|---|---|
| 结论 | R3G v1 的 U-Boot 在 0x200000（system 1）与 0x600000（system 2）寻找可启动内核 |
| 来源 | OpenWrt 提交 f2107fc；当前 DTSI 注释 |
| URL | https://github.com/openwrt/openwrt/commit/f2107fc328ff7f9817fe9ca64f84bba9e32abfc6 |
| 设备 | R3G v1 |
| 固件版本 | 提交基于 LEDE/OpenWrt 时代；机制延续到 25.12 |
| U-Boot 版本 | 未在提交中限定；本机 5.0.0.0 字符串含相同地址逻辑 |
| 验证程度 | 官方证实 |
| 风险 | 写错地址会覆盖错误内核；地址本身不是“可随意尝试”的参数 |
| 是否可以用于我的设备 | 是（地址与备份一致：kernel0 0x200000、kernel1 0x600000） |

| 项目 | 内容 |
|---|---|
| 结论 | `flag_last_success` 仅在两个 `flag_try_sys*_failed` 都为 0 时决定偏好；0=system1，1=system2 |
| 来源 | OpenWrt 提交 f2107fc |
| URL | 同上 |
| 设备 | R3G v1 |
| 固件版本 | 同上 |
| U-Boot 版本 | 本机 Bootloader 字符串含 `flag_last_success`，行为与之相符（未反汇编） |
| 验证程度 | 官方证实（逻辑）；本机行为未实测 |
| 风险 | 只改 `flag_last_success` 而不理解 rootfs 匹配，可能启动到不匹配的旧系统 |
| 是否可以用于我的设备 | 有条件：仅在 UART 日志确认 system1/rootfs0 完好后 |

| 项目 | 内容 |
|---|---|
| 结论 | U-Boot 的 TFTP“写 Flash”安装会把传输的镜像写入**两个**内核分区（0x200000 和 0x600000） |
| 来源 | OpenWrt 提交 f2107fc；同系列设备实测（ysc3839） |
| URL | 提交；https://blog.ysc3839.com/post/miwifi-r3-ttl-recovery.html |
| 设备 | R3G（官方提交明确）；小米路由器 3（实测） |
| 固件版本 | 提交时代；实测 2018 原厂 |
| U-Boot 版本 | 实测设备为 Ralink 5.0.0.0 系列；本机同为 5.0.0.0 |
| 验证程度 | 官方证实 + 同系列实测；**本机未实测** |
| 风险 | 选 2 会覆盖 kernel0 和 kernel1；不能用来“只写 kernel1”；传输中断可能导致两个内核都损坏 |
| 是否可以用于我的设备 | 有条件：仅作为“恢复原厂内核到两个槽”的整槽操作，且必须使用已校验的 4 MiB 原厂内核镜像 |

| 项目 | 内容 |
|---|---|
| 结论 | 从原厂安装 OpenWrt 的官方历史顺序是：写 kernel1 → 写 rootfs0 → `nvram set flag_try_sys1_failed=1` → `nvram commit` → reboot；本文件禁止执行这些写入步骤 |
| 来源 | OpenWrt 设备页（存档）；OpenWrt 提交 f2107fc |
| URL | https://openwrt.org/toh/xiaomi/mir3g；提交 |
| 设备 | R3G v1 |
| 固件版本 | 存档页示例 22.03.0；25.12.6 镜像类型相同 |
| U-Boot 版本 | 原厂 5.0.0.0 |
| 验证程度 | 官方证实（流程）；本机只执行了第一步 |
| 风险 | 只写 kernel1 不写 rootfs0、不设标志，会破坏当前活动系统且不会自动回退 |
| 是否可以用于我的设备 | 是，但必须在 UART 诊断后分步授权执行 |

| 项目 | 内容 |
|---|---|
| 结论 | 恢复原厂的历史记录是 `fw_setenv flag_try_sys2_failed 1` 强制回到 system 1 的原厂内核，再由原厂内核的 U 盘恢复模式刷回官方固件；本文件禁止执行 |
| 来源 | OpenWrt 设备页（存档）；OpenWrt 提交 f2107fc |
| URL | 同上 |
| 设备 | R3G v1 |
| 固件版本 | 原厂 2.x |
| U-Boot 版本 | 5.0.0.0 |
| 验证程度 | 官方证实（流程）；前提是 system 1 原厂内核完好 |
| 风险 | 若原厂内核/rootfs0 已损坏，则无法进入恢复模式；设置标志本身是 NVRAM 写入 |
| 是否可以用于我的设备 | 有条件：本机 kernel0 未写、rootfs0 未写，理论上满足前提，但需 UART 确认 |

---

## 3. 官方资料中的冲突与版本陷阱

| 冲突点 | 官方页/旧教程 | 本机实际证据 | 处理 |
|---|---|---|---|
| U-Boot 菜单编号 | 旧教程与部分 Wiki 写作 `1/2/3/4/9`（9=写 Bootloader） | 本机 `Bootloader.bin` 字符串为 **1–6**（5=串口写 Bootloader，6=TFTP 写 Bootloader） | **以屏幕实际菜单为准**；永远不选写 Bootloader 项 |
| 安装镜像版本 | Wiki 正文示例仍是 `22.03.0`，甚至更老的 `18.06.2` | 25.12.6 发布清单：v1 只有 4 个镜像（initramfs/kernel1/rootfs0/sysupgrade） | 使用 25.12.6 的 kernel1+rootfs0；不要把旧版本文件名照抄 |
| 分区标签 | 旧 Wiki “Flash Layout” 仍写 `kernel_erase` / `kernel` / `ubi` | 本机原厂运行时为 `kernel0` / `kernel1`；25.12.6 OpenWrt DTS 为 `kernel_stock` / `kernel` / `ubi` | 安装命令要在**原厂系统**里执行（标签 kernel1/rootfs0）；进入 OpenWrt 后标签已变化 |
| 选项 2 的目标 | Wiki 拆砖步骤直接说“用选项 2 刷 kernel0.bin” | 官方提交明确写“会写入两个 kernel 分区” | 选项 2 是**双槽写入**，不是单分区写入；必须按此评估风险 |
| `flag_boot_rootfs` | 本项目旧 Runbook 建议改它来切换系统 | 官方提交没有解释它；本机 U-Boot 只把它打印为 `0x%X` | **不改**；切换系统用官方文档中的 failed/last_success 语义 |
| `flag_boot_success` | 旧 NVRAM 中有此值 | 本机 `Bootloader.bin` 字符串中**没有** `flag_boot_success` | 它不是本机 U-Boot 的启动选择变量；不要用它推断启动行为 |

---

## 4. 结论

1. 官方资料足以证明双系统地址、三个启动标志的基本语义、TFTP 双内核写入、以及原厂安装/恢复流程。
2. 官方 Wiki 正文存在版本滞后和菜单编号差异，不能逐字照抄；必须与 25.12.6 发布清单和本机 U-Boot 字符串交叉核对。
3. 本机最需要的下一步仍是 UART 启动日志：确认 U-Boot 选择的系统、CRC 结果、卡在内核还是 rootfs。
