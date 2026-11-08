# BOOT_FLAG_ANALYSIS — 启动标志语义与当前数值

分析日期：2026-11-04
来源：OpenWrt 提交 f2107fc、本机 `Bootloader.bin` 字符串、写入前 Config 分区 NVRAM 快照、写入前后 live `nvram get`
原则：变量名不代表语义；只采用有源码/实测支持的结论。

---

## 1. 本机快照值（时间点必须分清）

| 标志 | 写入前备份快照 | 写入前 live | 写入后 live | 说明 |
|---|---|---|---|---|
| `flag_try_sys1_failed` | 0 | **0** | **0** | 唯一在写入后仍读到的标志 |
| `flag_try_sys2_failed` | 0 | 未读 | **未读**（设备失联） | 关键未知 |
| `flag_last_success` | 1 | 未读 | **未读** | 关键未知 |
| `flag_boot_success` | 1 | 未读 | 未读 | 不是 U-Boot 变量（见 §4） |
| `flag_boot_rootfs` | 1 | 未读 | 未读 | U-Boot 会打印，但语义未证实 |
| `flag_ota_reboot` | 0 | 未读 | 未读 | 语义未证实 |
| `mode` | Router | — | — | 原厂模式 |
| `nv_wan_type` | dhcp | — | — | WAN 模式 |
| `bootdelay` | 5 | — | — | 启动倒计时 |
| `boot_wait` | on | — | — | 菜单等待 |
| `uart_en` | 0 | — | — | 原厂 NVRAM 变量；**具体用途未证实**。官方 Wiki 用它开启原厂 Linux UART 控制台；不能据此认定它门控 U-Boot 菜单输入 |

> 写入后只确认了 `flag_try_sys1_failed=0`；其余标志在设备失联后未能读取。**禁止把备份快照当作当前值。**

---

## 2. 官方语义（OpenWrt 提交 f2107fc，原文归纳）

| 标志 | 语义 | 证据 |
|---|---|---|
| `flag_last_success` | 偏好：0=system 1（0x200000），1=system 2（0x600000）。**只有两个 `flag_try_sys*_failed` 都为 0 时才考虑** | 官方提交 |
| `flag_try_sys1_failed` | 非 0 表示 system 1 启动失败；U-Boot 会启动未失败的另一个系统 | 官方提交 |
| `flag_try_sys2_failed` | 非 0 表示 system 2 启动失败；同上 | 官方提交 |
| 两者都非 0 | 检查 system 1 的 uImage CRC；OK 则启动 system 1，否则无条件启动 system 2 | 官方提交 |
| 设置时机 | 当选中的系统 uImage CRC 不正确时，U-Boot 设置该系统的 failed 标志 | 官方提交 |
| 清除 | **U-Boot 永远不会清除 failed 标志** | 官方提交 |

### 启动选择伪代码

```text
if try_sys1_failed != 0 and try_sys2_failed != 0:
    boot system1 if uImage_crc(system1) ok else system2
elif try_sys1_failed != 0:
    boot system2
elif try_sys2_failed != 0:
    boot system1
else:
    boot system1 if last_success == 0 else system2
```

### 关键推论（对本机）

- 写入前：`last_success=1`、两个 failed 都是 0 → U-Boot 选择 **system 2（kernel1 @0x600000）**。
- kernel1 的原厂内核构建时间（2019-04-03）与运行中的 2.28.24 内核几乎一致 → system 2 很可能就是当前活动系统。
- 写入后：kernel1 是合法的 OpenWrt uImage（CRC 正确）→ U-Boot 仍选择 system 2，**不会**因为 rootfs 不匹配而设置 `flag_try_sys2_failed`。
- 因此系统进入“OpenWrt 内核 + 原厂 rootfs”的失败组合，表现为 boot loop。
- 这是**强推断**；只有 UART 日志能确认 U-Boot 实际选择了哪个系统、CRC 结果和失败点。

---

## 3. 为什么“改一个标志”不能想当然

### 3.1 只改 `flag_last_success=0`

- 条件：两个 failed 必须都为 0。当前 `sys2_failed` 未知；如果 U-Boot 已经置位，`last_success` 会被忽略。
- 结果：U-Boot 尝试 system 1（kernel0，2018 内核）+ rootfs0。rootfs0 未写，理论上是原厂，但 2018 内核能否匹配当前 UBI 状态未知。
- 风险：若 system 1 也失败，U-Boot 会设置 `flag_try_sys1_failed=1`；此时两个 failed 都可能非 0，逻辑会变成“检查 system1 CRC，OK 就继续启动 system1”——可能陷入同一循环。
- 结论：不是“最小风险首选”，只是候选方案之一，必须在 UART 日志后决定。

### 3.2 只改 `flag_try_sys2_failed=1`

- 官方恢复流程用它强制回到 system 1（原厂内核）。
- 前提：system 1 原厂内核与 rootfs0 完好；本机 kernel0/rootfs0 确实未被写。
- 风险：如果 system 1 也无法启动，U-Boot 设置 `sys1_failed`，两个 failed 都非 0 → 按官方逻辑仍会检查 system1 CRC 并启动它（因为 CRC 有效），不能自动回到 system 2。
- 结论：可作为“尝试原厂 system 1”的方案，但必须配合 UART 观察，且 `saveenv` 是 NVRAM 写入。

