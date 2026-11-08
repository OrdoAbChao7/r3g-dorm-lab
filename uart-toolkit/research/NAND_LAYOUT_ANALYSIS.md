# NAND_LAYOUT_ANALYSIS — 物理偏移、原厂分区与 OpenWrt 分区

分析日期：2026-11-04
数据来源：本机写入前 `/proc/mtd`、整片备份、OpenWrt 25.12.6 DTSI、原厂 Bootloader 字符串
原则：**物理偏移 ≠ U-Boot 地址 ≠ Linux MTD 编号**，三者分开记录。

---

## 1. 三层编号必须分开

| 层 | 例子 | 用途 |
|---|---|---|
| NAND 物理偏移 | `0x00600000` | 真正写入芯片的位置；U-Boot 与 DTS 使用它 |
| U-Boot 系统编号 | system 1 / system 2 | U-Boot 内部选择逻辑；对应 0x200000 / 0x600000 |
| Linux MTD 编号 | `mtd9`、`mtd10` | 只在当前运行的内核中有效；会因分区表不同而变化 |

**不能**把原厂的 `mtd9` 与 OpenWrt 的 `mtd9` 当成同一分区：

- 原厂运行时的 `mtd9` = `kernel1`（0x600000）。
- OpenWrt 运行时的 `mtd9` = `ubi`（0xA00000，117.5 MiB）。
- 原厂 `mtd10` = `rootfs0`；OpenWrt 没有这个编号。

---

## 2. 原厂运行时 `/proc/mtd`（2026-11-04 实测，写入前）

```text
dev:    size   erasesize  name
mtd0: 07f80000 00020000 "ALL"
mtd1: 00080000 00020000 "Bootloader"
mtd2: 00040000 00020000 "Config"
mtd3: 00040000 00020000 "Bdata"
mtd4: 00040000 00020000 "Factory"
mtd5: 00040000 00020000 "crash"
mtd6: 00040000 00020000 "crash_syslog"
mtd7: 00040000 00020000 "reserved0"
mtd8: 00400000 00020000 "kernel0"
mtd9: 00400000 00020000 "kernel1"
mtd10: 02000000 00020000 "rootfs0"
mtd11: 02000000 00020000 "rootfs1"
mtd12: 03580000 00020000 "overlay"
mtd13: 012e4000 0001f000 "ubi_rootfs"
mtd14: 030ec000 0001f000 "data"
```

说明：

- `mtd0 "ALL"` 是整片视图（0x07F80000 = 127.5 MiB），用于备份；不是独立物理分区。
- `mtd13/14` 是 UBI 卷，erasesize 不同（0x1F000），大小动态。
- 整片备份 133,693,440 B 正好等于 `0x07F80000`。

---

## 3. 物理偏移表（由 `/proc/mtd` 顺序累加，且与 OpenWrt DTS 一致）

| 起始偏移 | 大小 | 原厂标签 | OpenWrt 25.12.6 标签 | 只读 | 说明 |
|---:|---:|---|---|---|---|
| `0x00000000` | `0x00080000` | Bootloader | Bootloader | 是 | U-Boot 1.1.3 + Ralink 5.0.0.0；禁止写 |
| `0x00080000` | `0x00040000` | Config | Config | 否 | U-Boot 环境在偏移 0、0x1000 字节、扇区 0x20000；`saveenv` 写这里 |
| `0x000C0000` | `0x00040000` | Bdata | Bdata | 是 | 厂商数据；禁止写 |
| `0x00100000` | `0x00040000` | Factory | factory | 是 | MAC + 无线校准；禁止写 |
| `0x00140000` | `0x00040000` | crash | crash | 否 | crash dump |
| `0x00180000` | `0x00040000` | crash_syslog | crash_syslog | 否 | |
| `0x001C0000` | `0x00040000` | reserved0 | reserved0 | 是 | |
| `0x00200000` | `0x00400000` | kernel0 | kernel_stock | 否 | **system 1**；本机未被写，2018-11-09 原厂内核 |
| `0x00600000` | `0x00400000` | kernel1 | kernel | 否 | **system 2**；本机已被 25.12.6 kernel1 覆盖 |
| `0x00A00000` | `0x02000000` | rootfs0 | — | — | 原厂 rootfs0；OpenWrt 将其并入 ubi |
| `0x02A00000` | `0x02000000` | rootfs1 | — | — | 原厂 rootfs1；OpenWrt 将其并入 ubi |
| `0x04A00000` | `0x03580000` | overlay | — | — | 原厂 overlay；OpenWrt 将其并入 ubi |
| `0x00A00000` | `0x07580000` | — | ubi | 否 | 从 0xA00000 开始，合并 rootfs0+rootfs1+overlay，结束于 0x7F80000 |

