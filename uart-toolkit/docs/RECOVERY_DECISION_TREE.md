# RECOVERY_DECISION_TREE — 基于 UART 日志的恢复决策树

生成日期：2026-11-04
适用：R3G v1，原厂 U-Boot 5.0.0.0，当前 kernel1 被 OpenWrt 25.12.6 覆盖、rootfs 未写。
使用前提：已完成 `START_HERE.md` 第 4 节的只读启动日志抓取。

> 本文件不授权任何 L3+ 操作。每一分支都标注了所需证据、动作等级、风险与回滚。
> **没有日志证据，不进入下一步。**

> **第三轮流程边界**
> TFTP 传输成功只证明文件已送达，不等于 NAND 恢复成功；不得把 TFTP 成功描述为 Flash 恢复完成。
> - 选项 1：只作为 **RAM 临时加载候选**；不得描述为整个 initramfs 会话绝对只读。
> - 选项 2：继续 **BLOCKED**，不是回退方案。
> - 选项 7/9（本机实测）：**永久禁止**。
> - 任何 Flash/NVRAM 写入都必须单独审查并获得新的明确授权。

---

## 0. 先填观察表

从 `r3g_uart_*.log` 中抄下：

| 观察项 | 你的值 |
|---|---|
| U-Boot 版本 / Ralink 版本 | |
| 是否出现菜单 | |
| `Booting System N` | |
| `Verifying kernelN uImage CRC` 结果 | |
| 内核是否启动（`Starting kernel` / `Linux version`） | |
| cmdline（`console=`、`root=`、`ubi.mtd=`） | |
| UBI attach 的 mtd 编号与 PEB 数 | |
| UBIFS 挂载结果 | |
| panic / VFS 错误 | |
| `Rebooting in ...` / watchdog | |
| 是否重复循环（几轮） | |
| `printenv` 中的 `flag_try_sys1_failed` / `flag_try_sys2_failed` / `flag_last_success`（若已进 CLI） | |

---

## 1. 全局前置条件

- [ ] 已确认板子是 R3G v1（USB 3.0、128 MiB NAND）
- [ ] 已确认 J4 丝印并复核 3.3V / GND
- [ ] 串口只读日志至少 1 轮完整；最好 2–3 轮
- [ ] 已保存 `.bin` + `.log` + `.meta.json`
- [ ] 已运行 `uart_analyze.py`，但**未**据此自动执行任何写入
- [ ] 整片备份与分区哈希已通过 `verify_firmware.ps1 -VerifyBackups`
- [ ] 已获得对应等级的单独授权

---

## 情况 A：U-Boot 正常，内核无法启动

### A1. 判据

日志中出现 U-Boot 菜单/`Booting System N`，但：

- `Verifying kernelN uImage CRC` 失败（`Bad Magic Number` / `Bad Header Checksum` / `Bad Data CRC`）；或
- CRC 通过，但 `Uncompressing Kernel Image` 失败；或
- 内核启动后很快 panic，未见 UBI attach。

### A2. 先判断是哪一个系统

- 若 `Booting System 2` + `kernel2 uImage CRC` 失败：
  - U-Boot 应已设置 `flag_try_sys2_failed=1`，下一次可能改启动 system 1。
  - 观察下一轮是否出现 `Booting System 1`。
- 若 `Booting System 2` + CRC 通过 + 内核 panic：
  - 这不是 CRC 失败，U-Boot 不会回退；问题在 rootfs/内核匹配（转到情况 B）。
- 若 `Booting System 1`：
  - 说明 system 2 已被标记失败或偏好改变；重点看 kernel0/rootfs0 的匹配。

### A3. 候选动作（按风险从低到高）

