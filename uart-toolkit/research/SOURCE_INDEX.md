# SOURCE_INDEX — 证据来源总表

采集日期：2026-11-04（本地）
采集方式：WebFetch / curl 直接抓取；无法访问的来源如实标注。
本地原始文件：`research/sources/`

> 原则：官方源码/官方 Wiki/设备自身备份 > 同型号实测记录 > 同系列可类比记录 > 论坛经验 > 二手转载。
> 本表不把论坛经验升级为官方结论。

## 1. 官方来源

| # | 来源 | URL | 本地文件 | 状态 | 可靠性 |
|---|---|---|---|---|---|
| O1 | OpenWrt 设备页 Xiaomi Mi Router 3G | https://openwrt.org/toh/xiaomi/mir3g | `wiki_mir3g_archive.html` / `.txt` | 实时访问被 Anubis 拦截（Access Denied）；2026 年 web.archive.org 快照抓取成功（161,543 B） | 官方，但为存档副本 |
| O2 | OpenWrt 提交 f2107fc “ramips: improve Xiaomi Mi Router 3G support” | https://github.com/openwrt/openwrt/commit/f2107fc328ff7f9817fe9ca64f84bba9e32abfc6 | `openwrt_commit_f2107fc.patch`（11,551 B） | 完整 patch 抓取成功 | 官方提交，作者 Kevin Darbyshire-Bryant |
| O3 | OpenWrt 当前 master DTS | https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/ramips/dts/mt7621_xiaomi_mi-router-3g.dts | `dts_mt7621_xiaomi_mi-router-3g.dts`（2,386 B） | 抓取成功 | 官方源码 |
| O4 | OpenWrt 当前 master DTSI（分区表） | https://raw.githubusercontent.com/openwrt/openwrt/master/target/linux/ramips/dts/mt7621_xiaomi_nand_128m.dtsi | `dtsi_mt7621_xiaomi_nand_128m.dtsi`（2,683 B） | 抓取成功 | 官方源码 |
| O5 | OpenWrt openwrt-25.12 分支 DTS/DTSI | 同上（分支 `openwrt-25.12`） | `dts_2512.dts`、`dtsi_2512.dtsi`、`dtsi_tag.dtsi` | 抓取成功；与 master 内容一致 | 官方 25.12 源码 |
| O6 | OpenWrt 25.12.6 下载目录 | https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt7621/ | 目录页抓取；`profiles_25.12.6_mt7621.json`（319,895 B） | 抓取成功；文件日期 2026-10-18 | 官方发布 |
| O7 | OpenWrt 25.12.6 `sha256sums` | https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt7621/sha256sums | `sha256sums_25.12.6_mt7621.txt`（279,533 B） | 抓取成功；与项目本地 `firmware/sha256sums.txt` **逐字节一致** | 官方发布 |
| O8 | iscilyas openwrt-r3p PR #1（R3P 参考，非 R3G） | https://github.com/iscilyas/openwrt-r3p/pull/1 | 未保存 | 仅搜索结果 | 非本设备，未采用 |

## 2. 真实故障/恢复案例

