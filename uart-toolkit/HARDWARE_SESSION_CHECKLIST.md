# HARDWARE_SESSION_CHECKLIST — R3G v1 第一次只读 UART 采集

日期：2026-11-06
适用：Xiaomi Mi Router 3G v1（R3G，128 MiB NAND），CH340/CP210x/FTDI 3.3V USB-TTL。
事实源：[README.md](../README.md)。

本清单只覆盖 **L3 只读启动日志采集**。不包含 U-Boot 按键、命令行、TFTP、NVRAM 或 NAND 写入。

> 证据分级：E1 = 官方文档/源码；E2 = 官方 Wiki 照片或本地研究记录；E3 = 本机万用表/串口实测；E4 = 未验证推测。
> **2026-11-07 实测更新**：COM14 LISTEN-ONLY 采集成功，已收到 U-Boot/内核日志；已连接的 TX→RXD 与 GND 路径有效，但 J4 完整针号/线色仍需实物确认。恢复写入仍未授权。
> **2026-11-07 L4 例外**：在单独授权下，使用 `uart_l4_readonly_probe.py` 连接 CH340 TXD → R3G RX，菜单 4 被接受，仅发送 11 字节执行 `printenv`。第一轮 L3 仍只接 TX/GND，不接 TXD。

---

## A. 上电前

- [ ] **A1. 型号确认**：机身/标签/系统信息确认为 R3G v1（USB 3.0、128 MiB NAND），不是 v2、R3P 或小米路由器 3（非 3G）。
- [ ] **A2. J4 外观**：断电、未接电源，检查 J4 焊点/焊盘，无虚焊、无锡桥、无相邻焊盘短路。
- [ ] **A3. GND 通断**：万用表通断档，J4-3（Black/GND）对屏蔽罩或电容负极应导通；若不通，停止，不要凭线色接线。
- [ ] **A4. 信号对 VCC 短路**：断电测量 J4-4（TX）、J4-2（RX）对 J4-1（未知/疑似 VCC）不得短路；J4-1 永不连接。
- [ ] **A5. J4 映射复核**：按下方表格核对丝印/照片；若实物丝印与资料不一致，停止并记录，不猜测。
- [ ] **A6. CH340 逻辑电平**：适配器必须为 **3.3V TTL**；用万用表/规格书确认 TX 空闲电平为 3.3V 左右。不要因为模块标“3.3V 供电”就假定 TX 是 3.3V；不要使用 RS-232 电平。
- [ ] **A7. 供电边界**：R3G 使用原装 12V 电源；USB-TTL 只连接 TX/GND，**不负责给路由器供电**；CH340 VCC 不接 J4。
- [ ] **A8. COM 身份**：运行 `detect_com.ps1`，确认 Present 的 CH340 `1A86:7523`、FriendlyName、PNP 状态；拔插一次确认 COM 号消失/重现。若有多个 CH340，必须由用户确认哪一个属于本次接线，脚本不得自动选择第一个。
  - **2026-11-07 实测**：CH340 **COM14** 为 Present/OK；COM12/13 是 phantom。已用 COM14 完成只读采集；仍不得硬编码端口，插拔后重新确认。
- [ ] **A9. 串口参数**：115200 baud，8 data bits，Parity None，Stop bits 1，Flow control None；DTR=False，RTS=False。未验证前不得改变控制线。
- [ ] **A10. 日志目录**：`logs/` 可写、磁盘空间足够（至少数百 MB）、文件名带时间戳；确认 `.bin`/`.log`/`.meta.json` 都会保存。
- [ ] **A11. 只读约束**：确认本轮不运行 `uart_console.py`，不发送任何字节，不按 U-Boot 菜单，不执行 `saveenv`/`reset`/`nand` 写入；这些操作全部禁止。

### J4 映射与证据

| J4 | 丝印/记录 | CH340 | 第一轮 | 证据等级 |
|---|---|---|---|---|
| 4 | White / TX | **RXD** | **连接**（R3G TX → CH340 RXD） | E2：官方 Wiki 照片/本地研究记录；未在本机用示波器/逻辑分析仪确认 |
| 3 | Black / GND | **GND** | **连接**（共地） | E2；必须用 E3 通断复核 |
| 2 | Green / RX | TXD | **第一轮不接**；2026-11-07 L4 单独授权时已连接并工作 | E3（L4 菜单 4 被接受）；针号/丝印仍需实物复核 |
| 1 | 未标，疑似 VCC | — | **永不连接** | E4；不猜测、不接线 |

官方存档 `research/sources/wiki_mir3g_archive.html.txt` 确认 UART 为 **3.3 V、115200 8N1**；具体 J4 线色/针号来自照片/研究记录，必须用实物丝印和万用表复核。若官方资料与实物不一致，停止并报告。

---

## B. 接线（断电完成）

只允许两根线：

```text
R3G J4-4 (TX)  → CH340 RXD
R3G J4-3 (GND) → CH340 GND
```

不接：

```text
CH340 TXD → R3G J4-2 (RX)     第一轮不接
CH340 VCC → R3G J4-1          永不连接
```

- 断电接线；接完用万用表再次确认 GND 连通、TX/RX 对 VCC 无短路。
- 不要把线色当作唯一依据；以 J4 丝印、通断和电压为准。
- 如果 J4-1 无法确认，保持悬空。

---

## C. 采集

1. 先启动监听，再上电：

```powershell
python -I <repo-root>/uart-toolkit\scripts\uart_capture.py --port COMx --duration 180
```

2. 确认输出包含 `LISTEN-ONLY (no bytes are sent)` 和日志路径；确认 `.bin` 原始字节文件会生成。
3. 由用户手动给 R3G 接原装 12V 电源；采集器不发送任何字节，不按任何键。
4. 观察 2–3 轮启动；不要进入 U-Boot 菜单，不输入命令。
5. Ctrl+C 停止，保存 `.bin`、`.log`、`.meta.json`；记录 COM、HWID、参数、SHA-256、开始/结束时间。
6. 用 `uart_analyze.py` 生成分析报告；原始 `.bin` 为权威证据，文本日志仅辅助阅读。

---

## D. 立即停止条件

- 适配器/板子发热、异味、冒烟 → 立即断电。
- J4 TX 出现 5V 或负电压 → 立即断电，检查电平和接线。
- 串口无任何输出超过 60 秒 → 先检查 GND/COM/波特率；不要反复上电，不要按键。
- COM 口反复消失 → 检查 USB 线/口/驱动/静电。**2026-11-07 实测**：路由器 12V 上电瞬间 CH340 会掉线并重新枚举；不要在探针打开时上电，应先让路由器进入启动循环再启动探针。
- 出现 `Boot failure detected on both systems`、连续 panic/reboot loop → 保存日志后停止，不执行任何写入。
- 任何需要输入字符、进入菜单、`saveenv`、`reset`、`nand`/`mtd` 写入的冲动 → 停止；本轮未授权。

---

## E. 采集后

- [ ] 原始 `.bin` 与 `.log` 只读保存，计算 SHA-256。
- [ ] 填写 `docs/RECOVERY_DECISION_TREE.md` 的观察表（或最终决策树）。
- [ ] 区分“已确认事实 / 高可信推断 / 未证实假设 / 待验证问题”。
- [ ] 不根据单次黄灯、Wi-Fi 消失或猜测执行启动标志修改。
- [ ] 等待用户单独授权下一阶段；本轮不执行任何 Flash/NVRAM 操作。