| 动作 | 等级 | 前提 | 风险 | 回滚 |
|---|---|---|---|---|
| 仅记录，不写入 | L3 | 无 | 无 | — |
| 选项 1 启动 OpenWrt initramfs | L5 | TFTP 可达；initramfs 哈希通过 | 加载/启动失败；加载阶段按设计不写 NAND（用户态需实测） | 断电重启 |
| 选项 1 启动原厂 kernel1.bin | L5 | 同上；使用 2019 原厂内核 | 原厂系统启动可能写 overlay/NVRAM；匹配性未知 | 断电重启 |
| 从 initramfs 精确写回原厂 kernel1 | L7 | 情况 D 成功；分区标签已确认 | 写错分区/掉电 | 用备份重写；最坏上编程器 |
| 选项 2 写 4 MiB 原厂内核 | L7 | **BLOCKED**：本机未实测其擦除范围、单次写入长度、坏块处理与两槽写入顺序 | 双槽写入；可能覆盖 kernel0；中断即双槽损坏 | 只能再写或上编程器 |

> 选项 2 不是“只写 kernel1”，也**不是普通回退方案**。在未获得本机实测证据前，它保持 **BLOCKED**；不得写成“RAM 启动失败就自动用菜单 2”。见 `research/TFTP_RECOVERY_ANALYSIS.md`。

---

## 情况 B：内核正常，rootfs 无法挂载

### B1. 判据

日志中有：

- `Starting kernel ...`、`Linux version ...`；
- 但出现 `VFS: Cannot open root device`、`Unable to mount root fs`、`UBI error`、`UBIFS error`、`mount_root` 失败；
- 或 `Kernel panic - not syncing: VFS: Unable to mount root fs`。

### B2. 关键区分

| 现象 | 含义 | 处理 |
|---|---|---|
| `ubi0: attached mtdN` 成功，`good PEBs` 正常，但 UBIFS 失败 | UBI 卷/文件系统损坏或与内核不匹配 | 记录完整 UBI/UBIFS 错误；考虑从备份恢复 rootfs |
| `ubi0: cannot attach` / `bad PEBs` 很多 | UBI 区损坏/坏块 | 不要反复擦写；需要 initramfs 下 `ubinfo`/`dmesg` 评估 |
| 内核是 OpenWrt 6.12，rootfs 是原厂 | 典型“半安装”组合 | 目标明确：要么补写 OpenWrt rootfs0，要么恢复原厂内核 |
| 内核是原厂 3.10，rootfs 是 OpenWrt | 不应发生（rootfs0 未写） | 检查是否有人写过 rootfs |

### B3. 候选动作

- 若目标是**恢复原厂**：优先让 system 2 重新使用原厂内核（情况 A/E），而不是先动 rootfs。
- 若目标是**完成 OpenWrt 安装**：进入情况 F，写 `rootfs0`（5,636,096 B UBI），并确保 `flag_try_sys1_failed=1`。
- 任何 rootfs 写入都是 L7；写前必须再次校验镜像哈希与目标分区标签。
- 回滚：原厂 rootfs0/rootfs1/overlay 的备份在 `parts/`；恢复它们需要整片或分区写入，风险高。

---

## 情况 C：U-Boot 双系统均无法正常启动

### C1. 判据

- 日志出现 `Boot failure detected on both systems`；或
- 反复 `Booting System 1` / `Booting System 2`，两者 CRC 都失败；或
- 两个系统都进入 panic，且无法进入用户态。

### C2. 处理顺序

1. **不要改标志**。两个 failed 可能已经都是 1；再改只会增加变量。
2. 用选项 1 启动 OpenWrt initramfs（L5），进入 RAM 系统。
3. 在 initramfs 中只读采集：
   - `cat /proc/mtd`
   - `ubinfo -a`
   - `dmesg | tail -200`
   - `fw_printenv`（若镜像含 uboot-envtools）
   - 对 kernel0/kernel1 做只读校验（若工具可用）
4. 依据采集结果决定：
   - 若 NAND 可读、UBI 可 attach：优先精确写回原厂 kernel1（L7）。
   - 若 UBI 损坏：评估是否写回 rootfs0/rootfs1/overlay（L7，高风险）。
   - 若 NAND 大量坏块/读错误：停止软件恢复，考虑编程器（L8，本阶段禁止）。

### C3. 禁止

- 不要用选项 2 反复试不同镜像。
- 不要 `nand erase` 整片。
- 不要写 Bootloader。

---

## 情况 D：TFTP 临时启动成功

