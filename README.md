# mihomo-tproxy-gateway

通用 Linux mihomo TPROXY 旁路由透明代理与无人值守维护方案。

> **版本说明**：当前为开发版，尚未发布正式版。发布版本号在发版时决定，
> 本文档描述的均是当前分支的实际行为。

## 项目介绍

面向"喜欢用通用 Linux 发行版（Debian / Ubuntu / Armbian 等）做旁路由网关，
不想被 OpenWrt 生态绑定"的用户 —— OpenWrt 上的 mihomo/clash 方案高度依赖
`dnsmasq`、`netifd` 等 OpenWrt 专属组件，换到普通 Linux 发行版上并不适用，
这也是本项目存在的原因：把安装、TPROXY 规则、DNS 劫持、无人值守维护这一整套
在通用 Linux 上重新实现一遍。

本项目提供：

- 一键安装：自动检测系统、架构、网卡与网段，引导式配置订阅与面板
- 透明代理：TPROXY + 策略路由，只接管指定入口网卡与指定 LAN 网段的 IPv4 流量
- DNS 劫持：UDP/TCP 53 全部重定向到本机 fake-ip DNS，防 DNS 泄漏
- 无人值守维护：定时健康检查、订阅刷新、内核/面板/geodata 自动更新（带校验与回滚）
- 安装事务：下载/校验/配置/启动任一阶段失败都自动回滚，不留半成品状态
- 健康自检：`verify.sh` 一键检查服务、规则、DNS、订阅是否正常

安装时的拉取策略是**官方优先、专用资产仓 Release 兜底**：仓库本体只放
脚本与配置，克隆很轻量；安装时先从官方源（含镜像链）拉取最新版本，
全部失败则由脚本自动从**专用资产仓库的 Release 附件**按需拉取钉版资产
（逐个做 sha256 校验），先保证服务能装起来；服务跑通后，本机已有
代理，自动维护脚本会经本地代理把各组件滚动更新到官方版本。详见下方
「离线兜底与自动更新」一节。

## 工作原理

这是一套**旁路由**方案，代理规则只挂在 iptables 的 `PREROUTING` 链
（处理"经过本机转发"的流量），完全没有碰 `OUTPUT` 链（本机自己发起的
流量走这条链）。也就是说：

- 只有**把这台机器设成网关的其它设备**（手机、电视、别的电脑）会被代理
- 这台跑 mihomo-tproxy-gateway 的机器**自己**访问网络、以及它上面跑的其它服务
  （网站、数据库、别的脚本等）完全不受影响，走的是原始直连
- 已经实测验证过：`iptables -t mangle -L OUTPUT` / `iptables -t nat -L OUTPUT`
  均为空规则，`curl ifconfig.me` 返回本机真实出口 IP，DNS 走本机
  `systemd-resolved`，均未被代理或劫持

如果你想让**本机自己**也走代理，可以用手动代理方式（不涉及透明代理规则）：

```
地址: 127.0.0.1
端口: 7890
类型: HTTP 或 SOCKS5
```

数据面链路（IPv4，TCP/UDP 均走同一条路）：

```
客户端 ──(网关指向本机)──▶ PREROUTING ──▶ mangle MIHOMO 链
    │                                       │
    │  入口守卫：只放行指定网卡 + 指定网段     │  打 fwmark 1
    │  （其余流量 RETURN，不受影响）          ▼
    │                              策略路由：fwmark 1 → 表 100
    │                                       │
    │                              表 100：本地路由 → TPROXY socket
    │                                       ▼
    └────────────────────────── mihomo tproxy-port 7893 ──▶ 代理出口
```

DNS 链路：客户端的 UDP/TCP 53 请求在 `nat` 表 `MIHOMO_DNS` 链内被
`REDIRECT` 到本机 1053 端口（mihomo fake-ip DNS），同样受入口网卡与
来源网段守卫限制，不在受管范围的 DNS 请求不受影响。

关键固定参数（不要改，见「已知限制」中 1062 教训的说明）：

| 参数 | 值 | 说明 |
|---|---|---|
| fwmark | `1` | TPROXY 标记，策略路由的匹配条件 |
| 路由表 | `100` | 策略路由表，含一条本地路由 |
| TPROXY 端口 | `7893` | mihomo `tproxy-port` |
| DNS 端口 | `1053` | mihomo `dns.listen` |
| 混合代理端口 | `7890` | mihomo `mixed-port`（HTTP/SOCKS5） |
| 面板端口 | `9090` | mihomo `external-controller` |

规则由 `scripts/tproxy.sh` 管理，systemd 单元在服务启动后
（`ExecStartPost`）建规则、服务停止后（`ExecStopPost`）清规则：
服务停了规则就清掉，客户端流量不会被转发到无人监听的 7893 端口形成黑洞。
规则只删本项目自有的两条链（`MIHOMO` / `MIHOMO_DNS`，多网段时另有分发子链
`MIHOMO_DO` / `MIHOMO_DNS_DO`）与 fwmark 1 / 表 100，不动其他程序的规则。

## 网络拓扑示例

```
                    互联网
                       │
                 ┌─────┴─────┐
                 │  主路由    │  192.168.1.1（DHCP 网关，默认）
                 │（光猫/路由器）│
                 └─────┬─────┘
                       │ 局域网 192.168.1.0/24
        ┌──────────────┼──────────────┐
        │              │              │
   ┌────┴────┐   ┌─────┴──────┐  ┌────┴────┐
   │ 旁路由   │   │ 手机/电脑   │  │ 其他设备 │
   │ 本项目   │   │（网关指向  │  │（网关仍为│
   │192.168.1.2│   │ 192.168.1.2）│  │ 主路由） │
   └─────────┘   └────────────┘  └─────────┘
```

- 旁路由只是一台普通的局域网设备，不需要接在 WAN 口、不需要改主路由的任何设置。
- 想走代理的设备，把**网关**改成旁路由的 IP（如 `192.168.1.2`）即可；
  不想走代理的设备保持原样，完全不受影响。
- 也可以在主路由的 DHCP 里把默认网关改成旁路由 IP，让全网设备默认走代理
  （主路由本身仍负责拨号与 NAT）。

## 系统要求

### 支持的发行版与版本

| 发行版 | 支持状态 |
|---|---|
| Debian 12 / 13 | 支持 |
| Ubuntu 22.04 / 24.04 / 26.04 | 支持 |
| Armbian（ARM64 常见版本） | 支持 |
| 其他 Debian/Ubuntu 版本、未知发行版 | 警告后继续安装，不保证 |
| Alpine Linux | **明确不支持**（musl libc 无法运行 mihomo 官方 glibc 二进制，且无 systemd） |

要求：带 systemd 的通用 Linux，root 权限运行安装脚本，内核支持 TPROXY
（`xt_TPROXY` 模块或编入内核）。

### 安装前预检

安装脚本在做任何修改之前会先跑一遍系统预检，收集全部失败项后一次性报告，
预检不通过时中止安装、**不修改系统**，用户按指引修好后重跑即可：

