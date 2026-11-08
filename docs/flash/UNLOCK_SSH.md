# 解锁 R3G 原厂 SSH

> 授权范围：只开启 telnet/ssh/ftp。**不写 Flash、不刷机。**
> 不刷机时，重启路由器即可关闭这些服务。

## 前置条件

- 路由器通电，网线接 **LAN 口**（不是 WAN）。
- 电脑在该链路上拿到 `192.168.31.x`，或手动设 `192.168.31.2/24`。
- 或者笔记本 Wi-Fi 直接连 R3G 的 SSID。
- 浏览器能打开 `http://192.168.31.1`，并**至少登录过一次后台**（脚本需要 token）。
- 关闭对 `192.168.31.1` 的代理劫持（脚本会自动清除 HTTP(S)_PROXY）。

## 准备工具

脚本默认从 `router/flash/OpenWRTInvasion` 查找上游工具。它不随本仓库分发：

```bash
git clone https://github.com/acecilia/OpenWRTInvasion.git router/flash/OpenWRTInvasion
```

## 一键启动

```powershell
powershell -ExecutionPolicy Bypass -File .\router\flash\unlock_ssh.ps1
```

脚本会先检测 ICMP / TCP80 / TCP22；不可达就直接退出，不会运行漏洞。

## 交互输入

| 提示 | 输入 |
|---|---|
| Router IP address | 直接回车（默认 `192.168.31.1`） |
| Enter router admin password | 你的小米后台密码（只在本机终端输入） |
| Which option do you prefer? | `1`（本地 TCP 文件服务器） |

选 `1` 时路由器不需要外网，适合寝室/校园网环境。

## 成功标志

```
Done exploiting
```

端口检测：

```
FTP 21: True   SSH 22: True   Telnet 23: True
```

账号密码：`root` / `root`（OpenWRTInvasion 默认；首次登录后请修改）。

## 失败分支

| 现象 | 原因 | 处理 |
|---|---|---|
| `Xiaomi router not found` | 没登录过后台 / IP 不对 / 代理劫持 | 浏览器登录一次；确认直连；脚本已清代理 |
| 登录失败 / 拿不到 stok | 密码错误或版本不匹配 | 手动从地址栏复制 stok |
| 端口不开放 | 固件已修补 | 走官方开发者固件 + `miwifi_ssh.bin` |
| 脚本卡在文件服务器 | PC 防火墙阻止入站 | 临时允许 Python，或改用选项 1 后重试 |

## 实测记录（2026-11-04）

本机 R3G 固件 `2.28.24`，脚本版本说明写着漏洞只影响 `< 2.28.23`，
但实际执行 **成功**：

```
stok 获取成功
local file server is getting 'busybox-mipsel' for 192.168.31.1.
local file server is getting 'dropbearStaticMipsel.tar.bz2' for 192.168.31.1.
done!
21: True  22: True  23: True
```

结论：版本号不是绝对判据，仍需实测。

## 安全注意

- 解锁期间 `root/root` 对局域网暴露；不要在公共网络下长时间保持。
- 备份完成后如不立即刷机，重启路由器关闭服务。
- 不要把后台密码写进任何脚本或配置文件。
- 本项目只在你拥有的设备上执行。
