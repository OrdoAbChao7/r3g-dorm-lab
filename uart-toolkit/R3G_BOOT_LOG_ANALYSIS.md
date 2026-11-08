# R3G_BOOT_LOG_ANALYSIS — 首次真实 UART 只读启动日志

日期：2026-11-07
设备：Xiaomi Mi Router 3G v1（R3G v1，128 MiB NAND）
采集方式：`uart_capture.py`，COM14，115200 8N1，无流控，DTR=False，RTS=False
模式：LISTEN-ONLY；**未发送任何字节、未按键、未进入 U-Boot 菜单**
原始文件：

```text
logs/r3g_uart_20261107-193332.bin   49,392 B
SHA-256 89a6e2ffc76487fb81bd8a4eaa2df053b10f8225538f7a58974a3980f7d8089b

logs/r3g_uart_20261107-193332.log   49,678 B
SHA-256 9e2f17255e569d27bd5d6a41b1c2076f8961898d7e7243e4dc36f1bce67af81c

logs/r3g_uart_20261107-193332.meta.json

L4 printenv probe（2026-11-07 20:57）：
logs/r3g_l4probe_20261107-205729.rx.bin   25,729 B
SHA-256 af5f2ce9d0ecfc8165404cd929669ad0d78243ef83203dd7ce99c493f17da7de
logs/r3g_l4probe_20261107-205729.log      25,867 B
SHA-256 7507f83f065bf70787d3877bf7a81af3d6e25448dfa21ef755ab979750ae2916
logs/r3g_l4probe_20261107-205729.tx.bin   11 B
SHA-256 b7d6a7c94a6d17c3f45af965d76439a92d6a5a74c54c0cacafdffb4a691c0d69
logs/r3g_l4probe_20261107-205729.meta.json
logs/r3g_l4probe_20261107-205729.actions.json
```

分析工具：`uart_analyze.py`
输出：`logs/r3g_uart_20261107-193332_analysis.md`、`reports/uart_analysis_20261107-193332.json`

---

## 1. 已确认事实（CONFIRMED，直接来自原始日志）

| 事实 | 证据 |
|---|---|
| U-Boot 版本 `U-Boot 1.1.3 (Nov 9 2018 - 09:28:13)` | L383、L809 |
| Ralink UBoot `5.0.0.0` | L~390、L~816 |
| U-Boot 菜单实际为 **1, 2, 3, 4, 7, 9**（没有 5/6） | L425–L431、L851–L857 |
| 启动倒计时打印 `4 3 2 1 0`，自动选择 **3: Boot system code via Flash** | L~432–L433、L~858–L859 |
| 每次启动 U-Boot 执行 `ranand_erase: start:80000, len:20000` | L8、L434 |
| 自动启动 **System 2** | L7、L433 |
| 加载地址 `bc600000`，Image Name `MIPS OpenWrt Linux-6.12.112` | L~437–L440 |
| uImage 数据大小 **3,331,886 B**；本地 `kernel1.bin` 文件 3,331,950 B，减去 64 B uImage 头正好一致 | 日志 + 本地镜像 |
| `Verifying Checksum ... OK` | L~450 |
| `commandline uart_en=0 factory_mode=0 usb_u3=0` | L~452 |
| Linux `6.12.112`，machine `Xiaomi Mi Router 3G` | L~59、L~662 |
| NAND：ESMT 128 MiB，SLC，erase 128 KiB，page 2048，OOB 64 | L~220 |
| 10 个 MTD 分区：Bootloader/Config/Bdata/factory/crash/crash_syslog/reserved0/kernel_stock/kernel/ubi | L~225–L235 |
| `kernel_stock` = 0x200000–0x600000；`kernel` = 0x600000–0xa00000；`ubi` = 0xa00000–0x7f80000 | L~230–L235 |
| UBI auto-attach `mtd9`，随后报 `bad image sequence number 1856070410 in PEB 256, expected 887073040` | L~255–L260 |
| `UBI error: cannot attach mtd9`、`VFS: Cannot open root device`、`Kernel panic - not syncing` | L~267–L272 |
| `Rebooting in 1 seconds..`，随后再次进入 U-Boot；共 2 个 U-Boot banner | L~273、L~383、L~809 |

**结论：这不是猜测的 boot loop，而是已由原始日志证明的“System 2 内核 CRC 通过 → UBI 根文件系统 attach 失败 → VFS panic → 1 秒后复位”的循环。**

---

## 2. 关键判读

### 2.1 启动路径

