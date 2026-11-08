# TOOLCHAIN_TEST_REPORT — 硬件接入前封版测试报告

日期：2026-11-06
测试主机：Windows 11 Home China 10.0.26200 x64
运行时：Windows PowerShell 5.1.26100.7705；Python 3.13.7；pyserial 3.5
范围：**仅离线/只读测试**。未连接或拆开路由器、未接 UART、未打开真实 COM、未上电、未发送串口字节、未执行真实 TFTP、未写 Flash、未修改任何网络适配器/DNS/DHCP/Wi-Fi/路由/防火墙。

> 四种结果严格区分：**PASS-STATIC**、**PASS-OFFLINE**、**PASS-MOCK**、**PASS-WINDOWS-READONLY**。没有 UART 硬件 PASS；真实硬件项为 HARDWARE-BLOCKED / NOT TESTED。
> 软件测试通过不等于真实硬件恢复通过。Mock 不是 Windows 实机结果。

> **2026-11-07 实测更新**：COM14 LISTEN-ONLY 采集成功，原始 BIN 49,392 B，SHA-256 `89a6e2ff…`；确认 System 2 → OpenWrt 6.12.112 → UBI mtd9 attach 失败 → VFS panic → 1 秒复位循环。真实 UART 采集现为 **PASS-HARDWARE-READONLY**；真实 Apply/Rollback、Flash/NVRAM 写入仍为 HARDWARE-BLOCKED / NOT AUTHORIZED。详见 `R3G_BOOT_LOG_ANALYSIS.md`。
>
> **2026-11-07 20:57 L4 更新**：菜单 4 + 一次 `printenv` 成功，TX 仅 11 B；取得 `flag_last_success=1`、两个 failed=0 等当前环境值。未执行任何写入。原始日志含敏感信息，不得发布。

---

## 1. 汇总

| 模块 | 结果 | 类别 |
|---|---|---|
| Python 语法（9 文件） | PASS | PASS-STATIC |
| TFTP 完整套件 51 项 × 5 次 | 51/51 × 5 | PASS-OFFLINE |
| UART 只读 28 项 | 28/28 | PASS-OFFLINE |
| L4 探针离线状态机 | 3/3 | PASS-OFFLINE |
| no-pyserial 4 项 | 4/4 | PASS-OFFLINE |
| NIC 纯逻辑 40 项 | 40/40 | PASS-MOCK |
| NIC mock 恢复链 35 项 | 35/35 | PASS-MOCK |
| NIC Show/WhatIf/守卫 | 15 PASS / 4 BLOCKED / 0 FAIL | PASS-WINDOWS-READONLY + HARDWARE-BLOCKED |
| 文档安全扫描 237 项 | 237/237 | PASS-STATIC |
| 固件/备份校验 | ALL CHECKS PASSED | PASS-OFFLINE |
| 总预检 | PREFLIGHT PASSED | PASS-OFFLINE |
| 真实 UART/COM/上电 | PASS-HARDWARE-READONLY | COM13；启动日志、L4 printenv、L5 initramfs |
| L7-A OpenWrt 安装写入 | PASS-HARDWARE-WRITE | OpenWrt 已安装并断电重启验证 |
| 真实 Apply/Rollback/DAD | 未执行 | HARDWARE-BLOCKED |

---

## 2. TFTP（51/51 PASS；连续 5 次）

```powershell
python -I <repo-root>/uart-toolkit\tests\selftest_tftp.py
```

READY 握手：服务端 `sock.bind()` 成功后才用临时文件 + `os.replace()` 原子写 READY；客户端校验 `READY <bind>:<port>` 精确内容并检查子进程存活；超时 15 秒，不使用固定睡眠。

```text
PASS READY handshake is written only after bind - READY 127.0.0.1:17101
PASS delayed startup waits for READY - elapsed=0.67s
PASS READY timeout is reported, not guessed
PASS early server exit is reported by handshake
PASS occupied UDP port is reported by handshake - second server must not report READY
PASS repeated start/stop leaves no child running
PASS mid-test client abort leaves no child running
PASS port is reusable after mid-test abort
```

连续 5 次：

