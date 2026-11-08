# SOURCE_RESEARCH — 研究结论摘要

生成日期：2026-11-04
详细证据见 `research/` 下的 8 个文件与 `research/sources/` 原始抓取文件。

---

## 1. 研究范围

| 类别 | 来源 |
|---|---|
| 官方 | OpenWrt R3G 设备页（存档）、提交 f2107fc、25.12 分支 DTS/DTSI、25.12.6 profiles/sha256sums |
| 社区 | OpenWrt Forum 25073、mt76 issue #304、ysc3839 博客、恩山原帖、ksite 转载、MIR3G_RECOVERY、hackpascal issue #5 |
| 本机 | 整片备份、12 分区镜像、Bootloader 字符串、写入日志、NVRAM 快照 |
| 不可用 | skk.moe（403）、4pda（502）、openwrt.org 实时页（Anubis）、CSDN（付费/低质量） |

---

## 2. 最重要的十个结论

1. **双系统地址**：system 1 = 0x200000，system 2 = 0x600000。官方提交与 DTS 均确认。
2. **启动选择**：两个 `flag_try_sys*_failed` 都为 0 时，`flag_last_success` 决定偏好（0=system1，1=system2）；任一 failed 置位则启动未失败的系统；两个都置位则看 system1 CRC。
3. **U-Boot 只设置 failed 标志，从不清除**。
4. **U-Boot 只检查 uImage CRC，不检查 rootfs 是否匹配**——CRC 正确的内核即使无法挂载 rootfs，也不会触发回退。
5. **选项 2 是双槽写入**：官方提交明确写 “writes the transferred image to both kernel partitions”；ysc3839 实测写到 0x200000 和 0x600000。
6. **选项 1 是 SDRAM 临时启动**：官方提交说可通过 TFTP 启动 initramfs；菜单字符串无擦除警告。本机未实测。
7. **原厂 U 盘恢复依赖原厂内核 initramfs**，不是 U-Boot 功能；原厂内核被覆盖后该能力可能失效。
8. **本机活动系统已由 UART 确认**：`flag_last_success=1`、两个 failed=0；U-Boot 实际选择 system 2。原厂 kernel1 构建时间（2019-04-03）与运行中的 2.28.24 内核一致；2026-11-07 `printenv` 已取得当前值。
9. **本机故障机理**：kernel1 被写入合法 OpenWrt uImage（CRC 通过），U-Boot 仍选 system 2；OpenWrt 6.12 内核 + 原厂 rootfs 不匹配 → panic/复位循环。待 UART 证实。
10. **25.12.6 官方镜像已核验**：4 个 v1 镜像哈希与官方一致；首次安装必须写 kernel1 + rootfs0 + `flag_try_sys1_failed=1`，不能只写 kernel1。

---

## 3. 案例摘要

| 案例 | 设备 | 结果 | 关键教训 |
|---|---|---|---|
| OpenWrt Forum 25073 | R3G | 成功 | TFTP 服务器必须真正响应 RRQ；“启动服务”不够 |
| mt76 #304 | R3G | 失败→修复 | 完整日志显示 U-Boot→CRC→UBI→UBIFS→驱动的顺序；panic 可能在驱动 |
| ysc3839 / 恩山 | 小米路由器 3 | 成功 | 选项 2 双写；原厂恢复模式在原厂内核里；环境在 Config 前 0x1000 |
| ksite/MrK | 小米路由器 3 | 转载 | 页面自述过时；偏移不是 R3G 的 |
| MIR3G_RECOVERY | R3G | 硬件级 | 仅 Bootloader 已死时使用；坏块映射/MAC 风险 |
| hackpascal #5 | R3G + Breed | 未闭合 | OpenWrt 22.03+ 标签变为 kernel_stock/kernel/ubi |
| 本机 | R3G v1 | 待诊断 | 半安装 + 活动系统被覆盖 → boot loop |

---

## 4. 冲突与处理

