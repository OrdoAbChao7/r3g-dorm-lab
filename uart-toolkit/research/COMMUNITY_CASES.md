# COMMUNITY_CASES — 真实案例审查

审查日期：2026-11-04
范围：R3G / 同系列 MT7621 + Ralink U-Boot 的公开恢复记录。
原则：成功案例与失败案例都记录；转载与原创区分；论坛经验不当作官方结论。

---

## 案例总览

| # | 设备 | 场景 | 手段 | 结果 | 技术含量 | 对本机适用性 |
|---|---|---|---|---|---|---|
| C1 | R3G | 安装 OpenWrt 后软砖 | UART + TFTP 选项 2 + U 盘 | **成功** | 中（有 TFTP 失败日志） | 流程可参考；选项 2 必须按双内核写入评估 |
| C2 | R3G | OpenWrt 启动时内核 panic | 仅日志 | 新快照修复 | 高（完整 UART 日志） | 日志判读参考；不是救砖流程 |
| C3 | 小米路由器 3（非 3G） | 刷机失败 | TTL + U-Boot | **成功** | 高（明确选项 2 双写、恢复模式原理） | 机制可类比；偏移与型号不能照搬 |
| C4 | 小米路由器 3 | 同上（原帖+回复） | TTL | 多人成功/一人彻底砖 | 高（含回复者实测） | 机制参考；回复还暴露 Bootloader 写坏的风险 |
| C5 | 小米路由器 3 | 转载 C3 | TTL | — | 低（与 C3 同文） | 只作旁证，不作为独立案例 |
| C6 | R3G | Bootloader 已死/整片损坏 | Teensy++ NAND 编程器整片克隆 | 声称成功 | 高（硬件级） | **当前不适用**（本机 Bootloader 尚存） |
| C7 | R3G v1 + Breed 1.2 | Breed 找不到 kernel1 标签 | Breed telnet 手动 flash | 未闭合 | 中 | 不适用（本机无 Breed），但证实标签变化 |
| C8 | 本机 R3G v1 | kernel1 被 OpenWrt 覆盖 | — | 失败/待诊断 | 高（本机实测证据） | 当前对象 |

---

## C1 — OpenWrt Forum: Debricking Xiaomi R3G（2018-11-13）

来源：https://forum.openwrt.org/t/debricking-xiaomi-r3g/25073
本地：`research/sources/forum_25073.json`

### 经过

1. 用户按第三方教程给 R3G 安装 OpenWrt，过程中“mess it up”，设备软砖。
2. 已能通过 USB-TTL 进入 U-Boot 菜单，并在电脑上起 TFTP。
3. 失败日志（原文）：

```text
GOT ARP REPLY, ser server/gtwy eth addr (xx:xx:xx:xx:xx:xx)
Got ARP REQUEST, return our IP.
Loading T T T T T T T T T T
Retry count exceeded, starting again.
```

4. 回复者指出：timeout 表示 TFTP 服务器没有真正提供该文件，检查文件名和工作目录。
5. 最终解决（原文）：

```text
Ok i made It. Un the manual there's no pointing to a very important thing:
you must tell the tftp to "send" the file. Finally didn't do It on Linux,
i did It on Windows with Pumpkin as TFTP server, really easy to use,
woked perfect on the first try.
```

### 技术结论

- U-Boot 的 TFTP 客户端需要服务器**主动响应 RRQ**；“服务器已启动”不等于“会在 RRQ 时发送文件”。
- 该用户按 Wiki 的拆砖流程操作（选项 2 刷 `kernel0.bin`，再插 U 盘恢复），最终成功。
- 线程没有给出写入地址、字节数或 U-Boot 完整日志，因此**不能**用它证明选项 2 只写某一分区。

