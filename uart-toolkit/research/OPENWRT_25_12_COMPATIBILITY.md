# OPENWRT_25_12_COMPATIBILITY — 25.12.6 与 R3G v1 的兼容性审查

审查日期：2026-11-04
来源：OpenWrt 25.12.6 官方下载目录、`profiles.json`、`sha256sums`、25.12 分支 DTS/DTSI、设备页存档
原则：只使用官方发布文件；旧教程中的文件名/分区标签不能直接套用。

---

## 1. 发布真实性

| 检查 | 结果 |
|---|---|
| 发布目录 | `https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt7621/` 可访问 |
| 目录文件日期 | 2026-10-18 |
| 内核 | `6.12.112`（`profiles.json`: `linux_kernel.version`） |
| `sha256sums` | 与项目本地 `router/firmware/sha256sums.txt` **逐字节一致** |
| 本地镜像哈希 | 4 个 v1 镜像全部与官方清单一致（见下表） |

---

## 2. R3G v1 官方镜像（25.12.6）

| 文件 | 大小 | SHA-256 | 类型 | 用途 |
|---|---:|---|---|---|
| `...-initramfs-kernel.bin` | 7,607,308 | `8d58d8a1…` | initramfs kernel (uImage) | RAM 救援/测试；不用于首次安装 |
| `...-squashfs-kernel1.bin` | 3,331,950 | `cc7b1d18…` | kernel1 (uImage) | 首次安装写入 kernel1（system 2） |
| `...-squashfs-rootfs0.bin` | 5,636,096 | `3bede806…` | rootfs0 (UBI) | 首次安装写入 rootfs0 |
| `...-squashfs-sysupgrade.bin` | 7,813,734 | `78c15850…` | sysupgrade (tar) | **仅** OpenWrt 内部升级；禁止执行 |

`profiles.json` 中 v1 的关键限制：

```text
file_size_limits: image = 127401984, kernel = 4194304
device_packages: kmod-mt7603, kmod-mt76x2, kmod-usb3, kmod-usb-ledtrig-usbport
```

- `kernel` 限制 4,194,304 = 4 MiB，正好是内核槽大小。
- `image` 限制 127,401,984 = 0x7980000，小于整片 0x7F80000（为分区表/保留区留余量）。

### 镜像结构（本地解析）

| 镜像 | magic | uImage 名 | Load / Entry | Data Size |
|---|---|---|---:|---:|
| kernel1 | `27 05 19 56` | `MIPS OpenWrt Linux-6.12.112` | `0x80001000` / `0x80001000` | 3,331,886 |
| initramfs | `27 05 19 56` | `MIPS OpenWrt Linux-6.12.112` | `0x80001000` / `0x80001000` | 7,607,244 |
| rootfs0 | `UBI#` | — | — | 5,636,096 |
| sysupgrade（镜像类型；禁止执行） | tar | — | — | 7,813,734 |

---

## 3. R3G v2 镜像（必须排除）

| 文件 | 大小 | SHA-256 |
|---|---:|---|
| `...-3g-v2-initramfs-kernel.bin` | 7,455,358 | `2c8d4735…` |
| `...-3g-v2-squashfs-sysupgrade.bin` | 7,668,321 | `ccb3768d…` |

v2 只有 16 MiB SPI Flash、无 USB，分区与引导方式不同。**v2 镜像不能用于 v1**；本工具链的 `verify_firmware.ps1` 会把 v2 文件标记为 FAIL。

---

## 4. 从原厂安装（官方流程在 25.12.6 的适配）

官方设备页/提交的流程：

```text
// 历史记录；禁止执行
mtd write openwrt-25.12.6-...-squashfs-kernel1.bin kernel1
mtd write openwrt-25.12.6-...-squashfs-rootfs0.bin rootfs0
nvram set flag_try_sys1_failed=1
nvram commit
reboot
```

为什么这样能工作：

- 原厂 `/proc/mtd` 中 `kernel1` = 0x600000（system 2），`rootfs0` = 0xA00000。
- 设置 `flag_try_sys1_failed=1` 后，U-Boot 跳过 system 1，启动 system 2 的 OpenWrt 内核。
- OpenWrt 内核按自己的 DTS 把 0xA00000 起的 117.5 MiB 视为 `ubi`，从刚写入的 rootfs0 挂载。

**本机只执行了第一条**，未写 rootfs0、未设标志，因此 system 2 变成“OpenWrt 内核 + 原厂 rootfs”，无法启动。

### 安装后标签变化（重要）

25.12.6 运行时的 `/proc/mtd` 标签是：

```text
Bootloader, Config, Bdata, factory, crash, crash_syslog, reserved0,
kernel_stock, kernel, ubi
```

- `kernel_stock` = 0x200000（原厂 kernel0）
- `kernel` = 0x600000（OpenWrt kernel1）
- `ubi` = 0xA00000

因此：

- **在原厂系统里**安装时，目标标签是 `kernel1` / `rootfs0`。
- **进入 OpenWrt 后**，不存在 `kernel1` 标签；不要照抄旧命令。升级用 `sysupgrade`。
- 这也是 2022 年 Breed 用户遇到 “Unable to locate firmware / kernel1” 的原因（C7）。

---

## 5. initramfs 的作用与限制