| # | 来源 | URL | 本地文件 | 状态 | 设备 | 类型 |
|---|---|---|---|---|---|---|
| C1 | OpenWrt Forum “Debricking Xiaomi R3G” | https://forum.openwrt.org/t/debricking-xiaomi-r3g/25073 | `forum_25073.json`（22,595 B） | 抓取成功（6 楼） | R3G | 成功救砖 |
| C2 | mt76 issue #304 “Kernel Panic Xiaomi MIR3G on boot” | https://github.com/openwrt/mt76/issues/304 | `mt76_issue_304.json`、`_body.txt`、`_comments.json` | 抓取成功 | R3G | 失败日志/已修复 |
| C3 | ysc3839 博客 “小米路由器3 U-Boot TTL 恢复及一些注意事项” | https://blog.ysc3839.com/post/miwifi-r3-ttl-recovery.html | `ysc3839_blog.html` / `.txt` | 抓取成功 | 小米路由器 3（非 3G） | 成功 TTL 恢复 |
| C4 | 恩山无线论坛同文（ysc3839 原帖） | https://www.right.com.cn/forum/thread-308330-1-1.html | `right_308330.html` / `.txt` | 抓取成功（含回复） | 小米路由器 3 | 成功 + 回复者实测 |
| C5 | MrK/ksite 转载 | https://www.ksite.cn/contents/mirouter-r3-ttl-rec.html | `ksite_mrk.html` / `.txt` | 抓取成功；页面自述“3157 天前发表，内容可能过时” | 小米路由器 3 | 二手转载 |
| C6 | jesusvallejo/MIR3G_RECOVERY | https://github.com/jesusvallejo/MIR3G_RECOVERY | `gh_MIR3G_RECOVERY_README.md`、`gh_MIR3G_RECOVERY.json` | 抓取成功（2019 建库，2024 更新描述，最后提交 2019-09-07） | R3G | 硬件 NAND 编程器恢复 |
| C7 | hackpascal/mt7621-boot-spi-nand issue #5 | https://github.com/hackpascal/mt7621-boot-spi-nand/issues/5 | `gh_issue_5.json`、`gh_issue_5_body.txt` | 抓取成功（正文编码需 UTF-8 读取） | R3G v1 + Breed 1.2 | 自定义 Bootloader 问题 |
| C8 | 本项目设备（2026-11-04） | 本地证据 | `docs/evidence/*`、`backups/*` | 实测记录 | R3G v1 | 失败/待诊断 |
| C9 | skk.moe “mwan” 文章 | https://blog.skk.moe/post/miwifi-r3g-mwan/ | 无 | **BLOCKED**：curl 与 WebFetch 均 403 | R3G | 未采用 |
| C10 | 4pda R3G 主题 | http://4pda.ru/forum/lofiversion/index.php?t837667-2760.html | 无 | **BLOCKED**：502 | R3G | 未采用 |
| C11 | CSDN 若干 R3G TTL 文章 | 多个 | `csdn_results.txt`、`csdn_pits.html` | 抓取到检索摘要；正文付费/521/内容疑似 AI 生成 | R3G | **不作为证据** |

## 3. 设备自身证据（最高优先级）

| # | 证据 | 路径 | 说明 |
|---|---|---|---|
| L1 | 整片 NAND 备份 | `backups/r3g-stock-full-20261104.bin` | 133,693,440 B；SHA-256 `0d690a8f…` 重算一致 |
| L2 | 12 个分区镜像 | `backups/parts/*.bin` | 全部重算哈希与 manifest 一致 |
| L3 | 原厂 `/proc/mtd`、cmdline、uname、NVRAM | `docs/evidence/stage2_router_captured.txt` | 写入前实测 |
| L4 | kernel1 写入与 `mtd verify` 原始输出 | `docs/evidence/mtd_verify_kernel1.txt`、`mtd9_header.txt` | 写入后实测 |
| L5 | Bootloader 字符串 | `research/sources/bootloader_strings.txt`（1,217 条） | 从 `parts/Bootloader.bin` 提取；含菜单、flag、NAND 命令、TFTP 提示 |
| L6 | uImage 头解析 | 本报告 `NAND_LAYOUT_ANALYSIS.md` | 本地解析 kernel0/kernel1/OpenWrt 镜像 |

## 4. 访问限制声明

- `openwrt.org` 实时页面被 Anubis 反爬保护拦截，无法直接引用当前页面；本报告使用 2026 年存档快照，并在涉及版本处注明“存档页可能滞后”。
- `blog.skk.moe`、`4pda.ru` 在当前网络下不可访问；未用推测替代，相关章节标注 BLOCKED。
- CSDN 检索结果中大量文章标题雷同、内容空泛，疑似批量生成；未作为技术依据。