- U-Boot 没有选择 System 1；它自动选择默认 3，进入 **System 2（kernel at 0x600000）**。
- System 2 的 kernel1 是 OpenWrt 6.12.112；uImage CRC 正常，所以 U-Boot 不会因为内核损坏而回退。
- 失败发生在 **内核启动后、UBI/rootfs 挂载阶段**，不是 uImage CRC 阶段。
- 这与“kernel1 曾被 OpenWrt 覆盖、rootfs 未按 OpenWrt 布局写入”的历史状态一致，但现在有真实日志证据。

### 2.2 UBI 错误

```text
ubi0 error: bad image sequence number 1856070410 in PEB 256, expected 887073040
ubi0 error: failed to attach mtd9, error -22
UBI error: cannot attach mtd9
VFS: Cannot open root device "" or unknown-block(0,0): error -6
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

- `mtd9` 是 UBI 区（0xa00000–0x7f80000）。
- PEB 256 的 UBI image sequence 与预期不一致，导致整个 UBI attach 失败。
- 这不等于“kernel 坏了”；kernel 已解压并运行到 UBI 阶段。
- 也不能仅凭此判断 rootfs0/rootfs1 备份损坏；需要进一步只读证据。

### 2.3 `uart_en=0` 的实测意义

日志显示 `commandline uart_en=0`，但 U-Boot 和 Linux 都持续输出到串口。说明：

- `uart_en=0` **没有关闭 U-Boot/内核的串口日志输出**。
- 不能用“uart_en=0”解释“没有日志”；本次日志正常。
- 这修正了此前“uart_en 可能门控 UART 输出”的不确定说法；至少在本机、本 U-Boot 版本下，日志输出不受它控制。

### 2.4 实际菜单与旧文档差异

本次真实菜单是：

```text
1: Load system code to SDRAM via TFTP.
2: Load system code then write to Flash via TFTP.
3: Boot system code via Flash (default).
4: Entr boot command line interface.
7: Load Boot Loader code then write to Flash via Serial.
9: Load Boot Loader code then write to Flash via TFTP.
```

旧文档中的 `5/6` 是其他 U-Boot 版本/通用资料；**本机实际是 7/9**，两者都是 Bootloader 写入，仍然**永久禁止**。菜单 2 仍然 **BLOCKED**。

### 2.5 `ranand_erase: start:80000, len:20000`

每次启动在 `Booting System 2` 之前出现：

```text
..ranand_erase: start:80000, len:20000
..Done!
```

- `0x80000` 是 Config 分区起始；`0x20000` 是 128 KiB（一个 NAND erase block）。
- 这说明 U-Boot 在启动过程中对 Config 区域执行了擦除/写入动作（很可能是环境变量保存/恢复），**不是本工具发送的命令**。
- 具体是 `saveenv`、环境损坏恢复还是其他 U-Boot 内部逻辑，**尚未证实**。
- 影响：不能假设当前 NAND 上的 Config 与 2026-11-04 的 `Config.bin` 备份仍然完全一致；备份是历史快照。后续任何恢复方案都必须重新只读确认，不得直接覆盖。

### 2.6 L4 只读 `printenv` 结果（2026-11-07 20:57）

探针 `scripts/uart_l4_readonly_probe.py` 在路由器已经处于启动循环时打开 COM14，捕获到菜单后只发送 11 字节：

```text
34 0d 70 72 69 6e 74 65 6e 76 0d
4  Enter  p r i n t e n v  Enter
```

`.tx.bin` 只有这 11 字节；`actions.json` 记录 3 个动作：`menu4`、`menu4-enter`、`printenv`。路由器进入 `MT7621 #`，输出 `printenv` 后静默，探针自动退出（`state=COLLECT`）。未发送任何其他命令。

原始日志含设备序列号、MAC、Wi-Fi SSID/密码、管理员密码哈希。**不要发布原始 `.log`**；脱敏摘录见 `reports/uart_printenv_20261107-205729_REDACTED.txt`，机器可读 flags 见 `reports/uart_printenv_20261107-205729_flags.json`。

关键非敏感值：

