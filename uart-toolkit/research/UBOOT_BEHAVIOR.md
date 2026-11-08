# UBOOT_BEHAVIOR — 本机 U-Boot 行为证据审查

审查对象：本机原厂 `Bootloader.bin`（SHA-256 `bf3cc484…`，524,288 B）
辅助来源：OpenWrt 提交 f2107fc；ysc3839 实测；恩山回复
限制：以下“字符串证据”来自二进制中的可打印字符串；“行为”优先采用官方提交，其次同系列实测。**未在本机执行任何 U-Boot 命令。**

---

## 1. 身份

| 项 | 值 | 证据 |
|---|---|---|
| U-Boot 版本 | `U-Boot 1.1.3 (Nov  9 2018 - 09:28:13)` | `Bootloader.bin` 字符串 |
| Ralink UBoot | `Ralink UBoot Version: 5.0.0.0` | 同上 |
| SoC | MT7621A | 启动日志/字符串 |
| NAND | 128 MiB | 同上 |
| 提示符 | `MT7621 #` | 字符串 |
| 默认 `bootdelay` | 5 | 默认环境字符串 |
| 默认 `baudrate` | 115200 | 默认环境字符串 |
| 默认 `ipaddr` | 192.168.31.1 | 默认环境字符串 |
| 默认 `serverip` | 192.168.31.2 | 默认环境字符串 |
| 默认 `bootcmd` | `tftp` | 默认环境字符串 |

> `serverip` 冲突：默认环境是 `192.168.31.2`；项目旧文档从 Config 分区 NVRAM 解析到 `192.168.31.100`。二者可能分属“编译默认值”和“实际 env”。**上机后必须 `printenv` 读取实际值，不能预设。**

---

## 2. 菜单（本机真实字符串）

```text
Please choose the operation:
   1: Load system code to SDRAM via TFTP.
   2: Load system code then write to Flash via TFTP.
   3: Boot system code via Flash (default).
   4: Entr boot command line interface.
   7: Load Boot Loader code then write to Flash via Serial.
   9: Load Boot Loader code then write to Flash via TFTP.
```

注意：

- **2026-11-07 真实 UART 日志确认本机菜单为 1,2,3,4,7,9**（不是 1–6）。
- 7/9 都是写 Bootloader，**绝对禁止**。旧资料中的 5/6 是其他构建/通用模板。
- 菜单编号以屏幕实际输出为准；上述字符串是 `%d` 格式化模板，运行时才显示数字。

---

## 3. 选项逐一分析

### 3.1 选项 1：Load system code to SDRAM via TFTP

字符串证据：

- `%d: System Load Linux to SDRAM via TFTP.`
- 后续提示：`Input device IP`、`Input server IP`、`Input Linux Kernel filename`，附近有 `0x80A00000` 常量。
- 通用加载提示：`TIMEOUT_COUNT=%d,Load address: 0x%lx`、`## Booting image at %08lx ...`、`bootm`。
- 该分支**没有** `Warning!! Erase ...` 之类擦写警告。

官方提交证据：

- “Fortunately with serial console access, uboot provides the ability to boot an initramfs image transferred via tftp”
- 同一段紧接着说 “similarly an image may be flashed to nand however it will flash to *both* kernels” —— 把“临时启动”和“写 Flash”明确分开。

结论：选项 1 设计为**只把文件加载到 SDRAM 并执行**，不擦写 NAND。  
验证程度：官方描述 + 字符串 + 菜单语义；**本机未实测**。  
剩余风险：加载地址/文件名/镜像格式不匹配会导致启动失败并复位，但不应产生 NAND 写入；仍需以第一次实测日志确认没有擦除输出。

### 3.2 选项 2：Load system code then write to Flash via TFTP

字符串证据：

- `%d: System Load Linux Kernel then write to Flash via TFTP.`
- `Warning!! Erase Linux in Flash then burn new one. Are you sure?(Y/N)`
- `Operation terminated`
- `Writing image to 0x%x`

官方提交证据（决定性）：

> Note uboot's tftp flash install writes the transferred image to both kernel partitions.

同系列实测（ysc3839）：

> U-Boot 会先把下载来的数据写到闪存的 0x200000 位置 (也就是 kernel0)，再把数据写到 0x600000 位置 (kernel1)。

结论：选项 2 是**双内核槽写入**，不是“只写 kernel1”。  
验证程度：官方提交 + 同系列实测；本机未实测。  
风险：传输中断/文件错误会同时破坏两个内核；若文件大于 4 MiB，还可能越过内核分区边界（具体写入长度未在本机验证）。**不得把它当作单分区恢复手段。**

### 3.3 选项 3：Boot system code via Flash（默认）

字符串证据：