| 检查项 | 要求 | 不通过时 |
|---|---|---|
| 发行版/版本 | 见上表 | Alpine 拒绝；未知发行版只警告 |
| CPU 架构 | x86_64 / aarch64 / armv7l | 拒绝，明确说明不支持 |
| systemd | `systemctl` 可用 | 拒绝 |
| 必需命令 | `iptables`、`ip` | apt 系：确认后自动安装；非 apt 系：拒绝，给出针对该包管理器的完整命令 |
| TPROXY 内核支持 | 功能性探测：临时挂一条 TPROXY 规则，挂得上才算支持 | 拒绝（iptables 曾缺失时在自动安装后重测） |
| 必需依赖 | `wget`、`curl`、`tar`、`gzip`、`flock`、`sha256sum` | apt 系：确认后自动安装；非 apt 系：拒绝，给出针对该包管理器的完整命令 |
| 可选命令 | `ip6tables`（仅 IPv6 阻断需要） | 只警告，其余功能不受影响；缺失时 IPv6 阻断提问被门控禁止启用 |
| 可选依赖 | `openssl`（缺失时密钥改走 `/dev/urandom`） | 只警告，功能不受影响 |
| cron 服务 | `cron`/`crond` 在跑或已启用 | 只警告（网关本身不依赖 cron，但 15 分钟健康检查、订阅刷新与 IPv6 阻断补建依赖它定时触发）；成功页也会注明 |

**系统依赖自动安装（Debian/Ubuntu/Armbian）**：预检发现必需命令或依赖缺失时，
安装器不会直接中止，而是在确认页的"依赖安装"行展示安装计划（只列缺失的包，
不缺不列），用户确认后自动执行 `apt-get install -y <包>`；安装失败时打印完整
手动命令并中止，不会静默继续。非 apt 系（dnf/yum/pacman/zypper）不自动安装，
预检直接报错并给出针对该包管理器的完整安装命令（如 `sudo dnf install -y wget`）。
apt 系机器上若连 `apt-get` 本身都不存在，同样直接报错并给手动命令。

## 支持架构

| 架构 | 内核包 | 官方源 | 资产仓兜底 |
|---|---|---|---|
| amd64（x86_64） | `mihomo-linux-amd64` | ✅ | ✅ |
| arm64（aarch64） | `mihomo-linux-arm64` | ✅ | ✅ |
| armv7（armv7l） | `mihomo-linux-armv7` | ✅ | ✅ |

安装程序、恢复脚本与资产清单使用同一套架构映射
（x86_64→amd64、aarch64→arm64、armv7l→armv7），下载前验证架构是否受支持，
下载后校验文件完整性，不支持的架构明确提示、不会静默装错版本。

**armv7 当前状态**：`assets/manifest.json` 与 `assets/SHA256SUMS` 已包含
armv7 钉版资产条目（mihomo v1.19.32，sha256 已双源核对一致），资产本体
已上传到专用资产仓库 Release `v1.0.1`（2026-11-13，上传后往返校验通过），
官方源不可用时兜底路径自动生效。但 armv7 下载分支尚未在真机上跑通过，
只做了清单与校验层面的核对。

## 安装步骤

```bash
git clone https://github.com/moye-lab/mihomo-tproxy-gateway.git /tmp/mihomo-tproxy-gateway && sudo bash /tmp/mihomo-tproxy-gateway/scripts/install.sh
```

如果连 GitHub 都打不开、克隆不下来，用备用地址（同一份代码，托管在作者的备用站）：

```bash
git clone https://git.edge97.dpdns.org/sg/mihomo-tproxy-gateway.git /tmp/mihomo-tproxy-gateway && sudo bash /tmp/mihomo-tproxy-gateway/scripts/install.sh
```

更新到最新版：重新执行上面的安装命令即可（目录已存在时先删掉旧目录再克隆，
`sudo rm -rf /tmp/mihomo-tproxy-gateway` 后重跑）。**不要只 `git pull`**：
安装时拷入 `/etc/mihomo` 的是脚本的**副本**（`tproxy.sh`、`auto-maintain.sh`、
`verify.sh`），只拉代码不重跑安装，系统里跑的还是旧副本，新版可能新增的
必需配置也不会生效，服务会在下次重启后起不来。

安装流程（全部自动，只需回答几个问题）：

1. 系统预检（见上节），不通过则中止、不改系统
2. 交互提问（每项回车即用默认值，格式错误当场重问）：
   - 入口网卡（默认自动探测的默认路由网卡）
   - 局域网 CIDR 网段（默认按所选网卡自动探测；多网段用逗号分隔）
   - 机场订阅链接（可留空，装完再补；重装时回车保留现有订阅）
   - IPv6 阻断（仅 LAN 口分配了 IPv6 地址时出现，默认不启用；系统缺
     `ip6tables` 时该功能不可用，提问会被门控禁止启用）
   - 面板监听范围（三选一，默认仅本机 `127.0.0.1:9090`；可选局域网
     访问——绑定所选 LAN 网卡的真实 IP，或全部接口 `0.0.0.0:9090`）
   - 重装时：是否覆盖现有配置（默认保留，见「升级方式」）
3. 配置确认页：逐项展示本次安装的全部选择（网卡、网段、订阅打码显示、
   IPv6 状态、面板监听、Docker 提示），缺失系统依赖时还会展示"依赖安装"
   计划（确认后自动安装的包）；确认后才开始修改系统；选 `n` 取消，
   不做任何修改
4. 执行安装：识别 CPU 架构 → 获取 mihomo 内核、metacubexd 面板与
   GeoIP/GeoSite/MMDB 数据库 → 渲染配置文件 → 生成随机面板密钥
   （32 位十六进制）→ 启动前配置自检（`mihomo -t`）→ 安装 systemd
   服务与 cron 定时任务 → 轮询 API 确认服务真正就绪（30 秒超时）
   → API 就绪后自动跑完整功能验证（`verify.sh`：TPROXY/DNS 规则、
   策略路由、规则范围、订阅 provider），验证通过才打印成功页
5. 安装结束打印**产物获取汇总**（每个文件走官方下载还是资产仓兜底、
   用了哪个源）、订阅状态、面板地址与密钥

安装是事务性的：下载失败、校验失败、配置生成失败、`mihomo -t` 失败、
TPROXY/DNS 规则创建失败、API 30 秒未就绪，任一阶段失败都会自动回滚——
恢复旧二进制、旧配置、旧服务状态；全新安装失败则移除本次新建的文件，
恢复"未安装"状态。回滚后还会轮询 API 至多 30 秒确认旧服务真的恢复了，
验不过会如实报告"回滚未完全成功"而不是假装成功。**唯一例外是最后的
功能验证**：`verify.sh` 未通过时安装按失败处理（退出码非零、不打印
成功页，明确报"服务已启动但功能验证未通过"），但服务保持运行、不回滚、
不删配置——服务本身已正常启动，回滚反而会把能用的服务停掉；按自检
输出的排查指引修复后重跑 `sudo bash /etc/mihomo/verify.sh` 或重跑安装
即可。安装日志见 `/var/log/mihomo-install.log`（含阶段前缀，失败时可
定位到具体阶段）。

安装、卸载、换订阅、恢复、自动维护共用一把全局锁
（`/var/lock/mihomo-gateway.lock`）：手动操作撞上正在执行的任务时会明确
提示并退出，不会并发改坏系统；cron 触发的维护撞锁时静默跳过并记日志。

## 首次配置

