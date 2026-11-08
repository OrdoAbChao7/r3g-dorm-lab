# OpenWrt NAS + SMB + Aria2 部署方案

状态：**NOT_STARTED**（依赖刷机完成）。所有命令都需要在 R3G 上执行并逐项确认。

## 0. 前置条件

- R3G 已运行官方 OpenWrt 25.12.6，LAN 为 `192.168.1.1`。
- 移动硬盘已插入 USB 3.0 口，**文件系统已知**。
- 硬盘上可能有重要文件：**禁止格式化、分区、删除**。

先只读检查：

```sh
lsblk -f
blkid
df -h
dmesg | tail -40
```

确认：

- 分区有文件系统（ext4 / exFAT / NTFS / FAT32）
- 内核已识别容量
- 没有 I/O 错误或掉盘

> OpenWrt 默认内核通常支持 ext4 / FAT / exFAT；NTFS 需要 `kmod-fs-ntfs3` 或
> `ntfs-3g`，写入性能与可靠性不同。**不要为了省事格式化**。

## 1. 挂载

### 临时挂载（先验证读写）

```sh
mkdir -p /mnt/usb
mount /dev/sda1 /mnt/usb
touch /mnt/usb/.rw_test && rm /mnt/usb/.rw_test
df -h /mnt/usb
```

### 持久挂载（按 UUID，避免 /dev/sda 变化）

```sh
blkid /dev/sda1         # 取 UUID
uci add fstab mount
uci set fstab.@mount[-1].uuid='<UUID>'
uci set fstab.@mount[-1].target='/mnt/usb'
uci set fstab.@mount[-1].fstype='ext4'
uci set fstab.@mount[-1].options='noatime'
uci commit fstab
/etc/init.d/fstab restart
```

替换 `fstype` 为实际值。不要加 `ro`（SMB 需要写），也不要加 `sync`（性能极差）。

### 安全卸载

```sh
sync
umount /mnt/usb
```

拔线前必须卸载。热插拔可能导致文件系统损坏。

## 2. SMB：先评估 ksmbd，再考虑 samba4

| 方案 | 优点 | 缺点 |
|---|---|---|
| `ksmbd-server` | 内核态，内存占用低，适合 256 MB | 功能较少 |
| `samba4-server` | 功能全、兼容性好 | 内存占用高，R3G 上偏重 |

建议顺序：先装 ksmbd；若客户端兼容性有问题再换 samba4。

```sh
opkg update
opkg install ksmbd-server luci-app-ksmbd
# 若不可用：
# opkg install samba4-server luci-app-samba4
```

创建共享目录（在已挂载的硬盘内）：

```sh
mkdir -p /mnt/usb/media /mnt/usb/downloads /mnt/usb/backup
```

ksmbd 配置示例（LuCI：服务 → 网络共享）：

```sh
uci set ksmbd.@globals[0].workgroup='WORKGROUP'
uci set ksmbd.@globals[0].description='R3G NAS'

uci add ksmbd share
uci set ksmbd.@share[-1].name='media'
uci set ksmbd.@share[-1].path='/mnt/usb/media'
uci set ksmbd.@share[-1].read_only='no'
uci set ksmbd.@share[-1].guest_ok='no'
uci set ksmbd.@share[-1].create_mask='0664'
uci set ksmbd.@share[-1].dir_mask='0775'
uci commit ksmbd
/etc/init.d/ksmbd restart
```

设置账号：

```sh
# ksmbd
smbpasswd -a root
# samba4
smbpasswd -a root
```

**不允许匿名写入**；不要向校园网暴露 445 端口（R3G 默认不转发 WAN 入站）。

Windows 映射：

```powershell
net use Z: \\192.168.1.1\media /persistent:no /user:root
```

Win11 若报错，检查是否启用 SMB 1.0（老固件常见）；官方 OpenWrt 默认 SMB2/3，
通常不需要。

## 3. Aria2

```sh
opkg update
opkg install aria2
# 可选 Web 前端
opkg install ariang
```

创建配置：

```sh
mkdir -p /etc/aria2 /mnt/usb/downloads
cat > /etc/aria2/aria2.conf <<'EOF'
dir=/mnt/usb/downloads
continue=true
input-file=/etc/aria2/aria2.session
save-session=/etc/aria2/aria2.session
save-session-interval=30
enable-rpc=true
rpc-listen-all=false
rpc-listen-port=6800
rpc-secret=CHANGE_ME_LONG_RANDOM
max-concurrent-downloads=3
max-connection-per-server=4
file-allocation=falloc
disk-cache=16M
EOF
touch /etc/aria2/aria2.session
```

`rpc-listen-all=false` 只监听 LAN 接口；若必须跨网段访问，再改为 true 并确保
防火墙只允许 LAN 区域。**永远不要把 6800 暴露到公网**。

启动脚本（若软件包未自带 procd 服务）：

```sh
cat > /etc/init.d/aria2 <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/aria2c --conf-path=/etc/aria2/aria2.conf
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod +x /etc/init.d/aria2
/etc/init.d/aria2 enable
/etc/init.d/aria2 start
```

验证：

```sh
logread -e aria2
netstat -lntp | grep 6800
```

客户端用 AriaNg 或 Motrix 连接：

```
http://192.168.1.1:6800/jsonrpc
```

填写 `rpc-secret`。

## 4. 性能与稳定性

- R3G 是 880 MHz 双核 + 256 MB RAM：Aria2 适合 3–5 个并发，不适合几十个。
- 下载到 USB 硬盘时，SMB 同时读写会明显变慢；这是 USB/CPU 瓶颈，不是故障。
- USB 3.0 可能干扰 2.4 GHz：把硬盘线远离天线，或固定 2.4G 信道。
- 断电前 `sync`；建议给路由器配 UPS 或至少避免下载中直接断电。

## 5. 权限与安全

- SMB 必须账号认证，`guest_ok=no`。
- Aria2 RPC 必须设置 `rpc-secret`，只监听 LAN。
- 不在 WAN 区域开放 445 / 6800。
- 不把校园网认证信息写进共享目录。

## 6. 验收

- [ ] `lsblk` 能看到硬盘，`dmesg` 无 I/O 错误
- [ ] 挂载后可读写，重启后自动挂载
- [ ] Windows 能映射 `Z:` 并复制 1 GB 文件
- [ ] Aria2 能下载并断点续传
- [ ] 路由器重启后 SMB/Aria2 自动恢复
- [ ] 断电测试后文件系统未损坏（先 `sync`）
