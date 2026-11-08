# USB_RECOVERY_GUIDE

Xiaomi Mi Router 3G v1（R3G v1）原厂固件 USB 恢复指南
生成时间：2026-11-04 02:30
状态：**仅准备，未执行恢复。**

> 重要：本流程是**社区/论坛验证过、但小米官方没有为 R3G 明确文档化**的
> 整机 USB 恢复路径。官方 OpenWrt 页面只把 USB+Reset 用于
> `miwifi_ssh.bin`，整机安装写的是 UART + USB。请按“条件性可行”看待。

---

## 1. 适用硬件

| 项 | 要求 |
|---|---|
| 型号 | Xiaomi Mi Router 3G **v1**（R3G） |
| SoC | MT7621A |
| Flash | 128 MiB NAND |
| USB | 蓝色 USB 3.0 口 |
| 不适用 | R3G v2 / 4A Gigabit（无 USB、16 MiB Flash、bootloader 锁定） |

本机已确认：R3G v1，原厂 2.28.24，kernel0 完好，kernel1 已被 OpenWrt 覆盖。

---

## 2. 原理（证据分级）

- **社区证据**：原厂 kernel0 内含 USB 恢复功能；U-Boot 启动 kernel0 的
  恢复环境后，从 FAT32 U 盘读取根目录 `miwifi.bin` 并刷回原厂固件。
- **本机备份证据**：U-Boot 本身只有 TFTP 菜单，没有 USB 字符串；
  这与“USB 恢复在 kernel0”一致。
- **未确认**：当前 boot loop 状态下，U-Boot 是否还能进入该恢复环境。
- **官方文档**：没有 R3G 整机 USB 恢复步骤；不要把它当成官方保证。

---

## 3. 固件来源与校验

| 项 | 值 |
|---|---|
| 官方 API | `https://api.miwifi.com/upgrade/log/latest?typeList=R3GSTA` |
| 版本 | 2.28.46（稳定版） |
| 官方 URL | `http://cdn.cnbj1.fds.api.mi-img.com/xiaoqiang/rom/r3g/miwifi_r3g_firmware_dbc3c_2.28.46.bin` |
| 本地源文件 | `router/firmware/stock/miwifi_r3g_firmware_dbc3c_2.28.46.bin` |
| 大小 | 24,482,204 字节 |
| SHA-256 | `4b2b45e1e6c2dcacb9ad2b741345414eb8ba4bb434d5932a6dbd7e7354b20432` |
| 官方校验值 | 页面未提供独立 SHA-256 |
| 适用性确认 | 固件包内字符串含 `option HARDWARE 'R3G'`、`option ROM '2.28.46'` |

注意：这是 2.28.46，比路由器原来的 2.28.24 新。恢复流程是否接受更高版本
未获官方确认。

---

## 4. U 盘文件结构

已准备的 U 盘：

| 项 | 值 |
|---|---|
| 盘符 | `H:` |
| 型号 | SanDisk Cruzer Blade |
| 序列号 | `4C530301671021110171` |
| 分区 | MBR，单分区 FAT32 |
| 容量 | 8,000,094,208 字节 |
| 可用（复制后） | 6,520,422,400 字节 |
| 恢复文件 | `H:\miwifi.bin` |
| 文件大小 | 24,482,204 字节 |
| 文件 SHA-256 | `4b2b45e1e6c2dcacb9ad2b741345414eb8ba4bb434d5932a6dbd7e7354b20432` |

要求：

- 根目录文件名必须是 `miwifi.bin`；
- FAT32，MBR 单分区；
- 不要放在子目录；
- 不要有第二个同名文件；
- 现有文件未被删除或覆盖（复制前确认 `miwifi.bin` 不存在）。

---

## 5. 操作顺序（未执行，需授权）

