> **R3G 宿舍网络系列 · 阶段 4/4：运维**
> [阶段 1 救砖](uart-recovery.md) · [阶段 2 中枢](dorm-hub.md) · [阶段 3 复盘](retrospective.md) · **阶段 4 运维（本篇）**
>
> 这一篇写系统“跑起来之后”的事。前三个阶段回答的是能不能救回、能不能联网、为什么这样设计；阶段四回答的是每天都这样运行时，**谁在解析、会话还在不在、应用该连哪个端口**。

## 阶段四：问题变了

11-08 深夜，R3G 已经能稳定上网：mihomo 透明代理、anti-AD 去广告、DNS 自动回退、WoL 与 Tailscale 都已就位。按理说，接下来只需要观察。

但真正开始“日常使用”之后，问题从连通性换了一个维度：

- **解析器身份**：答案能返回，但答案是本地运营商给的，国外域名在 DNS 层就泄露了；
- **会话身份**：校园门户的会话会过期，重启或续租后需要重新认证；
- **应用接口**：PC 上多个代理栈各自写死端口，换一次端口就有一批应用失效。

这三个问题都不是“网络不通”，而是“网络通了，但身份或边界不对”。阶段四记录这三件事的排查与处置，以及一次把 PC 代理收敛到单一入口的改造。

## 一、DNS 泄露：答案对了，解析器错了

最早的信号来自 EDNS 检测页：`claude.ai` 的出口已经是代理 IP，但解析器一栏显示的是本地联通地址 `211.91.166.18`。

先排除客户端绕过：

- Windows 适配器 DNS 只有 `192.168.1.1`；
- 浏览器没有启用安全 DNS，系统没有 DoH；
- 系统代理关闭，浏览器没有代理扩展。

排查确认查询由 R3G 承接。根因在于路由器的上游配置：`dns.nameserver` 直接指定了校园 DNS，**所有域名**（包括国外域名）均由本地解析。流量虽走代理，域名却在本地暴露，这就是 DNS 泄露。

修复分两层：

```yaml
dns:
  nameserver:
    - https://1.1.1.1/dns-query#PROXY
    - https://1.0.0.1/dns-query#PROXY
  nameserver-policy:
    "geosite:cn,private":
      - 202.114.x.x
      - 202.114.x.y
  proxy-server-nameserver:
    - 202.114.x.x
    - 202.114.x.y
```

- 国外域名走 Cloudflare DoH，并且 **`#PROXY` 不能省**；
- `geosite:cn` 与 `geosite:private` 继续走校园 DNS，国内解析保持就近；
- `proxy-server-nameserver` 保留校园 DNS，用于代理节点自身的 bootstrap。

这里最容易踩的坑是第二行：**DoH 不带 `#PROXY`，请求仍然从本地 WAN 发出，解析器身份没有变。** 表面配置了加密 DNS，实际上泄露照旧。

`geosite.dat` 为 4,355,962 B，加载后 CN 规则 110,177 条、private 133 条。`mihomo -t` 通过后用 API 热重载，PID 不变。

验证结果：

| 检查项 | 结果 |
|---|---|
| EDNS 解析器 | Cloudflare US `172.69.32.29` |
| 国内站点 | 百度 200，仍走校园 DNS 解析 |
| 代理连通性 | `gstatic` 204 |
| Windows NCSI | 200，PC 显示 Internet |
| anti-AD | 连接层 `REJECT` 正常 |

mihomo RSS 约 65 MiB。PC 侧的 Clash Verge 有自己的一套 DNS；如果重新打开它的系统代理，浏览器会回到它的解析路径。这并非路由器失效，根本逻辑在于**同一时刻只能有一个 DNS 所有者**。

## 二、检测页的“中国出口”是另一回事

修完 DoH 后，检测页仍有一行红字：中国出口 `58.19.30.229`。直观上看似 Claude 识别到了真实 IP。

检查前端请求链发现，该行数据实际来自检测页在前端调用的 `my.ip.cn` 与 `2026.ip138.com`。这两个国内域名按 `GEOIP,CN,DIRECT` 走了直连，看到的自然是本地真实出口；Claude 端点本身已走代理。

判断标准应该以目标服务的回显为准：

```text
https://claude.ai/cdn-cgi/trace  →  ip=149.248.10.4   (US)
```

