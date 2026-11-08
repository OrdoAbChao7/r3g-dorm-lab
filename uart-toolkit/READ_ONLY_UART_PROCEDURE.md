# READ_ONLY_UART_PROCEDURE — 第一轮 UART 被动启动日志

日期：2026-11-06
适用：R3G v1，只读 UART，CH340 3.3V USB-TTL。
事实源：[README.md](../README.md)。

前置：已完成 `HARDWARE_SESSION_CHECKLIST.md` 的 A、B 部分。

> 本流程只使用 `uart_capture.py`。**禁止使用 `uart_console.py`**；第一阶段不发送任何字节、不按任何键、不进入 U-Boot 菜单。
>
> **2026-11-07 更新**：本文件的 L3 只读流程已完成（COM14，49,392 B）。之后在**单独授权**下执行了一次 L4 只读 `printenv`，使用专用 `uart_l4_readonly_probe.py`，只发送 11 字节；该例外见第 8 节，不改变 L3 的只读约束。

---

## 1. 主机侧预检（不接路由器）

```powershell
powershell -ExecutionPolicy Bypass -File <repo-root>/uart-toolkit\scripts\detect_com.ps1
powershell -ExecutionPolicy Bypass -File <repo-root>/uart-toolkit\scripts\preflight.ps1
```

确认：

- `detect_com.ps1` 列出 Present 的 CH340 `1A86:7523`；排除幽灵/ESP32/其他 CH340。
- **2026-11-07 实测**：CH340 **COM14** 为 Present/OK；COM12/13 是 phantom。第一阶段 LISTEN-ONLY 采集已完成（49,392 B），未发送字节。
- 多个 CH340 时，由用户确认本次使用的 COM；不得自动选择第一个。
- `preflight.ps1` 为 `PREFLIGHT PASSED`，不打开 COM、不修改网络。
- 串口参数：115200 / 8 / None / 1 / 无流控；DTR=False、RTS=False。

---

## 2. 接线（断电）

只接两根：

```text
R3G J4-4 (TX)  → CH340 RXD
R3G J4-3 (GND) → CH340 GND
```

不接 CH340 TXD，不接 CH340 VCC，不接 J4-1。接线后再次用万用表确认 GND 连通、TX 对 VCC 无短路。

---

## 3. 启动监听（先于上电）

```powershell
python -I <repo-root>/uart-toolkit\scripts\uart_capture.py --port COMx --duration 180
```

必须看到：

- `LISTEN-ONLY (no bytes are sent)`；
- 端口、VID:PID、日志路径；
- 没有发送/按键/自动命令。

**确认监听已开始后**，由用户给 R3G 接原装 12V 电源。采集器不会发送任何字节。

---

## 4. 采集窗口

- 观察 2–3 轮启动；第一轮不按任何键。
- 不进入 U-Boot 菜单，不输入命令，不执行 `saveenv`/`reset`/NAND 写入；这些操作本轮全部禁止。
- 出现冒烟/异味/过热/5V TX/COM 反复消失，立即断电并停止。
- 无输出超过 60 秒，先检查 GND/COM/波特率；不要反复上电。

---

## 5. 停止与保存

Ctrl+C 停止采集，确认生成：

| 文件 | 用途 |
|---|---|
| `logs/r3g_uart_<时间>.bin` | 原始字节，权威证据 |
| `logs/r3g_uart_<时间>.log` | 文本映射，阅读用 |
| `logs/r3g_uart_<时间>.meta.json` | COM、HWID、参数、字节数、SHA-256、时间 |

保留 `.bin`；不要只保留文本。记录本轮电源、接线、适配器和 COM 事实。

---

## 6. 离线分析

```powershell
python -I <repo-root>/uart-toolkit\scripts\uart_analyze.py --input logs\r3g_uart_<时间>.log --json reports\uart_analysis.json
```

在 `docs/RECOVERY_DECISION_TREE.md` 的观察表填写：

- U-Boot 版本 / 菜单是否出现；
- `Booting System 1/2`；
- kernel uImage CRC；
- `Starting kernel` / Linux 版本；
- UBI attach、UBIFS、rootfs 挂载；
- panic / VFS / watchdog / reboot loop；
- 最后一行的成功、第一行的失败。

---

## 7. 判读边界

- CRC OK ≠ 能启动；U-Boot 只检查 uImage，不检查 rootfs。
- UBI attach ≠ UBIFS 挂载成功；挂载 ≠ 用户态成功。
- 不以黄色 LED、Wi-Fi 消失或单次重启推断 boot loop；以原始日志为准。
- 没有日志证据，不进入恢复动作；不根据猜测修改启动标志。
- 本轮不执行任何 NVRAM/Flash 写入；只输出技术分析和下一步所需证据。

---

## 8. L4 只读例外（2026-11-07，已单独授权）

L3 仍只允许 `uart_capture.py`。L4 使用专用 `scripts/uart_l4_readonly_probe.py`，它硬编码只发送：

```text
4 + Enter
printenv + Enter
```

- 必须显式 `--allow-tx`；不读取键盘，不接受任意命令。
- 不使用 `uart_console.py`；不发送其他字节。
- 2026-11-07 实测：COM14，TX 11 B，`state=COLLECT`，进入 `MT7621 #`，取得当前环境值；未写入。
- CH340 在路由器 12V 上电瞬间会掉线并重新枚举。**先让路由器进入启动循环，再启动探针**；不要在上电瞬间打开串口。
- 原始日志含 SN/MAC/Wi-Fi 密码/管理员哈希；不得发布。脱敏摘录：`reports/uart_printenv_20261107-205729_REDACTED.txt`。
- 下一步 L5/L6/L7 仍需各自单独授权；本文件不提供写入命令。