安装成功后，还需要两步才能让设备走代理：

1. **记下面板密钥**：安装结束时只在终端打印一次（同时写入
   `/etc/mihomo/config.yaml` 与 `/etc/mihomo/maintain.env`，丢了可用
   `sudo grep '^secret:' /etc/mihomo/config.yaml` 查回）。
2. **把客户端的网关指向旁路由**：在手机/电脑的网络设置里，把网关改成
   旁路由的局域网 IP（DNS 不用单独改，DNS 劫持会自动处理）。

验证是否生效：

```bash
# 在旁路由本机跑健康自检，全部 [PASS] 即正常
sudo bash /etc/mihomo/verify.sh
```

```bash
# 在客户端浏览器打开面板，确认能看到节点列表
# http://<旁路由IP>:9090/ui
```

客户端实测（先把客户端网关指向旁路由，见上两步）：

```bash
# TCP：看出口 IP 是否变为代理出口（改网关前后各跑一次对比）
curl -s ifconfig.me
curl -s https://ipinfo.io/ip
# 预期：两次结果不同，改网关后显示的是代理节点的出口 IP；
# 若仍是宽带 IP，说明 TCP 流量没走代理，先跑 verify.sh 查 TPROXY 项
```

```bash
# UDP：DNS 走的就是 UDP 53，显式问一个外部 DNS 也能通即证明 UDP 路径正常
# （注意 DNS 会被劫持到旁路由 1053，所以问谁都一样是走代理 DNS，
# 这正是要验证的效果；若超时，先跑 verify.sh 查 DNS 项）
dig @8.8.8.8 example.com +time=5
# 有 HTTP/3 的 curl 时也可直接测 UDP 上的 QUIC：
curl --http3 -s -o /dev/null -w '%{http_code}\n' https://cloudflare.com
```

```bash
# DNS（命令行）：劫持生效时，显式指定外部 DNS 与默认查询结果一致，
# 因为请求都被重定向到了旁路由的 fake-ip DNS
dig +short example.com
dig @223.5.5.5 +short example.com
nslookup example.com
# 预期：三条命令都能解析出结果（fake-ip 段 198.18.x.x 亦属正常，
# 那是 mihomo 的 fake-ip 地址）；浏览器测漏方法见「DNS 说明」一节
# （dnsleaktest.com / browserleaks.com/dns 扩展测试）
```

如果安装时没填订阅链接（或填错了），装完后用换订阅脚本补上，
见「更换订阅链接」一节。

## 面板访问

浏览器访问：

```
http://<本机IP>:9090/ui
```

密钥在安装完成时打印一次，**只显示这一次**，如果没记下来或者当时终端已经
关了，可以随时用下面的命令重新查出来（不需要重装，密钥本身没变）：

```bash
sudo grep '^secret:' /etc/mihomo/config.yaml
```

也可以用这条，效果一样：

```bash
sudo cat /etc/mihomo/maintain.env
```

### 面板监听范围

安装时可选择面板监听范围（三选一，默认仅本机；重装时默认沿用现有选择，
旧 `0.0.0.0` 或旧 LAN IP 沿用为"局域网访问"——同一意图、更安全的绑定）：

| 选项 | 监听地址 | 适用场景 |
|---|---|---|
| 仅本机（默认） | `127.0.0.1:9090` | 只允许在本机访问，局域网内其他设备打不开 |
| 局域网访问 | `<LAN 口真实 IP>:9090` | 手机、电脑在局域网内直接打开面板 |
| 全部接口 | `0.0.0.0:9090` | 显式选择才可用，见下方警告 |

默认是仅本机：面板密钥再强也不应默认暴露给整个网络。局域网访问绑定的是
所选 LAN 网卡的真实 IP（不是 `0.0.0.0`），只在该网卡上监听。**全部接口
`0.0.0.0` 会同时绑定 WAN/公网接口，不只是"局域网内"**——任何能连通本机
公网 IP 的人都可尝试访问面板（仅靠 32 位随机密钥保护），选它时确认页与
成功页都会单独警告；如非必要请选局域网访问或仅本机。

非本机监听（局域网访问或全部接口）时，安装器会自动建防火墙来源限制：
filter 表 `MIHOMO_PANEL` 链 + `INPUT` 跳转，只放行受管 LAN 网段与本机
回环访问 9090，其余来源一律 DROP；仅本机监听时不建该链（外部本就连不上）。
该限制与 TPROXY/DNS 规则走同一归属/清理机制，停服、卸载、回滚时随其他
自有规则一起清理。`verify.sh` 会核对面板监听地址与实际监听是否一致，
以及非本机绑定时来源限制是否存在。

仅本机模式下，安装结束页会显示 `http://127.0.0.1:9090/ui（仅本机可访问）`。

远程访问面板请走可信网络或安全隧道（如 SSH 端口转发），**不要直接向公网
开放 9090 端口**。本项目不提供一键公网暴露面板的功能。

## 多网卡配置

### 手动指定入口网卡

安装时第一问就是入口网卡：默认是自动探测的默认路由网卡，回车即用；
多网卡机器可手动输入网卡名（如 `eth1`），网卡不存在会当场重问。
确认页会标注该网卡是"自动检测"还是"手动指定"。

注意：默认路由网卡在旁路由单网卡场景下就是 LAN 口，但在多网卡场景下
默认路由网卡可能是 WAN 口。安装器会检查**所选入口网卡**的 IP（不论自动
探测还是手动指定）：若是公网地址，会警告并要求显式确认它确实是 LAN 口，
拒绝则回到手动指定；警告会明确提到面板 9090 的暴露风险（面板监听非本机
地址时也会暴露在该公网接口上，不只是 TPROXY 接管问题）。

### 多 LAN 网段

局域网 CIDR 支持多网段，输入时用逗号分隔，不用加空格：

```
192.168.1.0/24,192.168.2.0/24
```

多网段会写入 `/etc/mihomo/tproxy.env` 的 `LAN_SUBNETS`（逗号列表），
主网段仍写 `LAN_SUBNET`（供旧版 `tproxy.sh` 兼容读取）；单网段时 env
文件有 `LAN_IFACE`、`LAN_SUBNET`、`PANEL_LISTEN` 三行（面板监听模式，
供 `tproxy.sh` 决定是否建 `MIHOMO_PANEL` 来源限制链）。规则侧用正向分发子链实现
"任一网段命中即代理"，不在受管网段的流量不受影响；任一网段格式非法
则整体拒绝，不会只建一半规则。

VLAN、桥接网卡与常见虚拟网卡均按普通网卡对待（只做 `ip link` 存在性校验），
没有特殊处理逻辑；自动识别失败时手动指定网卡与网段即可。

### Docker 共存

检测到 `docker0` 时，确认页会提示 Docker 网段，并明确"TPROXY 规则仅作用于
指定入口网卡与网段，不会接管 Docker 网段"。规则本身已限定范围，不需要
自动排除 Docker 网段；容器流量走 `docker0`，不在受管入口上，不受影响。

## IPv6 说明

本项目只代理 IPv4 流量：配置模板 `ipv6: false`，TPROXY 与 DNS 劫持规则
均为 IPv4。IPv4 透明代理**不代表** IPv6 流量也受到保护——有公网 IPv6 的
客户端可能经 IPv6 直连，绕过代理策略。