### 3.3 恢复 system 2 的原厂内核

- 用已校验的 `parts/kernel1.bin`（4 MiB，`ab893d6c…`）写回 0x600000。
- 这是最直接针对“活动系统被覆盖”的修复；rootfs0/1/overlay 未动，原厂 system 2 的 rootfs 应仍完整。
- 但写入方式必须解决：原厂 U-Boot 没有“只写 kernel1”的菜单项；选项 2 会写两个槽（见 UBOOT_BEHAVIOR.md）。
- 结论：这是**待授权的主要恢复候选**，但写入路径需要单独设计（选项 2 + 4 MiB 镜像，或先 TFTP 启动 initramfs 再从 Linux 写）。

---

## 4. 本机 U-Boot 字符串能证明什么

从 `Bootloader.bin` 提取的相关字符串：

```text
flag_try_sys1_failed
flag_try_sys2_failed
flag_ota_reboot
flag_last_success
flag_boot_rootfs
0x%X
Boot failure detected on both systems
Verifying kernel1 uImage CRC, addr: 0x%x
Verifying kernel2 uImage CRC, addr: 0x%x
Booting System 1
Booting System 2
```

可以证明：

- 本机 U-Boot 确实引用 `flag_try_sys1_failed`、`flag_try_sys2_failed`、`flag_last_success`、`flag_boot_rootfs`、`flag_ota_reboot`。
- 本机 U-Boot **没有**引用 `flag_boot_success`。
- 本机 U-Boot 会打印 `flag_boot_rootfs` 的值（`0x%X`），但字符串无法证明它如何影响启动。

不能证明：

- `flag_boot_rootfs` 的确切作用；
- `flag_ota_reboot` 的确切作用；
- failed 标志的值是否在本次故障中被置位（需要 UART/printenv）。

---

## 5. 标志证据表

| 项目 | 内容 |
|---|---|
| 结论 | `flag_last_success` 0=system1、1=system2，仅在两个 failed 都为 0 时生效 |
| 来源 | OpenWrt 提交 f2107fc |
| URL | https://github.com/openwrt/openwrt/commit/f2107fc328ff7f9817fe9ca64f84bba9e32abfc6 |
| 设备 | R3G v1 |
| 固件版本 | 提交时代至 25.12（机制延续） |
| U-Boot 版本 | 本机 5.0.0.0 含该字符串 |
| 验证程度 | 官方证实（逻辑）；本机值来自备份快照 |
| 风险 | 误读会导致选择错误系统 |
| 是否可以用于我的设备 | 是（用于解释，不用于盲目修改） |

| 项目 | 内容 |
|---|---|
| 结论 | U-Boot 只设置 failed 标志，从不清除；CRC 正确但 rootfs 不匹配不会触发回退 |
| 来源 | OpenWrt 提交 f2107fc |
| URL | 同上 |
| 设备 | R3G v1 |
| 固件版本 | 同上 |
| U-Boot 版本 | 5.0.0.0 |
| 验证程度 | 官方证实 + 本机症状吻合（强推断） |
| 风险 | 期待“自动回退”会误判恢复路径 |
| 是否可以用于我的设备 | 是 |

| 项目 | 内容 |
|---|---|
| 结论 | `flag_boot_success` 不是本机 U-Boot 的启动选择变量 |
| 来源 | 本机 `Bootloader.bin` 字符串 + OpenWrt 提交未提及 |
| URL | 本地证据 |
| 设备 | R3G v1 |
| 固件版本 | 原厂 2.28.24 |
| U-Boot 版本 | 1.1.3 / Ralink 5.0.0.0 |
| 验证程度 | 二进制字符串证实“未引用”；其用户态用途未研究 |
| 风险 | 用它判断启动状态没有依据 |
| 是否可以用于我的设备 | 否（不作为启动判断依据） |

| 项目 | 内容 |
|---|---|
| 结论 | U-Boot 环境位于 Config 分区偏移 0，长度 0x1000，扇区 0x20000，带 Little-Endian CRC32 |
| 来源 | 恩山回复 fyi2000 + OpenWrt 提交 `ubootenv_add_uci_config "/dev/mtd1" "0x0" "0x1000" "0x20000"` |
| URL | https://www.right.com.cn/forum/thread-308330-1-1.html |
| 设备 | 小米路由器 3 / R3G |
| 固件版本 | 原厂/Padavan/OpenWrt |
| U-Boot 版本 | Ralink 5.0.0.0 |
| 验证程度 | 同系列实测 + 官方源码一致 |
| 风险（禁止执行） | `saveenv`/`fw_setenv` 是真实写入；CRC 损坏会导致 env 回退默认值 |
| 是否可以用于我的设备 | 是（用于理解；写操作需授权） |

---

## 6. 结论

1. 官方语义足以解释本机“覆盖 kernel1 后启动失败且不回退”的现象。
2. 当前唯一确认的实时标志仍是 `flag_try_sys1_failed=0`；其他标志必须通过 UART `printenv` 重新读取。
3. `flag_boot_rootfs`、`flag_boot_success`、`flag_ota_reboot` 不应作为恢复操作依据；尤其不要改 `flag_boot_rootfs`。
4. 恢复路径必须建立在 UART 日志确认的实际系统选择与失败点上，而不是变量名推测。
