# STOCK_RESTORE_AND_OPENWRT_INSTALL — 原厂恢复与 OpenWrt 安装预案

> TFTP 传输成功只证明文件已送达，不等于 NAND 恢复成功；任何 Flash 写入都必须单独审查与授权。

日期：2026-11-04
状态：**全部为未来授权项，未执行。**
所有数值来自官方提交、25.12.6 发布清单与本机备份。

---

## 0. 决策入口

先完成 UART 只读日志，并按 `RECOVERY_DECISION_TREE.md` 判断：

- 只想恢复原厂 → 走 A 或 B。
- 想最终安装 OpenWrt → 先恢复一个可运行的原厂系统，再走 C。
- 不要在同一轮里同时尝试“恢复原厂”和“安装 OpenWrt”。

---

## A. 方案 A：选项 1 启动原厂内核（RAM；加载阶段不写 NAND，用户态行为需实测）

### A1. 前提

- U-Boot 菜单可见，能进入选项 1。
- TFTP 可达（电脑 `192.168.31.100/24`，无网关）。
- 使用 `firmware/tftp_stock/kernel1.bin`（2019 原厂内核，`ab893d6c…`）。
- 已获得 L5 授权。

### A2. 步骤

1. 启动只读 TFTP：

```powershell
python -I ...\scripts\tftp_server.py --root ...\firmware\tftp_stock --bind 192.168.31.100 --port 69 --allow kernel1.bin --expect-sha256 kernel1.bin=ab893d6c0732dcea7f029fd3d7101b844ff9d2b2fc6114b24e908d466e3b6168
```

2. UART 菜单选择 **1**。
3. 输入：
   - device IP：以 `printenv` 的 `ipaddr` 为准（通常 192.168.31.1）
   - server IP：以 `printenv` 的 `serverip` 为准（或电脑实际 IP）
   - filename：`kernel1.bin`
4. 观察 TFTP 日志：应传输 4,194,304 B，SHA-256 匹配。
5. 观察 UART：`## Booting image at ...`、`Starting kernel ...`、内核日志。
6. 若进入原厂用户态：记录网络/SSH 状态；**先不要写任何分区**。

### A3. 风险

- 原厂系统启动可能写 overlay/NVRAM（正常运行时行为）。
- 内核与 rootfs 是否匹配未验证。
- 若启动失败：断电重启，回到 U-Boot；不会写内核槽。

### A4. 成功后的选择

- 从原厂系统（RAM 内核 + NAND rootfs）执行精确的 kernel1 修复（L7）：
  - 需要 root shell（SSH/telnet 或 UART 登录）。
  - 先 `cat /proc/mtd` 确认标签与偏移。
  - 再 `mtd write` 原厂 `kernel1.bin` 到 kernel1（历史技术记录；禁止执行，需 L7 单独授权）。
- 或者直接通过原厂 Web 升级/恢复，把系统恢复到 NAND（由原厂流程决定写入范围）。

---

## B. 方案 B（BLOCKED）：选项 2 写回原厂内核（双槽写入）

> **状态：BLOCKED — 禁止作为普通回退方案执行。**
> 原因：本机尚未实测菜单 2 的具体擦除范围、单次写入长度、坏块跳过行为、两槽写入顺序和失败后的可恢复性。官方提交与同系列实测只证明“会写两个内核槽”，不足以证明本机可安全使用。不得写成“RAM 启动失败就自动用菜单 2”。

### B1. 前提（即使满足也不自动授权；技术审查，不构成操作步骤）

- 仅在取得本机实测证据后重新评估。
- TFTP 稳定、电源可靠、文件哈希通过。
- 明确接受“写两个槽”并单独获得 L7 授权。
- **必须保护 kernel0**：本机 kernel0 未写，是原厂恢复能力的一部分；菜单 2 会用同一镜像覆盖它。

### B2. 技术原理与历史证据（不可执行流程）