| 项目 | 内容 |
|---|---|
| 结论 | R3G 可通过 UART + TFTP（选项 2）+ U 盘原厂恢复镜像救回 |
| 来源 | OpenWrt Forum 25073 |
| URL | https://forum.openwrt.org/t/debricking-xiaomi-r3g/25073 |
| 设备 | R3G |
| 固件版本 | 未记录（2018 年） |
| U-Boot 版本 | 未记录 |
| 验证程度 | 同型号成功案例（细节有限） |
| 风险 | 选项 2 实际写两个内核分区；TFTP 未真正发送文件时会 timeout；电源中断风险未讨论 |
| 是否可以用于我的设备 | 有条件：仅作为流程参考，执行前需 UART 日志和双内核写入确认 |

---

## C2 — mt76 issue #304: Kernel Panic Xiaomi MIR3G on boot（2019-08）

来源：https://github.com/openwrt/mt76/issues/304
本地：`research/sources/mt76_issue_304_body.txt`

### 日志要点（原文）

- `U-Boot 1.1.3 (Jul 14 2017 - 15:16:26)`、`Ralink UBoot Version: 5.0.0.0`
- NAND：`128 MiB ESMT SLC NAND`，`NAND ID [C8 D1 80 95 40]`
- `Booting System 2`
- `Verifying Checksum ... OK`
- `Uncompressing Kernel Image ... OK`
- `Linux version 4.14.132`，OpenWrt `r10571-1282a63027`
- `ubi0: attached mtd9 (name "ubi", size 117 MiB)`
- `ubi0: good PEBs: 940, bad PEBs: 0, corrupted PEBs: 0`
- `UBIFS (ubi0:1): recovery needed` → `recovery completed`
- panic：

```text
CPU 2 Unable to handle kernel paging request at virtual address fffffff0
epc : 8f2835c8 mt76_eeprom_override+0x38/0xdc [mt76]
Kernel panic - not syncing: Fatal exception
Rebooting in 1 seconds..
```

- 结论：不是 UBI/UBIFS 挂载失败，而是 mt76 无线驱动在 `mt76_eeprom_override` 中崩溃；后续快照修复。

### 技术结论

- 该日志给出了 R3G 正常启动时 U-Boot → 内核 → UBI → UBIFS 的完整顺序，可作为日志判读模板。
- 它证明“能挂载 UBI/UBIFS”与“系统能启动”是两件事；panic 可能发生在驱动初始化阶段。
- 与本案不同：本案是内核/rootfs 不匹配，不是驱动 bug。

| 项目 | 内容 |
|---|---|
| 结论 | R3G 启动日志中 `Booting System 2` → CRC OK → UBI attach → UBIFS recovery → 驱动初始化，任一阶段都可能失败 |
| 来源 | GitHub openwrt/mt76 issue #304 |
| URL | https://github.com/openwrt/mt76/issues/304 |
| 设备 | R3G（MIR3G） |
| 固件版本 | OpenWrt snapshot r10571，Linux 4.14.132（2019-07） |
| U-Boot 版本 | 1.1.3 / Ralink 5.0.0.0 |
| 验证程度 | 同型号真实日志（失败案例，已修复） |
| 风险 | 旧快照的驱动 bug 不代表当前 25.12.6；不能据此降级或替换驱动 |
| 是否可以用于我的设备 | 是（仅用于日志判读，不用于选择固件） |

---

## C3 — ysc3839：小米路由器 3 U-Boot TTL 恢复（2018-03-05）

来源：https://blog.ysc3839.com/post/miwifi-r3-ttl-recovery.html
本地：`research/sources/ysc3839_blog.txt`

> 注意：标题是“小米路由器 3”（MIR3，非 3G）。作者在讲启动标志时写明“这里针对的是小米路由器 3G，不过实测是一样的”。因此它是**同系列机制证据**，不是 R3G 的偏移表。

### 关键技术点（原文）

1. 默认 TTL 不可输入，需要：

```text
// 历史记录；禁止执行
nvram set boot_wait=on
nvram set uart_en=1
nvram commit
```

OpenWrt 下的历史记录：`fw_setenv boot_wait on` / `fw_setenv uart_en 1`；本文件不提供执行步骤，禁止执行。

2. 菜单（该机）：

```text
1: Load system code to SDRAM via TFTP.
2: Load system code then write to Flash via TFTP.
3: Boot system code via Flash (default).
4: Entr boot command line interface.
9: Load Boot Loader code then write to Flash via TFTP.
```

