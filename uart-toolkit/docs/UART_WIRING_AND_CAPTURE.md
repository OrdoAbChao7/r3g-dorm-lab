# UART_WIRING_AND_CAPTURE — 接线、采集与日志判读

日期：2026-11-04
适用：R3G v1（J4 4 针），CH340/CP210x/FTDI 3.3V USB-TTL

---

## 1. 硬件与工具

| 物品 | 要求 |
|---|---|
| USB-TTL | 3.3V 逻辑；CH340/CP210x/FTDI；能确认电平跳线 |
| 杜邦线 | 母-母或公-母，线径细、接触可靠 |
| 万用表 | 通断 + 直流电压 |
| 焊接工具 | 若 J4 只有焊盘；细线 + 助焊剂 |
| 路由器电源 | 原装 12V；不要用 USB-TTL 供电 |
| 电脑 | Windows 11；Python 3 + pyserial；或 PuTTY 备用 |

---

## 2. 针脚与接线

J4 丝印（官方 Wiki 照片；必须用万用表在你的板子上复核）：

| J4 | 丝印 | 接到 CH340 | 第一轮是否连接 |
|---|---|---|---|
| 4 | White/TX | **CH340 RXD** | **连接**（路由器 TX → 适配器 RXD） |
| 3 | Black/GND | **CH340 GND** | **连接**（共地） |
| 2 | Green/RX | CH340 TXD | **不接**（第一轮只监听，不发送） |
| 1 | 未标（疑似 VCC） | — | **永不连接** |

规则：

- **第一轮只接两根：J4 TX → CH340 RXD，J4 GND → CH340 GND。**
- **第一轮不接 CH340 TXD，也不接 J4 RX。**
- VCC 永不连接。
- 只有进入 L4 且单独授权后，才考虑补接 J4 RX ↔ CH340 TXD。
- 断电接线，检查无短路后再上电。

### 电平复核

1. 断电，万用表通断：J4-3 与屏蔽罩/电容负极应导通。
2. 上电（需授权），直流电压：TX 空闲应接近 3.3V；GND 为 0V。
3. 若 TX 是 5V 或负电压，停止，检查适配器/针脚。

---

## 3. CH340 注意事项

- 很多 CH340 模块有 5V/3.3V 跳线；**必须确认在 3.3V**。
- 部分模块的 VCC 引脚始终输出 5V；即使跳线在 3.3V，也不要接 VCC。
- CH340 的 DTR/RTS 在打开串口时可能产生瞬态；本工具在打开前/后都设为 False，但驱动仍可能短暂拉低。
  - R3G 的 J4 没有 DTR/RTS 线，瞬态不会直接复位路由器。
  - 若你使用带 DTR/RTS 的夹具，确认它们没有接到板子的 Reset/BOOT 点。
- 幽灵 COM 设备：设备管理器里灰色/未知状态的 COM 号不能打开；以 `detect_com.ps1` 的 Present 列表为准。

---

## 4. 采集流程

### 4.1 预检

```powershell
powershell -ExecutionPolicy Bypass -File <repo-root>/uart-toolkit\scripts\detect_com.ps1
```

确认 Present 的 CH340/CP210x/FTDI 与 COM 号。

### 4.2 开始监听

```powershell
python -I <repo-root>/uart-toolkit\scripts\uart_capture.py --port COMx --duration 180
```

- 默认 LISTEN-ONLY，不发送字节。
- 确认屏幕出现 `LISTEN-ONLY (no bytes are sent)` 与日志路径。
- 再给路由器上电（需授权）。
- 看到 2–3 轮循环后停止（Ctrl+C）。

### 4.3 输出文件

| 文件 | 内容 |
|---|---|
| `logs/r3g_uart_<时间>.bin` | 原始字节（权威） |
| `logs/r3g_uart_<时间>.log` | 文本（Latin-1 逐字节映射） |
| `logs/r3g_uart_<时间>.meta.json` | 端口、HWID、字节数、SHA-256、开始/结束时间 |

保留 `.bin`；文本日志用于阅读，二进制用于复核。

### 4.4 分析

```powershell
python -I <repo-root>/uart-toolkit\scripts\uart_analyze.py --input logs\r3g_uart_<时间>.log --json reports\uart_analysis.json
```

---

## 5. 日志判读

### 5.1 U-Boot 阶段

正常顺序：

```text
U-Boot 1.1.3 (Nov  9 2018 - 09:28:13)
Ralink UBoot Version: 5.0.0.0
DRAM / NAND 初始化
Please choose the operation: 1–6
3: System Boot system code via Flash.
Booting System 1 / 2
Verifying kernelN uImage CRC, addr: 0x...
   Verifying Checksum ... OK
   Image Name: ...
   Load Address: 80001000
## Booting image at ...
   Uncompressing Kernel Image ... OK
Starting kernel ...
```

