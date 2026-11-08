# FLASH_SAFETY_REVIEW — 所有可能触及 Flash / NVRAM 的操作审查

生成日期：2026-11-04
适用：R3G v1（MT7621A，128 MiB NAND，原厂 U-Boot 5.0.0.0）
原则：**本文件不授权执行**。每条操作都列出目标、范围、后果、回滚与验证状态。未验证的命令不得进入执行流程。

> **第三轮流程边界**
> TFTP 传输成功只证明文件已送达，不等于 NAND 恢复成功；不得把 TFTP 成功描述为 Flash 恢复完成。
> - 选项 1：只作为 **RAM 临时加载候选**；不等于整个 initramfs 会话绝对只读。
> - 选项 2：继续 **BLOCKED**。
> - 选项 7/9（本机实测；旧资料常写作 5/6）：**永久禁止**。
> - 任何 Flash/NVRAM 写入（包括 `mtd`、`nand`、`saveenv`、`fw_setenv`、`ubiformat`、菜单 2/7/9）都必须单独审查并获得新的明确授权。

---

## 0. 总表

| # | 操作 | 层级 | 目标 | 实际范围 | 验证状态 | 本阶段 |
|---|---|---|---|---|---|---|
| F1 | `mtd write ...kernel1 kernel1`（原厂系统内） | L7 | kernel1 | 0x600000，镜像 3,331,950 B | 官方流程；本机已执行 | 已发生，不再重复 |
| F2 | `mtd write ...rootfs0 rootfs0`（原厂系统内） | L7 | rootfs0 | 0xA00000，镜像 5,636,096 B | 官方流程；本机未执行 | 禁止（未授权） |
| F3 | `nvram set flag_try_sys1_failed=1` + `nvram commit` | L6 | Config | Config 内 NVRAM | 官方流程；本机未执行 | 禁止（未授权） |
| F4 | `fw_setenv flag_try_sys2_failed 1` | L6 | Config | Config 偏移 0，0x1000 B | 官方流程；本机未执行 | 禁止（未授权） |
| F5 | U-Boot `setenv ...` + `saveenv` | L6 | Config | Config 偏移 0，0x1000 B | 同系列实测 + 字符串 | 禁止（未授权） |
| F6 | U-Boot 菜单 2：TFTP 写 Flash | L7 | kernel0 + kernel1 | 已知触及 0x200000 + 0x600000；具体擦除/写入长度未实测 | 官方 + 同系列；本机未实测 | **BLOCKED** |
| F7 | U-Boot 菜单 7/9：写 Bootloader（旧资料常写作 5/6） | L8 | Bootloader | 0x000000 | 字符串警告；无回滚 | **绝对禁止** |
| F8 | initramfs 内 `mtd write` 写 kernel1 | L7 | kernel1 | 0x600000 | 未实测 | 禁止（未授权） |
| F9 | initramfs 内 `mtd write` 写 rootfs0 | L7 | rootfs0 | 0xA00000 | 未实测 | 禁止（未授权） |
| F10 | `nand erase` / `nand write`（U-Boot） | L7/L8 | 任意 | 由命令决定 | 语法已知；语义危险 | **禁止** |
| F11 | 整片备份回写（编程器） | L8 | 全片 | 133 MB | 同型号项目声称可行 | 禁止（最后手段） |
| F12 | 原厂 U 盘恢复（miwifi.bin） | L7 | 全片（由原厂内核执行） | 原厂内核决定 | 同系列流程；本机两次失败 | 禁止（未授权） |
| F13 | OpenWrt `sysupgrade` | L7 | kernel + ubi | OpenWrt 内部 | 官方；不适用于当前 | 不适用 |
| F14 | `firstboot` | L7（overlay） | overlay/UBI | OpenWrt 内部 | 官方；不适用于当前 | 不适用 |
| F15 | 选项 1：TFTP 加载到 SDRAM | L5 | 无（RAM） | 加载阶段不写 NAND（按设计）；内核/用户态是否 attach/write 未验证 | 官方描述 + 源码；未实测 | 未授权 |
| F16 | `unlock_ssh.ps1` / OpenWRTInvasion | L3/L6? | 不改 Flash；启动服务 | 用户态 | 本机已成功过 | 当前不可达 |

---

## F1 — `mtd write ...-kernel1.bin kernel1`

