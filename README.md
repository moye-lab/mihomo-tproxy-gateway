# mihomo-tproxy-gateway

通用 Linux mihomo TPROXY 旁路由透明代理与无人值守维护方案。

面向"喜欢用通用 Linux 发行版（Debian / Ubuntu / Armbian 等）做旁路由网关，
不想被 OpenWrt 生态绑定"的用户 —— OpenWrt 上的 mihomo/clash 方案高度依赖
`dnsmasq`、`netifd` 等 OpenWrt 专属组件，换到普通 Linux 发行版上并不适用，
这也是本项目存在的原因：把安装、TPROXY 规则、DNS 劫持、无人值守维护这一整套
在通用 Linux 上重新实现一遍。

安装时的拉取策略是**官方优先、专用资产仓 Release 兜底**：仓库本体只放
脚本与配置，克隆很轻量；安装时先从官方源（含镜像链）拉取最新版本，
全部失败则由脚本自动从**专用资产仓库的 Release 附件**按需拉取钉版资产
（逐个做 sha256 校验），先保证服务能装起来；服务跑通后，本机已有
代理，自动维护脚本会经本地代理把各组件滚动更新到官方版本。详见下方
「离线兜底与自动更新」一节。

## 工作原理：本机不受影响

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

## ⚠️ 免责声明

