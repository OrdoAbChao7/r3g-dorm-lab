> 这是两篇中的上篇。下篇写路由器救回之后，怎么把它变成宿舍的 DNS 与远程开机中枢：[从能开机到能生活](./dorm-hub.md)。

## 三个“正常”

2026-11-04 凌晨，`mtd verify` 返回 `Success`。镜像和分区逐字节一致，MD5 也对上了。几分钟后，路由器从网络上消失。

接下来的两个小时里，Windows 给出了三个看起来很正常的信号：

- 网卡状态 `Up`，链路速率 `1 Gbps`；
- `ping 192.168.31.1` 有过回复；
- 网卡指示灯亮着，RJ45 灯也亮着。

但真实情况是：路由器在**每秒复位一次**。U-Boot 加载 OpenWrt 内核，内核启动到 UBI 挂载阶段失败，VFS panic，1 秒后重启，循环往复。LAN PHY 跟着每次复位起落，所以 Windows 看到的是“反复连接/断开”，而不是“设备不在”。

这篇文章按时间线复盘这次事故：哪些判断是错的，哪些证据是假的，最后是怎么用 UART 把原因定位到 `PEB 256` 的。

## 时间线

| 时间 | 阶段 | 结果 |
|---|---|---|
| 11-03 | 立项、固件、SSH、整片备份 | 备份完成 |
| 11-04 00:42–01:14 | 只写 kernel1，`mtd verify` 成功 | 随后失联 |
| 11-04 | 双网卡诊断、rootfs0 写入中止 | 停止写入 |
| 11-04–11-06 | UART 工具链、离线测试 | 只读准备 |
| 11-07 | UART 采集、`printenv`、initramfs、`sysupgrade` | 救回 |
| 11-08 | Wi-Fi、WAN、LuCI、ESP32、DNS、WOL、Tailscale | 中枢化，见下篇 |

## 这台路由器原本要做什么

设备是小米 R3G v1：MT7621A、128 MiB NAND、USB 3.0、双频 Wi-Fi。目标是把它放在宿舍里，做三件事：

- 校园网 WAN 入户，LAN/Wi-Fi 给手机和电脑；
- USB 移动硬盘做 Samba / Aria2；
- 给 ESP32-S3 和远程开机留一个稳定的内网。

原厂固件是 2.28.24。为了装 OpenWrt 25.12.6，先用 OpenWRTInvasion 拿到了 root shell，确认 21/22/23 端口开放，然后做了整片 NAND 备份。

这一步后来救了整台设备。

## 事故前夜：备份对了，系统认知错了一半

备份文件 `r3g-stock-full-20261104.bin` 是 133,693,440 字节，SHA-256 `0d690a8f…`，一共 12 个分区，manifest 也生成了。这个备份的完整性后来被反复核对，包括复制到第二块物理盘之后。

但备份只能保证“能回去”，不能保证“知道现在在哪”。当时有两个关键事实没有对齐：

```text
$ uname -a
Linux XiaoQiang 3.10.14 #1 MiWiFi-R3G-2.28.24 SMP Wed Apr 3 09:34:14 UTC 2019 mips GNU/Linux

$ cat /proc/cmdline
console=ttyS1,115200n8 root=/dev/mtdblock5 uart_en=0 factory_mode=0 usb_u3=0
```

正在运行的 2.28.24 内核构建于 **2019-04-03**；而备份里的 kernel0 构建于 **2018-11-09**，kernel1 构建于 **2019-04-03**。时间和版本都指向一个结论：当前活动系统很可能是 **System 2（kernel1）**，不是 kernel0。

当时的 NVRAM 里还有这些值：

```text
flag_last_success=1
flag_try_sys1_failed=0
flag_try_sys2_failed=0
flag_boot_success=1
flag_boot_type=2
flag_boot_rootfs=1
```

`flag_last_success=1` 很容易被读成“上一次成功的是 System 1”。但 U-Boot 的选择规则不是这么简单：在两个 `failed` 都为 0、`last_success=1` 的组合下，它优先选择 **System 2**。这个判断后来被 UART 日志和 `printenv` 直接证实。

**这是第一个坑：把“当前运行的系统”和“分区编号”混为一谈。** 如果当时确认了活动槽是 System 2，就不会只覆盖 kernel1。