- 25.12.6 提供 `initramfs-kernel.bin`（7.6 MB），可作为 U-Boot 选项 1 的 RAM 救援系统。
- 官方提交明确说 U-Boot 可以通过 TFTP 启动 initramfs；本机未实测。
- initramfs 的 U-Boot 加载阶段按设计不写 NAND；但内核是否因 cmdline attach UBI、以及启动后是否挂载/写入 UBI，仍取决于实际 cmdline 与人工操作，需实测。
- 它不是首次安装镜像；不能用它替代 kernel1+rootfs0 写入。

---

## 6. 版本差异（18.06 / 19 / 22.03 / 25.12）

| 版本 | 安装机制 | 标签 | 备注 |
|---|---|---|---|
| 18.06.2 | kernel1 + rootfs0 + nvram flag | kernel1/rootfs0 | 官方 Wiki 存档仍引用该版本示例 |
| 19.x | 同上 | 同上 | 内核/驱动变化 |
| 22.03 | 同上 | 开始出现 `kernel_stock` / `kernel` / `ubi` | Breed 兼容性问题（C7） |
| 25.12.6 | 同上 | `kernel_stock` / `kernel` / `ubi` | 内核 6.12.112；initramfs 7.6 MB |

结论：**安装机制稳定，但镜像文件名、内核版本、运行时标签都变了**。旧教程中的 `mtd write ... kernel1` 只适用于原厂运行阶段；进入 OpenWrt 后不能再用。

---

## 7. 原厂固件 2.28.46（恢复用）

| 项 | 值 |
|---|---|
| 文件 | `miwifi_r3g_firmware_dbc3c_2.28.46.bin` |
| 大小 | 24,482,204 B |
| SHA-256 | `4b2b45e1e6c2dcacb9ad2b741345414eb8ba4bb434d5932a6dbd7e7354b20432` |
| 来源 | 小米 CDN：`http://cdn.cnbj1.fds.api.mi-img.com/xiaoqiang/rom/r3g/miwifi_r3g_firmware_dbc3c_2.28.46.bin` |
| 版本 | 2.28.46（比原机 2.28.24 新） |
| 用途 | 原厂内核 initramfs 的 U 盘恢复；**不能**直接经 U-Boot TFTP 写入 |
| 未验证 | 2.28.46 是否被 2.28.24 的恢复内核接受；两次 USB 尝试均失败（项目记录） |

---

## 8. 兼容性证据表

| 项目 | 内容 |
|---|---|
| 结论 | 25.12.6 官方 v1 镜像为 initramfs/kernel1/rootfs0/sysupgrade 四种（sysupgrade 仅为镜像类型，禁止当作命令执行），内核 6.12.112 |
| 来源 | OpenWrt 25.12.6 profiles.json + sha256sums |
| URL | https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt7621/ |
| 设备 | R3G v1 |
| 固件版本 | 25.12.6 |
| U-Boot 版本 | 不适用（安装由原厂 U-Boot 完成） |
| 验证程度 | 官方发布 + 本地哈希/结构核验 |
| 风险 | 禁止用 sysupgrade 做首次安装（会失败）；用 v2 镜像必砖 |
| 是否可以用于我的设备 | 是（仅 kernel1 + rootfs0 首次安装；initramfs 用于救援） |

| 项目 | 内容 |
|---|---|
| 结论 | 首次安装必须在原厂系统内写 kernel1/rootfs0 并设置 flag_try_sys1_failed=1 |
| 来源 | OpenWrt 设备页（存档）+ 提交 f2107fc |
| URL | https://openwrt.org/toh/xiaomi/mir3g |
| 设备 | R3G v1 |
| 固件版本 | 原厂 2.x → OpenWrt 25.12.6 |
| U-Boot 版本 | 5.0.0.0 |
| 验证程度 | 官方流程；本机只完成第一步 |
| 风险 | 半安装状态导致 boot loop；rootfs 写入是不可逆分界点 |
| 是否可以用于我的设备 | 是，但必须在恢复管理通道后分步授权 |

| 项目 | 内容 |
|---|---|
| 结论 | OpenWrt 运行时分区标签为 kernel_stock/kernel/ubi，不再有 kernel1 |
| 来源 | 25.12 分支 DTSI + Breed issue #5 |
| URL | https://raw.githubusercontent.com/openwrt/openwrt/openwrt-25.12/target/linux/ramips/dts/mt7621_xiaomi_nand_128m.dtsi |
| 设备 | R3G v1 |
| 固件版本 | OpenWrt 22.03+ / 25.12.6 |
| U-Boot 版本 | 原厂或 Breed |
| 验证程度 | 官方源码 + 同型号报告 |
| 风险 | 在 OpenWrt 中执行旧标签命令会失败/写错 |
| 是否可以用于我的设备 | 是（安装后禁止照抄原厂阶段命令） |

---

## 9. 结论

1. 25.12.6 的 v1 镜像与哈希已核验，可用于首次安装与救援。
2. 首次安装只能在原厂系统内执行；本机已经处于“只写了一半”的状态。
3. 安装后的标签与安装前不同，所有命令必须按当前系统重新确认。
4. 25.12.6 在本机的实际启动/安装尚未验证；不得声称“已验证可用”。