| 字段 | 内容 |
|---|---|
| 原始命令 | `mtd write openwrt-25.12.6-...-squashfs-kernel1.bin kernel1` |
| 来源 | OpenWrt 设备页（存档）；提交 f2107fc |
| 适用设备 | R3G v1（原厂系统运行时） |
| 适用版本 | 原厂 2.x；镜像 25.12.6 |
| 目标分区 | `kernel1`（system 2） |
| 实际写入范围 | 0x00600000 起，3,331,950 B；分区 4 MiB，未越界 |
| 预期结果 | kernel1 变成合法 OpenWrt uImage；U-Boot CRC 通过 |
| 失败后果 | 若 system 2 是活动系统，下次启动进入“OpenWrt 内核 + 原厂 rootfs” → boot loop |
| 回滚 | 用备份 `parts/kernel1.bin`（`ab893d6c…`）写回；需 L7 授权 |
| 已验证 | 本机执行成功，`mtd verify` 成功，回读头正确；**但导致了当前故障** |
| 备注 | 这不是“安全的第一步”；必须同时写 rootfs0 并设置标志，否则是半安装 |

---

## F1.1 原厂内核/rootfs 配对关系（所有方案的前提）

OpenWrt DTS 注释明确：

- `rootfs0` = “rootfs partition for stock kernel0” → **kernel0 ↔ rootfs0（system 1）**
- `rootfs1` = “rootfs partition for stock failsafe kernel1” → **kernel1 ↔ rootfs1（system 2）**

推论：

- 不能假设任意原厂内核都能挂载任意原厂 rootfs；配对是版本相关的。
- 菜单 2 把同一份内核写到两个槽，会人为打破配对；这是它被标记为 BLOCKED 的关键原因。
- 写 OpenWrt `rootfs0` 会覆盖合并后的 `ubi` 区域（原厂 rootfs0+rootfs1+overlay），不是只动一个 32 MiB 分区。

---

## F2 — `mtd write ...-rootfs0.bin rootfs0`

| 字段 | 内容 |
|---|---|
| 原始命令 | `mtd write openwrt-25.12.6-...-squashfs-rootfs0.bin rootfs0` |
| 来源 | OpenWrt 设备页；提交 f2107fc |
| 适用设备 | R3G v1（原厂系统运行时） |
| 适用版本 | 原厂 2.x；镜像 25.12.6 |
| 目标分区 | `rootfs0` |
| 实际写入范围 | 0x00A00000 起，5,636,096 B；分区 32 MiB |
| 预期结果 | rootfs0 变成 OpenWrt UBI；配合 kernel1 与标志启动 OpenWrt |
| 失败后果 | 写到一半失败 → 原厂 rootfs 区域可能损坏；重启后原厂系统也可能不可用 |
| 回滚 | 从 `parts/rootfs0.bin` 整分区写回；需要 UART/initramfs 或编程器 |
| 已验证 | 本机未执行 |
| 备注 | **rootfs0 是不可逆分界点**；执行前必须有两份备份与 UART 通道 |

---

## F3 — `nvram set flag_try_sys1_failed=1` + `nvram commit`

| 字段 | 内容 |
|---|---|
| 原始命令 | `nvram set flag_try_sys1_failed=1`；`nvram commit` |
| 来源 | OpenWrt 设备页；提交 f2107fc |
| 适用设备 | R3G v1（原厂系统运行时） |
| 适用版本 | 原厂 2.x |
| 目标 | Config 分区内的 U-Boot 环境（NVRAM） |
| 实际范围 | Config 偏移 0，长度 0x1000，扇区 0x20000 |
| 预期结果 | U-Boot 跳过 system 1，启动 system 2（OpenWrt） |
| 失败后果 | 若 system 2 不可启动，两个系统都可能不可用；标志不会自动清除 |
| 回滚 | `nvram set flag_try_sys1_failed=0` + `nvram commit`（需要有可运行系统） |
| 已验证 | 本机未执行（写入后只读过 `flag_try_sys1_failed=0`） |
| 备注 | 这是 NVRAM 写入，不是“只是变量”；写入前确认 system 2 可启动 |

---

## F4 — `fw_setenv flag_try_sys2_failed 1`