1. 在 Windows 中安全弹出 `H:`；
2. 拔掉路由器电源（**需要你单独授权**）；
3. 把 U 盘插入 R3G 的 **USB 3.0 蓝色口**；
4. 用卡针按住 Reset 孔，保持不放；
5. 插上 12V 电源，继续按住 Reset；
6. 观察正面 LED：**黄色开始闪烁**（约 15 秒）后松开 Reset；
7. 等待刷写，通常 3–10 分钟，中途不要断电；
8. 刷写完成后路由器重启，LED 变为蓝色/常亮；
9. 手机应能搜到 `Xiaomi_XXXX` / `Xiaomi_XXXX`；
10. 浏览器打开 `http://192.168.31.1`。

> Reset 时长来自 OpenWrt 的 `miwifi_ssh.bin` 流程；用于 `miwifi.bin`
> 属于社区推断，不是 R3G 官方整机恢复文档。

---

## 6. LED 状态

| LED | 含义 | 证据 |
|---|---|---|
| 黄色闪烁 | 恢复/刷写进行中 | OpenWrt 页面（SSH 文件流程） |
| 黄色常亮 | 恢复等待/失败/启动卡住，均可能 | 不能确定 |
| 蓝色 | 正常启动/恢复完成 | OpenWrt 页面 |
| 红色慢闪 | 等待恢复 U 盘镜像 | OpenWrt 页面（部分型号） |

当前黄色常亮：**不能仅凭 LED 判断是否在恢复模式**。

---

## 7. 成功判断

- LED 由黄色转为蓝色/正常；
- 路由器自动重启；
- 手机能搜到原来的 Xiaomi SSID；
- `http://192.168.31.1` 可打开原厂管理页；
- 原厂固件版本可在后台查看。

---

## 8. 失败判断

- 按住 Reset 上电 60 秒后，LED 仍不闪烁；
- 松开后 15 分钟仍无 Wi-Fi、无 `192.168.31.1`；
- LED 反复重启/常亮不变；
- 有线链路仍然周期性断开。

出现任一情况：停止，不要反复 Reset；改走 UART + TFTP。

---

## 9. 可能被覆盖的分区

| 分区 | 风险 |
|---|---|
| kernel0 | 可能被原厂固件写回（恢复目标） |
| kernel1 | 可能被覆盖；当前已是 OpenWrt |
| rootfs0/rootfs1 | 可能被原厂 rootfs 覆盖 |
| Bootloader | 通常不写；但不能保证 |
| Factory / EEPROM | **通常不写**；无线校准/MAC 所在，风险最高 |
| Bdata / Config | 通常不写 |

原厂整片备份：`backups/r3g-stock-full-20261104.bin`
（SHA-256 `0d690a8f…`），包含 Factory 与所有分区。

---

## 10. 保护 Factory / EEPROM / MAC

- 不要执行任何会写 Factory 的命令；
- 恢复后第一件事：登录后台确认 MAC 是否仍是 `AA:BB:CC:DD:EE:01`；
- 若 MAC 异常/无线校准丢失，不要用第三方固件覆盖；用 UART 或编程器
  从备份恢复 Factory；
- 备份目前只有一份，建议先复制到另一块物理磁盘。

---

## 11. 失败后的回退

1. **UART + TFTP**（官方 OpenWrt 路线）：3.3V、115200 8N1；
   用 U-Boot 菜单的 “Load system code then write to Flash via TFTP”
   写回原厂 kernel0/完整备份。
2. **整片恢复**：用 `r3g-stock-full-20261104.bin` 通过 UART/编程器恢复。
3. **不要**反复按 Reset 或尝试不匹配的固件。

---

## 12. 官方 / 推断 / 未确认

**官方明确记载**

- OpenWrt 页面：FAT32 U 盘 + `miwifi_ssh.bin` + 按住 Reset 至黄灯闪；
- OpenWrt 页面：UART 3.3V、115200 8N1、U-Boot 菜单；
- 小米官方 API/下载页：R3G 2.28.46 固件地址。

**社区证据**

- 原厂固件改名 `miwifi.bin` 放 FAT32 U 盘；
- kernel0 内含 USB 恢复功能；
- 按住 Reset 上电触发整机恢复。

**未确认**

- 当前 boot loop 状态能否进入恢复模式；
- 2.28.46 是否被恢复环境接受；
- 恢复具体覆盖哪些分区；
- 黄色常亮是否等于恢复等待。