后来把这两个检测域名用 `DOMAIN` 精确匹配放到规则最前、指向 `PROXY`，检测页那一行也变成了代理 IP。这属于对齐仪表盘展示的 cosmetic 修复，不改变实际业务分流。

**教训：不要用某一个检测页的一行字判断泄露；要看目标服务自己看到的来源。**

排查中未采用全局模式应对该问题。全局模式会跳过 anti-AD、NCSI 直连和国内直连例外，代理故障时国内流量会连带中断；引入更大可用性风险以迎合单点检测展示，在工程上并不可取。

## 三、Claude / Anthropic 显式分流

DoH 配置完成后，Claude 的域名分流仍依附于 `MATCH,PROXY` 兜底策略。为了让分流规则清晰可审计，把 Anthropic 相关流量显式放到最前：

- 7 个域名后缀 + 4 个精确域名；
- `sentry`、`statsig`、`datadog`、`sift`、`intercom`、`fathom` 等遥测域名；
- `IP-CIDR,160.79.104.0/21`；
- `GEOSITE,anthropic`（21 条）。

`mihomo -t` 通过后执行热重载，PID 4760 保持不变。实际验证时 `api.anthropic.com`、`claude.ai` 都命中 `DomainSuffix` 规则走 `PROXY`，Claude 回显 `149.248.10.4`（US）；百度、NCSI、anti-AD 均正常；RSS 约 70 MiB。

必须如实界定工程边界：节点为 Vultr 机房 IP，**风控属性不是规则能改的**。显式分流解决的是“该走代理的走代理”，无法干预机房出口 IP 自身带来的风险特征。

## 四、校园门户：在线时什么都别做

校园有线口需要 WHUT 网页门户认证。未认证时，HTTP 会被门户接管，HTTPS 会报：

```text
x509: certificate is not valid for any names
```

更棘手的是会话周期性失效：设备重启、DHCP 续租及校园网定期策略（间隔数日）均可能要求重新认证。WAN 接口 MAC 虽然在“无感知认证”列表里，但实际会话仍是账号认证，`/api/account/status` 的 `AddTime` 正好等于最近一次手动登录时间。**“已绑定 MAC”不等于“已经验证长期有效”。**

门户接口本身很规整：

| 接口 | 作用 |
|---|---|
| `GET /api/account/status` | 当前来源 IP 的会话状态，`code:0` 即在线 |
| `GET /api/csrf-token` | 登录前的 token + cookie |
| `POST /api/account/login` | `0` 成功 / `1` 失败 / `2` 需要验证码 |
| `GET /api/config` | `default_nas=14`、`err_count_captcha=10` |

脚本的设计只有一句话：**在线时什么都不做，掉线才登录，登录后必须复查。**

```text
每 3 分钟
  GET /api/account/status
    ├─ 在线 → 退出（不登录、不写日志）
    └─ 离线 → GET /api/csrf-token → POST /api/account/login
         ├─ code 0 → 2 秒后复查，真在线才算成功
         ├─ code 1 → 退避（5→10→…→30 分钟）
         │    └─ 若报“设备IP不在线”：重连 WAN（15 分钟最多一次）
         │       → 等最多 60 秒复查 → 仍离线再登录一次
         └─ code 2 → 需要验证码：停 30 分钟，等人工
```

### 事故：在线补登录会杀掉原会话

部署后做了一次诊断性登录：在会话处于在线状态时手动调用 `test-login`。门户先返回 `code 0`，表面提示成功；但原有合法会话随即被终止，下一次请求变成：

```text
code 1  您的设备IP不在线，请断开网络重新连接后再次登陆
```

最终靠用户在手机上重新认证才恢复。

**门户接受登录请求，不等于原会话还能活着。** 现在脚本在 `attempt_login` 内部做二次在线检查，`test-login` 在线时默认拒绝，只有 `PORTAL_FORCE_LOGIN=1` 才允许覆盖。

### 演练：注销之后，登录不是第一步

经用户同意做了一次受控演练：主动注销后状态变为离线；随后两次凭据登录都返回“设备IP不在线”；执行：

```sh
ifdown wan; ifup wan
```

之后**会话自行恢复**，期间未产生任何凭据登录请求。

