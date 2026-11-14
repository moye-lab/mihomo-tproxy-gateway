# 桩测套件（tests/）

P0–P2 整改的自动化测试：用带状态的桩命令（`ip` / `iptables` /
`systemctl` / `curl` / `wget` / `mihomo` / `ss` / `apt-get`）模拟系统行为，在真实文件
路径上验证安装、回滚、卸载、恢复、更新与规则管理。不是 grep 断言：
`systemctl` 桩在 start/restart 时真的执行 `/etc/mihomo/tproxy.sh`
（ExecStartPost 模拟），在 stop/restart 时按单元文件内容执行
ExecStopPost，因此 "tproxy 失败 → 服务启动失败 → 安装回滚" 这条链路
是真实走通的。

## 怎么跑

```bash
# 从仓库根目录运行，需要 root（读写 /etc/mihomo 等真实路径）
sudo bash tests/run-tests.sh              # 全部（约 2 分钟）
sudo bash tests/run-tests.sh T6           # 只跑名字含 T6 的测试
sudo bash tests/run-tests.sh rollback     # 只跑名字含 rollback 的测试
```

每个测试前后都重置系统状态与桩状态；跑完恢复干净环境（删
`/etc/mihomo`、`/usr/local/bin/mihomo`、服务文件、cron 与测试日志）。

**不要在已安装 mihomo-tproxy-gateway 的生产网关上跑**：`reset_system`
会删除真实安装。只在测试机、虚拟机或容器里跑。

## 结构

| 路径 | 说明 |
|---|---|
| `run-tests.sh` | 总入口：断言辅助、状态重置、场景播种、全部测试、主循环 |
| `stubs/` | 桩命令：`ip`、`iptables`（`ip6tables` 为指向它的符号链接）、`systemctl`、`curl`、`wget`、`mihomo`、`ss`（面板监听模拟）、`apt-get`（依赖安装模拟）；状态目录由 `STUB_STATE` 指定 |
| `fixtures/` | 假 mihomo 新/旧二进制（可区分标记）、UI tarball、地数据库、假 os-release、差异内核包 |
| `outputs/` | 每次运行的各测试完整日志（运行时生成，不进版本库） |
| `state/` | 桩状态（运行时生成，不进版本库） |

## 覆盖了什么（171 个测试）