## 半套刷机：verify 成功之后

当时的安装走的是分步写入：先把 OpenWrt 的 kernel1 写进去，再写 rootfs0。第一步执行了：

```text
$ mtd write /tmp/openwrt-25.12.6-...-kernel1.bin kernel1
Unlocking kernel1 ...
Writing from /tmp/...-kernel1.bin to kernel1 ... [e][w]...
MTD_EXIT=0
```

随后 `mtd verify`：

```text
5bdd858ac143240646934daa7d381b9c - kernel1
5bdd858ac143240646934daa7d381b9c - /tmp/...-kernel1.bin
Success
VERIFY_EXIT=0
```

到这里，所有命令都成功了。但 `mtd verify` 只回答一个问题：**分区里的内容和文件是否一致**。它不回答“这个内核能不能启动”，更不回答“内核和 rootfs 是否配套”。

写入后几分钟，设备失联。没有保存到重启命令，也没有看到当时的控制台输出；可能是外部重启、看门狗，或者写入过程影响了正在运行的系统。这一点至今没有确证。能确证的是之后 UART 看到的启动链：

- U-Boot 每次都选 System 2；
- kernel1 已经是 OpenWrt 6.12.112，uImage CRC 正常；
- mtd9 的 UBI 根文件系统 attach 失败；
- VFS 打不开 root device，panic，1 秒后复位。

**第二个坑：双系统设备只刷一半。** 内核换了，rootfs 没换；U-Boot 又不会因为 rootfs 失败而自动回退。失败发生在 U-Boot 交接之后，`flag_try_sys2_failed` 仍然是 0，所以下一次启动它还是选 System 2。

这不是“刷坏了”，而是“刷成了半个系统”。

## 误诊：链路、网卡与一次假 ping

失联后的第一反应是怀疑物理链路。两块网卡都参与了测试：

- USB 网卡：Realtek RTL8156（`VID_0BDA&PID_8156`）；
- 内置网卡：Realtek Gaming 2.5GbE。

两块网卡都出现了周期性 `Up/Down`，恢复时协商到 1 Gbps，但接收字节始终为 0，DHCP 拿不到地址。USB 网卡还在 01:37:35 从 USB 总线上消失，变成 `CM_PROB_PHANTOM`。

看起来像“网线/网卡/路由器 LAN 口坏了”。但有三条证据把方向掰了回来：

1. **1 Gbps 只是 PHY 协商结果。** 链路层协商成功，不代表对端在正常收发包；接收字节为 0 才是关键。
2. **两块网卡同时坏的概率不高。** 更合理的解释是路由器在复位，LAN PHY 跟着起落。
3. **那次 ping 是假阳性。** `Find-NetRoute` 显示，发往 `192.168.31.1` 的流量走的是 `WLAN 2 → 198.51.100.x`，也就是校园网，不是本地有线口。回复来自校园网路径，不能证明 R3G 可达。

还有一次差点走错：当时已经准备写 rootfs0，授权条件是“能通过正常 root shell 访问设备”。实际检查发现：

```text
21: False
22: False
23: False
80: False
```

没有 DHCP 租约，没有 ARP 条目，`192.168.31.1` 的邻居查询也没有记录。条件不满足，写入中止。现在回看，这是整次事故里最重要的一个“没有执行”。

**第三个坑：把链路层、网络层、应用层的“成功”混在一起。** 灯亮、1 Gbps、单次 ping、端口开放，各自只证明一件事。

## 停手：把“猜”换成“证据”

从 11-04 到 11-06，项目没有再写任何 Flash。取而代之的是一套 UART 只读工具链，从 v5 迭代到 v5.2.1，先做离线测试，再上硬件：

- TFTP 套件 51/51，连续 5 次；
- UART 只读测试 28/28；
- 文档扫描 237/237；
- NIC 纯逻辑 40/40，Mock 恢复链 35/35；
- 固件/备份哈希与总预检全部通过。

工具链里有一条很硬的约束：L4 探针只允许发送固定的 11 个字节：

```text
34 0d 70 72 69 6e 74 65 6e 76 0d
4  Enter  p r i n t e n v  Enter
```