排查结论：这个有线口在链路重连后会有 MAC/无感知式恢复，但会话过期或注销后，单纯 POST 登录不够，必须先让 NAS 重新登记这个 IP。脚本因此改成：离线 → 登录；若报“不在线”→ 重连 WAN → 复查；仍离线再重试一次登录。真实“自然过期”路径仍在观察。

### 根因：nasId 不是 default_nas

此前系列“设备IP不在线”报错的真正根因，是 **nasId 写错**。

门户 `/api/config` 返回的 `default_nas=14` 只是默认页。这个有线口真正连接的 BRAS，在浏览器被重定向的 URL 里写得很清楚：

```text
acip=172.30.1.223&acname=WHUT-Bras-ME60-A&nasId=52&ip=<WAN IP>
```

把 `NAS_ID=52` 写入 `/etc/portal/nas.conf` 后，注销 → 脚本登录**一次成功**：

```text
login OK and verified online (ip <WAN IP>, nas 52)
```

**登录参数以 BRAS 重定向 URL 为准，不要拿门户默认值当本口 NAS。** 这也合理解释了为何此前重连 WAN 偶尔能够恢复连通：真正生效的是物理链路重连触发了底层无感知认证，并非凭据登录奏效。

### 副作用：路由器自己的出站被代理截获

R3G 上的 mihomo 有一条 nat output 规则，把本机 TCP 重定向到 `:45919`。结果是：

```text
wget/curl → Failed to send request: Operation not permitted
apk update → 同样失败
```

校园门户 `172.30.0.0/12` 已从 TUN 排除，所以门户不受影响；但路由器上装包、访问公网会失败。排障时不要误判为镜像或 DNS 问题。**透明代理不只接管转发流量，也会接管网关自己的出站。**