| 组 | 测试 | 覆盖要点 |
|---|---|---|
| T | T1–T14 | tproxy.sh：缺 env 失败关闭；CIDR 数值/前缀/前导零拒绝；正常建规则且守卫在前；历史重复清理与幂等；外部 fwmark/表 100 占用拒绝；stop 模式 |
| U | U1–U7 | uninstall.sh：stop-only 保文件；keep-config 保配置；彻底卸载清干净（含安装日志、二进制暂存与事务残留）；未安装时幂等；清历史重复规则 |
| R | R1–R7 | restore.sh：keep-config/stop-only 后一键恢复；无配置拒绝；已在跑直接返回；自检失败拒绝启动；单引号密钥恢复；掩码规则时警告 |
| S | S1–S7 | switch-sub.sh：正常换链（精确匹配，不误改 health-check，缓存备份+成功后清旧缓存）；自检失败回滚且无固定路径日志；重启失败回滚旧配置与缓存；API 未就绪报失败并回滚；回滚重启也失败时如实报错；拉取失败回滚；拉到 0 节点时等满超时再回滚 |
| A | A1–A2 | auto-maintain.sh 锁：被占时跳过并记日志；空闲时正常跑 |
| I | I1–I16 | install.sh：全新安装；重装保留配置/换网段/显式覆盖/换订阅；自检/TPROXY/API 失败回滚；全新安装失败回滚到未安装；非法输入当场拒绝；确认页取消零修改；安装后自动跑 verify.sh 且通过后才打印成功页；verify 失败时安装失败但服务保持运行、不回滚 |
| L | L1–L4 | 全局锁冲突：安装/卸载/换订阅/恢复被占时 exit 1 并明示，且零修改 |
| P5 | P5a–P5b | 模板新增键迁移：缺失键合并进旧配置且无重复键；无缺失键时不合并 |
| P6 | P6a–P6j | 系统预检：缺 wget 且无 apt-get 时失败并给完整手动命令；TPROXY 探测失败无残留；未知发行版警告继续；Alpine 拒绝；Armbian 支持；缺依赖时确认页展示计划并自动安装成功；自动安装失败给完整手动命令并中止；非 apt 系给针对该管理器的完整命令且不自动安装；缺 cron / cron 未运行时大声警告加成功页注明但安装继续 |
| P7 | P7a–P7i | 多网卡/多网段：分发子链；非法网段整体拒绝；去重；手动网卡；公网 IP 警告两分支；Docker 只提示；单网段规则逐字节一致（v1.1.0 布局 + comment 标识）；手动指定网卡有公网 IP 时警告并明确提 9090 暴露 |
| P8 | P8a–P8h | IPv6 阻断：建 MIHOMO_V6 链；无前缀时警告不建规则；stop 清理；安装启用/不启用两分支；地址晚到时等待后建链；等满超时警告且默认等 60 秒；缺 ip6tables 时阻断提问被门控禁止启用 |
| P9 | P9a–P9h | 面板监听：全新安装仅本机/默认仅本机；重装切换与沿用；局域网模式绑定真实 LAN IP 且经 LAN IP 可达、MIHOMO_PANEL 链内容逐条核对；全部接口时确认页与成功页均有 0.0.0.0 专属警告；仅本机模式经 LAN IP 不可达；公网来源访问 9090 被拦截（负向，桩模拟） |
| P10 | P10a–P10c | 资产清单与架构映射一致：manifest 总量与 SHA256SUMS 一致、含 armv7；三处映射一致；最新批次失败退回钉版后安装继续（P10b）；最新与钉版双败时安装中止、坏文件不落盘（P10c） |
| M11 | M11a–M11c、M11e–M11f | full 更新：双源一致升级；不一致放弃内核；第二源不可达降级；规则缺失只告警；掩码规则只告警 |
| M12 | M12a | 锁覆盖静态核查：五脚本同一锁路径 + `flock -n`；旧锁 0 引用；tproxy/verify 不拿锁 |
| M13 | M13a–M13d | systemd：停服务清规则；重启先清后建恰 1 条；旧版单元残留对照；StartLimit |
| V | V1–V21 | verify.sh：健康全通过；服务停/API 挂/规则缺失/env 不一致/节点为 0/缓存缺失均 exit 1 且点名；API 挂时订阅检查 SKIP；DNS 检查容忍真实 iptables 的 `-m udp`/`-m tcp` 输出；API 中途就绪时重试后通过；代理环境下 API 检查绕过代理；IPv6 项无地址时 SKIP、地址在链缺失时 FAIL；DNS 守卫错误/分发缺失或错网段时报 FAIL；安装模式下缓存缺失记 SKIP 并明说首次拉取未完成、缓存存在但节点数为 0 仍 FAIL；面板来源限制缺失时 FAIL 且监听项仍 PASS；配置监听与实际监听不一致时 FAIL；仅本机监听时来源限制 SKIP 且整体通过；仅掩码规则时 FAIL；plain 规则通过 |
| M15 | M15a–M15d | 订阅状态与脱敏：刷新日志含节点数；节点为 0 记警告；终端与日志不含完整订阅链接与密钥；组合校验失败时日志打码（订阅 token 与 secret 不进日志，只留打码形式） |
| M16 | M16a–M16c | 日志格式：安装/维护日志全部行符合统一格式；恢复/卸载/换订阅终端输出含 `[级别] [阶段]` |
| M17 | M17a–M17e | check 补建 IPv6 阻断链（v1.2.1，v1.2.2 起走 repair-v6）：地址在+链缺失时补建且不重启服务；链在/无地址/未启用阻断时不动；链在但跳转缺失时补建 |
| M18 | M18a–M18g | IPv6 独立修复（第二轮第 7 项）：repair-v6 只动 V6 链、IPv4 四链逐字节不变（含标记规则鉴别）；端到端超时→补建时间线；前缀变更检测与修复；无地址不等、未启用不动作、遇他人 V6 链拒绝 |
| W | W1–W12 | 防火墙归属与清理安全（第二轮第 1 项）：他人同名链/(1,100)/带掩码 fwmark 时 start 拒绝且 stop/卸载/回滚保留；旧版无 STOP_MODE 明确拒绝；自有规则全带 comment；旧版规则指纹认领；stale 归属记录三场景（stop/start/路由失败关闭） |
| Q | Q1–Q6 | P2：单引号/无引号密钥重装复用；单引号占位密钥替换；extract_secret 三种写法单元测试；单引号订阅覆盖沿用；临时文件与红线静态核查；ASSETS_DIR 默认与 restore 覆盖、wget 单行进度参数静态钉死 |
| C | C1–C6 | 发布流程检查脚本 check-release.sh：夹具全过；tag 被移动/manifest 与 SHA256SUMS 不一致/安装器钉版 tag 不一致/Release 指向错误 tag 或缺失时失败；--no-api 离线核对通过 |

