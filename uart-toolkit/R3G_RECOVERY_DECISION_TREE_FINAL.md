# R3G_RECOVERY_DECISION_TREE_FINAL — 基于 UART 日志的封版决策树

日期：2026-11-06
适用：R3G v1，原厂 U-Boot 5.0.0.0；当前已知 kernel1 曾被 OpenWrt 25.12.6 覆盖，rootfs 未按 OpenWrt 布局写入。
前置：已完成 `READ_ONLY_UART_PROCEDURE.md`，至少 2 轮完整只读启动日志。
事实源：`../README.md`；当前已有真实 UART 启动日志 + L4 只读 `printenv`。

> 本文件只做技术分析与决策，不生成可执行的 Flash/NVRAM 命令。
> **菜单 2 永久 BLOCKED；菜单 7/9（本机实测；旧资料常写作 5/6）永久禁止；不自动修改启动标志；不自动执行 saveenv/reset/NAND 写入。**
> 任何 L6/L7 操作都必须另行取得本机 UART 证据、单独风险评估和明确授权。

---

## 0. 先填观察表

| 观察项 | 本轮值 | 证据等级 |
|---|---|---|
| U-Boot 版本 / Ralink 版本 | 1.1.3 (2018-11-09) / 5.0.0.0 | E3（日志） |
| 是否出现 `Please choose the operation` | 是：1,2,3,4,7,9；自动默认 3 | E3 |
| `Booting System 1` / `System 2` | 两轮均 System 2 | E3 |
| `Verifying kernelN uImage CRC` 结果 | OK；OpenWrt 6.12.112 | E3 |
| `Starting kernel` / Linux version | 是；6.12.112 | E3 |
| cmdline（console/root/ubi.mtd） | `console=ttyS0,115200n8 rootfstype=squashfs,jffs2`；U-Boot `uart_en=0 factory_mode=0 usb_u3=0` | E3 |
| UBI attach 的 mtd 编号/PEB | mtd9；PEB 256 image_seq 1856070410 ≠ 887073040；attach error -22 | E3 |
| UBIFS / rootfs 挂载 | 未到达；`VFS: Cannot open root device` | E3 |
| panic / VFS / watchdog | `Kernel panic - not syncing: VFS...`；1 秒复位 | E3 |
| reboot loop 轮数 | 34 秒内 2 个 U-Boot banner；约 4.3 秒/轮 | E3 |
| 最后一次成功 / 第一次失败 | 内核解压并启动成功 / UBI attach 失败 | E3 |
| L4 `printenv` | 菜单 4 进入 CLI；TX 仅 11 B；环境有效 791/4092 | E3 |
| `flag_last_success` / `flag_try_sys1_failed` / `flag_try_sys2_failed` | `1` / `0` / `0` | E3（设备环境） |
| `flag_boot_success` / `flag_boot_type` / `flag_boot_rootfs` | `1` / `2` / `1` | E3（语义未确认） |
| `bootcmd` / `bootdelay` | `tftp` / `5` | E3；未执行 |
| 当前路由器状态 | U-Boot `MT7621 #`；应断电 | E3 |

没有日志证据，不进入下一分支。

---

## 1. 全局边界

| 项目 | 状态 | 说明 |
|---|---|---|
| U-Boot 菜单 1（SDRAM） | 未授权（L5） | 只作为 RAM 候选，不等于安装 |
| U-Boot 菜单 2（TFTP 写 Flash） | **BLOCKED** | 双槽写入；擦除范围/长度/坏块/顺序未实测 |
| U-Boot 菜单 7/9（Bootloader；本机实测） | **永久禁止** | 写坏后 UART 可能完全无输出 |
| 启动标志修改（`flag_*`） | **禁止自动执行** | 必须先由日志确认启动选择和失败位置 |
| `saveenv` / NVRAM 写入 | **禁止自动执行** | 需单独 L6 审查与授权 |
| `reset` / NAND 擦写 / rootfs 写入 | **禁止自动执行** | 需单独 L7 审查与授权 |
| TFTP 成功 | 不等于恢复成功 | 只证明文件送达 |

