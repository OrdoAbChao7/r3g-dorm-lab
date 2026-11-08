# AUDIT_OLD_FILES — 本地已有成果审计

审计日期：2026-11-04
范围：`<repo-root>` 现有文档、脚本、备份、固件
原则：先核实文件，再采信文档；不覆盖唯一原厂备份。

---

## 1. 文件与哈希核实

### 1.1 原厂整片备份

| 项 | 结果 |
|---|---|
| 路径 | `backups/r3g-stock-full-20261104.bin` |
| 大小 | 133,693,440 B（= 0x07F80000） |
| 重算 SHA-256 | `0d690a8f6c36f4d34e89c2f13675120a500e72c6ae430eafeba4e4572e0e555d` |
| 与 manifest | 一致 |
| 结论 | 真实、完整、可读；是写入前状态 |

### 1.2 分区镜像

12 个分区全部存在，重算哈希与 manifest 一致。关键值：

| 分区 | SHA-256 |
|---|---|
| Bootloader | `bf3cc484be162285…` |
| Config | `0d572659579d55a7…` |
| Bdata | `dd01e42d66c82a44…` |
| Factory | `20460d6b7f9c49b6…` |
| kernel0 | `ab58d7a35bb75c98…` |
| kernel1（原厂） | `ab893d6c0732dcea…` |
| rootfs0 | `b1ec27567aa0ecb8…` |
| rootfs1 | `b4e123eadad9659a…` |
| overlay | `c8f5b48c23d468bc…` |

结论：备份可用于恢复；`kernel1` 原厂镜像与设备当前 OpenWrt 内核不同，证明备份早于写入。

### 1.3 OpenWrt 固件

| 文件 | 大小 | 结果 |
|---|---:|---|
| initramfs-kernel | 7,607,308 | 与官方 25.12.6 `sha256sums` 一致 |
| kernel1 | 3,331,950 | 一致 |
| rootfs0 | 5,636,096 | 一致 |
| sysupgrade（镜像类型，禁止当作命令执行） | 7,813,734 | 一致 |

官方 `sha256sums` 与本地 `firmware/sha256sums.txt` 逐字节一致；`profiles.json` 确认 v1 镜像类型与大小限制。

### 1.4 原厂固件 2.28.46

| 项 | 结果 |
|---|---|
| 大小 | 24,482,204 B |
| SHA-256 | `4b2b45e1e6c2dcac…` |
| 来源 | 小米 CDN（项目文档记录） |
| 结论 | 文件存在且可读；是否为恢复内核接受的版本未验证 |

---

## 2. 脚本审计

| 脚本 | 审计结果 | 问题 | 处理 |
|---|---|---|---|
| `serial_terminal.py` | 逻辑正确；默认交互，`--listen-only` 只收不发；DTR/RTS false | 无 `.meta.json`；打开端口前设置 DTR 可能被驱动忽略；无 SHA-256 记录 | 新 `uart_capture.py` 取代 |
| `tftp_server.py`（旧） | RRQ 只读、拒绝 WRQ、路径越界检查 | 默认绑定 `0.0.0.0`；无文件名白名单/哈希 pin；ACK 块号校验不严格；默认块 1468 可能与 U-Boot 不兼容 | 新 `tftp_server.py` 取代 |
| `tftp_client_test.py` | 仅本机自测，安全 | 无 | 保留参考；新测试用 `tests/selftest_tftp.py` |
| `uart_capture.ps1` | 只读、DTR/RTS false、TX 不发送 | 默认输出到 `<workspace>`；ASCII 解码会丢失非 ASCII；无元数据/哈希 | 新 Python 工具取代；旧脚本仍可作为备用 |
| `uart_analyze.ps1` | 关键词报告，不决策 | `mt76` 模式会误匹配 `MT7621`；无 JSON/循环计数 | 新 `uart_analyze.py` 取代 |
| `verify_firmware.ps1`（旧） | 哈希 + magic 检查 | 依赖本地 `sha256sums`（若被篡改则失效）；无 v2 拒绝、无备份校验、无结构详情 | 新 `verify_firmware.ps1` 使用内置官方 pin |
| `set_wired_ip.ps1`（旧，01 目录） | 拒绝无线网卡、不设网关、可回滚 | 默认 `InterfaceIndex=9` 是硬编码，网卡索引变化会指向错误设备 | 新工具链已内置独立 `scripts/set_wired_ip.ps1`：GUID/MAC/描述识别、仅 Realtek USB 2.5GbE、默认只读、Apply 双重开关、Rollback 只恢复目标；本阶段不执行 Apply |
| `backup_stream.py` | 只读流式备份，避免 /tmp OOM | 需要路由器可达；当前不可用 | 保留，恢复后可用于再次备份 |
| `backup_readonly.sh` | 只读，但把 ALL 和每个分区都写入 `/tmp` | **资源风险**：ALL 127.5 MB + 分区重复约 127.5 MB，超过 123.6 MB tmpfs，可能 OOM/中断 | **不要运行**；使用流式备份 |
| `unlock_ssh.ps1` | 仅启动 telnet/ssh/ftp，不写 Flash | 依赖漏洞版本；当前路由器不可达 | 保留；恢复后如需要再评估 |