3. 选项 2 的行为（原文）：

> U-Boot 会先把下载来的数据写到闪存的 0x200000 位置 (也就是 kernel0)，再把数据写到 0x600000 位置 (kernel1)。这样的话，就变成了 kernel0 和 kernel1 数据是相同的。不能实现 kernel0 和 kernel1 写入不同的数据。

4. 历史记录：曾有方案将 kernel 补齐到 4 MiB（0xFF 填充），后接 rootfs，`cat` 成一个文件后用选项 2 刷入；本文件不提供执行步骤，禁止照抄。
5. 小米官方恢复模式是**原厂内核 initramfs 的功能**，不是 U-Boot 的功能；没有原厂内核就没有 U 盘恢复。
6. 进入恢复模式的条件：`flag_try_sys1_failed`、`flag_try_sys2_failed` 都为 1。可在 U-Boot 菜单 4 中：

```text
// 历史记录；禁止照抄执行
setenv flag_try_sys1_failed 1
setenv flag_try_sys2_failed 1
saveenv
```

### 技术结论

- “选项 2 双内核写入”有第二个独立来源，且描述与 OpenWrt 官方提交一致。
- 原厂 U 盘恢复依赖原厂内核；这与本机“kernel0 未写、kernel1 被覆盖”的状态直接相关。
- 文章中的分区偏移是 MIR3 的，不是 R3G 的（例如 Bootloader 结束于 0x40000，而 R3G 是 0x80000）。**禁止照抄偏移**。

| 项目 | 内容 |
|---|---|
| 结论 | 选项 2 将同一份数据写入 0x200000 与 0x600000；原厂 U 盘恢复由原厂内核 initramfs 提供 |
| 来源 | ysc3839 博客 / 恩山原帖 |
| URL | https://blog.ysc3839.com/post/miwifi-r3-ttl-recovery.html |
| 设备 | 小米路由器 3（非 3G）；启动标志段作者称对 3G 实测一致 |
| 固件版本 | 2018 原厂 |
| U-Boot 版本 | Ralink 5.0.0.0 系列 |
| 验证程度 | 同系列实测 + 与 R3G 官方提交相互印证 |
| 风险 | 偏移/菜单编号与本机不同；原厂内核被覆盖后 U 盘恢复失效 |
| 是否可以用于我的设备 | 有条件：机制可用，偏移与菜单必须以本机 `Bootloader.bin`/屏幕为准 |

---

## C4 — 恩山原帖与回复（2018-03-05 至 2019-12）

来源：https://www.right.com.cn/forum/thread-308330-1-1.html
本地：`research/sources/right_308330.html.txt`

补充信息（C3 之外的回复）：

- 9 楼用户：“我的 boot 就还在，直接 TTL 修复了 kernel。我的小米3 活了。”——同系列成功。
- 7/8 楼用户：接线成功后设备“彻底砖”，TTL 无输出，怀疑 bootloader 掉了——说明在 Bootloader 层操作失误的后果。
- 12 楼 fyi2000 给出更细的 U-Boot 环境存储信息：

```text
Padavan的BootEnv分区包含官方的Config+Bdata分区，
u-boot变量存放于Config前0x1000字节，最前面是个Little Endian CRC32
```

- 同楼给出 OpenWrt 下的 `fw_setenv` 批量设置历史示例（禁止执行），以及“官方固件/Padavan 不锁分区，OpenWrt/PandoraBox 只能改包含固件的分区”的提醒。

### 技术结论

- U-Boot 环境位于 Config 分区**前 0x1000 字节**，带 Little-Endian CRC32；这与 OpenWrt 提交中的 `ubootenv_add_uci_config "/dev/mtd1" "0x0" "0x1000" "0x20000"` 完全一致。
- 修改环境（saveenv/fw_setenv）是真实的 NVRAM 写入，不是“只是变量”。
- Bootloader 层操作失败会导致 TTL 完全无输出，恢复只能上编程器。