| 变量 | 实测值 | 判读 |
|---|---|---|
| `bootcmd` | `tftp` | 观察值；未执行 |
| `bootdelay` | `5` | 观察值 |
| `ipaddr` / `serverip` | `192.168.31.1` / `192.168.31.100` | U-Boot 默认网络值；未配置 |
| `model` / `mode` | `R3G` / `Router` | 观察值 |
| `flag_boot_type` | `2` | 观察值；官方语义未确认 |
| `flag_last_success` | `1` | 与两个 failed=0 组合时优先 System 2；与启动日志一致 |
| `flag_try_sys1_failed` | `0` | 未被 U-Boot 标记失败 |
| `flag_try_sys2_failed` | `0` | 未被 U-Boot 标记失败；解释为何不回退 |
| `flag_boot_success` | `1` | 观察值；研究结论称 U-Boot 字符串未引用它，不作为回退依据 |
| `flag_boot_rootfs` | `1` | 观察值；语义未确认，不修改 |
| `uart_en` | `0` | 实测未阻止 U-Boot/内核串口输出 |
| `ssh_en` / `telnet_en` | `0` / `0` | 不影响当前只读诊断 |
| `normal_firmware_md5` | `f85f26fe6fce32f991dde02fc87ce9b8` | 观察值；未用于任何写入 |
| `Environment size` | `791/4092` | 环境有效且未满 |

**判读：**

- `flag_last_success=1` + `flag_try_sys1_failed=0` + `flag_try_sys2_failed=0` 与研究中的选择规则完全一致：优先 **System 2**。这次是来自设备本身的环境值，不再是推断。
- U-Boot 不回退 System 1 的原因现在是完整的：kernel uImage CRC 通过；U-Boot 不检查 rootfs；两个 failed 标志都保持 0。rootfs panic 发生在 U-Boot 交接之后，U-Boot 不会因此设置 `flag_try_sys2_failed`。
- `bootcmd=tftp` 是观察值；自动启动仍走菜单默认 3。**不得**在没有单独授权时执行 `bootcmd`、`run` 或任何网络启动命令。
- `flag_boot_type=2`、`flag_boot_rootfs=1`、`flag_boot_success=1` 的实际语义未被官方确认；**不得修改**。
- 当前 `printenv` 是设备当前环境的权威快照；`ranand_erase` 的触发原因仍未证实。不能因为读到了环境值就假设 Config 备份与当前 NAND 完全一致。

### 2.7 L5 initramfs 只读诊断（2026-11-07 23:10）

U-Boot 菜单 1 通过 TFTP 加载官方 OpenWrt 25.12.6 initramfs（7,607,308 B，SHA-256 `8d58d8a1…`）成功，进入 RAM 用户态；根为 tmpfs，未挂载 NAND，未写 NAND。详见 `reports/L5_INITRAMFS_READONLY_REPORT.md`。

关键只读结果：

- `/dev/mtd7`（kernel_stock）SHA-256 `ab58d7a35bb75c988aad53001d52ed3f3306d138e36be8e7de2067891f7c5db8`，与原厂 kernel0 备份一致。
- `/dev/mtd8`（kernel）SHA-256 `ea6039f0…`，为当前 OpenWrt kernel，不是原厂 kernel1。
- mtd9 UBI：PEB 0/255 的 image_seq = `0x34dfa910`（887073040，期望值）；PEB 256/257 = `0x6ea1630a`（1856070410，旧值）。前 256 个 PEB（32 MiB）为新 UBI 序列，之后仍是旧序列，UBI 因序列不一致拒绝 attach（error -22）。
- `ubinfo -a`：UBI devices = 0；`mount`/`df` 仅 tmpfs，确认本次未写 NAND。

**含义**：system 2 的 OpenWrt 内核正常，但 mtd9 的 UBI 格式/写入不完整；不是 kernel CRC 错误，也不是 NAND 全坏。原厂 kernel0 仍完整，但原厂 rootfs0/rootfs1 已被 OpenWrt UBI 覆盖/部分覆盖。

### 2.8 L7-A OpenWrt 安装与 NAND 启动（2026-11-07 23:24）

- 第二份整片备份已复制到 USB `I:` 并校验。
- initramfs 通过 HTTP 下载 `squashfs-sysupgrade.bin`（7,813,734 B，SHA-256 `78c15850…`），在 `/tmp` 校验后执行固定安装命令。
- 安装工具对 mtd9 执行完整格式化（940 PEB，0 bad），创建 `rootfs`（4.3 MiB）和 `rootfs_data`（106.5 MiB），写入 OpenWrt kernel，输出安装成功。
- 重启后 UBI attach 成功，squashfs rootfs + UBIFS overlay 挂载，OpenWrt 25.12.6 进入用户态。
- LAN `192.168.1.1` ping 0% 丢包；22/80 开放；HTTP 200 重定向到 LuCI。
- 再次 12V 断电重启后，UBI attach、rootfs/overlay 挂载和网络均恢复；安装已持久化到 NAND。
- 未设置 root 密码；Wi-Fi/WAN 尚未配置。

---

## 3. 证据等级

### CONFIRMED