| 冲突 | 处理 |
|---|---|
| 旧教程菜单 9 vs 本机 1–6 | 以本机 Bootloader 字符串/屏幕为准；永不选写 Bootloader 项 |
| 旧文档“选项 2 只写 kernel1” | 官方提交 + 同系列实测否定；按双槽写入对待 |
| 旧文档“sys1_failed=0 → system1 优先” | 漏掉 last_success；官方算法显示本机应优先 system2 |
| `flag_boot_rootfs` 用法 | 官方未解释；本机仅见打印；不修改 |
| `flag_boot_success` | 本机 U-Boot 字符串未引用；不作为启动判断 |
| `root=/dev/mtdblock5` vs mtd5=crash | 未解现象；不作为分区映射依据 |
| Wiki 示例 22.03 vs 25.12.6 | 机制相同，文件名/标签不同；以 25.12.6 发布清单为准 |

---

## 5. BLOCKED 项（没有可靠证据）

| 项 | 状态 | 说明 |
|---|---|---|
| skk.moe 文章 | **BLOCKED** | curl/WebFetch 均 403；未用推测替代 |
| 4pda R3G 主题 | **BLOCKED** | 502 |
| openwrt.org 实时页 | **BLOCKED** | Anubis 反爬；使用 2026 存档快照 |
| 25.12.6 在本机实际启动 | **BLOCKED** | 需硬件与授权 |
| 选项 1/2 在本机的精确行为 | **BLOCKED** | 需硬件与授权 |
| 2.28.46 恢复包兼容性 | **BLOCKED** | 两次 USB 尝试失败，原因未明 |
| 本机实际活动系统/flag 值 | **DONE（2026-11-07）** | UART 启动日志 + L4 `printenv`；`flag_last_success=1`、两个 failed=0 |

---

## 6. 对“我的设备”的适用性

| 方法 | 是否适用 | 条件 |
|---|---|---|
| UART 只读抓日志 | 是 | L3 授权；3.3V/115200 8N1 |
| U-Boot 选项 1 启动 initramfs | 有条件 | L5 授权；TFTP 可达；实测确认无擦写 |
| U-Boot 选项 1 启动原厂内核 | 有条件 | 未验证；可能写 overlay/NVRAM |
| U-Boot 选项 2 写 4 MiB 原厂内核 | 有条件 | L7 授权；接受双槽写入 |
| 从 initramfs 精确写 kernel1 | 有条件 | 先成功选项 1；标签核对 |
| 改 NVRAM 标志 | 有条件 | L6 授权；UART 日志支持 |
| 原厂 U 盘恢复 | 有条件 | 原厂内核在任一槽；两个 failed=1；版本兼容未知 |
| 编程器整片恢复 | 否（当前） | 仅 Bootloader 已死/NAND 损坏 |
| Breed | 否 | 本项目不使用；会改变引导与标签 |
| Padavan | 否 | 用户明确不使用 |

---

## 7. 详细文档索引

- `research/SOURCE_INDEX.md` — 全部来源、URL、本地文件、访问状态
- `research/OFFICIAL_DOCS_REVIEW.md` — 官方 Wiki/提交/源码逐项审查
- `research/COMMUNITY_CASES.md` — 6 个技术案例 + 本机案例
- `research/UBOOT_BEHAVIOR.md` — 菜单、选项、命令、地址、风险矩阵
- `research/NAND_LAYOUT_ANALYSIS.md` — 物理偏移、原厂/OpenWrt 分区、保护区域
- `research/BOOT_FLAG_ANALYSIS.md` — 每个标志的语义、当前值、未知项
- `research/TFTP_RECOVERY_ANALYSIS.md` — 选项 1/2、镜像用途、失败模式
- `research/OPENWRT_25_12_COMPATIBILITY.md` — 25.12.6 镜像/安装/标签
- `research/AUDIT_OLD_FILES.md` — 旧文件审计与纠正
- `docs/RECOVERY_DECISION_TREE.md` — 按日志决策
- `FLASH_SAFETY_REVIEW.md` — 所有 Flash 操作审查
- `TOOLCHAIN_TEST_REPORT.md` — 离线测试结果