| 字段 | 内容 |
|---|---|
| 原始命令（仅技术审查，禁止执行） | `fw_setenv flag_try_sys2_failed 1` |
| 来源 | OpenWrt 设备页“Recovery to stock”；提交 f2107fc |
| 适用设备 | R3G v1（OpenWrt 运行中或 failsafe） |
| 适用版本 | OpenWrt 18.06+（含 25.12.6，前提是 envtools 配置正确） |
| 目标 | Config 分区内的 U-Boot 环境 |
| 实际范围 | Config 偏移 0，0x1000 B |
| 预期结果 | U-Boot 回到 system 1 的原厂内核，进入原厂 U 盘恢复模式 |
| 失败后果 | 若 system 1 也失败，可能进入双失败逻辑；原厂内核被覆盖时无效 |
| 回滚（禁止执行；需单独授权） | `fw_setenv flag_try_sys2_failed 0`（需要有可运行系统） |
| 已验证 | 官方流程；本机未执行 |
| 备注 | 本机 kernel0 未写、rootfs0 未写，理论上具备前提；但仍需 UART 确认 |

---

## F5（技术审查，不提供执行流程）— U-Boot `setenv` / `saveenv`

> 仅技术审查；`setenv`/`saveenv` 必须单独授权，禁止照抄执行。

| 字段 | 内容 |
|---|---|
| 原始命令（仅技术审查，禁止执行） | 例如 `setenv flag_last_success 0`；`setenv flag_try_sys2_failed 1`；`saveenv` |
| 来源 | 官方提交的变量语义；同系列实测（ysc3839） |
| 适用设备 | R3G v1 |
| 适用版本 | U-Boot 5.0.0.0 |
| 目标 | Config 分区内的 U-Boot 环境 |
| 实际范围 | Config 偏移 0，0x1000 B；带 CRC32 |
| 预期结果 | 改变下次启动选择 |
| 失败后果 | 写错变量/值 → 选择错误系统；CRC 损坏 → U-Boot 回退默认环境（可能导致无法启动） |
| 回滚 | 重新设置正确值并 `saveenv`；若环境损坏，需要重新写入 Config 备份（L7） |
| 已验证 | 变量语义官方证实；本机 `saveenv` 未执行 |
| 备注 | **不要修改 `flag_boot_rootfs`**；不要在不了解当前值的情况下 `saveenv` |

---

## F6 — U-Boot 菜单 2：TFTP 写 Flash

| 字段 | 内容 |
|---|---|
| 技术对象 | U-Boot 菜单 2 `Load system code then write to Flash via TFTP`；本审查**不提供执行步骤** |
| 来源 | 本机菜单字符串；OpenWrt 提交；ysc3839 实测 |
| 适用设备 | R3G v1 |
| 适用版本 | U-Boot 5.0.0.0 |
| 目标 | **kernel0 与 kernel1 两个槽** |
| 实际范围 | 已知会触及 0x200000 与 0x600000；但擦除粒度、单次写入长度、坏块跳过行为、两槽写入顺序均**未在本机实测** → 具体范围 **UNVERIFIED** |
| 预期结果 | 两个槽都变成同一镜像；system 1 变成“该镜像 + rootfs0”，配对关系被打破 |
| 失败后果 | 传输中断/坏文件 → 两个内核都可能不可启动；文件 >4 MiB 时可能越过内核区；kernel0 被覆盖后原厂恢复能力受损 |
| 回滚 | 只能再次写入正确镜像，或上编程器；本审查不给出按键流程 |
| 已验证 | 官方提交 + 同系列实测证明“写两个槽”；本机未实测擦除/写入细节 → **BLOCKED** |
| 备注 | **绝不能描述为“只写 kernel1”**；**不得作为普通回退或默认恢复方案**；必须保护 kernel0；永久不属于默认恢复流程 |

---

## F7 — U-Boot 菜单 7/9：写 Bootloader（旧资料常写作 5/6）

| 字段 | 内容 |
|---|---|
| 原始操作 | `7: Load Boot Loader code then write to Flash via Serial`；`9: ... via TFTP` |
| 来源 | 本机菜单字符串 |
| 适用设备 | R3G v1 |
| 适用版本 | U-Boot 5.0.0.0 |
| 目标 | Bootloader（0x000000） |
| 实际范围 | Bootloader 分区 |
| 预期结果 | 替换引导程序 |
| 失败后果 | 设备彻底无串口输出，只能拆 NAND 用编程器 |
| 回滚 | 无软件回滚 |
| 已验证 | 菜单字符串已证实存在 |
| 备注 | **绝对禁止**；本项目任何阶段都不应选择 |