### D0. TFTP 传输参数边界

- 客户端未请求 `blksize`：服务端始终按 RFC 1350 使用 512 字节，即使 `--max-block` 更大。
- 客户端请求 8–65464：协商值 = `min(客户端请求, --max-block)`；`--max-block` 默认 512。
- 请求 0/1/7/65465 等非法值：返回 ERROR 8（Option negotiation failed），不得自动截断为合法值。
- 旧参数 `--block` 已移除；出现即拒绝启动。以上只影响传输层，不改变任何 Flash 风险等级。

### D1. 判据

- 选项 1 加载完成，出现 `Starting kernel ...`；
- OpenWrt initramfs 或原厂内核进入用户态；
- 串口出现 shell/登录提示，或网络可用。

### D2. 这是最好的诊断窗口

在 RAM 系统中只读采集并保存：

```text
cat /proc/mtd
cat /proc/cmdline
ubinfo -a
dmesg
fw_printenv            # 若可用
cat /etc/fw_env.config # 若可用
```

要回答：

- [ ] 当前内核看到的 `kernel_stock`/`kernel`/`ubi` 标签与偏移
- [ ] UBI 是否 attach、PEB 好坏、卷状态
- [ ] `flag_try_sys1_failed` / `flag_try_sys2_failed` / `flag_last_success` 的真实值
- [ ] NAND 是否有读错误/坏块

### D3. 之后的选择

| 目标 | 动作 | 等级 |
|---|---|---|
| 恢复原厂 | 从 RAM 系统精确写回 `parts/kernel1.bin` 到 0x600000 对应分区 | L7 |
| 恢复原厂（更彻底） | 写回 rootfs0/rootfs1/overlay 备份 | L7，高风险 |
| 安装 OpenWrt | 写 kernel1 + rootfs0 + 设置标志 | L7 + L6 |
| 仅诊断 | 不写，导出日志 | L3/L5 |

> 在 RAM 系统中写 NAND 前，必须再次确认 `/proc/mtd` 的标签与本次会话一致；不同内核版本的编号可能不同。

### D4. initramfs 启动后会不会自动挂载 UBI / overlay？

必须区分四个阶段，不能把整个 initramfs 会话笼统称为“绝对只读”：

1. **U-Boot 把镜像加载到 SDRAM**：按选项 1 的设计不写 NAND。
2. **内核启动**：内核会解析 `bootargs`；如果 cmdline 含 `ubi.mtd=` 等参数，内核可能 attach UBI。是否会这样，取决于 U-Boot 传给它的实际 cmdline，本机 **UNVERIFIED**。
3. **initramfs 用户态启动**：OpenWrt 25.12 源码提供了明确证据：
   - `70_initramfs_test`：当 `$INITRAMFS` 非空时，运行 `initramfs` hook、撤销 preinit 网络配置并 `break` 出 `preinit_main`。
   - `80_mount_root`：只有在 `$INITRAMFS != 1` 时才注册 `do_mount_root`。
   - 因此**正常 preinit 路径不会自动执行 mount_root，不会自动挂载 NAND 上的 rootfs/overlay**。
4. **手动操作/服务写入**：一旦你在 initramfs 中运行 `mtd`、`ubiformat`、`mount`、`sysupgrade` 等命令，就可能写 NAND；这不是自动行为，但也不能说“绝对只读”。

结论：

- “U-Boot 选项 1 不写 NAND”和“initramfs 会话绝对只读”是两件事。
- 源码支持“initramfs 模式跳过 mount_root”；但内核是否因 cmdline 自动 attach UBI、以及你手动执行什么，仍需以本机日志和操作记录为准。
- 上机后只读检查：`cat /proc/cmdline`、`dmesg | grep -i ubi`、`ubinfo -a`、`mount`。若 UBI 已 attach，只读命令仍不会写；不要执行 `ubiformat`/`mtd write`。
- 该结论的证据文件：`research/sources/openwrt_preinit_70_initramfs_test.sh`、`openwrt_preinit_80_mount_root.sh`（OpenWrt `openwrt-25.12` 分支）。

---

## 情况 E：需要恢复原厂系统