合计：`0x7F80000` = 133,693,440 B，与整片备份完全一致。

### 3.1 原厂内核与 rootfs 的配对（官方 DTS 注释）

- `rootfs0`：OpenWrt DTS 注释为 “rootfs partition for stock kernel0” → **kernel0（0x200000）与 rootfs0（0xA00000）配对 = system 1**
- `rootfs1`：注释为 “rootfs partition for stock failsafe kernel1” → **kernel1（0x600000）与 rootfs1（0x2A00000）配对 = system 2**
- `overlay`（0x4A00000）在原厂布局中独立，不属于某一套内核的固定配对。

因此：

- 不能假设跨版本内核/rootfs 可以互换；本机 kernel1 原厂镜像（2019-04-03）与 rootfs1 才是一对。
- 菜单 2 把同一内核写到两个槽，会让 system 1 变成“该内核 + rootfs0”，打破配对。
- OpenWrt 的 `ubi`（0xA00000，0x7580000）把 rootfs0+rootfs1+overlay 合并；写 OpenWrt rootfs0 会覆盖这三块区域。

---

## 4. 两个内核槽的真实内容

| 分区 | uImage 名 | Data Size | Load / Entry | 构建时间 | SHA-256 |
|---|---|---:|---|---|---|
| kernel0（原厂） | `MIPS OpenWrt Linux-3.10.14` | 3,491,524 | `0x80001000` / `0x8046a0a0` | 2018-11-09 09:38:58 | `ab58d7a3…` |
| kernel1（原厂备份） | `MIPS OpenWrt Linux-3.10.14` | 3,491,822 | `0x80001000` / `0x8046a0a0` | 2019-04-03 09:34:56 | `ab893d6c…` |
| kernel1（当前设备） | `MIPS OpenWrt Linux-6.12.112` | 3,331,886 | `0x80001000` / `0x80001000` | 25.12.6 构建 | `cc7b1d18…` |

- 原厂内核使用 compression=3（LZMA），OpenWrt 25.12.6 使用 compression=0（未压缩/自解压）。
- 两个原厂分区镜像都是 **4 MiB 整分区 dump**，尾部填充 `0xFF`。
- 这解释了一个重要事实：原厂 kernel1 与正在运行的 2.28.24 内核构建时间几乎完全一致，**system 2 很可能就是当前活动系统**。

---

## 5. `root=/dev/mtdblock5` 异常（未解决）

写入前实测 cmdline：

```text
console=ttyS1,115200n8 root=/dev/mtdblock5 uart_en=0 factory_mode=0 usb_u3=0
```

但 `/proc/mtd` 中 `mtd5` 是 `crash`。这与“rootfs 在 mtdblock5”矛盾。可能解释（均未证实）：

1. U-Boot 传入的 `bootargs` 使用的是**另一套分区编号**，与用户态重新分区后的 `/proc/mtd` 不同；
2. 实际根文件系统来自 UBI 卷，`root=` 是遗留/回退参数；
3. 原厂内核在启动早期重新映射了 MTD，`/proc/mtd` 是重新映射后的结果。

结论：**不要用 `root=/dev/mtdblock5` 推断物理分区**。UART 进入 U-Boot 后执行 `printenv` 读取实际 `bootargs`，并在内核日志中确认 UBI attach 的 mtd 编号，才能定论。

| 项目 | 内容 |
|---|---|
| 结论 | 原厂 cmdline 的 `root=/dev/mtdblock5` 与用户态 `/proc/mtd` 的 mtd5=crash 不一致，不能作为分区映射依据 |
| 来源 | 本机 `stage2_router_captured.txt` |
| URL | 本地证据 |
| 设备 | R3G v1 |
| 固件版本 | 2.28.24 |
| U-Boot 版本 | 5.0.0.0 |
| 验证程度 | 实测矛盾；原因未验证 |
| 风险 | 依据 `root=` 猜分区会写错位置 |
| 是否可以用于我的设备 | 仅作为“待解释现象”，不作为操作依据 |

---

## 6. Factory / Bdata / Config 的保护