安装器会检测系统是否启用 IPv6、LAN 口是否分配了全局 IPv6 地址，
并在确认页与安装结束页明确告知：

| 检测结果 | 安装器行为 |
|---|---|
| 系统未启用 IPv6 | 无需处理 |
| 系统启用 IPv6，但 LAN 口未分配 IPv6 地址 | 提示暂无绕过风险 |
| LAN 口已分配 IPv6 地址 | **明确警告"IPv6 流量不受代理保护、可绕过代理策略"**，并给出可选的 IPv6 阻断 |

### 可选的 IPv6 阻断

LAN 口有 IPv6 时，确认页会询问是否启用 IPv6 阻断（默认不启用，重装时沿用
旧选择）。启用后写入 `IPV6_BLOCK="1"` 到 `tproxy.env`，`tproxy.sh` 会在
filter 表建 `MIHOMO_V6` 链（挂 `FORWARD` 链），丢弃经本机转发的、来自
LAN 口全局 IPv6 前缀的流量。阻断需要 `ip6tables`：缺失时确认页直接说明
原因、不提供启用选项（提问门控），避免用户选完、装完才在服务启动时失败；
即使重装时旧配置曾启用阻断，缺 `ip6tables` 时同样失效。旧配置已启用阻断
但 `ip6tables` 事后被卸载时，服务拒绝以无阻断状态启动（失败关闭，不假装
阻断生效）。开机时 LAN 口地址晚到会先等最多 60 秒（`V6_WAIT_SECS` 可覆盖），
等满仍无全局前缀时只警告、不建规则（不是失败），地址出现后由自动维护
`check`（每 15 分钟）补建，或重启服务重建。补建走 `tproxy.sh repair-v6`，
只重建 `MIHOMO_V6` 链与 `FORWARD` 跳转，不清理、不重建 IPv4 的 TPROXY/DNS
规则；LAN 前缀变更（重编号）后旧 DROP 规则滞留时，`check` 也会检测到并重建。

必须说清楚的限制：

- 阻断只覆盖 `FORWARD` 链，只对**经本机转发**的流量生效；旁路由模式下
  客户端 IPv6 通常走主路由、不经过本机，阻断可能实际不生效。
  彻底防绕过需要在**主路由**上处理 IPv6（关闭 IPv6 或做相应策略），
  本项目不替主路由做决定。
- 本项目**绝不关闭系统 IPv6、不动默认路由**。阻断只是丢弃受管前缀的
  转发流量，本机自身的 IPv6 不受影响。

## DNS 说明

- **客户端 DNS**：UDP 与 TCP 的 53 端口请求都会被劫持（`REDIRECT` 到
  本机 1053），走 mihomo 的 fake-ip DNS（`fake-ip-range: 198.18.0.0/15`）；
  劫持范围与 TPROXY 规则一致（同一入口网卡与来源网段守卫），
  不在受管网段的设备 DNS 不受影响。
- **本机 DNS**：旁路由本机自己的 DNS 不走劫持（`OUTPUT` 链无规则），
  仍走本机 `systemd-resolved`。
- **上游 DNS**：模板默认 `nameserver` 为 `223.5.5.5` 与 `119.29.29.29`，
  `proxy-server-nameserver` 为 `https://1.1.1.1/dns-query`；需要换上游
  直接改 `/etc/mihomo/config.yaml` 的 `dns` 段，改完 `mihomo -t` 自检后重启。
- **DNS 泄漏验证**：在局域网客户端浏览器打开 `dnsleaktest.com` 或
  `browserleaks.com/dns` 做一次扩展测试，看到的 DNS 服务器应为代理出口的
  DNS，而非本地宽带运营商的 DNS；若看到运营商 DNS，说明 DNS 流量未走代理，
  请先跑 `sudo bash /etc/mihomo/verify.sh` 检查 DNS 劫持规则项与客户端
  DNS 设置。本项目不在脚本里内置外网测试站调用，避免依赖外部服务。

## 离线兜底与自动更新

这套方案要解决的失败模式只有一个：**安装那一刻的网络不可控**
（GitHub 直连不通、镜像失效、订阅拉不到），导致逻辑没问题的安装器在不同
网络环境下成败不一。处理分三层：

1. **官方优先**：内核、面板、GeoIP/GeoSite/MMDB 都先走官方源 +
   gh-proxy 等镜像链拉最新版本。仓库本体只克隆脚本与配置，很快。
2. **专用资产仓 Release 兜底**：官方链全部失败时，脚本自动改从
   专用资产仓库（`sg/mihomo-assets`，与代码仓库相互独立、
   资产只维护一处）的 Release 附件按需拉取资产（内核按当前
   架构只拉对应的那一个包；拉到后先逐个校验 sha256 才用），先把
   服务完整装起来。批次优先用专用资产仓库的**最新批次**（仓库由
   自动刷新脚本保持新鲜，始终躺着最新版，安装器先查询最新批次
   再拉取）；查询不到时退回脚本内钉版批次。
   钉版批次与专用资产仓库 Release 的对应关系：其 Release `v1.0.1` 附带
   mihomo 内核 v1.19.32、MetaCubeXD v1.273.1、geodata 为
   meta-rules-dat 2026-10-20 批次；清单、校验值与刷新发版步骤见
   [assets/README.md](assets/README.md)。兜底地址由 `install.sh` 的
   `FALLBACK_ASSETS_API` / `PROJECT_ASSETS_BASE` 定义，可用同名
   环境变量覆盖。
3. **跑通后自更新**：服务起来后本机已有代理，`auto-maintain.sh full`
   经本地代理（127.0.0.1:7890）把内核、面板 UI 与 geodata 更新到
   官方版本；新文件先在暂存区逐个校验（geodata 用官方 `.sha256sum`、
   内核做完整性与版本自检），再用待更新组合跑一遍 `mihomo -t`，
   全部通过才替换；替换后健康检查不过会自动回滚到上一份可用版本，
   坏更新永远不会覆盖正在用的好文件。

内核更新的校验说明：mihomo 官方 Release 不发布 checksum 文件
（已核查最新 Release，124 个资产中无任何 checksum/sig 文件），因此
自动维护改用**双源哈希一致**作为校验依据——按两条不同路线各下载一次
内核，两份 sha256 一致才采用；不一致则放弃本次内核更新（旧内核不动，
UI/geodata 更新照常继续）。第二源全部不可达时降级为 gzip 完整性 +
版本自检，并明确记 WARN 日志，不假装已校验。

订阅链接是用户自己的输入，不属于上面任何一层：安装时不填或填错
都不会让安装失败，装完会在汇总里明确标注订阅状态，后续可用
`/tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh` 设置/更换。

### 无人值守维护

`auto-maintain.sh` 支持三种模式，由 `/etc/cron.d/mihomo-maintain` 分层调度：

| 模式      | 频率        | 做什么                                                                 |
|-----------|-------------|------------------------------------------------------------------------|
| `check`   | 每 15 分钟  | 健康检查：服务/API 异常、或经代理探测连续失败才重启（带冷却）；IPv6 阻断链缺失但地址已在时补建 |
| `refresh` | 每天 03:00  | 通过 API 刷新机场订阅（刷新后日志记录当前节点数，节点数为 0 时记警告） |
| `full`    | 每周日 03:30 | 刷新订阅 + 经本地代理更新 GeoIP/GeoSite/MMDB、面板 UI 与 mihomo 内核（带校验与自动回滚）；更新后验证网络规则存在，缺失时记日志告警 |