不能读键盘，不能接受任意命令，不能发 `saveenv`、`setenv`、`reset`、`boot`、`mtd`、`nand`。这不是“谨慎”，而是把“人在紧张时会不会手滑”从流程里拿掉。

硬件侧也有坑：

- CH340 的 COM 号每次插拔都会变，COM12/13/14 里经常有 phantom；不能硬编码端口。
- 路由器 12V 上电瞬间，CH340 可能从 USB 掉线再枚举，探针会收到 `00 00` 后报 `ClearCommError failed (PermissionError(13))`。规避方法是**先让路由器进入启动循环，再打开探针**，不要在探针打开时给路由器上电。
- J4 的候选映射是 4=TX、3=GND、2=RX、1=疑似 VCC；第一轮只接 TX→RXD 和 GND→GND，不接 VCC、不接 TXD。

**第四个坑：工具本身也需要被验证。** 如果采集工具会乱发字节，后面的“只读”就没有意义。

## UART 说话：System 2、PEB 256 与 1 秒复位

11-07 晚上，被动采集到 49,392 字节的启动日志。U-Boot 的第一行是：

```text
U-Boot 1.1.3 (Nov 9 2018 - 09:28:13)
Ralink UBoot Version: 5.0.0.0
```

菜单实际是：

```text
1: Load system code to SDRAM via TFTP.
2: Load system code then write to Flash via TFTP.
3: Boot system code via Flash (default).
4: Entr boot command line interface.
7: Load Boot Loader code then write to Flash via Serial.
9: Load Boot Loader code then write to Flash via TFTP.
```

倒计时后自动选 3，进入 **System 2**，加载地址 `0x600000`，镜像名 `MIPS OpenWrt Linux-6.12.112`，`Verifying Checksum ... OK`。到这里一切正常。然后：

```text
ubi0 error: bad image sequence number 1856070410 in PEB 256, expected 887073040
ubi0 error: failed to attach mtd9, error -22
UBI error: cannot attach mtd9
VFS: Cannot open root device "" or unknown-block(0,0): error -6
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
Rebooting in 1 seconds..
```

这就是 1 秒复位的全部原因。内核没坏，CRC 也过了；坏的是 UBI 根文件系统的元数据。

后来用 U-Boot 菜单 1 从 TFTP 加载 OpenWrt initramfs（7,607,308 字节）进 RAM，只读检查了 mtd9 的 PEB 头：

| PEB | image_seq | 判断 |
|---:|---|---|
| 0 | `0x34dfa910` = 887073040 | 新序列，与期望一致 |
| 255 | `0x34dfa910` = 887073040 | 新序列 |
| 256 | `0x6ea1630a` = 1856070410 | 旧序列 |
| 257 | `0x6ea1630a` = 1856070410 | 旧序列 |

前 256 个 PEB（32 MiB）是新 UBI 序列，之后是旧序列。UBI 要求整个 mtd9 的序列一致，所以在 PEB 256 处拒绝 attach。

**这里要诚实：序列为什么分成两段，至今没有确证。** 时间上和 kernel1 写入相邻，但不能把“刷 kernel1”直接当成唯一原因。能确证的是：System 2 的内核已经是 OpenWrt，而 mtd9 的 UBI 元数据不完整；两者组合导致无法启动。

同一轮还拿到了 `printenv`：

```text
flag_last_success=1
flag_try_sys1_failed=0
flag_try_sys2_failed=0
flag_boot_success=1
flag_boot_type=2
flag_boot_rootfs=1
bootcmd=tftp
bootdelay=5
```

这解释了为什么 U-Boot 不回退：uImage CRC 通过，U-Boot 不检查 rootfs；rootfs panic 发生在交接之后，不会把 `flag_try_sys2_failed` 置 1。两个 failed 都是 0，它每次仍然选 System 2。

还有两个版本差异值得记下来：

- 旧资料里的菜单是 5/6，这台机器实际是 7/9。两者都是 Bootloader 写入，仍然永久禁止；菜单 2 是双槽写内核，仍然 BLOCKED。
- `uart_en=0` 并没有关闭 U-Boot/内核的串口输出。之前“uart_en 可能门控 UART”的假设是错的。

## 救回：TFTP initramfs → sysupgrade

