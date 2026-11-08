# NIC_CROSS_TEST

检测时间：2026-11-04 01:38（UTC+08:00）。操作仅为读取状态，未修改网络配置或路由器。

## 结论

内置网卡也反复断开，短暂接通时显示 1 Gbps，接收字节始终为零。结合此前 USB RTL8156 的类似现象，网线及 R3G LAN 端口或路由器端状态是下一步重点；本次不能单独确认任何部件损坏，也不能排除采样期间插拔等外部动作的影响。

## 内置网卡身份

名称：以太网；InterfaceDescription：Realtek Gaming 2.5GbE Family Controller；MAC：AA-BB-CC-DD-EE-04；GUID：{181F9A20-6257-4AF8-85E3-F2BCE23BE183}；InterfaceIndex：9。USB 网卡未出现在开始时的适配器列表中。

## 采样记录

按每次读取后等待 2 秒采样 16 次，实际跨度 01:38:14–01:38:46（读取耗时导致间隔略超过 2 秒）。

| 时间 | 状态 | LinkSpeed | Media |
|---|---|---|---|
| 01:38:14、16、18 | Disconnected | 1 Gbps | Disconnected |
| 01:38:21、23、25、27 | Up | 1 Gbps | Connected |
| 01:38:29、31、33、35 | Disconnected | 1 Gbps | Disconnected |
| 01:38:37、39、42、44 | Up | 1 Gbps | Connected |
| 01:38:46 | Disconnected | 1 Gbps | Disconnected |

断开时仍显示 1 Gbps，不能将该值视为当时链路已接通。接收字节始终为 0；发送从 22893 增至 53081 字节；收发错误计数均为 0。计数变化不证明对端收到数据。

## IPv4 和 ARP

采样结束时 DHCP Enabled、ConnectionState Disconnected；IPv4 为自动配置的 169.254.225.51/16，状态 Deprecated，未获得 DHCP 地址。内置接口的 192.168.31.1 邻居查询无记录；这是缓存查询，未主动发起 ARP，不能单独证明 ARP 请求失败。

## WLAN、默认路由和 Clash

采样前后 WLAN 2 均连接 Campus-WiFi，AP BSSID a8:5b:f7:a2:e0:71；开始时 IPv4 为 198.51.100.20。采样前后 IPv4 默认路由均为接口 7、下一跳 198.51.100.1、RouteMetric 0。127.0.0.1:7897 前后均由 PID 20160 监听。上述为采样前后的快照比较，不代表检测期间每一瞬间均未变化，也未核验 Clash 全部配置。

## 建议

用已知正常的另一根网线复测，并用已知正常的网络设备交叉验证内置网卡；必要时再检查 R3G 其他 LAN 口及其启动状态。保持原厂 kernel0、rootfs0 和 NVRAM 不动。