OpenWrt 25.12.6 DTSI 明确：

- `factory` 分区只读，内含：
  - `eeprom@0`（0x0，0x400）：2.4 GHz 校准；
  - `eeprom@8000`（0x8000，0x200）：5 GHz 校准；
  - `macaddr@e000`（0xE000，6 B）：WAN/主 MAC；
  - `macaddr@e006`（0xE006，6 B）：LAN MAC。
- `Bdata`、`reserved0`、`Bootloader` 只读。
- `Config` 可写（U-Boot 环境）。

本项目备份核对：`Factory.bin` 中 `AA:BB:CC:DD:EE:01` 位于 `0xE000`，另在 `0x04` 命中 `AA:BB:CC`。

必须保护（任何恢复方案都不得写）：

```text
Bootloader (0x000000, 0x80000)
Config     (0x080000, 0x40000)   # 仅 saveenv 会改；禁止执行，且必须单独授权
Bdata      (0x0C0000, 0x40000)
Factory    (0x100000, 0x40000)
reserved0  (0x1C0000, 0x40000)
```

---

## 7. 备份完整性（本次重算）

| 文件 | 大小 | SHA-256 |
|---|---:|---|
| `r3g-stock-full-20261104.bin` | 133,693,440 | `0d690a8f6c36f4d34e89c2f13675120a500e72c6ae430eafeba4e4572e0e555d` |
| `parts/Bootloader.bin` | 524,288 | `bf3cc484be162285639a1790c712a4eead39498281d7c6b1006d4cc0201f8ea3` |
| `parts/Config.bin` | 262,144 | `0d572659579d55a7751880870e0861cf909b1f3b0b1685be54d01b94d44af786` |
| `parts/Bdata.bin` | 262,144 | `dd01e42d66c82a44d011b19c493a323a909bb0d7552370e03c03581d3f9ae432` |
| `parts/Factory.bin` | 262,144 | `20460d6b7f9c49b608a051e7e64176af5b1791bcf8646e9251a533351e5a45d1` |
| `parts/kernel0.bin` | 4,194,304 | `ab58d7a35bb75c988aad53001d52ed3f3306d138e36be8e7de2067891f7c5db8` |
| `parts/kernel1.bin` | 4,194,304 | `ab893d6c0732dcea7f029fd3d7101b844ff9d2b2fc6114b24e908d466e3b6168` |
| `parts/rootfs0.bin` | 33,554,432 | `b1ec27567aa0ecb81be4fba1266e9b7145d014814ab6622475765f2864b5391f` |
| `parts/rootfs1.bin` | 33,554,432 | `b4e123eadad9659a3c02995667e382adbbe6854683ea2fa9b3b4c8b44e091757` |
| `parts/overlay.bin` | 56,098,816 | `c8f5b48c23d468bcb8757de033dcf1c984db85a7fc815ac9b909e118b73b6dcd` |
| `parts/crash.bin` | 262,144 | `3b874d3ba46c638fc3094f8e92fb744ca974893873f8885f54e23760f9b6311b` |
| `parts/crash_syslog.bin` | 262,144 | 同上（均为 0xFF 空分区） |
| `parts/reserved0.bin` | 262,144 | 同上 |

结论：备份完好，且是**写入前**状态（原厂 kernel1 哈希 `ab893d6c…` 与当前设备上的 OpenWrt 内核不同）。

---

## 8. NAND 容量说明

- 芯片标称 128 MiB = 0x8000000。
- Linux `ALL` 分区 = 0x7F80000（127.5 MiB），差 0x80000（512 KiB）。
- 差异来自厂商分区/坏块保留，不影响整片备份与恢复；但**不能**假设 raw dump 包含 OOB/spare 区。
- `/dev/mtd0` 读取的是去 OOB 的数据区；NAND 编程器读取的是含 OOB 的原始镜像。两者格式不同，不能直接互换。

---

## 9. 结论

1. 物理偏移表已由本机 `/proc/mtd` 与 OpenWrt DTS 双重确认。
2. 原厂与 OpenWrt 的 MTD 编号完全不同，禁止混用。
3. kernel1 当前是合法 OpenWrt uImage，但它占据的是原厂 system 2；这正是启动失败的根源。
4. Bootloader/Config/Bdata/Factory/reserved0 是保护区；任何恢复流程都应先声明写入范围。
5. `root=/dev/mtdblock5` 仍是未解现象，需 UART 日志解释。