```text
RUN 1: TOTAL 51  PASS 51  FAIL 0  SKIP 0
RUN 2: TOTAL 51  PASS 51  FAIL 0  SKIP 0
RUN 3: TOTAL 51  PASS 51  FAIL 0  SKIP 0
RUN 4: TOTAL 51  PASS 51  FAIL 0  SKIP 0
RUN 5: TOTAL 51  PASS 51  FAIL 0  SKIP 0
ALL EXECUTED TFTP SELF-TESTS PASSED
```

覆盖：RRQ-only、WRQ 拒绝、白名单、SHA-256 pin、TOCTOU 单次快照、RFC 2348 块大小/OACK、非法块大小 ERROR 8、ACK 严格匹配、重传、路径穿越/junction、文件大小限制、源地址绑定、READY 清理。

---

## 3. UART（28/28 + 4/4 PASS，离线）

```powershell
python -I tests\selftest_uart.py
python -I tests\selftest_no_pyserial.py
```

- 多轮启动 System 1→2→1、kernel1/kernel2 地址、CRC/panic/UBI/VFS、flag 历史值。
- `uart_capture.py` 无 `ser.write`/`serial.write`；无自动按键/回车/命令/定时发送。
- `uart_console.py` 发送功能独立，必须显式 `--allow-tx`，不属于第一阶段。
- 无 pyserial：replay 成功；capture --port exit 5；console 无 `--allow-tx` exit 2。

**以上 28/28 是离线测试，没有真实 COM/UART 硬件参与。**

### 3.1 L4 只读探针（PASS-OFFLINE + PASS-HARDWARE-READONLY）

`scripts/uart_l4_readonly_probe.py` 是硬件阶段附加工具，不修改冻结 v5.2.1 的其他脚本。它硬编码只发送：

```text
4 + Enter
printenv + Enter
```

不读取键盘，不接受任意命令，不发送任何其他字节。

离线测试 `tests/selftest_l4_probe.py` 使用 fake serial，断言 TX 精确为 `4\rprintenv\r`，并验证输出保存和串口关闭：

```text
PASS l4 probe sends only 4/Enter/printenv
PASS l4 probe captures printenv output
PASS l4 probe closes the port and writes meta/actions
```

2026-11-07 20:57 真实执行：COM14，RX 25,729 B，TX 11 B，`state=COLLECT`；取得当前启动标志（`flag_last_success=1`、两个 failed=0）。原始日志含敏感信息，未发布。

### 3.2 L5 菜单 1 + initramfs（PASS-OFFLINE + PASS-HARDWARE-READONLY）

`scripts/uart_l5_tftp_probe.py` 只发送菜单 `1`、设备/服务器默认回车和 initramfs 文件名；`tests/selftest_l5_probe.py` 使用 fake serial 验证 TX 序列。真实执行于 2026-11-07 23:10：TFTP 传输 7,607,308 B，OpenWrt 25.12.6 initramfs 进入 RAM shell；未写 NAND。`scripts/uart_readonly_diag.py` 的固定命令列表完成分区、cmdline、UBI、内核 SHA-256 和 PEB 头只读采集。

### 3.3 L7-A OpenWrt 安装（PASS-HARDWARE-WRITE）

第二份整片备份已复制到 USB `I:` 并校验；OpenWrt 安装镜像 SHA-256 `78c15850…`；固定安装命令完成 UBI 格式化 940 PEB、rootfs/rootfs_data 创建、kernel 写入，输出安装成功。首次 NAND 启动和 12V 断电重启均成功；LAN `192.168.1.1` ping 0% 丢包，22/80 开放，HTTP 200。root 密码、Wi-Fi、WAN 尚未配置。

### 3.4 Wi-Fi 2.4/5 GHz 配置（PASS-HARDWARE-CONFIG）

`scripts/uart_wifi_config.py` 仅发送固定 UCI 命令，Wi-Fi 密钥通过 `stty -echo` + `read` 传入，不写入 shell 命令行或本工具日志；密钥单独保存在本地文件。实际结果：`phy0-ap0`（2.4 GHz，`R3G-OpenWrt`，channel 1，HT20）与 `phy1-ap0`（5 GHz，`R3G-OpenWrt-5G`，channel 36，VHT80）均为 AP，`iwinfo` 显示 WPA2-PSK (CCMP)。客户端关联已验证（test phone，5G，`192.168.1.124`，-27 dBm）；WAN 尚未验证。