---

## 2. 决策树

### 情况 A：U-Boot 有输出，但内核不启动

判据：出现 U-Boot 菜单或 `Booting System N`，但 uImage CRC 失败、解压失败，或内核早期 panic。

| 子情况 | 观察 | 技术判断 | 允许动作 | 禁止动作 |
|---|---|---|---|---|
| A1 | `Booting System 2` + kernel2 CRC 失败 | U-Boot 可能设置 system 2 failed，下一轮可能尝试 system 1 | 继续只读采集；确认下一轮选择 | 手动改 flag；菜单 2；NAND 写入 |
| A2 | `Booting System 2` + CRC OK + panic/VFS | 失败在 rootfs/内核匹配，不是 CRC；U-Boot 不会因 rootfs 回退 | 记录 panic/UBI/rootfs 证据 | 把 CRC OK 当作可启动；自动改 flag |
| A3 | `Booting System 1` + kernel0/rootfs0 失败 | 可能 system 2 已失败或偏好改变；需确认 kernel0 与原厂 rootfs0 配对 | 只读采集；比对备份 | 覆盖 kernel0；菜单 2 |
| A4 | 两轮 `Boot failure detected on both systems` | 两个系统都未通过 U-Boot 检查 | 保存日志；评估 U 盘/编程器路径 | 反复上电；自动写 Flash |

### 情况 B（2026-11-07 ACTIVE）：U-Boot 正常，Linux 启动但 rootfs 失败

判据：`Starting kernel`/Linux 版本出现，随后 `VFS: Cannot open root device`、`UBI error`、`UBIFS error` 或 panic。

- 这通常说明 **kernel 与 rootfs 不匹配**，而不是 uImage CRC 错误。
- 继续只读采集 `cmdline`、`ubi attach`、`UBIFS`、`mount_root` 的完整输出。
- 不在本阶段写 rootfs0/rootfs1；不自动改启动标志。
- 需要回答：当前内核期望哪个 rootfs？UBI 是否 attach？原厂 rootfs0/rootfs1 是否仍完整？
- **本机实测补充**：System 2 的 kernel1 为 OpenWrt 6.12.112，uImage CRC OK；mtd9 UBI attach 失败（PEB 256 image_seq 不匹配），随后 VFS panic/复位。
- **2026-11-07 L4 补充**：`flag_last_success=1`、两个 failed=0，直接解释 U-Boot 持续选择 System 2；rootfs panic 发生在 U-Boot 交接之后，不会设置 U-Boot 的 failed 标志，因此不会自动回退 System 1。
- **2026-11-07 L5 补充**：initramfs 已成功启动；mtd7 原厂 kernel0 SHA-256 `ab58d7a3…` 与备份一致；mtd8 为 OpenWrt kernel。mtd9 PEB 0/255 image_seq `0x34dfa910`，PEB 256/257 `0x6ea1630a`，UBI 在 PEB 256 处拒绝 attach。故障是 UBI 格式化/写入不完整，不是 kernel CRC。
- **2026-11-07 L7-A 结果**：`sysupgrade -n` 完整格式化 mtd9（940 PEB），创建 rootfs/rootfs_data，写入 kernel；首次启动和断电重启均成功，LAN/SSH/HTTP 正常。OpenWrt 已持久化到 NAND。
- U-Boot 每次启动前对 `0x80000/0x20000` 执行 `ranand_erase`（Config 区域，原因未证实）；不能假设 Config 备份等于当前 NAND 内容，但本次 `printenv` 是当前环境的权威快照。

### 情况 C：内核和 UBI 都正常，用户态失败

判据：UBI attach、UBIFS 挂载成功，但 init/驱动/网络/无线失败或反复重启。

- 这属于用户态问题，优先保留日志和配置，不进入 Flash 写入。
- 记录最后成功阶段与第一失败阶段；不要把 Wi-Fi 消失或黄灯当作 boot loop 证据。
- 可能需要原厂恢复镜像/配置，但必须先确认启动选择与分区状态。