确认原因后，恢复路径反而清晰了：不从 U-Boot 改启动标志，也不盲写 rootfs0，而是用 initramfs 进入 RAM 系统，再对 mtd9 做一次完整的 `sysupgrade -n`。

写入前先做了第二份整片备份，复制到 USB 盘 `I:`，重新计算 SHA-256，与源一致。

然后在 initramfs 里通过 HTTP 下载 `squashfs-sysupgrade.bin`（7,813,734 字节，SHA-256 `78c15850…`），校验后执行固定命令：

```text
sysupgrade -n /tmp/fw.bin
```

关键输出：

```text
ubiformat: mtd9 (nand), size 123207680 bytes (117.5 MiB), 940 eraseblocks
ubiformat: formatting eraseblock 939 -- 100 % complete
ubi0: attached mtd9 (name "ubi", size 117 MiB)
ubi0: good PEBs: 940, bad PEBs: 0, corrupted PEBs: 0
Volume ID 0, name "rootfs", 36 LEBs (4.3 MiB)
Volume ID 1, name "rootfs_data", 880 LEBs (106.5 MiB)
sysupgrade successful
```

旧的 image_seq 不一致被完整 `ubiformat` 覆盖，新的 UBI 全分区序列一致。第一次 NAND 启动成功：

```text
U-Boot → Booting System 2 → OpenWrt kernel 6.12.112
ubi0: attached mtd9 ... good PEBs: 940
VFS: Mounted root (squashfs filesystem) readonly
UBIFS ... mounted UBI device 0, volume 1, name "rootfs_data"
OpenWrt 25.12.6 r33311-981c978eff
```

LAN `192.168.1.1` ping 4/4，22/80 开放，HTTP 200。随后 12V 断电重启，UBI 再次 attach，squashfs/UBIFS 恢复，网络回来。安装已经持久化到 NAND。

安装后还踩了几个小坑：

- `/cgi-bin/luci/` 返回 403，看起来像 LuCI 坏了；实际响应头有 `x-luci-login-required: yes`，这是未登录的正常响应。
- 镜像里残留了旧的 `uhttpd.main.lua_prefix`，指向不存在的 Lua SGI；`uci del` 后重启 uhttpd 才正常。
- 这个镜像用 `apk` 而不是 `opkg`；`apk add luci` 装了 160 个包、12.1 MiB，overlay 只剩 91.7 MiB 可用，空间要提前算。

Wi-Fi 2.4/5、WAN DHCP、root 密码、软重启都在同一天完成。5G 第一次密码输错，hostapd 连报四次 `AP-STA-POSSIBLE-PSK-MISMATCH`，重试后才连上——这种小事先记着，后面写“验收”时挺真实。

## 五条教训

1. **双系统设备不要只刷一半。** 先确认活动槽，再决定写哪个分区；`flag_last_success=1` 不足以判断。
2. **verify、link、ping 是三种不同层次的证据。** `mtd verify` 只证明分区内容；1 Gbps 只证明 PHY；单次 ping 要先看路由表。
3. **写入前先证明能恢复。** 备份至少两份、跨物理盘、重新校验；写入范围要单独审计。
4. **只读优先，工具先离线测试。** TX 字节数、命令白名单、PASS 分级都要可审计；“PASS-OFFLINE”不是“PASS-HARDWARE”。
5. **没有 root shell 就停手。** 不猜 IP、不切 Wi-Fi、不用 U-Boot 危险命令绕过；授权条件不满足就不执行。

## 还没确认的事

- System 1（kernel0 + rootfs0）在当前 NAND 上是否还能启动，仍然 UNVERIFIED。
- UBI PEB 256 之后旧序列的具体来源、为什么只格式化了前 32 MiB，仍然没有确证。
- `flag_boot_type`、`flag_boot_rootfs`、`flag_boot_success` 的官方语义未确认，不能修改。
- 每次启动前的 `ranand_erase: start:80000, len:20000` 是谁触发的，仍未证实。
- 长期运行稳定性还在观察。

这次能救回来，靠的不是某个神秘命令，而是三件事：**备份在手、只读证据、以及在没把握的时候停手。**

下一篇写救回之后的事：ESP32 接管 DNS、mihomo 的 fake-IP、PSRAM 的 7 字节 stub，以及一次 43 秒的全屋断网演练。[从能开机到能生活](./dorm-hub.md)。