- `3: System Boot system code via Flash.`
- `Booting System 1` / `Booting System 2`
- `Verifying kernel1 uImage CRC, addr: 0x%x` / `Verifying kernel2 uImage CRC, addr: 0x%x`
- `flag_boot_rootfs`、`0x%X`
- `Boot failure detected on both systems`
- CRC 失败字符串：`Bad Magic Number,%08X`、`Bad Header Checksum`、`Bad Data CRC`

行为（官方提交）：

1. U-Boot 在 0x200000（system 1）和 0x600000（system 2）寻找 uImage。
2. 选择逻辑见第 4 节。
3. 只有 uImage 头/CRC 会阻止启动；**rootfs 是否匹配不在 U-Boot 检查范围内**。
4. 如果内核 CRC 正确但内核无法挂载 rootfs，U-Boot 不会因此回退到另一个系统。

这正好解释本机状态：kernel1 被写入合法的 OpenWrt uImage（CRC 正确），U-Boot 持续选择 system 2，内核因 rootfs 不匹配而失败/复位。

### 3.4 选项 4：Entr boot command line interface

- 字符串：`%d: System Enter Boot Command Line Interface.`，提示符 `MT7621 #`。
- 可用于 `printenv`、`help`、`nand id` 等只读命令。
- `saveenv`/`setenv` 属于 NVRAM 写入，禁止执行；必须单独授权。

### 3.5 选项 7/9：写 Bootloader（本机实测）

- 7：`System Load Boot Loader then write to Flash via Serial.`
- 9：`System Load Boot Loader then write to Flash via TFTP.`
- 9 带警告：`Warning!! Erase Boot Loader in Flash then burn new one. Are you sure?(Y/N)`
- **禁止进入/选择**。Bootloader 写坏后 UART 不再有输出，只能拆 NAND。

---

## 4. 启动选择算法（官方提交，逐条）

```text
系统 1 = kernel @ 0x200000
系统 2 = kernel @ 0x600000

if (flag_try_sys1_failed != 0 && flag_try_sys2_failed != 0):
    if uImage CRC(system1) is OK: boot system1
    else:                        boot system2   # 即使 system2 CRC 不对
elif (flag_try_sys1_failed != 0):
    boot system2
elif (flag_try_sys2_failed != 0):
    boot system1
else:
    if flag_last_success == 0: boot system1
    else:                      boot system2
```

补充规则：

- U-Boot **只设置** failed 标志，**从不清除**。
- 当选中的系统 uImage CRC 不正确时，U-Boot 设置该系统的 failed 标志。
- `flag_last_success` 只在两个 failed 都为 0 时生效：0=system1，1=system2。
- `flag_boot_rootfs` 在本机字符串中被打印为 `0x%X`，但官方提交没有解释其语义；**不要修改**。
- `flag_boot_success` **不在本机 U-Boot 字符串中**；它不是本机 U-Boot 的启动选择变量。
- `flag_ota_reboot` 出现在 U-Boot 字符串中，语义未证实；不要修改。

---

## 5. NAND 命令语法（本机 help 字符串）

```text
// 仅命令语法记录；禁止执行
nand id
nand read <addr> <len>
nand write <addr> <data...>
nand page <number>
nand erase <addr> <len>
nand oob <number>
nand dump
```

注意：

- 这是 Ralink 风格的 `nand` 命令，**不是**标准 U-Boot 的 `nand erase <offset> <size>` 语义；写入数据来自内存地址。
- **没有 `nand bad` 命令**。旧清单里的 `nand bad` 在本机 U-Boot 中不存在，执行只会报未知命令（无害，但不要把它当作坏块检查）。
- 上述命令全部属于 L4+；本轮不执行。

---

## 5.1 MIPS 地址空间与 `0xA0200000` 的正确解释

MT7621 是 MIPS32。地址不能只看“是否小于 256 MiB”；必须先判断它位于哪个 KSEG：

| 区域 | 虚拟地址范围 | 物理地址换算 | 属性 |
|---|---|---|---|
| KSEG0 | `0x80000000`–`0x9FFFFFFF` | `addr & 0x1FFFFFFF` | cached |
| KSEG1 | `0xA0000000`–`0xBFFFFFFF` | `addr & 0x1FFFFFFF` | uncached |
| KSEG2/其他 | 更高 | 映射方式不同 | 不用于本机常规 DRAM 访问 |

因此：

| 地址 | 段 | 物理地址 | 已知用途/状态 |
|---|---|---|---|
| `0x80001000` | KSEG0 | `0x00001000` | 本机 uImage header 的 load/entry（OpenWrt 与 stock 均如此） |
| `0x80A00000` | KSEG0 | `0x00A00000` | U-Boot 字符串中出现；候选 TFTP 下载地址，**UNVERIFIED** |
| `0xA0200000` | KSEG1 | `0x00200000` | 旧文档称为“载入地址”；**用途 UNVERIFIED** |
| `0x8046A0A0` | KSEG0 | `0x0046A0A0` | 原厂 stock uImage 的 entry point（header 中给出） |