| 项目 | 内容 |
|---|---|
| 结论 | U-Boot 环境在 Config 分区偏移 0、长度 0x1000、扇区 0x20000；错误写 Bootloader 会导致无串口输出 |
| 来源 | 恩山回复（fyi2000）+ OpenWrt 提交 |
| URL | https://www.right.com.cn/forum/thread-308330-1-1.html |
| 设备 | 小米路由器 3 / R3G 通用环境布局 |
| 固件版本 | 原厂/Padavan/OpenWrt |
| U-Boot 版本 | Ralink 5.0.0.0 |
| 验证程度 | 同系列实测 + 官方源码一致 |
| 风险 | `saveenv`/`fw_setenv` 写 Config；写错 Bootloader 不可用 UART 恢复 |
| 是否可以用于我的设备 | 是（用于理解环境位置）；写操作仍需单独授权 |

---

## C5 — ksite/MrK 转载（2018-03-05）

来源：https://www.ksite.cn/contents/mirouter-r3-ttl-rec.html
本地：`research/sources/ksite_mrk.html.txt`

- 页面开头即声明“本文于 3157 天之前发表，文中内容可能已经过时”。
- 正文与 C3 基本同文；末尾注明 `copy from https://blog.ysc3839.com/... and https://www.right.com.cn/forum/thread-308330-1-1.html`。
- 其给出的分区表与 R3G 实际不符（Bootloader 0x0–0x40000），再次证明它面向的是小米路由器 3，而非 R3G。
- 结论：**不作为独立证据**，只作为 C3 的转载旁证。

---

## C6 — jesusvallejo/MIR3G_RECOVERY（2019 建库，最后提交 2019-09-07）

来源：https://github.com/jesusvallejo/MIR3G_RECOVERY
本地：`research/sources/gh_MIR3G_RECOVERY_README.md`

### 方法

- 仅适用于 **Mi Router 3G（Gigabit，带 USB）**；README 明确警告不要用于 Mi Router 3。
- 使用 Teensy++ 2.0 + NORway/NANDway + TSOP48 适配器（或 360 Clip）直接读写 NAND。
- 写入一个“fullNandClone”整片镜像（来自另一台正常 R3G），约 30 分钟。
- 警告：
  - NAND 有坏块，128 MiB 芯片实际有 138 MB 地址空间，坏块由 Bootloader 做物理/虚拟地址映射；整片镜像中的坏块位置若与目标芯片不同，可能无法启动。
  - 需要拆焊 TSOP48 或使用免拆夹；容易撕裂焊盘。
  - 刷入他人镜像会得到**别人的 MAC/名称**；需要再刷 Breed 修改参数。
- 依赖：NORway、WAY-launchers、Python 2.7/pyserial 2.5 等老工具。

### 技术结论

- 这是“Bootloader 已死 / 整片 NAND 损坏”的最后手段，不是本阶段的选项。
- 它反证了：只要 Bootloader 还在，就不应该先动 NAND 芯片。
- 本机 Bootloader 备份完好（`bf3cc484…`），且 U-Boot 大概率仍可运行（症状符合 boot loop，而非无输出）。

| 项目 | 内容 |
|---|---|
| 结论 | 硬件 NAND 编程器整片克隆只适用于 Bootloader 已死或 NAND 损坏；会改变 MAC/校准数据，坏块映射可能不兼容 |
| 来源 | GitHub MIR3G_RECOVERY |
| URL | https://github.com/jesusvallejo/MIR3G_RECOVERY |
| 设备 | R3G（Gigabit） |
| 固件版本 | 原厂整片克隆 |
| U-Boot 版本 | 取决于镜像 |
| 验证程度 | 作者声称成功；无独立复现记录 |
| 风险 | 拆焊损坏、坏块映射不兼容、MAC/无线校准被替换、老工具链 |
| 是否可以用于我的设备 | 否（当前阶段）；仅作为 Bootloader 死亡后的最后手段 |

---

## C7 — hackpascal issue #5：R3G v1 + Breed 1.2（2022-08）

来源：https://github.com/hackpascal/mt7621-boot-spi-nand/issues/5
本地：`research/sources/gh_issue_5_body.txt`

### 内容要点