### E1. 最小写入原则

优先保护：

```text
Bootloader 0x000000
Config     0x080000   （saveenv 属 NVRAM 写入，需单独授权；此处不是操作步骤）
Bdata      0x0C0000
Factory    0x100000
reserved0  0x1C0000
kernel0    0x200000   （本机未写，尽量保留）
```

### E2. 方案排序（技术审查，不构成操作步骤）

| 方案 | 写入范围 | 前提 | 风险 | 证据等级 |
|---|---|---|---|---|
| E-A：选项 1 启动原厂 kernel1 | 无（RAM） | 内核/rootfs 匹配 | 原厂系统可能写 overlay/NVRAM | 未实测 |
| E-B：从 initramfs 精确写 kernel1 | 0x600000 一个槽 | 情况 D 成功；分区确认 | 写错/掉电 | 未实测 |
| E-C：选项 2 写 4 MiB 原厂内核 | 0x200000 + 0x600000 | **BLOCKED**：本机未实测擦除范围/写入长度/坏块处理 | 双槽写入；可能覆盖 kernel0；中断双损 | 官方+同系列，但本机未实测 |
| E-D：设置两个 failed=1 进 U 盘恢复 | Config（NVRAM） | 原厂内核在任一槽；U 盘镜像可被接受；配对关系明确 | 标志写入；2.28.46 兼容性未验证 | 同系列+官方 |
| E-E：整片备份恢复 | 全片 | 编程器/特殊流程 | 最高 | 仅最后手段 |

### E3. 推荐决策

1. 若情况 D 成功：选 **E-B**（单槽精确写回），这是范围最小、最可控的方案。
2. 若无法 RAM 启动但 U-Boot 正常：**保持 E-C 为 BLOCKED**。先用选项 1 启动 initramfs 或原厂内核做诊断；不得把菜单 2 当作自动回退。只有在取得本机实测证据并单独授权后，才重新评估 E-C。
3. 只有在 NAND 无法读取/UBI 严重损坏时，才考虑 E-E。

### E4. U 盘恢复注意

- 官方恢复依赖原厂内核 initramfs；本机 kernel0 未写，理论保留该能力。
- 需要两个 failed 标志为 1（同系列实测）；这是 NVRAM 写入，需 L6 授权。
- 本地 `miwifi_...2.28.46.bin` 比原机 2.28.24 新；恢复内核是否接受未验证。
- 两次 USB 尝试已失败，第三次前必须先查明原因（UART 日志/恢复模式是否真正进入）。

### E5. 原厂内核与 rootfs 的配对关系（不得跨版本假设）

OpenWrt DTS 注释明确写：

- `rootfs0` = “rootfs partition for stock kernel0” → **kernel0 与 rootfs0 配对（system 1）**
- `rootfs1` = “rootfs partition for stock failsafe kernel1” → **kernel1 与 rootfs1 配对（system 2）**

因此：

- 不能假设“任意版本的原厂内核都能挂载任意一个原厂 rootfs”。
- 本机 kernel1 原厂镜像是 2019-04-03，rootfs1 是同一时期的状态；两者才是一对。
- 用 kernel0（2018）去启动 rootfs1，或用 kernel1（2019）去启动 rootfs0，都**未被验证**。
- 技术分析（不构成操作步骤）：选项 2 会把同一份内核写到两个槽；如果使用 `kernel1.bin`，system 1 就变成“2019 内核 + rootfs0（2018）”，配对关系被打破。这正是不能把选项 2 当普通回退的原因之一。

### E6. 原厂双系统布局 vs OpenWrt UBI 合并布局

| 布局 | 内核槽 | rootfs 区域 | 说明 |
|---|---|---|---|
| 原厂 | kernel0 / kernel1 | rootfs0 + rootfs1 + overlay 三个独立分区 | 两套系统各自配对；overlay 独立 |
| OpenWrt | kernel_stock / kernel | 单个 `ubi`（0xA00000，0x7580000） | 把 rootfs0+rootfs1+overlay 合并成一个 UBI 容器 |