必须区分五个不同的地址概念：

1. **U-Boot TFTP 下载地址**：U-Boot 把文件放进 SDRAM 的位置。字符串中出现 `0x80A00000`，但运行时是否使用、是否询问、是否随镜像变化，均未验证。
2. **uImage header load address**：镜像头声明的加载地址；本机 OpenWrt 与 stock 都是 `0x80001000`。
3. **uImage entry point**：镜像头声明的入口；OpenWrt 为 `0x80001000`，stock 为 `0x8046A0A0`。
4. **内核解压目标地址**：由内核/引导代码决定；本机未验证。
5. **实际 DRAM 物理地址**：由 KSEG 掩码换算得到，但同一物理页可能同时有 cached/uncached 两个虚拟别名。

关于 `0xA0200000`：

- 它**不是**“超出 256 MiB RAM”，而是 KSEG1 的 uncached 映射，物理地址为 `0x00200000`。
- 这个物理值与 NAND 的 kernel0 偏移（`0x00200000`）相同，但这只是数值巧合；**不能**据此推断它是 TFTP 加载地址，也不能据此生成任何 U-Boot 命令。
- 它的真实来源/用途未在官方源码或本机日志中证实 → **UNVERIFIED**。

> 禁止生成任何基于 `0xA0200000` 或 `0x80A00000` 的“加载地址命令”。实际地址以上机时 U-Boot 屏幕提示、`printenv` 与本机日志为准。

---

## 6. 选项 1 / 2 的风险矩阵

| 操作 | 目标 | 是否写 NAND | 证据强度 | 主要风险 | 本阶段 |
|---|---|---|---|---|---|
| 选项 1 + stock kernel0.bin | SDRAM | 否（按设计） | 官方描述 + 字符串；未实测 | 地址/格式不符导致启动失败；需确认无擦除输出 | 未授权 |
| 选项 1 + OpenWrt initramfs | SDRAM | 否（按设计） | 官方描述“boot initramfs via tftp”；未实测 | 同上；initramfs 较大，加载时间较长 | 未授权 |
| 选项 2 + 4 MiB stock kernel | 0x200000 **和** 0x600000 | **是，双槽** | 官方提交 + 同系列实测 | 覆盖两个内核；中断/坏文件导致双槽损坏 | 未授权 |
| 选项 2 + kernel+rootfs 拼接镜像 | 从 0x200000 起的连续区域 | **是，跨分区** | 同系列实测 | 覆盖 kernel0/kernel1/rootfs0 等，风险最高 | 禁止 |
| 选项 3 | 从 Flash 启动 | 否 | 默认行为 | 无 | 允许（只读启动） |
| 选项 4 + printenv/help/nand id | CLI | 否 | 字符串 | 误输入写命令 | 未来只读授权 |
| 选项 7/9（本机实测） | Bootloader | **是** | 字符串警告 | 设备彻底无输出 | **禁止** |

---

## 7. 旧文档纠错

| 旧说法 | 证据 | 纠正 |
|---|---|---|
| “U-Boot 载入地址 0xA0200000” | `0xA0200000` 是 KSEG1 地址，物理为 `0x00200000`，并非超出 RAM；但它究竟是 TFTP 下载地址、uImage 地址还是其他用途，未验证。本机 uImage load=0x80001000，字符串出现 0x80A00000 | **删除“它是本机载入地址”的说法**；标记 UNVERIFIED；以运行时提示和 uImage 头为准，禁止生成基于它的命令 |
| “只读命令包含 `nand bad`” | 本机 help 字符串无 `nand bad` | 改为 `help` / `nand id` / `printenv`；不要依赖 `nand bad` |
| “菜单 9 是写 Bootloader” | 2026-11-07 真实日志：本机菜单为 1,2,3,4,7,9，9 确实是 Bootloader 写入 | 以屏幕菜单为准；永不选 7/9 |
| “改 `flag_boot_rootfs=0` 可切到第 0 套” | 官方提交未解释该变量；本机仅见打印 | 不作为首选方案；系统切换使用官方 failed/last_success 语义 |
| “选项 2 只写 kernel1” | 官方提交明确写两个 kernel | **禁止**该假设 |

---

## 8. 结论

1. 本机 U-Boot 的身份、菜单、NAND 命令语法已由备份二进制直接证实。
2. 双系统选择算法由 OpenWrt 官方提交证实，并与本机备份中的 flag 值吻合。
3. 选项 2 的双内核写入有官方 + 同系列双重证据，必须按“写两个槽”对待。
4. 选项 1 的“只加载 SDRAM、不写 Flash”有官方描述与菜单字符串支持，但本机未实测；第一次使用必须在 UART 全日志下确认没有擦除/写入输出。
5. 关键盲点仍是：本机实际启动日志。没有它，不进入任何 L5+ 操作。