- 设备：小米路由器 3G v1；OpenWrt 22.03（2022-08-14 自编译）。
- 现象：Breed 1.2 找不到 “kernel1” 标签，autoboot 报 `Unable to locate firmware`。
- 原因：OpenWrt 22.03 起 DTS 把 0x200000 命名为 `kernel_stock`，0x600000 命名为 `kernel`；Breed 仍按旧标签 `kernel1` 查找。
- 用户用 Breed telnet 手动执行 `flash erase/write 0x200000` 与 `0x600000`，并修改固件内 label 才启动。

### 技术结论

- 再次确认两个内核槽的物理地址是 0x200000 与 0x600000。
- 证实 OpenWrt 现代版本的标签已从 kernel1 改为 kernel；**在 OpenWrt 用户态不能照抄 `mtd write ... kernel1`**。
- 本机没有 Breed，不适用其手动 flash 命令；但标签变化对本项目安装后的操作有直接警示。

| 项目 | 内容 |
|---|---|
| 结论 | OpenWrt 22.03+ 的 0x600000 分区标签是 `kernel`，不再是 `kernel1`；Breed 按旧标签会启动失败 |
| 来源 | hackpascal issue #5 |
| URL | https://github.com/hackpascal/mt7621-boot-spi-nand/issues/5 |
| 设备 | R3G v1（Breed 1.2） |
| 固件版本 | OpenWrt 22.03 自编译 |
| U-Boot 版本 | Breed 1.2（非原厂） |
| 验证程度 | 同型号用户报告（未闭合 issue） |
| 风险 | 在 OpenWrt 里用旧标签写分区会失败或写错；Breed 非本机环境 |
| 是否可以用于我的设备 | 有条件：仅用于理解标签变化；本机原厂阶段仍使用 kernel1/rootfs0 |

---

## C8 — 本机 R3G v1（2026-11-04）

- 写入前：`flag_last_success=1`、`flag_try_sys1_failed=0`、`flag_try_sys2_failed=0`。
- 按官方语义，U-Boot 会偏好 **system 2（kernel1 @0x600000）**。
- 原厂 kernel1 构建时间 2019-04-03，与正在运行的 2.28.24 内核构建时间一致；kernel0 是 2018-11-09。
- 已执行：`mtd write ...kernel1`（成功）、`mtd verify`（成功）；未写 rootfs0、未改 NVRAM、未主动 reboot。
- 之后设备不可达，症状符合 boot loop。
- 推断（待 UART 证实）：system 2 的 uImage CRC 合法（OpenWrt 内核），U-Boot 不会置 `flag_try_sys2_failed`，会持续启动 system 2；OpenWrt 内核 + 原厂 rootfs 不匹配 → panic/复位循环。

| 项目 | 内容 |
|---|---|
| 结论 | 覆盖“当前活动系统”的 kernel1 会破坏下次启动，且 U-Boot 不会因“内核能解压但 rootfs 不匹配”而回退 |
| 来源 | 本机备份、写入日志、官方启动逻辑 |
| URL | 本地证据 |
| 设备 | R3G v1 |
| 固件版本 | 原厂 2.28.24 → kernel1 被 25.12.6 覆盖 |
| U-Boot 版本 | 5.0.0.0（2018-11-09） |
| 验证程度 | 写入/哈希/分区为实测；启动行为为强推断，待 UART |
| 风险 | 继续盲目写入可能同时破坏两个系统 |
| 是否可以用于我的设备 | 是（本案本身） |

---

## 失败案例共同教训

1. **只写一个内核、不写匹配的 rootfs、不设标志**，是典型的“半安装”状态；U-Boot 的双系统回退只检查 uImage CRC，不检查 rootfs 是否匹配。
2. **选项 2 是双内核写入**；把它当“只写 kernel1”会破坏原厂内核。
3. **原厂 U 盘恢复依赖原厂内核 initramfs**；原厂内核被覆盖后，U 盘恢复不再可用。
4. **TFTP 服务器必须真正响应 RRQ**；只启动服务不够。
5. **Bootloader 层操作没有 UART 回退**；任何写 Bootloader 的菜单项都不应触碰。