手动触发某一种维护：

```bash
sudo bash /etc/mihomo/auto-maintain.sh full
```

只想看看有哪些更新、不实际替换也不重启（dry-run，输出直接打到终端）：

```bash
sudo bash /etc/mihomo/auto-maintain.sh full --dry-run
```

查看维护日志：

```bash
cat /var/log/mihomo-maintain.log
```

实时跟踪日志（先执行这条再触发维护，才能看到滚动输出）：

```bash
tail -f /var/log/mihomo-maintain.log
```

## 升级方式

升级 = 重新跑安装命令（见「安装步骤」），不要只 `git pull`
（原因见该节：系统里跑的是拷入 `/etc/mihomo` 的副本）。

重装时默认**保留现有配置**：检测到已有 `config.yaml` 时走迁移式合并，
只动三处——本次新输入的订阅链接、入口网段变化时的网段规则行、
缺失或占位符的面板密钥；自定义规则、DNS、代理组等一律不动。
同时还会把模板里新增的顶层配置键补进旧配置（旧配置已有的键不动，
旧配置多出的自定义键保留）。留空订阅 = 保留现有订阅，不会丢订阅。

确认页会明确提示"默认保留现有 config.yaml"；只有显式选择覆盖时，
才会先备份旧配置（`config.yaml.bak.<时间戳>`）再用模板重新生成，
且覆盖模式下若本次未输入订阅，仍沿用旧配置里的订阅地址，
不会渲染出空订阅。

配置文件更新全程用临时文件编辑 + 原子替换，更新失败不会破坏原有可运行版本。

## 配置备份

建议升级前备份 `/etc/mihomo`，整个目录拷走即可：

```bash
sudo tar -czf /tmp/mihomo-backup-$(date +%Y%m%d).tar.gz -C /etc mihomo
```

`/etc/mihomo` 里包含：`config.yaml`（订阅、规则、DNS、密钥）、
`tproxy.env`（入口网卡、网段、IPv6 阻断选择）、`maintain.env`
（面板密钥、架构、订阅状态）、面板 UI 与地数据库、运行脚本副本。

安装与重装时也会自动备份旧配置：`config.yaml.bak.<时间戳>` 就放在
`/etc/mihomo` 目录里；安装失败回滚时旧二进制保留在
`/usr/local/bin/mihomo.bak`（回滚失败时才会留下，成功时自动删除）。

## 配置恢复

### 卸载/停止后的一键恢复

`--keep-config` 卸载或 `--stop-only` 停止后，用 `restore.sh` 一键恢复：

```bash
sudo bash /tmp/mihomo-tproxy-gateway/scripts/restore.sh
```

恢复流程：前置检查（`config.yaml` 与 `tproxy.env` 完好）→ 服务已在跑则
直接返回 → 缺失/损坏的二进制重新下载（官方最新 → 镜像 → 专用资产仓
钉版兜底，gzip + `-v` 自检，兜底验 sha256）→ 重拷服务文件、脚本与 cron →
`mihomo -t` 校验 → 启动服务并 30 秒 API 轮询验证。配置原样保留，
不碰订阅、规则、DNS、密钥。若 `/etc/mihomo` 已不存在（彻底卸载过），
`restore.sh` 会明确拒绝，请改跑 `install.sh` 全新安装。

`--stop-only` 后也可以只启动服务而不恢复定时维护（不推荐，维护会缺失）：

```bash
sudo systemctl enable --now mihomo
```

### 从备份文件恢复

有 `tar` 备份时：停服务 → 解压覆盖 `/etc/mihomo` → 启动服务：

```bash
sudo systemctl stop mihomo
sudo tar -xzf /tmp/mihomo-backup-20261113.tar.gz -C /etc
sudo systemctl start mihomo
sudo bash /etc/mihomo/verify.sh
```

只有 `config.yaml.bak.<时间戳>` 时：停服务 → 拷回原名 → `mihomo -t` 自检 →
启动服务（备份文件在 `/etc/mihomo` 目录里，按实际时间戳替换文件名）。

## 卸载方式

卸载脚本分三种模式，执行前会打印删除清单（按模式列出将删除项与将保留项，
不存在的标注"跳过"），执行后明确报告结果；清理失败时完成文件清理后
退出 1 并明确报告残留，不假装成功。

| 模式 | 命令 | 删除 | 保留 | 之后怎么恢复 |
|---|---|---|---|---|
| 仅停止 | `uninstall.sh --stop-only` | cron 定时任务、网络规则 | 全部文件（配置、二进制、服务文件、日志） | `restore.sh`（恢复定时维护）或 `systemctl enable --now mihomo`（仅启动服务） |
| 保留配置卸载 | `uninstall.sh --keep-config` | 二进制、服务文件、cron、缓存与事务残留 | `/etc/mihomo`（配置、订阅、密钥、面板、地数据库） | `restore.sh` |
| 彻底卸载（默认） | `uninstall.sh` | 全部：`/etc/mihomo`、二进制、服务文件、cron、日志、缓存与事务残留 | 无 | 重新跑 `install.sh` 全新安装 |

```bash
# 彻底卸载（默认）
sudo bash /tmp/mihomo-tproxy-gateway/scripts/uninstall.sh

# 保留配置卸载，之后可一键恢复
sudo bash /tmp/mihomo-tproxy-gateway/scripts/uninstall.sh --keep-config

# 仅停止服务，保留全部文件
sudo bash /tmp/mihomo-tproxy-gateway/scripts/uninstall.sh --stop-only
```

说明：

- `--stop-only` 必须清 cron，否则 15 分钟内的健康检查会自动重启服务，
  "停止"会在 15 分钟内被悄悄撤销。
- 同时给出 `--keep-config` 与 `--stop-only` 时，以破坏最小的 `--stop-only` 为准。
- 彻底卸载与保留配置卸载还会清理二进制暂存（`mihomo.bak` / `mihomo.new` /
  `mihomo.restoring`）与失败安装的事务残留（`/tmp/mgb-*`）；`--stop-only` 不动它们。
- 卸载只清理本项目创建的防火墙规则、路由规则、systemd 服务、cron 与临时文件，
  不会删除其他程序的网络配置与用户无关文件。归属判定：自建 iptables 规则都带
  `-m comment --comment mihomo-tproxy-gateway` 标识，策略路由（fwmark 1 / 表 100）
  的归属记在 `/etc/mihomo/.tproxy-owned`；清理前逐条验归属，他人同名链或恰好
  用了 (1,100) 的规则一律保留。启动时若同名链或 (1,100) 已被他人占用，会明确
  报错拒绝覆盖，不会静默删掉对方的规则。
- 卸载脚本只清理安装到系统里的文件，不会删除 clone 下来的源码目录。
  如需连源码目录一起删除，手动执行：

```bash
sudo rm -rf /tmp/mihomo-tproxy-gateway
```

## 健康自检

