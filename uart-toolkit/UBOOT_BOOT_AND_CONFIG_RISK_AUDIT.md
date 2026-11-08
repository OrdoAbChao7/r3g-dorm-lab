# U-Boot 启动机制与 Config 风险审计

审计日期：2026-11-07。范围：本机保存的只读日志、Bootloader 分区镜像及项目已有 OpenWrt 官方补丁；没有连接设备。本报告是静态判断，不构成硬件操作授权。

## 核心结论

- **LOG CONFIRMED**：`logs/r3g_l4probe_20261107-205729.log` 启动片段显示 System 2、`ranand_erase: start:80000, len:20000`、内核校验 OK，随后 UBI attach 失败和 panic 重启。先前 `r3g_uart_20261107-193332.log` 有两次相同的 System 2 和擦除行。两次启动记录不能证明每次上电均如此。
- **INFERENCE（强，非同一 boot 直接实验）**：当前 L4 printenv 的两个 failed 都为 0、last_success 为 1，与 OpenWrt R3G 提交记载的 system 2 选择规则相符；结合两次 System 2 日志，解释力强，但没有本机二进制完整控制流证明。
- **BLOCKED**：`ranand_erase` 的调用者、实际擦除对象、返回结果及是否写回均未证明；不能把它等同于正常 `saveenv`，也不能断言仅由于某个菜单而执行。它是后续上电的最高优先级风险。
- **BLOCKED**：菜单 1 的无 NAND/Config 写入和真实加载地址尚未通过本机控制流证明；现有资料不足以宣布 L5 READY。

## 启动标志逐项判断

依据本地保存的 [OpenWrt 原始提交](https://github.com/openwrt/openwrt/commit/f2107fc328ff7f9817fe9ca64f84bba9e32abfc6) 的设备描述（`research/sources/openwrt_commit_f2107fc.patch`，提交信息第 48–68 行；是作者对 R3G 的行为说明，不是本机 U-Boot 源码）：系统 1/2 分别对应 NAND 内核地址 0x200000/0x600000。两个 failed 均为 0 时 last_success=0 偏好 system 1，=1 偏好 system 2；若一个 failed 置位则选择另一系统；两个都置位时依 system 1 uImage CRC 选择 system 1 或 system 2。该提交称 U-Boot 在已选系统 uImage CRC 不正确时设置其 failed 标志，不负责清除。

- `flag_last_success=1`：**PASS-SOURCE-VERIFIED（R3G 描述）**，仅在两个 failed 均为零的条件下指向 system 2；本机运行轨迹相符。
- `flag_try_sys1_failed=0`、`flag_try_sys2_failed=0`：**PASS-SOURCE-VERIFIED（R3G 描述）**，触发上述偏好逻辑；不证明所有情形均由本机实测覆盖。
- `flag_boot_success=1`、`flag_boot_type=2`：**UNVERIFIED**，尚无此固件中两项如何参与启动及持久化的可靠控制流证据，不能仅按变量名判断。
- `flag_boot_rootfs=1`：**UNVERIFIED**；二进制中有变量名及格式字符串，不足以推断它选择哪一个分区、谁更改它或是否实际使用。
- U-Boot 是否“只检查 CRC”：**UNVERIFIED**，提交说明 magic/uImage CRC 用于启动选择，并不证明不存在其他检查；不能推广为仅检查 CRC。它没有提供 Linux UBI 健康检查的证据。**INFERENCE**：CRC 正确而 Linux 在交出控制后才发生 UBI/VFS panic，可解释 failed 标志未改变和持续选择 system 2；未验证崩溃是否被其他持久化组件记录。
- `bootcmd=tftp`、`bootdelay=5`：**LOG CONFIRMED** 此快照有这些值，菜单也曾实际显示；**UNVERIFIED** 菜单派发、倒计时和 `bootcmd` 的优先级/具体关系，不能从标准 U-Boot 的默认行为套用。启动日志与该环境值并不矛盾，但现有证据不能证明为什么出现菜单，也不能证明 5 秒由该变量控制。

## 擦除字符串和静态分析

独立计算 `<repo-root>/backups/parts/Bootloader.bin` SHA-256 为 `bf3cc484be162285639a1790c712a4eead39498281d7c6b1006d4cc0201f8ea3`，长度 524288 字节。原始文件中的 ASCII `ranand_erase` 位于文件偏移 0x1b6a4，`ranand_erase_raw`、`ranand_erase_write` 等字符串紧邻；通用格式 `%s: start:%x, len:%x` 位于约 0x1dc40。字符串共存仅支持候选格式关联，并不证明调用关系。原始串口输出显示该调用报告 start=0x80000、len=0x20000；这些是输出参数，而非已经独立核验的分区操作结果。Config 是依据历史分区资料的候选映射，长度不等于必然覆盖完整 Config。

文件开头是 uImage 头：其 load 与 entry 为 0xA0200000，属于此 Bootloader 备份镜像的头部字段，**不是菜单 1 的 TFTP 地址证据**。使用现有 Capstone 对头后字节尝试 MIPS32 little-endian 反汇编；样本未建立可信映射、重定位和函数边界，无法可靠追踪字符串交叉引用及 erase 调用者。**BLOCKED**：erase 是否环境保存、擦除后是否写回、失败路径、是否每次启动执行以及菜单 1 是否绕过该行为。没有对此做新的上电实验。

## 菜单 1

本机日志显示菜单 1 描述为 `Load system code to SDRAM via TFTP`；上述 OpenWrt R3G 提交也描述可借助串口通过 TFTP 启动 initramfs。两者支持“设计用途为 RAM 临时启动”的判断，**不证明本机菜单 1 的所有分支无 NAND erase/write、无 Config 变更或无自动环境保存**；本机函数入口、TFTP 调用、bootm、失败路径、网络参数更新均未静态追踪。字符串 `0x80A00000` 位于文件偏移 0x1bb30，邻近网络与文件名提示，但这只是位置关系，不证明运行时加载地址。`0xA0200000` 和 `0x80A00000` 均不构成可执行地址结论。菜单所需 192.168.31.1/192.168.31.100 是否直接使用当前环境也未证明。

过去 `research/UBOOT_BEHAVIOR.md` 对“无 NAND 写入”及“不会因此回退”的绝对语气证据不足，应以本审计的限定范围覆盖解释，保留原文件作为历史。禁止把“未看到擦除警告”当作无擦写的证明。所有实机动作需要后续独立授权，且在关键未知项消除前不满足 L5 READY。