- U-Boot 1.1.3 / Ralink 5.0.0.0。
- 菜单编号 1、2、3、4、7、9；自动默认 3。
- System 2 被选择；kernel1 是 OpenWrt 6.12.112；uImage CRC OK。
- UBI mtd9 attach 失败（bad image sequence PEB 256）；VFS panic；1 秒复位；循环。
- `uart_en=0` 未阻止串口日志。
- U-Boot 在启动时对 0x80000/0x20000 执行 ranand_erase（日志事实）。
- L4 `printenv` 已通过菜单 4 取得；TX 仅 11 字节；环境有效（791/4092）。
- 当前环境值：`flag_last_success=1`、`flag_try_sys1_failed=0`、`flag_try_sys2_failed=0`、`flag_boot_success=1`、`flag_boot_type=2`、`flag_boot_rootfs=1`、`bootcmd=tftp`、`bootdelay=5`。
- L5 initramfs 已通过菜单 1 + TFTP 启动；根为 tmpfs，未写 NAND。
- mtd7 kernel_stock SHA-256 与原厂 kernel0 备份一致；mtd8 为 OpenWrt kernel。
- mtd9 PEB 0/255 image_seq `0x34dfa910`，PEB 256/257 `0x6ea1630a`；UBI attach error -22。

### HIGH-CONFIDENCE

- 当前无法启动的原因是 System 2 的 kernel 与 UBI rootfs 不匹配/UBI 元数据损坏，而不是 uImage CRC 错误。
- System 1（kernel0 + rootfs0）仍是原厂恢复可能性的核心；但当前未被 U-Boot 选择，不能仅凭备份断言可启动。
- 当前 `flag_last_success=1` 与两个 failed=0 的组合，直接解释 U-Boot 为何持续选择 System 2；rootfs panic 不会改变 U-Boot 的 failed 标志。
- Config 可能被 U-Boot 自身改写；但本次 `printenv` 是当前环境的权威快照，旧 `Config.bin` 备份只能当作历史快照。
- mtd9 UBI 的故障是前 256 PEB 与后续 PEB 的 image_seq 不一致；这是写入/格式化不完整，而不是 kernel CRC 或整片 NAND 损坏。

### UNVERIFIED

- `ranand_erase` 的具体触发原因（环境保存/恢复/其他）。
- `flag_boot_type`、`flag_boot_rootfs`、`flag_boot_success` 的官方语义。
- `bootcmd=tftp` 的实际用途；未执行。
- System 1 的 rootfs0 在当前 NAND 上是否仍完整（UBI 已覆盖 mtd9 前 32 MiB）。
- UBI PEB 256 之后旧数据的具体来源，以及 OpenWrt UBI 只格式化前 32 MiB 的原因。

### BLOCKED / NOT AUTHORIZED

- 菜单 2 写入（双槽）——BLOCKED。
- 菜单 7/9 Bootloader 写入——永久禁止。
- 修改启动标志、saveenv、reset、NAND 擦写、rootfs 写入——未授权。
- 任何“恢复”动作——必须先有本机只读证据和单独授权。

---

## 4. 对恢复策略的影响

1. 当前失败点已明确：System 2 的 OpenWrt kernel 正常，但 mtd9 UBI 在 PEB 256 处 image_seq 不一致，UBI attach 失败。
2. U-Boot 不会因为 rootfs 失败而自动回退 System 1；当前环境值 `flag_last_success=1`、两个 failed=0 解释了持续选择 System 2 的原因。
3. L5 initramfs 已成功启动并完成只读诊断：mtd7 原厂 kernel0 完整；mtd8 为 OpenWrt kernel；mtd9 前 32 MiB 为新 UBI 序列，之后为旧序列。
4. 下一步只能在单独授权后选择：
   - **L7-A**：完整 `ubiformat` mtd9 并写入 OpenWrt rootfs/sysupgrade；
   - **L7-B**：用原厂备份写回 rootfs0/rootfs1/overlay；
   - **L6**：只改启动标志尝试 System 1（rootfs0 已被 UBI 覆盖，不保证可启动）。
   本文件不提供也不授权任何写入命令。
5. 菜单 2/7/9 均不得作为恢复路径；菜单 2 为 BLOCKED，7/9 永久禁止。任何 L7 前必须完成第二份整片备份。

---

## 5. 停止状态

L5 只读诊断已完成：initramfs 运行于 RAM，根为 tmpfs；未修改 NVRAM/Flash/UBI。原始 L5 与只读诊断日志、SHA-256 已保存。路由器当前可保持通电在 initramfs shell，或断电；任何写入操作都需新的授权。原始 L4 日志含敏感信息，不得发布。