安装时会自动把 `scripts/verify.sh` 拷入 `/etc/mihomo/verify.sh`，并在
API 就绪后自动运行一次完整自检：未通过时安装按失败处理（退出码非零、
不打印成功页），但服务保持运行、不回滚，见「安装」一节的事务说明。
它只做只读检查，不修改任何系统状态，随时可以手动再跑：

```bash
sudo bash /etc/mihomo/verify.sh
```

检查项（逐项输出 `[PASS]` / `[FAIL]` / `[SKIP]` 与排查指引）：

1. 服务运行状态（`systemctl is-active mihomo`）
2. API 就绪（配置的 `external-controller` 监听地址 + `:9090/version` 可达；
   LAN 模式只绑 LAN IP 时本机走 LAN IP，不再硬编码 `127.0.0.1`）
3. TPROXY 规则链存在、PREROUTING 跳转、策略路由（fwmark 1 / 表 100）、
   表 100 路由、TCP/UDP TPROXY 规则
4. 规则与 `tproxy.env` 一致性：链内入口守卫（单网段 `! -i` / `! -s`，
   多网段分发规则）必须与 env 里的网卡/网段相符
5. DNS 劫持链、跳转、UDP/TCP 53 重定向到 1053，以及 DNS 规则与
   `tproxy.env` 一致性（入口网卡守卫、单网段 `! -s` 守卫、多网段分发规则）
6. 订阅 provider 节点数（provider 存在性经 API 查
   `/providers/proxies`，节点数数订阅缓存文件
   `/etc/mihomo/providers/<provider>.yaml` 里的节点；缓存缺失或节点
   数为 0 即失败；API 未就绪时跳过而不误报）。安装调用时有一项明示
   宽限：全新安装首次拉取尚未完成、缓存文件未生成时，该项记为
   `[SKIP]` 并说明"首次订阅拉取尚未完成"，待拉取完成（通常数分钟内）
   后重跑本脚本复核；宽限只覆盖"缓存缺失"——缓存存在但节点数为 0
   （拉取已完成而订阅为空）仍报失败，独立运行本脚本时缓存缺失也仍
   报失败。之所以宽限而不是安装时等待拉取：首次拉取没有可靠的时间
   上界，固定等待要么白耗时间、要么到期仍误报。
7. 面板 9090 监听与来源限制：配置的 `external-controller` 监听地址须与
   `ss` 报告的实际监听一致；非本机绑定时，`MIHOMO_PANEL` 来源限制链
   与 `INPUT` 跳转、逐网段放行、末尾 DROP 必须存在（仅本机绑定时来源
   限制项跳过；9090 本身无监听时两项均跳过——上方 API 检查已报失败）。
8. IPv6 阻断链（仅 `IPV6_BLOCK=1` 时检查）

任一项失败退出 1，全部通过退出 0；失败时输出通用排查指引
（`systemctl status` / `journalctl` / 维护日志 / 重启重建规则）。
自检输出不打印订阅链接与面板密钥。DNS 泄漏验证方法见「DNS 说明」一节。

## 更换订阅链接

机场订阅过期、换机场，用专门的脚本操作，比手动改配置更安全——它会自动
备份（配置与旧 provider 缓存）、精确定位到订阅链接那一行（不会误伤
`health-check` 或测速地址里同名的 `url` 字段）、校验语法、重启并等 API
真正就绪、确认成功后再清旧缓存，重启失败或 API 未就绪时自动回滚旧配置
与旧缓存并重新验证：

```bash
sudo bash /tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh "新的订阅链接"
```

不带参数运行也可以，会交互式询问：

```bash
sudo bash /tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh
```

**如果只是订阅内容更新了、链接本身没变**（比如机场刷新了节点），不用换
链接，直接手动触发一次刷新就行：

```bash
sudo bash /etc/mihomo/auto-maintain.sh refresh
```

这也是 cron 每天自动做的事（见上面"无人值守维护"表格）。

<details>
<summary>手动改配置的方式（了解原理，或者 switch-sub.sh 用不了时的备用方案）</summary>

```bash
sudo nano /etc/mihomo/config.yaml
```

找到 `proxy-providers.airport1.url`，把值换成新的订阅链接，保存退出。

**关键一步，容易漏掉**：mihomo 会把上次拉取的节点列表缓存在本地文件里，
只改了 URL、不清缓存的话，短时间内看到的可能还是旧订阅的节点：

```bash
sudo rm -f /etc/mihomo/providers/airport1.yaml
```

语法自查：

```bash
mihomo -t -d /etc/mihomo
```

确认没问题后重启生效：

```bash
sudo systemctl restart mihomo
```

</details>

## 自定义分流规则

模板里的 `config.yaml` 只是一个能跑起来的最小配置：所有流量走同一个代理组。
如果你需要更细的分流（比如某些网站直连、某些单独走特定节点、屏蔽广告域名），
直接改 `/etc/mihomo/config.yaml` 就行，不需要碰任何脚本。

编辑配置文件：

```bash
sudo nano /etc/mihomo/config.yaml
```

改完之后，语法先自查一遍，避免写错缩进导致服务起不来：

```bash
mihomo -t -d /etc/mihomo
```

确认没问题后重启服务生效：

```bash
sudo systemctl restart mihomo
```

如果不想中断现有连接，也可以用 API 热重载（不重启进程），把
`<你的密钥>` 换成面板密钥：

```bash
curl -X PUT http://127.0.0.1:9090/configs \
  -H "Authorization: Bearer <你的密钥>" \
  -H "Content-Type: application/json" \
  -d '{"path": "/etc/mihomo/config.yaml"}'
```