菜单 2 在 U-Boot 中的设计用途是：通过 TFTP 接收一个镜像，然后擦除并写入内核区域。历史证据（官方提交与同系列实测）表明：

- U-Boot 的 TFTP 写 Flash 安装会把传输的镜像写到 **0x200000 与 0x600000 两个内核槽**。
- 它会先用同一镜像覆盖 system 1（kernel0），再覆盖 system 2（kernel1）；因此会破坏 kernel0 与 rootfs0、kernel1 与 rootfs1 的配对关系。
- 实际擦除粒度、单次写入长度、坏块跳过行为、两槽写入顺序、失败后的可恢复性，**本机均未实测**。
- U-Boot 可能显示擦除警告并等待确认；本文件**不提供按键顺序、确认步骤或写入观察流程**，也不得被改写成可照做的操作指南。

> 历史警告文本仅作为风险证据保留：`Warning!! Erase Linux in Flash then burn new one. Are you sure?(Y/N)`。
> 不得据此输入 `Y` 或执行菜单 2。

因此，菜单 2 **永久不属于本项目默认恢复流程**；它不是普通恢复、回退或救砖方案。若未来要重新评估，必须先取得本机实测证据并完成独立的 Flash 写入审查与授权。

### B3. 预期与失败（理论）

- 理论结果：两个槽都是同一原厂内核；U-Boot 按原标志选择系统。
- **配对风险**：把 kernel1（2019）写到 system 1 后，system 1 变成“2019 内核 + rootfs0（2018）”，配对关系被打破；不能假设它能启动。
- 失败：传输中断/掉电 → 两个槽都可能损坏；只能再写或上编程器。
- 不修复 rootfs；若 rootfs 也损坏，需要另案处理。
- 以上均为理论/历史分析，不构成执行建议。

### B4. 回滚

- 本文件不提供菜单 2 的回滚操作；不得通过再次选项 2 回滚。任何回滚都必须另行审查和授权，且菜单 2 永久不属于本项目恢复流程。
- 若 Bootloader 仍正常，UART 仍可用。
- 该“回滚”本身仍是双槽写入，风险不低。

---

## C. 方案 C：安装 OpenWrt 25.12.6

### C1. 前提

- 已有一个可运行的原厂系统（NAND 或 RAM）。
- `kernel1` 与 `rootfs0` 哈希通过。
- 当前系统 `/proc/mtd` 显示 `kernel1` 与 `rootfs0` 标签（原厂阶段）。
- 整片备份至少两份。
- 已获得 L6+L7 授权。

### C2. 镜像

| 文件 | 大小 | SHA-256 |
|---|---:|---|
| `...-squashfs-kernel1.bin` | 3,331,950 | `cc7b1d18…` |
| `...-squashfs-rootfs0.bin` | 5,636,096 | `3bede806…` |

### C3. 步骤（每步单独确认）

1. 把两个镜像传到路由器 `/tmp`（USB 或 scp）。
2. 校验 SHA-256（与官方清单逐字比对）。
3. 写 kernel1：

```text
// 历史记录；禁止执行
mtd write openwrt-25.12.6-...-squashfs-kernel1.bin kernel1
```

4. 确认无报错，回读头部/`mtd verify`。
5. 写 rootfs0：

```text
// 历史记录；禁止执行
mtd write openwrt-25.12.6-...-squashfs-rootfs0.bin rootfs0
```

6. 确认无报错。
7. 设置标志：

```text
// 历史记录；禁止执行
nvram set flag_try_sys1_failed=1
nvram commit
```

8. 确认 `nvram get flag_try_sys1_failed` 返回 1。
9. `reboot`。
10. UART 观察：`Booting System 2`、OpenWrt 内核、UBI attach、UBIFS、init。

### C4. 写入边界

| 目标 | 偏移 | 分区大小 | 镜像大小 |
|---|---:|---:|---:|
| kernel1 | 0x600000 | 4 MiB | 3,331,950 |
| rootfs0 | 0xA00000 | 32 MiB | 5,636,096 |