- 本项目是一个通用的 **网络流量转发与规则路由工具**（基于开源项目
  [mihomo](https://github.com/MetaCubeX/mihomo)），可用于企业分流、家庭
  网络管理、开发测试等多种场景，工具本身不预设、不限定用途。
- 请在遵守您所在地法律法规的前提下使用本项目，由此产生的一切后果由使用者
  自行承担，与本项目作者无关。
- 作者提供本项目仅出于技术学习与交流目的，代码以"现状"提供，不作任何明示
  或暗示的担保，也不对使用本项目造成的任何直接或间接后果负责。
- 若您不认可以上条款，请勿下载、安装或使用本项目。

## 安装

```bash
git clone https://github.com/moye-lab/mihomo-tproxy-gateway.git /tmp/mihomo-tproxy-gateway && sudo bash /tmp/mihomo-tproxy-gateway/scripts/install.sh
```

更新到最新版：重新执行上面的安装命令即可（目录已存在时先删掉旧目录再克隆）。**不要只 `git pull`**：新版可能新增必需配置，只拉代码不重跑安装，服务会在下次重启后起不来。

如果连 GitHub 都打不开、克隆不下来，用备用地址（同一份代码，托管在作者的备用站）：

```bash
git clone https://git.edge97.dpdns.org/sg/mihomo-tproxy-gateway.git /tmp/mihomo-tproxy-gateway && sudo bash /tmp/mihomo-tproxy-gateway/scripts/install.sh
```

安装过程中需要交互式输入两项：

1. 局域网 CIDR 网段（回车使用自动探测到的默认值即可）
2. 机场订阅链接

脚本会自动完成：识别 CPU 架构 → 获取 mihomo 内核、metacubexd 面板与
GeoIP/GeoSite/MMDB 数据库 → 渲染配置文件 → 生成随机面板密钥 →
启动前配置自检（`mihomo -t`）→ 安装 systemd 服务与 cron 定时任务 →
轮询 API 确认服务真正就绪。

安装结束时会打印一份**产物获取汇总**（每个文件是走官方网络下载还是
专用资产仓库兜底、用了哪个源）和订阅状态。安装完成后会打印面板地址和
密钥，**请自行保存这个密钥**，它同时也写入了 `/etc/mihomo/config.yaml`
和 `/etc/mihomo/maintain.env`。

支持的环境：带 systemd 的通用 Linux 发行版（Debian / Ubuntu / Armbian
等），root 权限；CPU 架构 amd64 / arm64（专用资产仓兜底仅覆盖这两个
架构；armv7 只能走网络源，官方源不可用时会明确报错）。

透明代理规则只处理 IPv4 流量；IPv6 不在本项目的处理范围内。安装时会记录默认路由网卡和所选 LAN CIDR，TPROXY 与 DNS 劫持只匹配该网卡上的该来源网段；多网卡/多 LAN 环境请在部署后检查并按需编辑 `/etc/mihomo/tproxy.env`。

重复运行 `install.sh` 是安全的：已有的 `config.yaml` 会先备份
（`config.yaml.bak.<时间戳>`）再覆盖；服务如果已经在跑，会用
`systemctl restart` 保证新配置生效，不会出现"改了配置但没生效"的情况。

## 卸载

标准卸载（清空配置、二进制、日志和下载缓存）：

```bash
sudo bash /tmp/mihomo-tproxy-gateway/scripts/uninstall.sh
```

只下线服务，保留配置和密钥，之后可以直接恢复：

```bash
sudo bash /tmp/mihomo-tproxy-gateway/scripts/uninstall.sh --keep-config
```

卸载脚本只清理安装到系统里的文件，不会删除 clone 下来的源码目录。
如需连源码目录一起删除，手动执行：

```bash
sudo rm -rf /tmp/mihomo-tproxy-gateway
```

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
   钉版批次与专用资产仓库 Release 的对应关系：其 Release `v1.0.0` 附带
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

订阅链接是用户自己的输入，不属于上面任何一层：安装时不填或填错
都不会让安装失败，装完会在汇总里明确标注订阅状态，后续可用
`/tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh` 设置/更换。

## 无人值守维护

`auto-maintain.sh` 支持三种模式，由 `/etc/cron.d/mihomo-maintain` 分层调度：

| 模式      | 频率        | 做什么                                                                 |
|-----------|-------------|------------------------------------------------------------------------|
| `check`   | 每 15 分钟  | 健康检查：服务/API 异常、或经代理探测连续失败才重启（带冷却） |
| `refresh` | 每天一次    | 通过 API 刷新机场订阅                                                   |
| `full`    | 每周一次    | 刷新订阅 + 经本地代理更新 GeoIP/GeoSite/MMDB、面板 UI 与 mihomo 内核（带校验与自动回滚） |

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

## 面板

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

## 更换订阅链接

机场订阅过期、换机场，用专门的脚本操作，比手动改配置更安全——它会自动
备份、精确定位到订阅链接那一行（不会误伤 `health-check` 或测速地址里同
名的 `url` 字段）、校验语法、清缓存、重启，任何一步失败都会自动回滚：

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

## 已知限制

- 目前仅支持单个机场订阅（`airport1`），多机场分组需要手动改
  `config.yaml`（模板里有注释说明）。
- 仅在 x86_64 / arm64 架构上验证过，`armv7` 架构的下载分支已适配但尚未
  实机测试；且专用资产仓兜底资产不含 armv7，armv7 设备在官方源不可用时
  无法离线安装。
- IPv6 默认关闭，如果局域网设备有全局 IPv6 直连能力，需要自行评估是否会
  绕过代理。

## 常见问题

**面板打不开？**
先确认服务在跑：`systemctl status mihomo`。再确认地址是
`http://<本机IP>:9090/ui`、密钥没记错（查密钥：
`sudo grep '^secret:' /etc/mihomo/config.yaml`）。

**装完之后设备没网、节点不通？**
多半是订阅问题。先看安装结尾的「订阅状态」，不对就用
`sudo bash /tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh "新链接"` 更换；
只是节点过期的话，手动刷新一次：
`sudo bash /etc/mihomo/auto-maintain.sh refresh`。

**服务起不来？**
先自检配置：`mihomo -t -d /etc/mihomo`；再看日志最后 50 行：
`journalctl -u mihomo -n 50`。维护侧的记录在
`/var/log/mihomo-maintain.log`。

**安装中途失败了怎么办？**
直接重新运行安装命令即可：已有的 `config.yaml` 会先备份再覆盖，
不会把原来的可用配置弄丢。安装日志的「产物获取汇总」会标明每个
文件走的是官方下载还是资产仓兜底。

## 安全与部署注意事项

- `external-controller` 默认监听 `0.0.0.0:9090`，这是为了兼容局域网内直接访问面板的部署方式。请务必使用强随机 `secret`，并在主机/上游防火墙中限制 9090 的可访问来源，绝不要将该端口映射到公网；需要远程访问时优先使用 VPN/SSH 隧道。HTTP 控制 API 不应被当作公网安全管理入口。
- 当前 TPROXY 与 DNS 劫持规则面向 IPv4，并挂载在 `PREROUTING`，但通过 `/etc/mihomo/tproxy.env` 限定入口网卡和来源 LAN CIDR。多网卡、Docker、多个 LAN 或复杂防火墙环境仍应先检查规则作用范围；本项目当前只自动配置一个入口网卡/网段。策略路由使用 `fwmark 1` / `table 100`，仍建议确认没有其他程序占用。
- 当前模板关闭 Mihomo IPv6（`ipv6: false`），这不等于客户端 IPv6 被自动阻断。若 LAN 客户端仍有 IPv6 上游路由，IPv6 流量可能绕过 IPv4 透明代理。请根据网络环境明确选择支持 IPv6 透明代理、在 LAN 禁用 IPv6，或接受 IPv6 直连。
- 自动维护的回滚包含 UI 目录及 `.ui-asset-sha` 记录；仍建议升级前备份 `/etc/mihomo`，并在非关键网关上先验证。
- 官方下载文件的 gzip/tar 完整性检查不能单独证明发布来源可信。部署在敏感网络前，应核对上游官方发布页提供的校验和/签名（如果有），并避免使用来源不明的镜像资产。