异常：

| 现象 | 含义 |
|---|---|
| `Bad Magic Number` | 该地址不是 uImage |
| `Bad Header Checksum` | uImage 头 CRC 错 |
| `Bad Data CRC` | 内核数据损坏 |
| `Boot failure detected on both systems` | 两个系统都失败 |
| 无任何输出 | 接线/波特率/Bootloader 死 |
| 单字符重复 | 波特率/地线/晶振问题 |

### 5.2 内核阶段（OpenWrt）

```text
Linux version 6.12.112 ...
SoC Type: MediaTek MT7621
Memory: ...
mt7530 ...
mt7603e / mt7612e ...
ubi0: attaching mtdN
ubi0: attached mtdN ...
ubi0: good PEBs / bad PEBs / corrupted PEBs
UBIFS ...
mount_root ...
```

异常：

| 现象 | 含义 |
|---|---|
| `VFS: Cannot open root device` | 内核找不到 rootfs |
| `Kernel panic - not syncing: VFS...` | rootfs 挂载失败 |
| `UBI error: cannot attach` | UBI 区损坏/不匹配 |
| `UBIFS error` | 文件系统损坏 |
| `mt76_eeprom_override` panic | 无线驱动/校准问题（旧快照 bug） |
| `Rebooting in N seconds` | panic 后自动复位 → boot loop |

### 5.3 关键判读原则

- **CRC OK ≠ 能启动**。U-Boot 只检查 uImage，不检查 rootfs。
- **能 attach UBI ≠ 能挂载 UBIFS**。两者是不同阶段。
- **能挂载 rootfs ≠ 能进入用户态**。init/驱动仍可能失败。
- 必须记录“最后一行的成功”和“第一行的失败”。

---

## 6. 常见故障

| 现象 | 检查 |
|---|---|
| 完全无输出 | GND 是否共地；TX/RX 是否交叉；波特率 115200；板子是否上电 |
| 乱码 | 地线不良；波特率不对；5V 电平；线太长 |
| 只有开机几个字符 | 电源不稳；串口线接触不良；USB 口供电不足 |
| 反复掉 COM | USB 线/口；CH340 驱动；静电 |
| 输出正常但按键无反应 | 先确认当前处在哪一层（见 6.1）；**不要**直接把原因归为 `uart_en=0`，也不要为了按键去改 `uart_en` |
| 菜单不出现 | `boot_wait=off`；需要在启动瞬间按键；或 U-Boot 已跳过 |

### 6.1 `uart_en` 到底影响什么（证据有限）

必须区分三个层次：

| 层次 | 是什么 | `uart_en` 是否控制它 | 证据 |
|---|---|---|---|
| U-Boot 菜单交互 | 上电后 `Please choose the operation:` 的 1–6 选择 | **未证实** | 本机 U-Boot 字符串引用 `uart_en`，并通过 bootargs 传成 `uart_en=%s`；这更像传给内核的参数，不能证明它门控 U-Boot 自身的按键输入 |
| U-Boot 命令行 | 菜单 4 进入的 `MT7621 #` | **未证实** | 同上；没有源码/反汇编证据表明 U-Boot 检查 `uart_en` 后才接受输入 |
| 原厂 Linux 串口控制台 | 原厂内核/用户态的 console 登录 | 官方 Wiki 用它开启 | 官方 Wiki 的 UART 安装步骤：`setenv uart_en 1` → `saveenv` → `boot`，用于“enable UART console for the default firmware” |

结论：

- 官方 Wiki 的 `uart_en 1` 是**为原厂 Linux 控制台**准备的，不是“修复 U-Boot 菜单按键”的通用开关。
- 社区文章（ysc3839）说默认 TTL 不可输入、需要 `uart_en=1`，但没有区分是 U-Boot 还是原厂控制台；不能据此断言 U-Boot 菜单受它门控。
- **本阶段不要修改 `uart_en`**。只读采集只需要 U-Boot/内核把日志打印出来，不需要键盘输入。
- 若未来确认 U-Boot 菜单确实无法接收输入，应先取得源码/反汇编证据，并把它作为独立的 L6 风险评估，而不是盲目 `setenv`。

---

## 7. 安全

- 不接 VCC；不用 5V TTL；不用 RS-232 电平。
- 断电接线；防静电。
- 适配器/板子发热、异味、冒烟 → 立即断电。
- 串口无输出超过 60 秒 → 先检查接线/COM/波特率，不要反复上电。
- 本阶段只读；任何按键发送都需要 L4 授权。