**常见的几种自定义方向**（在 `rules:` 和 `proxy-groups:` 里加，具体字段
参考 [mihomo 官方文档](https://wiki.metacubex.one/)）：

- 按类别拆分代理组，比如流媒体、AI 服务单独选节点：
  ```yaml
  proxy-groups:
    - name: "🎬 流媒体"
      type: select
      proxies:
        - "🚀 节点选择"
  rules:
    - GEOSITE,netflix,🎬 流媒体
    - GEOSITE,youtube,🎬 流媒体
  ```
- 用 `rule-providers` 引入现成的分类规则集（比如广告拦截、AI 服务分组），
  比手写 `GEOSITE` 规则更省事，社区维护的规则集可以搜 "mihomo rule-providers"
  或 "ACL4SSR" 找现成的。
- 需要多个机场订阅做故障转移/分组，照抄 `config.example.yaml` 里
  `airport1` 那一段改个名字（比如 `airport2`），再把新 provider 名加进
  某个 `proxy-groups` 的 `use` 列表里即可。

## 常见故障

**面板打不开？**
先确认服务在跑：`systemctl status mihomo`。再确认地址与监听模式相符：
仅本机模式（默认）只能在本机用 `http://127.0.0.1:9090/ui` 访问，局域网
内其他设备打不开；局域网访问模式用 `http://<LAN 口 IP>:9090/ui`（安装结
束页会打印该地址）；全部接口模式用任一本机 IP 均可。密钥没记错的话查
`sudo grep '^secret:' /etc/mihomo/config.yaml`。局域网访问模式下手机打
不开时，先确认手机与旁路由在同一受管网段（防火墙来源限制只放行受管 LAN
网段），再跑 `sudo bash /etc/mihomo/verify.sh` 看面板两项检查是否通过。
要改监听模式直接重跑安装（重装默认保留配置）。

**装完之后设备没网、节点不通？**
多半是订阅问题。先看安装结尾的「订阅状态」，不对就用
`sudo bash /tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh "新链接"` 更换；
只是节点过期的话，手动刷新一次：
`sudo bash /etc/mihomo/auto-maintain.sh refresh`。
再跑一遍 `sudo bash /etc/mihomo/verify.sh`，看是哪一项失败。

**客户端打开网站报 ERR_PROXY_CONNECTION_FAILED？**
先看客户端系统代理有没有关干净：本项目是透明代理，客户端只改网关
和 DNS 就行，系统里不能留显式代理。实测有客户端残留旧代理设置
（例如 `127.0.0.1:10808`）时所有网站都打不开，关掉系统代理（Windows：
设置 → 网络和 Internet → 代理 → 关闭"使用代理服务器"；代理插件如
SwitchyOmega 也切回直连）即恢复。

**服务起不来？**
先自检配置：`mihomo -t -d /etc/mihomo`；再看日志最后 50 行：
`journalctl -u mihomo -n 50`。维护侧的记录在
`/var/log/mihomo-maintain.log`。如果 5 分钟内启动失败超过 5 次，
systemd 会停止自动重启（`StartLimit`），需人工修好后
`sudo systemctl reset-failed mihomo && sudo systemctl start mihomo`。
如果日志里是 tproxy.sh 报错"已被其他程序占用"或"链已存在且不属于本项目"，
说明另一程序恰好用了同名链或 fwmark 1 / 表 100：先停用对方再启动；若确认
是本项目旧版本残留，按报错里的手动清理命令清掉后再重试。

**服务停了，但客户端还是没网？**
正常情况下服务停止后 `ExecStopPost` 会清掉 TPROXY/DNS 规则，客户端流量
恢复直连。如果规则残留（例如手动改过服务文件），手动清一次：

```bash
sudo bash /etc/mihomo/tproxy.sh stop
```

**安装中途失败了怎么办？**
安装是事务性的：失败会自动回滚到安装前状态（旧版本与旧配置都在，
全新安装失败则恢复到未安装状态），并明确报告失败阶段与回滚结果。
修好失败原因后直接重新运行安装命令即可。安装日志在
`/var/log/mihomo-install.log`，可定位到具体失败阶段。

**预检不通过怎么办？**
预检失败时安装尚未修改系统，按终端给出的指引逐项修复后重跑安装。apt 系
机器上必需依赖缺失时安装器会在确认后自动安装（确认页有安装计划），只有
自动安装失败或系统连 `apt-get` 都没有时才需要手动安装（终端会给完整命令，
如 `sudo apt-get install -y wget curl`）；非 apt 系机器按终端给出的针对该
包管理器的完整命令手动安装。cron 缺失与 `ip6tables` 缺失只警告、不中止
安装：前者导致定时维护（15 分钟健康检查、订阅刷新、IPv6 阻断补建）不会
自动运行，请按警告安装并启动 cron；后者导致 IPv6 阻断功能不可选，请安装
iptables 包后再重跑安装。预检会一次性报告全部失败项，不用修一个重跑一次。

**安装/卸载时提示"另一个任务正在运行"？**
安装、卸载、换订阅、恢复、自动维护共用一把全局锁，等正在执行的任务完成
后再试。锁随进程退出自动释放，不存在 stale 锁，**不要手动删锁文件**。

**提示 fwmark 或路由表 100 被占用？**
说明已有其他透明代理程序在使用 fwmark 1 / 表 100。本项目拒绝启动且
不碰对方规则：请先停用或卸载对方程序（或改对方的 mark/表号），再重跑安装。
本项目的 mark/table 固定为 1/100，不提供改值选项（见「已知限制」）。

**IPv6 网站还是直连、没走代理？**
预期行为：本项目只代理 IPv4。LAN 口有 IPv6 时可重跑安装并启用 IPv6 阻断
（仅丢弃经本机转发的受管前缀流量），彻底防绕过需在主路由上处理 IPv6，
见「IPv6 说明」。

## 日志查看

| 日志 | 位置 | 内容 |
|---|---|---|
| 安装日志 | `/var/log/mihomo-install.log` | 安装/回滚全过程，含阶段前缀 |
| 维护日志 | `/var/log/mihomo-maintain.log` | 定时维护（check/refresh/full）的版本、时间与结果 |
| 服务日志 | `journalctl -u mihomo` | mihomo 自身输出与 tproxy.sh 输出（进 journal，自带时间戳） |

```bash
# 服务日志实时跟踪
journalctl -u mihomo -f

# 服务日志最后 50 行
journalctl -u mihomo -n 50

# 维护日志实时跟踪
tail -f /var/log/mihomo-maintain.log

# 安装日志（失败定位用）
cat /var/log/mihomo-install.log
```

操作日志统一格式：`[时间] [级别] [阶段] 消息`，级别为 INFO/WARN/ERROR，
安装日志的阶段是安装阶段（预检/下载/配置/…/回滚），维护日志的阶段是
运行模式（check/refresh/full）。订阅链接在终端与日志中只显示打码形式
（协议+主机+`****`），面板密钥只在安装成功页的终端显示一次、绝不进日志文件。
注意：`mihomo -t` 失败时终端可能看到含订阅链接的报错行（mihomo 自身行为，
脚本层未做脱敏过滤），转发终端截图/日志时请自行注意。

## 测试与 CI

### 桩测套件

仓库 `tests/` 目录是自动化测试套件：用带状态的桩命令（`ip` / `iptables` /
`systemctl` / `curl` / `wget` / `mihomo` / `ss` / `apt-get`）模拟系统行为，在真实文件路径上
验证安装、回滚、卸载、恢复、更新与规则管理。不是 grep 断言：
`systemctl` 桩在 start/restart 时真的执行 `/etc/mihomo/tproxy.sh`
（ExecStartPost 模拟），因此"tproxy 失败 → 服务启动失败 → 安装回滚"
这条链路是真实走通的。

```bash
# 从仓库根目录运行，需要 root（读写 /etc/mihomo 等真实路径）
sudo bash tests/run-tests.sh              # 全部（约 2 分钟，155 个测试、945 个断言）
sudo bash tests/run-tests.sh T6           # 只跑名字含 T6 的测试
sudo bash tests/run-tests.sh rollback     # 只跑名字含 rollback 的测试
```

覆盖范围：tproxy 校验与冲突拒绝、防火墙归属与清理安全、卸载三态、恢复、换订阅、全局锁、
安装/回滚、模板迁移、系统预检、多网卡/多网段、IPv6 阻断与独立修复、面板监听、
armv7 资产一致性、资产兜底回退、双源校验、systemd 停止清理、健康自检、订阅状态与脱敏、
日志格式、引号提取等，完整覆盖表见 [tests/README.md](tests/README.md)。

**不要在已安装 mihomo-tproxy-gateway 的生产网关上跑**：每个测试前后都会
重置系统状态，`reset_system` 会删除真实安装。只在测试机、虚拟机或容器里跑。

桩测覆盖不了数据面：真实流量转发、多网卡隔离、IPv6 阻断的实际效果、
各发行版真机安装，仍需在真实机器上验证，见「已知限制」。

### CI

`.github/workflows/ci.yml`（GitHub Actions，push 与 pull_request 触发），
每次提交自动执行 7 步检查：

1. ShellCheck（`-S warning` 零告警，全部仓库脚本 + 测试入口 + 桩）
2. Bash 语法检查（`bash -n`，同上文件清单）
3. 配置模板检查（合法 YAML、10 个必需键、secret 与订阅为占位符、
   tproxy-port 7893、dns.listen 0.0.0.0:1053）
4. 桩测全套件（`sudo bash tests/run-tests.sh`）
5. 架构资产一致性检查（install/restore 架构映射一致且含三架构；
   manifest 总量与 SHA256SUMS 一致；三档内核齐全）
6. 敏感信息扫描（私钥标记、常见令牌前缀、URL 内嵌凭证）
7. 项目文件一致性检查（安装/恢复脚本拷贝的文件存在且被引用）

CI 已在 GitHub 上真实跑通：v1.2.0 run 43394957808、v1.2.1 两 run
43435791038 与 43435786023（push + tag），7 步全部 success。

## 安全建议

- `external-controller` 默认只监听本机 `127.0.0.1:9090`；局域网访问绑定
  LAN 口真实 IP，全部接口 `0.0.0.0:9090` 仍可显式选择，但会同时绑定
  WAN/公网接口。非本机监听时安装器自动建防火墙来源限制（`MIHOMO_PANEL`
  链，只放行受管 LAN 网段与本机回环），仍请务必使用强随机 `secret`
  （安装器自动生成 32 位十六进制密钥），绝不要将 9090 端口映射到公网；
  需要远程访问时优先使用 VPN/SSH 隧道。HTTP 控制 API 不应被当作公网
  安全管理入口。
- 当前 TPROXY 与 DNS 劫持规则面向 IPv4，并挂载在 `PREROUTING`，但通过 `/etc/mihomo/tproxy.env` 限定入口网卡和来源 LAN CIDR。策略路由使用 `fwmark 1` / `table 100`，安装前会检测是否被其他程序占用，被占用时拒绝启动、不覆盖对方规则。规则优先级冲突（外部程序用无 fwmark 的高优先级规则抢在本项目之前）目前未做检测，见「已知限制」。
- 当前模板关闭 Mihomo IPv6（`ipv6: false`），这不等于客户端 IPv6 被自动阻断。若 LAN 客户端仍有 IPv6 上游路由，IPv6 流量可能绕过 IPv4 透明代理。请根据网络环境明确选择启用 IPv6 阻断、在主路由上处理 IPv6，或接受 IPv6 直连，见「IPv6 说明」。
- 自动维护的回滚包含 UI 目录及 `.ui-asset-sha` 记录；仍建议升级前备份 `/etc/mihomo`，并在非关键网关上先验证。
- 官方下载文件的 gzip/tar 完整性检查不能单独证明发布来源可信。部署在敏感网络前，应核对上游官方发布页提供的校验和/签名（如果有），并避免使用来源不明的镜像资产。自动维护的内核更新已用双源哈希一致作为校验依据（官方不发布 checksum 文件时），但第二源不可达时会降级为 gzip + 版本自检，见「离线兜底与自动更新」。
- 订阅链接与面板密钥是敏感信息：终端与日志中只显示打码的订阅链接，密钥只在安装成功页显示一次；`mihomo -t` 报错原文可能回显含订阅链接的配置行，转发日志时请自行脱敏。

## 已知限制

- 目前仅支持单个机场订阅（`airport1`），多机场分组需要手动改
  `config.yaml`（模板里有注释说明）。订阅刷新日志的节点数取自响应里
  第一个 provider，多 provider 时只反映第一个。
- `armv7` 架构的下载分支已适配但尚未实机测试；资产本体已上传到专用资产
  仓库 Release `v1.0.1`（清单与校验已核对），兜底路径的真机跑通仍待验证。
- IPv6 默认不代理；可选的 IPv6 阻断只覆盖 `FORWARD` 链，只对经本机转发的流量
  生效，旁路由模式下客户端 IPv6 通常走主路由，阻断可能实际不生效。
  彻底防绕过需在主路由上处理。
- **fwmark 1 / table 100 是真机验证的结果，不要改**：2026-10-21 真机实验
  证明，换成 0x1062/1062 后在 Ubuntu（iptables-nft）上出现"规则计数正常、
  包递不到 TPROXY socket、客户端全超时"，换回 1/100 立即恢复，机制至今未查明。
  因此本项目不提供 mark/表号的配置化改值选项；检测到冲突时拒绝启动并明示，
  而不是静默换值。任何改值方案都必须先经同机 A/B 真机验证。
- 规则优先级冲突检测未做：只检测了 fwmark 冲突与表 100 占用；外部程序若用
  一条无 fwmark 的高优先级规则（如 `from 192.168.1.0/24 lookup 200`）
  抢在本项目规则之前，安装器不会发现。检测它需要评估规则语义，暂无真实
  触发证据，记为已知限制。
- 模板合并只认顶层键：重装迁移时，模板若在已有键的块内新增子项
  （如 `dns` 下新增 nameserver），不会合并进旧配置；合并粒度是顶层键，
  块内新增需人工注意。
- `/etc/iproute2/rt_tables` 中若表 100 被命名，`ip rule show` 会打印名字而非
  `lookup 100`，fwmark 冲突检测可能把自有规则误判为外部规则而拒绝启动。
  默认无命名，实属罕见。
- 旧版已安装的 `auto-maintain.sh` 仍用旧锁路径：老用户不重装就还是旧锁文件，
  过渡期内新旧锁并存，安装与旧版维护可能撞车一次；重装/恢复后刷新为新锁，消除。
- CI 已在 GitHub 上真实跑通三次（v1.2.0 run 43394957808、v1.2.1 两 run
  43435791038 与 43435786023），7 步全部 success；本轮新增测试仍待下一次
  push 后由 CI 在 runner 上复核。
- 数据面尚未真机验证：桩测覆盖逻辑层，但真实流量转发（TCP/UDP/DNS 劫持）、
  多网卡隔离、多网段分发、IPv6 阻断实际效果、面板 9090 防火墙来源限制的
  真实包过滤效果、LAN IP 绑定后手机经 LAN IP 访问面板、手动指定网卡为公网 IP
  时暴露检测警告的真机表现、cron 在真实 Debian/Ubuntu/Armbian 上的默认存在性、
  Debian 12/13、Ubuntu 22.04/24.04、Armbian ARM64 真机安装，均待真实机器验证，沙箱结果
  不标记为已验证。

## ⚠️ 免责声明

- 本项目是一个通用的 **网络流量转发与规则路由工具**（基于开源项目
  [mihomo](https://github.com/MetaCubeX/mihomo)），可用于企业分流、家庭
  网络管理、开发测试等多种场景，工具本身不预设、不限定用途。
- 请在遵守您所在地法律法规的前提下使用本项目，由此产生的一切后果由使用者
  自行承担，与本项目作者无关。
- 作者提供本项目仅出于技术学习与交流目的，代码以"现状"提供，不作任何明示
  或暗示的担保，也不对使用本项目造成的任何直接或间接后果负责。
- 若您不认可以上条款，请勿下载、安装或使用本项目。
