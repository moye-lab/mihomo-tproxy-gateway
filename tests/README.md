# 桩测套件（tests/）

P0–P2 整改的自动化测试：用带状态的桩命令（`ip` / `iptables` /
`systemctl` / `curl` / `wget` / `mihomo`）模拟系统行为，在真实文件
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
| `stubs/` | 桩命令：`ip`、`iptables`（`ip6tables` 为指向它的符号链接）、`systemctl`、`curl`、`wget`、`mihomo`；状态目录由 `STUB_STATE` 指定 |
| `fixtures/` | 假 mihomo 新/旧二进制（可区分标记）、UI tarball、地数据库、假 os-release、差异内核包 |
| `outputs/` | 每次运行的各测试完整日志（运行时生成，不进版本库） |
| `state/` | 桩状态（运行时生成，不进版本库） |

## 覆盖了什么（104 个测试）

| 组 | 测试 | 覆盖要点 |
|---|---|---|
| T | T1–T14 | tproxy.sh：缺 env 失败关闭；CIDR 数值/前缀/前导零拒绝；正常建规则且守卫在前；历史重复清理与幂等；外部 fwmark/表 100 占用拒绝；stop 模式 |
| U | U1–U7 | uninstall.sh：stop-only 保文件；keep-config 保配置；彻底卸载清干净（含安装日志、二进制暂存与事务残留）；未安装时幂等；清历史重复规则 |
| R | R1–R6 | restore.sh：keep-config/stop-only 后一键恢复；无配置拒绝；已在跑直接返回；自检失败拒绝启动；单引号密钥恢复 |
| S | S1–S2 | switch-sub.sh：正常换链（精确匹配，不误改 health-check）；自检失败回滚且无固定路径日志 |
| A | A1–A2 | auto-maintain.sh 锁：被占时跳过并记日志；空闲时正常跑 |
| I | I1–I14 | install.sh：全新安装；重装保留配置/换网段/显式覆盖/换订阅；自检/TPROXY/API 失败回滚；全新安装失败回滚到未安装；非法输入当场拒绝；确认页取消零修改 |
| L | L1–L4 | 全局锁冲突：安装/卸载/换订阅/恢复被占时 exit 1 并明示，且零修改 |
| P5 | P5a–P5b | 模板新增键迁移：缺失键合并进旧配置且无重复键；无缺失键时不合并 |
| P6 | P6a–P6e | 系统预检：缺依赖拒绝+指引；TPROXY 探测失败无残留；未知发行版警告继续；Alpine 拒绝；Armbian 支持 |
| P7 | P7a–P7h | 多网卡/多网段：分发子链；非法网段整体拒绝；去重；手动网卡；公网 IP 警告两分支；Docker 只提示；单网段与 v1.1.0 逐字节一致 |
| P8 | P8a–P8e | IPv6 阻断：建 MIHOMO_V6 链；无前缀时警告不建规则；stop 清理；安装启用/不启用两分支 |
| P9 | P9a–P9d | 面板监听：全新安装仅本机/默认 LAN；重装切换与沿用 |
| P10 | P10a | 资产清单与架构映射一致：manifest 总量与 SHA256SUMS 一致、含 armv7；三处映射一致 |
| M11 | M11a–M11c、M11e | full 更新：双源一致升级；不一致放弃内核；第二源不可达降级；规则缺失只告警 |
| M12 | M12a | 锁覆盖静态核查：五脚本同一锁路径 + `flock -n`；旧锁 0 引用；tproxy/verify 不拿锁 |
| M13 | M13a–M13d | systemd：停服务清规则；重启先清后建恰 1 条；旧版单元残留对照；StartLimit |
| V | V1–V9 | verify.sh：健康全通过；服务停/API 挂/规则缺失/env 不一致/节点为 0/缓存缺失均 exit 1 且点名；API 挂时订阅检查 SKIP；DNS 检查容忍真实 iptables 的 `-m udp`/`-m tcp` 输出；API 中途就绪时重试后通过 |
| M15 | M15a–M15c | 订阅状态与脱敏：刷新日志含节点数；节点为 0 记警告；终端与日志不含完整订阅链接与密钥 |
| M16 | M16a–M16c | 日志格式：安装/维护日志全部行符合统一格式；恢复/卸载/换订阅终端输出含 `[级别] [阶段]` |
| Q | Q1–Q6 | P2：单引号/无引号密钥重装复用；单引号占位密钥替换；extract_secret 三种写法单元测试；单引号订阅覆盖沿用；临时文件与红线静态核查 |

静态检查（CI 与本地均跑）：`bash -n` 全过；ShellCheck `-S warning`
0 告警（仓库脚本 + `run-tests.sh` + 全部桩）。

## 桩的边界（测试证明不了什么）

- **curl 桩不校验 `Authorization` 头**：API 就绪只看 `api-up` 状态。
  因此"密钥值正确"一级的证明在 Q4（直接调用 `extract_secret`）与
  落盘文件断言（`maintain.env` 内容）里做，不靠 API 成功来证明。
- **桩保真（2026-11-13 真机实测教训）**：`curl` 桩的
  `/providers/proxies` 响应按真 mihomo v1.19.34 的形状（三个
  provider、无 `count` 字段），`iptables` 桩的 `-S` 输出模拟真实
  归一化（带 `--dport` 的规则插入 `-m udp`/`-m tcp`）。两处都曾因
  桩与真实不一致漏过 bug，改桩时先对真机输出，别按想象写。
- **数据面无法验证**：桩测只验证规则文本与状态文件，不验证真实流量
  是否经 TPROXY、DNS 是否真的被劫持、IPv6 阻断是否真的丢包。
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
7. armv7 真机兜底拉取（资产上传后）。
8. 回滚 API 轮询 10 秒是否够用（真机冷启动可能更慢）。

## 如何加新测试

1. 在 `run-tests.sh` 里按组加 `t_<组><编号>_<英文名>()` 函数，首行
   `begin_test "<编号>_<中文名>"`。
2. 播种用现成辅助：`reset_system`（干净系统）、`seed_running_install`
   （运行中的旧安装）、`seed_stopped_install`、`seed_keep_config_uninstalled`、
   `seed_stop_only_state`；安装输入用 `run_install '<\n 分隔的回答>'`
   （顺序见 I 组注释：入口网卡 / 网段 / 订阅 / 面板监听 / 覆盖确认 / 确认安装）。
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