---

## F8/F9 — initramfs 内 `mtd write`

| 字段 | 内容 |
|---|---|
| 原始命令 | `mtd write parts/kernel1.bin kernel1`（标签以 initramfs 的 `/proc/mtd` 为准）；`mtd write ...rootfs0.bin rootfs0` |
| 来源 | 本工具链设计；OpenWrt mtd 工具 |
| 适用设备 | R3G v1（RAM 启动的 OpenWrt initramfs） |
| 适用版本 | 25.12.6 initramfs |
| 目标 | 由标签决定；OpenWrt 下可能是 `kernel` / `ubi`，不是 `kernel1` / `rootfs0` |
| 实际范围 | 由分区标签决定 |
| 预期结果 | 精确修复单个分区 |
| 失败后果 | 标签错误 → 写错分区；掉电 → 分区损坏 |
| 回滚 | 用备份重写；最坏上编程器 |
| 已验证 | 未实测 |
| 备注 | 执行前必须打印 `/proc/mtd` 并人工核对标签；不得使用旧标签 |

---

## F10（禁止操作，仅技术分析）— `nand erase` / `nand write`

> 仅记录语法与风险；禁止执行 `nand erase`/`nand write`。

| 字段 | 内容 |
|---|---|
| 原始命令（禁止执行） | 本机 help：`nand erase <addr> <len>`、`nand write <addr> <data...>` |
| 来源 | 本机 Bootloader 字符串 |
| 适用设备 | R3G v1 |
| 适用版本 | U-Boot 5.0.0.0 |
| 目标 | 由地址决定，可能整片 |
| 实际范围 | 由参数决定 |
| 预期结果 | 擦除/写入原始 NAND |
| 失败后果 | 地址/长度错误 → 覆盖 Bootloader/Factory；设备不可恢复 |
| 回滚 | 通常无 |
| 已验证 | 语法已知；语义**不适合**手工使用 |
| 备注 | **禁止**；本文件不提供恢复命令。菜单 2 为 BLOCKED，不得作为恢复路径；任何 RAM 临时加载或 Linux mtd 写入都必须另行审查和授权 |

---

## F11 — 整片备份回写（编程器）

| 字段 | 内容 |
|---|---|
| 方法 | Teensy++/NORway + TSOP48（C6）或等效编程器 |
| 来源 | jesusvallejo/MIR3G_RECOVERY |
| 适用设备 | R3G |
| 适用版本 | 不限 |
| 目标 | 整片 NAND |
| 实际范围 | 含 OOB 的原始芯片内容 |
| 预期结果 | 恢复到备份状态 |
| 失败后果 | 拆焊损坏、坏块映射不兼容、MAC/校准被替换 |
| 回滚 | 无；只能在编程器上再写 |
| 已验证 | 作者声称成功；无独立复现 |
| 备注 | **最后手段**；仅当 Bootloader 已死/NAND 损坏 |

---

## F12 — 原厂 U 盘恢复（miwifi.bin）

| 字段 | 内容 |
|---|---|
| 方法 | 原厂内核 initramfs + FAT32 U 盘中的 `miwifi.bin` + Reset |
| 来源 | 小米官方恢复流程；ysc3839；项目 USB 文档 |
| 适用设备 | R3G |
| 适用版本 | 原厂 2.x；镜像 2.28.46 |
| 目标 | 原厂固件全片（由原厂内核决定） |
| 实际范围 | 由原厂恢复程序决定（可能包含 Bootloader/Config） |
| 预期结果 | 恢复原厂系统 |
| 失败后果 | 若镜像版本不被接受/供电中断 → 可能进一步损坏 |
| 回滚 | UART/编程器 |
| 已验证 | 流程存在；本机两次尝试失败，原因未明 |
| 备注 | 需要两个 failed 标志为 1（同系列实测）；第三次尝试前先查明失败原因 |

---

## F13/F14 — OpenWrt `sysupgrade` / `firstboot`