### 情况 D：UART 完全无输出

判据：接线/COM/波特率已复核，60 秒内无任何字节。

| 检查 | 处理 |
|---|---|
| GND 是否共地 | 断电重查 J4-3 通断 |
| CH340 是否 3.3V TTL | 万用表/规格书确认 TX 电平 |
| TX/RX 是否接反 | 第一轮只接 R3G TX → CH340 RXD |
| COM 是否幽灵/错误设备 | `detect_com.ps1`，拔插确认 |
| 波特率/8N1 | 115200 8N1，无流控 |
| 板子是否上电 | 原装 12V，适配器不供电 |

若仍无输出：停止，不反复上电；不得通过 `uart_en` 猜测修复，禁止执行 `saveenv`。

### 情况 E：需要恢复原厂系统

**已知资产与不确定性：**

- kernel0（system 1）与 rootfs0 是原厂系统配对的重要资产；本机 kernel0 未写、rootfs0 未写。
- kernel1 曾被 OpenWrt 覆盖；不能假设 kernel1 与原厂 rootfs1 仍配对。
- U-Boot 只检查 uImage CRC，不检查 rootfs；CRC OK 不代表能启动。
- 启动标志的真实值必须来自 UART 日志/只读查询，不能用猜测替代。

**决策顺序：**

1. 先完成只读日志，确认当前 `Booting System N`、CRC、panic、UBI/rootfs 失败点。
2. 确认 kernel0/rootfs0 的备份完整性与哈希（见 `reports/FINAL_READINESS_MATRIX.md`）。
3. 只在取得本机证据并单独授权后，评估“使用原厂 kernel0 + rootfs0 的恢复可能性”；本文件不提供 Flash 写入命令。
4. 菜单 2 仍 BLOCKED：它可能写两个内核槽并破坏配对；不得作为普通回退。
5. 菜单 7/9（本机实测；旧资料常写作 5/6）永久禁止；不得写 Bootloader。
6. 任何启动标志、`saveenv`、`reset`、NAND 擦写都必须单独 L6/L7 审查；本轮不执行。

---

## 3. 恢复路径技术比较（不构成执行步骤）

| 路径 | 技术范围 | 主要风险 | 当前状态 |
|---|---|---|---|
| 只读启动日志 + L4 `printenv` | 无写入 | 无 | **DONE（2026-11-07）** |
| 菜单 1 RAM 启动 initramfs | SDRAM | 加载失败；用户态行为未实测 | **DONE（2026-11-07）** |
| L7-A：完整 `ubiformat` mtd9 + OpenWrt rootfs | mtd9 | 擦除旧 UBI；需第二份备份 | **DONE（2026-11-07）** |
| L7-B：写回原厂 rootfs0/rootfs1/overlay | mtd9/分区 | 写入范围大、最高风险 | 未使用；备份保留 |
| 从 initramfs 精确写单一分区 | 指定分区 | 分区标签/掉电/镜像不匹配 | L7 未授权；禁止生成命令 |
| 菜单 2 双槽写入 | kernel0+kernel1 | 破坏配对、擦除范围未知 | **BLOCKED；禁止执行** |
| 启动标志/环境修改（例如 System 1 优先） | Config/NVRAM | 选择错误系统、CRC/环境损坏 | **L6 未授权；禁止自动执行** |
| 整片备份/编程器 | 全片 | 最高风险、需拆机 | 仅最后手段，未授权 |

---

## 4. 封版停止条件

- 日志不足 2 轮：停止，不做恢复判断。
- 无法确认 J4 GND/TX 或适配器电平：停止，不接线/不上电。
- L4 已单独授权并完成；**L5（TFTP/菜单 1）、L6（标志/环境）、L7（Flash 写入）仍需各自单独授权**。
- 出现硬件异常（过热/异味/5V TX/CH340 反复掉线）：立即断电并停止；先修复 USB/供电，不强行继续。
- 本轮结束只输出技术分析；不生成可直接执行的 Flash 写入命令。