### C5. 失败与回滚

| 失败点 | 后果 | 回滚 |
|---|---|---|
| kernel1 写失败 | system 2 内核损坏 | 写回原厂 kernel1（L7） |
| rootfs0 写一半 | 原厂 rootfs 可能损坏 | UART + initramfs/备份；不能依赖 Web 恢复 |
| 标志设置后不启动 | 两个系统都可能不可用 | UART；选项 1 initramfs；按决策树 C/D |
| OpenWrt 启动但网络不通 | 可能配置/驱动问题 | UART 登录/ failsafe；不要盲目重刷 |

### C6. 安装后

- LAN `192.168.1.1`，无密码；无线默认关闭。
- `cat /proc/mtd` 应显示 `kernel_stock` / `kernel` / `ubi`。
- `ubinfo -a` 检查卷。
- 立即做整片备份并复制到第二介质。
- 后续升级只用 `sysupgrade`，不要再用原厂阶段的 `mtd write ... kernel1`。

### C7. 配对关系与布局（安装前必须理解）

OpenWrt DTS 注释：

- `rootfs0` = “rootfs partition for stock kernel0” → **kernel0 ↔ rootfs0（system 1）**
- `rootfs1` = “rootfs partition for stock failsafe kernel1” → **kernel1 ↔ rootfs1（system 2）**

原厂布局：

```text
kernel0 (0x200000) ↔ rootfs0 (0xA00000)
kernel1 (0x600000) ↔ rootfs1 (0x2A00000)
overlay  (0x4A00000) 独立
```

OpenWrt 布局：

```text
kernel_stock (0x200000)
kernel       (0x600000)
ubi          (0xA00000, 0x7580000)  <- 合并 rootfs0 + rootfs1 + overlay
```

因此：

- 不能假设任意原厂内核都能挂载任意原厂 rootfs；配对关系是版本相关的。
- 写 OpenWrt `rootfs0` 会覆盖整个合并 UBI 区域（原厂 rootfs0/rootfs1/overlay 全部失效）。
- 技术分析（不构成操作步骤）：菜单 2 把同一内核写到两个槽，会打破配对；这是它被标记为 BLOCKED 的原因之一。

---

## D. 原厂 U 盘恢复（独立路径）

### D1. 前提

- 原厂内核位于 system 1 或 system 2。
- 两个 `flag_try_sys*_failed` 为 1（同系列实测条件）。
- FAT32 U 盘根目录有 `miwifi.bin`（2.28.46）。

### D2. 风险

- 2.28.46 是否被恢复内核接受未验证。
- 本机两次 USB 尝试失败，原因未明。
- 设置两个 failed 标志是 NVRAM 写入（L6）。
- 原厂恢复程序可能重写 Bootloader/Config（取决于镜像版本），需先确认。

### D3. 建议

- 先通过 UART 日志确认原厂内核是否真的进入恢复模式（红灯慢闪、串口提示）。
- 不要在没有日志的情况下反复插 U 盘/按 Reset。

---

## E. 不要做的事

- 不要用 `sysupgrade.bin` 做首次安装。
- 不要用 U-Boot 选项 2 写 OpenWrt kernel1（会覆盖两个槽）。
- 不要在 OpenWrt 里使用 `kernel1` 标签。
- 不要写 Bootloader/Factory/Bdata。
- 不要在电源不稳时写 rootfs0。
- 不要把“CRC OK”当成“系统能启动”。

---

## F. 检查清单（执行前）

- [ ] UART 日志已保存并分析
- [ ] 当前系统 `/proc/mtd` 已打印
- [ ] 镜像哈希与官方一致
- [ ] 目标分区/偏移已核对
- [ ] 备份两份、其中一份不在本机
- [ ] 电源稳定
- [ ] 已获得对应等级授权
- [ ] 回滚方案已写下来
