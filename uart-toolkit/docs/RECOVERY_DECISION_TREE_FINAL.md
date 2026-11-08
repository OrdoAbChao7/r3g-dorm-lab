# L5 恢复决策树（2026-11-07）

当前 L5 BLOCKED。先审阅 [README.md](../README.md)、[R3G_BOOT_LOG_ANALYSIS.md](../R3G_BOOT_LOG_ANALYSIS.md)、[UBOOT_BOOT_AND_CONFIG_RISK_AUDIT.md](../UBOOT_BOOT_AND_CONFIG_RISK_AUDIT.md)。

菜单 1 真实调用链、加载地址、Config 擦写和 initramfs 自动行为任一未证实 → 停止；需要新证据，不能通过未经授权的上电实验取得。若全部风险经证据审查解决，仍须完成 UART TX 电平确认、供电与身份核对，并取得用户对具体方案的单独授权。菜单 2 禁止；不更改 NVRAM、原厂分区或备份。本页不含执行步骤。