静态检查（CI 与本地均跑）：`bash -n` 全过；ShellCheck `-S warning`
0 告警（仓库脚本 + `run-tests.sh` + `check-release.sh` + 全部桩）。

## 桩的边界（测试证明不了什么）

- **curl 桩不校验 `Authorization` 头**：API 就绪只看 `api-up` 状态。
  因此"密钥值正确"一级的证明在 Q4（直接调用 `extract_secret`）与
  落盘文件断言（`maintain.env` 内容）里做，不靠 API 成功来证明。
- **桩保真（2026-11-13 真机实测教训）**：`curl` 桩的
  `/providers/proxies` 响应按真 mihomo v1.19.34 的形状（三个
  provider、无 `count` 字段），`iptables` 桩的 `-S` 输出模拟真实
  归一化（带 `--dport` 的规则插入 `-m udp`/`-m tcp`）。两处都曾因
  桩与真实不一致漏过 bug，改桩时先对真机输出，别按想象写。
- **curl 桩的面板访问模拟不是真实包过滤**：桩按 config 的
  external-controller 模拟监听（只绑某地址时其他地址拒绝），并仅在
  `$STUB_STATE/curl-source-ip` 标记存在时按 MIHOMO_PANEL 链评估模拟
  来源（远端客户端模拟）；无标记时不模拟防火墙——本机进程连本机 IP
  只走 OUTPUT 链、不进 INPUT。它证明的是"安装产物编码了正确的拦截
  语义"，真实包过滤效果仍需真机验证（见 P9h 注释与待真机项）。
- **apt-get 桩不真实安装软件包**：只记录调用并把对应命令软链进
  `$STATE/bin-installed/`，供安装后复核；真实 apt 安装行为需真机。
- **ss 桩按 config 报告监听**：默认报告 config 的 external-controller
  地址（api-up=1 时），`ss-listen-override` 标记可注入不一致的监听；
  它不验证 mihomo 真实监听了哪个地址。
- **curl 桩的 Gitea 资产仓 API 返回固定 tag v1.0.2**：`resolve_fallback_tag`
  在桩下总能查到该 tag（除非 `gitea-api-fail` 标记存在）；它不验证真实
  Gitea API 的响应形状，tag 值本身只用于区分"最新批次"与钉版 v1.0.1。
- **wget 桩的兜底故障注入只模拟"下载失败"**：`wget-fail-official`（官方源
  全败）、`wget-fail-latest-batch`（最新批次下载失败）按 URL 模式拦截；
  真实网络的超时、半截文件、DNS 失败等形态不在模拟范围内。
