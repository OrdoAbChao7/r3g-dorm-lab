# 校园门户自动重登录（R3G WAN）

R3G 的宿舍网口需要 WHUT 网页门户认证。会话会因重启、DHCP 续租或学校策略（隔几天）
失效；失效后国外 HTTPS/代理全部失败（常见 `x509: certificate is not valid for any names`）。

这套脚本在路由器上做一件事：**会话在线时什么都不做；掉线才用本机保存的账号登录，
并验证真的上线了。**

- 通用版（含 Windows PC、兼容性评估）：<https://github.com/OrdoAbChao7/campus-portal-autologin>
- 本目录是 R3G 部署实例（默认门户 `172.30.21.100`、WAN `wan`、本口 NAS `52`）。

## 文件

| 文件 | 作用 |
|---|---|
| `portal_autologin.sh` | 主程序：`run`（cron）、`status`（只读）、`test-login`（诊断） |
| `portal_set_credentials.sh` | 在终端交互输入账号密码，写入 `/etc/portal/login.conf`（600） |

## 部署

```sh
scp portal_autologin.sh portal_set_credentials.sh root@192.168.1.1:/usr/bin/
ssh root@192.168.1.1 'chmod 755 /usr/bin/portal_autologin.sh /usr/bin/portal_set_credentials.sh'

# 交互输入校园网账号（密码不回显，只写 600 文件）
ssh -t root@192.168.1.1 /usr/bin/portal_set_credentials.sh

# 本口 NAS 号：从未认证时浏览器被 BRAS 重定向的 URL 里取（…&nasId=52&…）
ssh root@192.168.1.1 'printf "NAS_ID=52\n" > /etc/portal/nas.conf && chmod 600 /etc/portal/nas.conf'

# 每 3 分钟巡检（在线静默）
ssh root@192.168.1.1 'echo "*/3 * * * * /usr/bin/portal_autologin.sh run >/dev/null 2>&1" >> /etc/crontabs/root'

# 只读检查
ssh root@192.168.1.1 '/usr/bin/portal_autologin.sh status'
```

日志：`/tmp/portal_autologin.log`。

## 工作方式

```
每 3 分钟
  GET /api/account/status
    ├─ 在线 → 退出（不登录、不写日志）
    └─ 离线 → GET /api/csrf-token → POST /api/account/login
         ├─ code 0 → 2 秒后复查，真在线才算成功
         ├─ code 1 → 退避（5→10→…→30 分钟）
         │    └─ 若报“设备IP不在线”：ifdown/ifup wan（15 分钟最多一次）
         │       → 等最多 60 秒复查 → 仍离线再登录一次
         └─ code 2 → 需要验证码：停 30 分钟，等人工登录
```

关键点：

- **在线绝不补登录**。实测过：在线时再发登录，门户先回成功，随后原会话被终止，
  NAS 报“设备IP不在线”。脚本在登录前有二次在线检查。
- **nasId 必须用 BRAS 重定向 URL 的值**（本口为 `52`）。门户 `/api/config` 的
  `default_nas=14` 只是默认页，用错会一直报“设备IP不在线”。
- 验证码只在连续错误 `err_count_captcha` 次后出现；脚本遇 `code 2` 即停，不破解。
- 凭据只在 `/etc/portal/login.conf`（600）和 `/etc/portal/nas.conf`（600）。

## 已验证状态

| 项目 | 状态 |
|---|---|
| 在线状态判断（`/api/account/status`） | 已验证：在线/离线均正确 |
| 受控注销后自动登录 | 已验证：`login OK and verified online (ip … nas 52)` |
| 在线保护（拒绝补登录） | 已验证：`session is online; refusing test-login` |
| 自然过期（非注销）路径 | 待观察 |
| “设备IP不在线”后的 WAN 重连兜底 | 已实现；实测中该分支曾把会话等回来，但并非每次立刻生效 |