---

## 4. 网卡 / DAD / 恢复（mock + Windows 只读）

### 4.1 纯逻辑 40/40（PASS-MOCK）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\set_wired_ip.ps1 -SelfTest
```

### 4.2 Mock 恢复链 35/35（PASS-MOCK）

实际调用 `Restore-StateInternal`、`Wait-ManualAddressPreferred`、`Remove-NewIpv4`、`Restore-DnsState`、`Get-CurrentSnapshot`、`Compare-State`；注入 ops，不执行真实网络命令。

```text
PASS restore: DadTransmits=0 is INCONCLUSIVE -> INCONCLUSIVE
PASS restore: DadTransmits unreadable is INCONCLUSIVE -> INCONCLUSIVE
PASS restore: Tentative manual address times out -> ROLLBACK_FAILED
PASS restore: Duplicate manual address fails -> ROLLBACK_FAILED
PASS restore: Invalid manual address fails -> ROLLBACK_FAILED
PASS restore: Deprecated manual address fails -> ROLLBACK_FAILED
PASS restore: missing AddressState is INCONCLUSIVE -> INCONCLUSIVE
PASS restore: adapter disappears during manual DAD -> ROLLBACK_PENDING
PASS restore: GUID changes during manual DAD -> ROLLBACK_FAILED
PASS restore: MAC changes during manual DAD -> ROLLBACK_FAILED
PASS restore: DHCP+Manual full restore -> ROLLBACK_VERIFIED
RESTORE TOTAL 35  PASS 35  FAIL 0
TOTAL 40  PASS 40  FAIL 0
```

### 4.3 Windows 只读/守卫（PASS-WINDOWS-READONLY）

```text
PASS Show runs read-only
PASS Show does not mark Wi-Fi as target
PASS target interface has DAD enabled (DadTransmits > 0, read-only) - value=3
PASS Get-NetAdapter has no -InterfaceGuid parameter - exit=0
PASS Show accepts exact GUID+MAC identity
PASS Show rejects wrong MAC / wrong GUID
PASS Apply without GUID+MAC is refused
PASS Apply + Rollback together is refused
BLOCKED Apply WhatIf - administrator rights required
BLOCKED Rollback WhatIf - administrator rights required
BLOCKED Real ARP/neighbor/DAD probe on USB interface
BLOCKED Real automatic rollback on modification failure
TOTAL 19  PASS 15  FAIL 0  BLOCKED 4  SKIP 0
```

真实 Apply/Rollback、真实 DAD、真实 DNS/DHCP 失败注入：**HARDWARE-BLOCKED**，未执行。

---

## 5. 文档安全扫描（237/237 PASS）

```powershell
python -I tests\selftest_safety.py
```

### 5.1 新规则

- 扫描单位是段落；标题 `历史证据`/`风险分析`/`原理`/`研究记录`/`BLOCKED`/`禁止` 不再提供任何自动豁免。
- 正向菜单操作独立识别：选择/进入/按/启动/执行菜单 2、选项 2、中文数字、输入 2、输入 Y、确认写入、恢复原厂、写入内核、选项 1/2；支持空格、标点、跨行、跨段、不同语序。
- 危险写入独立识别：`mtd write/erase`、`nand write/erase`、`setenv`、`saveenv`、`fw_setenv`、`ubiformat`、`flash_erase`、`flashcp`、`nvram set/commit`、`uci set/commit`、`dd ... of=/dev/mtd|ubi`、`sysupgrade`。
- 只读命令不误报：`printenv`、`fw_printenv`、`nanddump`、`nand read`、`mtdinfo` 不当作写入。
- 同一段落出现正向步骤 → 违规，即使同段有 `BLOCKED`/禁止/历史；禁止语句不能放行后面的正向操作。
- 历史命令记录只允许逐文件、逐行号、精确行内容 SHA-256 白名单；白名单条目及原因在 `tests/safety_allowlist.json`，扫描器逐条校验内容；过期条目会 FAIL。

### 5.2 范围

- 根入口：`START_HERE.md`、`FLASH_SAFETY_REVIEW.md`、`TOOLCHAIN_TEST_REPORT.md`、`README.md`、`SOURCE_RESEARCH.md`、`HARDWARE_SESSION_CHECKLIST.md`、`READ_ONLY_UART_PROCEDURE.md`、`R3G_RECOVERY_DECISION_TREE_FINAL.md`。
- `docs/`、`research/`（合成研究文档）、`scripts/`、`tests/`。
- `research/sources/` 原始 HTML/JSON/字符串导出是外部证据数据，不当作操作手册；扫描其 `research/*.md` 摘要。
- `tests/selftest_safety.py` 自身包含 60 个恶意测试字符串，故排除自扫描；其余测试文件均扫描。

### 5.3 样例

60 个合成样例（20 个 v5.2 保留 + 40 个新增），20+ 违规、20+ 允许。审计发现的漏检全部成为固定回归：

```text
请再次选择菜单 2。                  -> 违规
请进入菜单 2。                      -> 违规
选择菜单2后等待。                   -> 违规
在 U-Boot 中输入 2。                -> 违规
请执行 mtd write image kernel1。    -> 违规
请执行 setenv flag_last_success 0。 -> 违规
```

只读/禁止样例：

```text
fw_printenv 只读，不写入。          -> 允许
nanddump /dev/mtd0 只读。           -> 允许
禁止执行 `mtd write`。              -> 允许
`sysupgrade.bin` 是文件名，不是命令。 -> 允许
```

实际输出：

```text
TOTAL 203  PASS 203  FAIL 0
ALL SAFETY SELF-TESTS PASSED
```

白名单共 9 条（6 条扫描器回归示例 + 3 条 verify_firmware 的升级包类型标签），每条含文件、行号、SHA-256、原因。

---

## 6. 固件与备份（PASS-OFFLINE）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\verify_firmware.ps1 -VerifyBackups
```

```text
initramfs-kernel.bin   7607308   8d58d8a14c72eacf  PASS
kernel1.bin            3331950   cc7b1d187e1f5f42  PASS
rootfs0.bin            5636096   3bede8061525b69e  PASS
sysupgrade.bin         7813734   78c15850ee6d41f2  PASS（仅升级包）
tftp_stock\kernel0.bin 4194304   ab58d7a35bb75c98  PASS
tftp_stock\kernel1.bin 4194304   ab893d6c0732dcea  PASS
backup:r3g-stock-full-20261104.bin 133693440 0d690a8f6c36f4d3 PASS
12 个分区全部 matches manifest
ALL CHECKS PASSED
```

整片备份真实路径与哈希见 `reports/FINAL_READINESS_MATRIX.md`。当前只有一份物理副本；L7 前必须制作第二份并重算 SHA-256（ACTION REQUIRED）。

---

## 7. 总预检（PASS-OFFLINE）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\preflight.ps1
```

`PREFLIGHT PASSED`：PowerShell/Python/pyserial、脚本解析、Python compile、固件/备份哈希、USB-TTL 状态；不打开 COM、不修改网络。

---

## 8. HARDWARE-BLOCKED / UNVERIFIED

| 项目 | 状态 |
|---|---|
| 真实 UART 采集、COM 打开、DTR/RTS | **PASS-HARDWARE-READONLY（2026-11-07）** |
| R3G 上电、J4 实物测量 | PARTIAL E3：日志与菜单 4 已工作；万用表/针号仍需复核 |
| U-Boot 菜单/命令行 + `printenv` | **PASS-HARDWARE-READONLY（2026-11-07 20:57）** |
| TFTP 实机互通 | HARDWARE-BLOCKED（L5 未授权） |
| 真实 Windows Apply/Rollback/DAD | HARDWARE-BLOCKED |
| 菜单 2 擦写范围 | BLOCKED |
| J4 线色/针号 | PARTIAL E3（TX/RX/GND 路径已工作；实物复核未完成） |
| 2.28.46 厂商真实性与兼容性 | UNVERIFIED |
| 第二份整片备份 | ACTION REQUIRED（L7 前） |

---

## 9. 结论

- 文档扫描器漏检已修复，60 个合成样例、L4/L5/L7 工具测试和全范围扫描通过（237/237）。
- TFTP 51/51 连续 5 次、UART 28/28、L4/L5 探针测试、no-pyserial 4/4、NIC 40/40 + 35/35、Windows 只读 15/4 BLOCKED、扫描 237/237、固件/备份/预检通过。
- 真实 UART 启动日志、L4 `printenv`、L5 initramfs 和 L7-A OpenWrt 安装已完成；安装后断电重启验证通过。
- 未修改任何真实 Windows 默认路由/DNS/DHCP；未执行真实 Apply/Rollback/DAD；未使用任何写入型 U-Boot 菜单，Bootloader 写入永久禁止。

---

## 10. 安装后 Wi-Fi 客户端验证（2026-11-08）

`scripts/uart_readonly_diag.py` 新增只读 `radio`/`scan` 配置；新增 `scripts/wlan_force_scan.ps1`（Windows 原生 WlanScan，只触发扫描，不改适配器配置）。

- 射频：MT7603E / MT76x2E 固件与校准加载正常；hostapd 两个 AP 均 `AP-ENABLED`，无错误。
- 扫描：R3G 反向扫描看到 10 个邻居 BSS（最弱 -83 dBm）；Windows AX200 强制扫描看到 `R3G-OpenWrt`（99%，ch1）与 `R3G-OpenWrt-5G`（94%，ch36）。
- 关联：test phone（`AA:BB:CC:DD:EE:05`）连接 `R3G-OpenWrt-5G`，WPA 4-way 完成，信号 -27 dBm，VHT80/NSS2，702–866 Mbps；DHCP 分配 `192.168.1.124`。
- LAN 可达：PC 有线侧 `ping 192.168.1.124` 4/4，0% 丢包，1–8 ms。
- 证据：`logs/r3g_readonly_diag_20261108-002728.*`（关联/DHCP）、`002254.*`（扫描）、`002149.*`（射频）。
- 说明：路由器时钟未 NTP 同步，hostapd 日志时间为路由器本地时钟。
- 2.4 GHz 客户端关联尚未单独实测；AP 已启用且 AX200 扫描可见（99%）。
- 本验证未修改路由器配置，未执行 Flash/NVRAM 写入。

---

## 11. WAN 与 LuCI 安装（2026-11-08）

- 唯一网线改插「宿舍墙上网口 ↔ WAN」；WAN 默认 proto=dhcp，未改配置即获得 `198.51.100.0/24`，网关 `198.51.100.1`，DNS `192.0.2.53/.34`。
- `ping 223.5.5.5` 4/4、`ping www.baidu.com` 2/2；204 探测 0 字节 RC=0，无门户；手机 5G 上网验证通过。
- 本镜像无 opkg，使用 apk-tools 3.0.5；`apk update` 11,042 packages；`apk add luci` 12.1 MiB / 160 packages。
- 移除镜像残留的旧 `uhttpd.main.lua_prefix`（指向不存在的 Lua 文件），提交配置后重启 uhttpd。
- `/cgi-bin/luci/` 返回 `403 Forbidden` + `x-luci-login-required: yes` + LuCI 登录页（正常未登录响应）；静态 `/` 200。
- 新工具（固定命令 + 确认开关）：`uart_luci_install.py`、`uart_luci_enable.py`、`uart_luci_fix_uhttpd.py`；扫描器 235/235；修复工具中的配置提交命令行已加入精确 allowlist。
- 证据：`logs/r3g_readonly_diag_20261108-004958.*`、`logs/r3g_luci_install_20261108-005451.*`、`logs/r3g_luci_fix_uhttpd_20261108-005916.*`、`logs/r3g_readonly_diag_20261108-010558.*`。
- root 密码更换：用户经 LuCI 完成（`/etc/shadow` 17:20 更新，passwd 日志有记录）；新密码未记录在本项目。
- 2.4G 关联与 LuCI 登录验证通过；软重启验收由 `scripts/uart_reboot_test.py`（固定 `sync`+`reboot`，确认开关）执行：UBI 940 PEB、squashfs/UBIFS 恢复、WAN link up、双 AP forwarding、无 panic；重启后手机上网与 LuCI 正常。证据 `logs/r3g_reboot_test_20261108-012608.*`。
- 说明：OpenWrt 串口为 askfirst 模式，重启后需按 Enter 并输入密码登录；UART root 会话已随重启结束。