通用化版本已经独立成 [campus-portal-autologin](https://github.com/OrdoAbChao7/campus-portal-autologin)（MIT，OpenWrt shell + Windows beta），R3G 上的脚本是它的一个部署实例。

## 五、PC 侧：应用只认一个门

PC 侧原来的痛点在于代理栈冗余且端口缺乏统管：系统代理、环境变量、Clash Verge 的 TUN/系统代理三层互相冲突；某个应用把上游端口写死在数据库里，端口一变就断。

现在的结构收敛成一个稳定入口：

```text
应用 / Claude Code / 浏览器
        │
        ▼
127.0.0.1:17890  (dispatcher, proxyauto-mihomo)
        │  fallback
        ├─ 127.0.0.1:7897  Clash Verge mixed
        ├─ 127.0.0.1:7899  self-proxy mihomo
        └─ DIRECT（可配置）
```

该架构的核心价值在于确立了三条管控约束：

1. **应用只写 facade。** 应用不知道 7897/7899，只知道 17890；
2. **内部端口只有一份登记表。** `ports.json` 是唯一来源，`render-config.ps1` 校验后生成配置；
3. **系统代理只有一个所有者。** Clash Verge 的 `enable_system_proxy` 保持关闭，由 `enforce.ps1` 统一把 WinINET 和环境变量指向 17890。

生成和切换流程是：`ports.json` → `render-config.ps1`（校验 + 生成 + `mihomo -t` + 原子替换）→ `restart-dispatcher.ps1`（失败自动回滚）。健康检查用 `https://www.gstatic.com/generate_204` 期望 204，**不能用百度**：百度走上游的 CN 直连分支，节点全挂也可能显示“健康”。

实测切换时间：

| 故障类型 | 检测/切换 |
|---|---|
| 进程死亡（连接被拒绝） | 约 1 秒 |
| 端口开着但不响应（黑洞） | 8.3 秒 |
| 主上游恢复 | 1.8 秒切回 |

### 一次真实的端口错配

本地模型网关 CC Switch 曾在数据库里把 `global_proxy_url` 写死成 `http://127.0.0.1:7897`。Clash Verge 的 mixed 端口一变，它立刻报：

```text
tcp connect error: 由于目标计算机积极拒绝，无法连接 (os error 10061)
```

当时把端口改回 7897 确实恢复了连通，但实质仅是让两处硬编码值暂时偶合。工程上的正确处置是把 CC Switch 的全局代理改成 `http://127.0.0.1:17890`，让它重新经过 facade。后来的 Magpie（本地网关 `127.0.0.1:3425`）默认跟随系统代理 / `HTTPS_PROXY`，不再需要改应用内数据库。

**铁律：不要为了让某个应用能用，去对齐它的内部端口。应用只认 facade，内部端口只改登记表。**

### PC 也要给校园门户留直连

PC 的系统代理指向 17890 后，浏览器打开 `http://172.30.x.x` 会超时，而 `curl --noproxy '*'` 8 毫秒就返回 200。排查确认门户服务正常，超时症结在于认证流量被 dispatcher 当普通流量转给上游；门户按来源 IP 绑定，会重置这种代理请求。

在 `render-config.ps1` 的规则里，于 `MATCH,auto` 之前加：

```yaml
- IP-CIDR,172.30.0.0/12,DIRECT,no-resolve
- IP-CIDR,10.84.0.0/15,DIRECT,no-resolve
- DOMAIN-SUFFIX,whut.edu.cn,DIRECT
```

之后 `curl -x http://127.0.0.1:17890 http://172.30.x.x/api/account/status` 返回 200，`gstatic` 仍是 204。**`--noproxy '*'` 只能绕过命令行，浏览器和系统代理必须靠 dispatcher 规则。**

### 还没解决：主路径抖动

约 30 分钟的持续测试成功率是 99.66%，但 `auto` 组进入 `selfproxy` 9 次、回到 `clash-verge` 10 次，单次停留 6–19 秒。请求基本没断，但这不符合“避免频繁切换”的目标。

根因是 `fallback` 对周期性健康检查没有恢复滞回：单次检查失败就切走，下一次成功又切回。可选的修法是把稳定的自建 7899 设为主上游，或引入“连续 3 次失败切走、连续 6 次成功切回”的看门狗。当前实机在 Clash Verge 关闭时，`auto.now=selfproxy`，Magpie 的 4 条出站全部经 17890，基础连通可用，但链路抖动仍作为待办项跟踪。

## 六、阶段四的边界

已经验证的：

- 国外域名经代理 DoH 解析，EDNS 显示 Cloudflare；国内域名继续走校园 DNS；
- Claude / Anthropic 显式分流命中 `PROXY`，Claude 回显代理出口；
- 校园门户：在线判断、受控注销后自动登录、在线保护、`nasId=52` 均已实测；
- PC facade：自动切换、恢复、Magpie 出站经 17890、门户直连规则均已实测。

还没验证的：

- 门户会话“自然过期”（非主动注销）的完整路径；
- 真实 kill mihomo 演练；
- 真实 WoL 唤醒与手机端 Tailscale 外网；
- 24 小时以上稳定性、IPv6 / 手机 DoH 是否绕过过滤；
- facade 主路径抖动（30 分钟 9 次切换）的最终修法。

## 四个阶段，各回答一个问题

| 阶段 | 时间 | 回答的问题 | 文章 |
|---|---|---|---|
| 1 救砖 | 11-03–11-07 | 设备还能不能回来？ | [只刷了 kernel1](uart-recovery.md) |
| 2 中枢 | 11-08 | 网络能不能自己活着？ | [从能开机到能生活](dorm-hub.md) |
| 3 复盘 | 11-08 晚 | 哪些决策是对的，哪些数字是真的？ | [从救砖到托管](retrospective.md) |
| 4 运维 | 11-09–11-11 | 每天都这样运行时，谁在解析、谁在认证、应用连哪里？ | 本篇 |

阶段二解决“能通”，阶段三解决“为什么这样”，阶段四解决“每天都这样”。

## 六条教训

1. **先问“谁在回答”，再问“答案对不对”。** DNS 排障的第一步不是看返回值，而是看解析器身份。
2. **加密 DNS 不等于不泄露。** DoH 不带 `#PROXY`，请求仍然从本地出口发出。
3. **不要用一个检测页的一行字判断泄露。** 以目标服务的 `cdn-cgi/trace` 为准。
4. **会话在线时不要补登录。** 门户返回 `code 0` 不等于原会话还活着。
5. **参数以 BRAS 重定向为准。** `default_nas` 是默认页，不是本口 NAS。
6. **应用只认 facade。** 内部端口只能有一份登记表；健康检查必须经代理并校验状态码。

代码与复现：[github.com/OrdoAbChao7/r3g-dorm-lab](https://github.com/OrdoAbChao7/r3g-dorm-lab)

上一篇：[从救砖到托管：一台 R3G 的项目复盘](retrospective.md)