- 仅适用于已经运行 OpenWrt 的系统；当前设备不适用。
- `sysupgrade` 写 kernel + UBI，属于 OpenWrt 内部事务；`-n` 会清除配置。本文件禁止执行该命令。
- `firstboot` 重建 overlay，不修复内核/rootfs。
- 本阶段不展开；安装成功后再单独审查。

---

## F15 — 选项 1：TFTP 加载到 SDRAM（非 Flash）

| 字段 | 内容 |
|---|---|
| 原始操作 | 菜单 `1: Load system code to SDRAM via TFTP` |
| 来源 | 本机菜单；OpenWrt 提交 |
| 目标 | SDRAM |
| 实际范围 | U-Boot 选项 1 的加载阶段按设计不写 NAND；内核是否因 cmdline 自动 attach UBI **未验证**；initramfs 中手动执行 `mtd`/`ubiformat`/`mount` 仍可能写 NAND；本文件禁止执行这些写入命令 |
| 预期结果 | 临时启动 initramfs/内核；OpenWrt 25.12 的 preinit 在 `INITRAMFS=1` 时跳过 `mount_root`（源码证据） |
| 失败后果 | 启动失败并复位；一般不动 Flash |
| 回滚 | 断电重启 |
| 已验证 | 官方描述 + 字符串 + preinit 源码；本机未实测 |
| 备注 | 仍需 L5 授权；第一次必须在全日志下确认无擦除输出；**不要把整个 initramfs 会话称为“绝对只读”** |

TFTP 传输层的块大小边界（未请求 `blksize` 时固定 512；请求时按 `min(客户端, --max-block)`；非法值 ERROR 8）只影响传输，不改变本项 Flash 风险等级。详见 `START_HERE.md` 7.2 与 `docs/RECOVERY_DECISION_TREE.md` D0。

---

## F16 — OpenWRTInvasion / `unlock_ssh.ps1`

| 字段 | 内容 |
|---|---|
| 方法 | 利用原厂 Web 漏洞启动 telnet/ssh/ftp |
| 来源 | acecilia/OpenWRTInvasion；项目脚本 |
| 目标 | 用户态服务，不改 Flash |
| 实际范围 | 无 Flash 写入（但可能触发厂商日志/配置） |
| 预期结果 | 获得 root shell |
| 失败后果 | 漏洞不适用/路由器重启；无 Flash 风险 |
| 回滚 | 重启即关闭服务 |
| 已验证 | 本机 2.28.24 曾成功（项目记录） |
| 备注 | 当前路由器不可达，不适用 |

---

## 永久禁止清单（禁止项，不是操作指引）

```text
# 以下均为禁止项，不是可执行步骤
写 Bootloader（任何方式）
写 Factory / Bdata
写 kernel0（除非整片恢复方案明确且已授权）
写 rootfs0/rootfs1/overlay 而不先确认镜像与标签
nand erase（任何范围，禁止）
nand write（任何范围，禁止）
erase all（禁止）
saveenv 而不先 printenv（禁止）
setenv flag_boot_rootfs
fw_setenv 而不先 fw_printenv
覆盖唯一原厂备份
```

---

## 执行前检查门（每条写入命令都必须通过）

1. [ ] 当前运行系统的 `/proc/mtd` 已打印并人工核对标签
2. [ ] 镜像 SHA-256 与官方/备份清单一致
3. [ ] 镜像大小 ≤ 目标分区大小
4. [ ] 写入目标偏移与 NAND_LAYOUT_ANALYSIS.md 一致
5. [ ] 已确认不是“双槽写入”或已明确接受双槽风险
6. [ ] 备份至少两份，其中一份不在本机磁盘
7. [ ] UART 日志已保存，串口通道可用
8. [ ] 电源稳定（建议 UPS 或笔记本电池供电）
9. [ ] 已获得对应等级（L6/L7）的单独授权
10. [ ] 写入后校验方案已准备（mtd verify / 回读哈希 / 启动日志）

---

## 结论

- 本机已经发生过一次 L7 写入（F1），并导致了当前故障；这不是“安全操作”的先例。
- 所有其他写入均为未来授权项；本文件不构成执行许可。
- 最高风险操作是 F6（双槽写入）、F7（Bootloader）、F10（nand erase/write）、F11（编程器）。
- 在 UART 日志确认前，唯一允许的动作是 L0–L2。