- OpenWrt 的 `ubi` 覆盖了原厂三个分区；一旦写入 OpenWrt rootfs0，原厂 rootfs0/rootfs1/overlay 的内容就不再完整。
- 在原厂布局下，写 kernel1 不应影响 rootfs0；但写 OpenWrt rootfs0 会覆盖整个合并区域。
- 两种布局的 `mtd` 编号/标签完全不同，禁止混用。

---

## 情况 F：准备安装 OpenWrt

### F1. 前置条件

- [ ] 已有一个可运行的原厂系统（NAND 启动或 RAM 启动）
- [ ] `kernel1` 与 `rootfs0` 哈希通过（`verify_firmware.ps1`）
- [ ] 已确认当前 `/proc/mtd` 标签：原厂阶段是 `kernel1`/`rootfs0`
- [ ] 整片备份 + 分区备份已校验，且至少有两份物理介质
- [ ] 已获得 L6（NVRAM）与 L7（NAND）授权

### F2. 官方步骤（原厂系统内）

```text
// 历史记录；禁止执行
mtd write openwrt-25.12.6-...-squashfs-kernel1.bin kernel1
mtd write openwrt-25.12.6-...-squashfs-rootfs0.bin rootfs0
nvram set flag_try_sys1_failed=1
nvram commit
reboot
```

每一步单独执行、单独确认输出；不要一次粘贴全部。

### F3. 写入边界

| 目标 | 偏移 | 大小 | 镜像大小 | 余量 |
|---|---:|---:|---:|---:|
| kernel1 | 0x600000 | 4 MiB | 3,331,950 | 862,354 B |
| rootfs0 | 0xA00000 | 32 MiB | 5,636,096 | 27,918,336 B |

### F4. 失败回滚

| 失败点 | 状态 | 回滚 |
|---|---|---|
| kernel1 写入失败 | 原厂 system 2 可能被破坏 | 从备份写回 kernel1（L7） |
| rootfs0 写到一半 | 原厂 rootfs 可能损坏 | UART + initramfs/备份；不能依赖 Web 恢复 |
| 设置标志后 OpenWrt 不启动 | 两个系统都可能不可用 | UART + 选项 1 initramfs；按情况 C/D 处理 |

### F5. 安装后

- LAN 默认 `192.168.1.1`，无密码；无线默认关闭。
- 立即检查 `/proc/mtd`：标签已变为 `kernel_stock`/`kernel`/`ubi`。
- 立即重新做一次整片备份，并复制到第二块物理磁盘。

---

## 2. 停止条件（任何情况）

出现任一情况立即停止，不再尝试：

1. 串口乱码/无输出超过 60 秒；
2. `printenv` 显示环境损坏（大量乱码/默认值）；
3. 写入地址与预期不符；
4. TFTP 传输字节数不足；
5. 写入过程中断电/重启；
6. 日志出现 NAND 读错误、坏块激增、ECC 不可纠正；
7. 设备发热/异味/反复掉 USB。

---

## 3. 证据状态表

| 结论/动作 | 证据 | 状态 |
|---|---|---|
| 双系统地址 0x200000/0x600000 | OpenWrt 提交 + DTS + 本机备份 | 已证实 |
| 三标志选择算法 | OpenWrt 提交 | 已证实 |
| 选项 2 写两个内核槽 | OpenWrt 提交 + 同系列实测 | 已证实（未在本机实测） |
| 选项 1 加载阶段不写 NAND | 官方描述 + 菜单字符串 | 高置信，未实测；不等于整个会话只读 |
| 原厂 U 盘恢复依赖原厂内核 | 同系列实测 + 官方流程 | 已证实 |
| 本机活动系统是 system 2 | 构建时间 + 标志值推断 | **待 UART 证实** |
| 25.12.6 在本机可启动 | 无 | **未验证** |
| 2.28.46 可被恢复内核接受 | 无 | **未验证** |
| 选项 1 启动原厂内核可挂载 rootfs | 无 | **未验证** |

---

## 4. 一句话原则

**先用 UART 看清发生了什么，再用最小写入范围修复；任何“双槽写入”都必须当作高风险操作单独授权。**