- **钉版校验在桩测里用测试清单对齐**：夹具文件哈希与仓库真实 SHA256SUMS
  不符，P10b/P10c 用 `make_test_sums` 按夹具实时算哈希生成测试清单，
  经 `ASSETS_DIR` 环境变量指向它（install.sh 同名变量可覆盖）；生产
  默认仍按仓库真实清单校验，测试清单只在桩测里存在。
- **数据面无法验证**：桩测只验证规则文本与状态文件，不验证真实流量
  是否经 TPROXY、DNS 是否真的被劫持、IPv6 阻断是否真的丢包、面板
  9090 来源限制是否真的拦包。
- **真实发行版安装无法验证**：预检的各发行版分支只用假 os-release
  与桩命令覆盖，未在真实 Debian/Ubuntu/Armbian 上跑过。
- **真实下载路径无法验证**：wget/curl 桩只服务 fixture；真实
  GitHub/镜像/资产仓下载需真机。
- **armv7 二进制无法运行**：只校验清单一致性与文件格式，未在 armv7
  真机上跑过。

## 待真机项（沙箱证不了，不标记已验证）

见各阶段报告的待真机节（P0/P1/P1P2-REPORT.md），摘要：

1. 数据面：客户端经网关访问外网（TCP/UDP/DNS 劫持真实生效）；多网卡
   隔离；非受管网段不受影响。
2. 回滚/恢复后真实服务可用（真实订阅拉取与节点连通）。
3. ExecStopPost 真实行为；StartLimit 触发表现。
4. 双源校验真实路径（代理路线与直连/镜像路线哈希是否一致）。
5. verify.sh 在真实运行网关上的输出与各检查项解析。
6. Debian 12/13、Ubuntu 22.04/24.04/26.04、Armbian ARM64 真机安装；
   无法直接访问 GitHub 的环境；Docker 共存环境。
7. 专用资产仓兜底拉取真机跑通：断官方源的真机安装，amd64/arm64 均未完整
   跑通（x86 VM 曾走到 83% 被中断）；armv7 同样未测（资产已上传）。
8. 回滚 API 轮询 10 秒是否够用（真机冷启动可能更慢）。
9. 面板 9090 防火墙来源限制的真实包过滤效果（桩测只验证规则文本与
   模拟评估）；LAN IP 绑定后手机经 LAN IP 访问面板的真实可用性（含
   DHCP 换 IP 后面板失效的权衡）；手动指定网卡为公网 IP 时暴露检测
   警告的真机表现；cron 在真实 Debian/Ubuntu/Armbian 上的默认存在性。

## 如何加新测试

1. 在 `run-tests.sh` 里按组加 `t_<组><编号>_<英文名>()` 函数，首行
   `begin_test "<编号>_<中文名>"`。
2. 播种用现成辅助：`reset_system`（干净系统）、`seed_running_install`
   （运行中的旧安装）、`seed_stopped_install`、`seed_keep_config_uninstalled`、
   `seed_stop_only_state`；安装输入用 `run_install '<\n 分隔的回答>'`
   （顺序见 I 组注释：入口网卡 / 网段 / 订阅 / 面板监听 / 覆盖确认 / 确认安装）。
   缺命令场景用 `make_bindir_without <目录> <排除命令...>` 造受限 PATH
   （常用真实命令 + 除排除项外的全部桩），不要手写软链循环。
3. 断言用 `check` / `check_contains` / `check_not_contains` /
   `check_exit` / `check_eq`；规则计数用 `rule_count` /
   `route100_count` / `jump_count`。
4. 故障注入用 `$STATE/` 下的标记文件（见各桩头注释，如
   `mihomo-t-fail`、`api-fail`、`ip-rule-add-fail-once`）；用完删掉
   标记，避免污染后续测试（`reset_system` 会清 `$STATE`，但同一测试
   内多次调用时需注意）。
5. 在 `ALL_TESTS` 列表里加上新测试，并更新本文件的覆盖表。
6. 跑 `bash -n` 与 `shellcheck -S warning` 后再提交；测试函数经
   `ALL_TESTS` 间接调用，SC2317 是已知误报（文件头已有 disable 说明）。