---

## 3. 文档审计与矛盾

### 3.1 已发现的错误

| 文档 | 位置/说法 | 问题 | 纠正 |
|---|---|---|---|
| `UART_RECOVERY_RUNBOOK.md` | “U-Boot 载入地址 0xA0200000” | `0xA0200000` 是 KSEG1 地址（物理 `0x00200000`），并非超出 RAM；但它是否为 TFTP 下载地址未验证。本机 uImage load=0x80001000，U-Boot 字符串出现 0x80A00000 | 标记 UNVERIFIED；删除“本机载入地址”的断言；禁止据此生成命令 |
| 同上 | `nand bad` 作为只读命令 | 本机 U-Boot help 无此命令 | 改为 `help` / `nand id` / `printenv` |
| 同上 | 菜单 1–6 vs 旧教程 9 | 本机实测为 1,2,3,4,7,9 | 以屏幕为准；永不选 5/6 |
| 同上 | 第三阶段 A 首选 `setenv flag_boot_rootfs 0` | `flag_boot_rootfs` 语义未被官方证实 | 降级为“未验证”，首选改为 UART 日志 + 选项 1 诊断 |
| 同上 | server IP 固定 192.168.31.100 | 编译默认 serverip=192.168.31.2；实际 env 需 `printenv` | 上机后读取实际值 |
| `FLASH_STAGE2_REVIEW.md` | 第 2 节：“`flag_try_sys1_failed=0` 表示系统 1（kernel0）仍被优先尝试” | 不完整：当两个 failed 都为 0 时，`flag_last_success=1` 会优先 system 2 | 按官方算法更正：备份值意味着 system 2 优先 |
| `R3G_FLASH_GUIDE.md` | “u-boot 先尝试系统 1；flag_try_sys1_failed=1 时跳过” | 同上，漏掉 last_success 语义 | 更正为三变量算法 |
| `UART_READ_ONLY_CHECKLIST.md` | `nand bad` | 同上 | 改为 `help` / `nand id` |
| `R3G_UART_RECOVERY_PLAN.md` | 对标志保持谨慎，基本正确 | 无致命错误 | 保留；与新证据交叉引用 |
| the old project status | “kernel1 可能是原厂活动系统” | 与官方算法一致 | 保留 |

### 3.2 关键矛盾（必须在 UART 日志后解决）

1. **活动系统到底是 system 1 还是 system 2？**
   - `FLASH_STAGE2_REVIEW.md` 曾按“sys1_failed=0 → 系统 1 优先”推断。
   - `R3G_FAILURE_ANALYSIS.md` 按构建时间推断 system 2。
   - 官方算法 + `flag_last_success=1` 支持 **system 2**。
   - 结论：以 UART 的 `printenv` 和 `Booting System N` 为准；当前证据倾向 system 2。

2. **kernel0 是否真的完好？**
   - 备份中 kernel0 是合法 uImage；未写过。
   - 但它是否与当前 rootfs/UBI 匹配未验证。
   - 结论：不要假设“kernel0 完好 = 能启动”。

3. **原厂 U 盘恢复是否可用？**
   - 依赖原厂内核 initramfs + 两个 failed 标志为 1。
   - 本机 kernel0 未写、rootfs0/1 未写，理论上可用。
   - 但两次 USB 尝试失败，原因未明。
   - 结论：未验证；不作为默认路径。

---

## 4. 已采取的处理

1. 旧文档与脚本已复制到 `UART_Recovery_Toolkit/backups/legacy_docs_snapshot/`，未覆盖原文件。
2. 新工具链不复用旧脚本的危险默认值（0.0.0.0 绑定、无白名单、无哈希 pin）。
3. 新 `verify_firmware.ps1` 内置官方 25.12.6 哈希，不再依赖可被篡改的本地清单。
4. 原厂整片备份与分区镜像保持原位，未修改、未移动。
5. 旧文档中三处最危险的说法已在文件顶部加入“已被新工具链取代/纠正”的横幅（见下节）。

---

## 5. 旧文档横幅与修正

已在以下文件顶部加入醒目说明，指向本工具链：

- `UART_RECOVERY_RUNBOOK.md`
- `UART_READ_ONLY_CHECKLIST.md`
- `R3G_FLASH_GUIDE.md`
- `R3G_UART_RECOVERY_PLAN.md`
- `FLASH_STAGE2_REVIEW.md`（纠正 `flag_try_sys1_failed=0` 的片面解释）

说明内容：旧文档保留作历史记录；其中的载入地址、`nand bad`、菜单编号、`flag_boot_rootfs` 首选方案已被纠正；实际操作用 `UART_Recovery_Toolkit/START_HERE.md`。

---

## 6. 结论

1. 备份与固件真实、完整、哈希一致；没有发现备份损坏。
2. 旧脚本总体安全，但旧 TFTP 服务缺少白名单/哈希 pin；`backup_readonly.sh` 有 /tmp OOM 风险。
3. 旧文档存在三处实质性错误和一处关键矛盾；新工具链已用证据纠正。
4. 没有任何旧文件被覆盖；所有修改前都有快照。
