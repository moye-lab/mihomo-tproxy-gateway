#!/bin/bash
# Mihomo 旁路由健康自检：只读检查，不修改任何系统状态。
#
# 用法:
#   sudo bash /etc/mihomo/verify.sh
#   sudo bash /path/to/mihomo-tproxy-gateway/scripts/verify.sh
#
# 检查项：服务运行状态、API 就绪（重试约 30 秒）、TPROXY 规则存在且
# 与 tproxy.env 一致、DNS 劫持规则存在且与 tproxy.env 一致、订阅 provider 有节点（存在性
# 经 API 查，节点数数订阅缓存文件）、IPv6 阻断规则（仅启用时）、面板 9090
# 监听地址与实际监听一致、面板 9090 来源限制（仅非本机绑定时）。逐项
# 输出 [PASS]/[FAIL]/[SKIP] 清单与排查指引；任一项失败退出 1，全部
# 通过退出 0。
#
# 安装场景宽限：install.sh 在 API 就绪后会自动调用本脚本
# （VERIFY_INSTALL_MODE=1）。全新安装时 mihomo 首次拉取订阅可能尚未
# 完成，缓存文件不存在是"还没拉完"而非"网关坏了"，安装调用时这一项
# 降为 SKIP 并明说原因；独立运行本脚本时仍严格 FAIL。宽限只覆盖
# "缓存文件缺失"这一项：provider 未在 API 出现、缓存存在但节点数为
# 0 仍 FAIL（见第 5 节注释）。
#
# DNS 泄漏验证（本脚本不内置外网测试站调用，避免依赖外部服务）：
#   在局域网客户端浏览器打开 dnsleaktest.com 或 browserleaks.com/dns
#   做一次扩展测试：看到的 DNS 服务器应为代理出口的 DNS，而非本地
#   宽带运营商的 DNS；若看到运营商 DNS，说明 DNS 流量未走代理，
#   请检查 DNS 劫持规则（本脚本的 DNS 检查项）与客户端 DNS 设置。
#
# 脱敏：本脚本只输出检查结论与排查指引，不打印订阅链接与面板密钥。

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行此脚本（需读取 /etc/mihomo 下的运行配置）。"
    exit 1
fi

ENV_FILE="/etc/mihomo/tproxy.env"
MAINTAIN_ENV="/etc/mihomo/maintain.env"
CONFIG_FILE="/etc/mihomo/config.yaml"

# 订阅缓存目录：mihomo 把拉到的订阅落盘到
# <PROVIDERS_DIR>/<provider>.yaml，节点数就数这里（见第 5 节注释）。
# 环境变量覆盖只供测试用。
PROVIDERS_DIR="${PROVIDERS_DIR:-/etc/mihomo/providers}"
# 安装场景宽限开关：只供 install.sh 调用时设置 VERIFY_INSTALL_MODE=1
# （见文件头注释与第 5 节）。为什么选"安装场景宽限"而不是"调用前等
# 首次拉取"：首次拉取没有可靠的时间上界（慢速/不稳定网络下可能要几
# 分钟），任何固定等待要么白耗安装时间、要么到期仍误报安装失败；而
# 安装时自检的职责是证明网关功能（服务/API/规则/路由/DNS 范围），
# 订阅拉取是后台可重试的事，auto-maintain 刷新与独立跑 verify.sh
# 都会继续盯它。宽限只覆盖"缓存文件缺失"这一项，且以 SKIP 明示原因，
# 不是把失败藏起来。
VERIFY_INSTALL_MODE="${VERIFY_INSTALL_MODE:-0}"
# API 就绪重试：真机实测重启后 mihomo 启动（含拉订阅）可超过 10 秒
# （2026-11-13 Armbian ARM64），默认 15 次 × 2 秒 ≈ 30 秒，与
# install.sh 的就绪轮询同量级；环境变量覆盖只供测试用。
VERIFY_API_TRIES="${VERIFY_API_TRIES:-15}"
VERIFY_API_INTERVAL="${VERIFY_API_INTERVAL:-2}"
case "$VERIFY_API_TRIES" in ''|*[!0-9]*) VERIFY_API_TRIES=15 ;; esac
case "$VERIFY_API_INTERVAL" in ''|*[!0-9]*) VERIFY_API_INTERVAL=2 ;; esac

# 从 config.yaml 取面板 API 的本机访问地址：读 external-controller 的
# 监听地址；0.0.0.0 监听全部接口时本机走 127.0.0.1；无配置行或解析
# 失败时默认 127.0.0.1（mihomo 未写 external-controller 时的默认监听）。
# LAN 模式只绑 LAN IP 时 127.0.0.1:9090 根本不监听，本机 API 必须走监
# 听地址本身，硬编码 127.0.0.1 会误报 API 未就绪（第二轮第 2 项）。
# 与 install.sh / switch-sub.sh / restore.sh 的 panel_api_host 同一条规则。
panel_api_host() { # panel_api_host <config.yaml>
    local _listen=""
    _listen=$(grep -E '^external-controller:' "$1" 2>/dev/null | head -1 | sed -E 's/^external-controller:[[:space:]]*([^:]+):.*/\1/' || true)
    case "$_listen" in
        ""|"0.0.0.0") printf '127.0.0.1' ;;
        *) printf '%s' "$_listen" ;;
    esac
}

# API 地址、鉴权 secret、订阅 provider 名：secret 与 provider 优先读
# maintain.env，secret 缺失时退回 config.yaml 提取（与 restore.sh 同一
# 条提取规则）；API 地址以 config.yaml 的 external-controller 为准（运
# 行时真相：用户手改监听后 maintain.env 可能过期，配置才是 mihomo 实
# 际监听的地址）。
API="http://127.0.0.1:9090"
API_SECRET=""
PROVIDERS="airport1"
if [ -f "$MAINTAIN_ENV" ]; then
    # shellcheck disable=SC1090
    source "$MAINTAIN_ENV"
fi
if [ -f "$CONFIG_FILE" ]; then
    API="http://$(panel_api_host "$CONFIG_FILE"):9090"
fi
# 从 config.yaml 提取面板 secret：双引号、单引号、无引号三种写法都认，
# 只取引号内的值（与 install.sh / restore.sh 的 extract_secret 同一条规则）。
# sed 脚本里的 '"'"' 是 shell 单引号字符串内嵌单引号的标准写法。
extract_secret() { # extract_secret <config.yaml>
    grep -E '^secret:' "$1" 2>/dev/null | head -1 \
        | sed -E 's/^secret:[[:space:]]*"([^"]*)".*/\1/; s/^secret:[[:space:]]*'"'"'([^'"'"']*)'"'"'.*/\1/; s/^secret:[[:space:]]*([^"[:space:]]+).*/\1/' || true
}

if [ -z "${API_SECRET:-}" ] && [ -f "$CONFIG_FILE" ]; then
    API_SECRET=$(extract_secret "$CONFIG_FILE")
    [ "$API_SECRET" = "CHANGE_ME_SECRET" ] && API_SECRET=""
fi
AUTH_HEADER=()
[ -n "$API_SECRET" ] && AUTH_HEADER=(-H "Authorization: Bearer $API_SECRET")

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
API_OK=0

check_pass() { # check_pass <检查名> <详情>
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "[PASS] $1：$2"
}
check_fail() { # check_fail <检查名> <问题> <排查指引>
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[FAIL] $1：$2"
    echo "       排查：$3"
}
check_skip() { # check_skip <检查名> <原因>
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo "[SKIP] $1：$2"
}

echo "Mihomo 旁路由健康自检"
echo "=========================================="

# --- 1. 服务运行状态 ---
if systemctl is-active --quiet mihomo 2>/dev/null; then
    check_pass "服务运行中" "systemctl is-active mihomo 为 active"
else
    check_fail "服务运行中" "mihomo 服务未运行" \
        "systemctl status mihomo 查看状态；journalctl -u mihomo -n 50 看最近日志；确认无误后 systemctl start mihomo"
fi

# --- 2. API 就绪（带重试：mihomo 启动含拉订阅，冷启动可能超过 10 秒）---
_api_tries=0
while [ "$_api_tries" -lt "$VERIFY_API_TRIES" ]; do
    # --noproxy：本机 API 不走代理——curl 默认连 127.0.0.1 也发给 https_proxy，
    # 代理到不了本机端口（2026-11-13 真机实测：回滚轮询因此 30 秒全败误报）。
    if curl --noproxy '*' -s -m 5 "${AUTH_HEADER[@]}" "$API/version" >/dev/null 2>&1; then
        API_OK=1
        break
    fi
    _api_tries=$((_api_tries + 1))
    [ "$_api_tries" -lt "$VERIFY_API_TRIES" ] && sleep "$VERIFY_API_INTERVAL"
done
if [ "$API_OK" -eq 1 ]; then
    check_pass "API 就绪" "$API/version 可达"
else
    check_fail "API 就绪" "$API/version 在约 30 秒内不可达" \
        "服务可能还在启动中（订阅拉取慢时会更久，稍等再跑一次），或面板端口/密钥有问题；看 journalctl -u mihomo -n 50"
fi

# --- 3. TPROXY 规则（存在性 + 与 tproxy.env 一致性）---
TPROXY_CHAIN="MIHOMO"
if iptables -t mangle -n -L MIHOMO_DO >/dev/null 2>&1; then
    # 多网段安装：实际代理规则在分发子链 MIHOMO_DO 里
    TPROXY_CHAIN="MIHOMO_DO"
fi
if iptables -t mangle -n -L MIHOMO >/dev/null 2>&1; then
    check_pass "TPROXY 规则链存在" "mangle 表 MIHOMO 链存在"
else
    check_fail "TPROXY 规则链存在" "mangle 表 MIHOMO 链缺失" \
        "服务启动时 ExecStartPost 应自动建规则；先确认服务在跑，再看 systemctl status mihomo 是否有 tproxy.sh 报错"
fi
if iptables -t mangle -S PREROUTING 2>/dev/null | grep -qE -- '-j MIHOMO$'; then
    check_pass "TPROXY 跳转存在" "mangle PREROUTING 已跳转到 MIHOMO"
else
    check_fail "TPROXY 跳转存在" "mangle PREROUTING 未跳转到 MIHOMO" \
        "同上：检查 tproxy.sh 启动日志；也可手动跑 bash /etc/mihomo/tproxy.sh 看报错"
fi
# 只认精确形态：带掩码的规则（如 0x1/0x1）永远不是我们的（真机 ⑩），
# 宽模式会把他人掩码规则误当自有规则、掩盖真实缺失。
if ip rule show 2>/dev/null | grep -qE 'fwmark 0x1 lookup 100$'; then
    check_pass "策略路由存在" "fwmark 1 / 表 100 策略路由存在"
else
    check_fail "策略路由存在" "fwmark 1 / 表 100 策略路由缺失" \
        "检查 tproxy.sh 启动日志；确认无其他程序占用 fwmark 1（ip rule show）"
fi
if ip route show table 100 2>/dev/null | grep -q '^local default dev lo'; then
    check_pass "表 100 本地路由存在" "表 100 内 local default 路由存在"
else
    check_fail "表 100 本地路由存在" "表 100 内 local default 路由缺失" \
        "检查 tproxy.sh 启动日志；确认路由表 100 未被其他程序占用（ip route show table 100）"
fi
# TPROXY 规则带 -m comment 标识（第二轮第 1 项加的），真实 iptables 输出
# 里 -p tcp 与 -j TPROXY 之间隔着 "-m comment --comment ..."，
# 故用 ERE 的.*容忍中间的 -m 选项（真机实测：-p tcp -m comment ... -j TPROXY）。
if iptables -t mangle -S "$TPROXY_CHAIN" 2>/dev/null | grep -qE -- '-p tcp.*-j TPROXY --on-port 7893' \
    && iptables -t mangle -S "$TPROXY_CHAIN" 2>/dev/null | grep -qE -- '-p udp.*-j TPROXY --on-port 7893'; then
    check_pass "TPROXY 转发规则存在" "$TPROXY_CHAIN 链内含 TCP/UDP TPROXY 规则（端口 7893）"
else
    check_fail "TPROXY 转发规则存在" "$TPROXY_CHAIN 链内缺少 TCP 或 UDP TPROXY 规则" \
        "规则可能被人工误删；重启服务重建：systemctl restart mihomo"
fi

# 规则与 tproxy.env 一致性：链内入口守卫必须与 env 里的网卡/网段相符。
if [ ! -r "$ENV_FILE" ]; then
    check_fail "规则与 tproxy.env 一致" "$ENV_FILE 缺失，无法确认规则范围" \
        "请重跑 install.sh 重新生成该文件（重装默认保留配置）"
else
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    _guard_ok=1
    _guard_why=""
    _chain_rules="$(iptables -t mangle -S MIHOMO 2>/dev/null || true)"
    if ! printf '%s\n' "$_chain_rules" | grep -qE -- "! -i ${LAN_IFACE:-}.*-j RETURN"; then
        _guard_ok=0
        _guard_why="MIHOMO 链内缺少入口网卡守卫（! -i ${LAN_IFACE:-}）"
    fi
    # 受管网段列表：LAN_SUBNETS（逗号列表）优先于 LAN_SUBNET，与 tproxy.sh 同一条规则。
    _subnets=""
    if [ -n "${LAN_SUBNETS:-}" ]; then
        _subnets="$(printf '%s' "$LAN_SUBNETS" | tr ',' ' ')"
    elif [ -n "${LAN_SUBNET:-}" ]; then
        _subnets="$LAN_SUBNET"
    fi
    if [ -z "$_subnets" ]; then
        _guard_ok=0
        _guard_why="$ENV_FILE 中未指定任何受管网段"
    elif [ "$TPROXY_CHAIN" = "MIHOMO_DO" ]; then
        for _s in $_subnets; do
            if ! printf '%s\n' "$_chain_rules" | grep -qE -- "-s $_s.*-j MIHOMO_DO"; then
                _guard_ok=0
                _guard_why="MIHOMO 链内缺少网段 $_s 的分发规则"
                break
            fi
        done
    else
        for _s in $_subnets; do
            if ! printf '%s\n' "$_chain_rules" | grep -qE -- "! -s $_s.*-j RETURN"; then
                _guard_ok=0
                _guard_why="MIHOMO 链内缺少网段守卫（! -s $_s）"
                break
            fi
        done
    fi
    if [ "$_guard_ok" -eq 1 ]; then
        check_pass "规则与 tproxy.env 一致" "入口网卡 ${LAN_IFACE:-} 与受管网段守卫均与 $ENV_FILE 相符"
    else
        check_fail "规则与 tproxy.env 一致" "$_guard_why" \
            "tproxy.env 改动后需重启服务重建规则：systemctl restart mihomo"
    fi
fi

# --- 4. DNS 劫持规则 ---
DNS_CHAIN="MIHOMO_DNS"
if iptables -t nat -n -L MIHOMO_DNS_DO >/dev/null 2>&1; then
    DNS_CHAIN="MIHOMO_DNS_DO"
fi
if iptables -t nat -n -L MIHOMO_DNS >/dev/null 2>&1; then
    check_pass "DNS 劫持链存在" "nat 表 MIHOMO_DNS 链存在"
else
    check_fail "DNS 劫持链存在" "nat 表 MIHOMO_DNS 链缺失" \
        "检查 tproxy.sh 启动日志；重启服务重建：systemctl restart mihomo"
fi
if iptables -t nat -S PREROUTING 2>/dev/null | grep -qE -- '-j MIHOMO_DNS$'; then
    check_pass "DNS 跳转存在" "nat PREROUTING 已跳转到 MIHOMO_DNS"
else
    check_fail "DNS 跳转存在" "nat PREROUTING 未跳转到 MIHOMO_DNS" \
        "检查 tproxy.sh 启动日志；重启服务重建：systemctl restart mihomo"
fi
# 真实 iptables 的 -S 输出会在带 --dport 的规则里插入 "-m udp"/"-m tcp"
# （2026-11-13 真机实测：-p udp -m udp --dport 53），且第二轮第 1 项给
# 全部规则加了 -m comment 标识（-p udp -m comment ... -m udp --dport 53），
# 故用 ERE 的.*容忍中间的全部 -m 选项。
if iptables -t nat -S "$DNS_CHAIN" 2>/dev/null | grep -qE -- '-p udp.*--dport 53 -j REDIRECT --to-ports 1053' \
    && iptables -t nat -S "$DNS_CHAIN" 2>/dev/null | grep -qE -- '-p tcp.*--dport 53 -j REDIRECT --to-ports 1053'; then
    check_pass "DNS 重定向规则存在" "$DNS_CHAIN 链内含 UDP/TCP 53 端口重定向到 1053"
else
    check_fail "DNS 重定向规则存在" "$DNS_CHAIN 链内缺少 UDP 或 TCP 53 端口重定向规则" \
        "规则可能被人工误删；重启服务重建：systemctl restart mihomo"
fi
# DNS 规则与 tproxy.env 一致性：MIHOMO_DNS 链内入口守卫与来源/分发
# 规则必须与 env 里的网卡/网段相符（与第 3 节 TPROXY 一致性同一条
# 规则；规则文本带 comment 标识时子串匹配仍命中）。单立一项，不并入
# TPROXY 一致性检查，以免失败文案混淆。链本身缺失或 env 缺失时上方
# 已有检查报 FAIL，这里跳过不重复报；守卫错误/分发缺失/错网段一律 FAIL。
if ! iptables -t nat -n -L MIHOMO_DNS >/dev/null 2>&1; then
    check_skip "DNS 规则与 tproxy.env 一致" "MIHOMO_DNS 链缺失，无法核对规则范围（见上方 DNS 劫持链存在检查）"
elif [ ! -r "$ENV_FILE" ]; then
    check_skip "DNS 规则与 tproxy.env 一致" "$ENV_FILE 缺失，无法确认 DNS 规则范围（见上方 TPROXY 一致性检查）"
else
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    _dns_guard_ok=1
    _dns_guard_why=""
    _dns_rules="$(iptables -t nat -S MIHOMO_DNS 2>/dev/null || true)"
    if ! printf '%s\n' "$_dns_rules" | grep -qE -- "! -i ${LAN_IFACE:-}.*-j RETURN"; then
        _dns_guard_ok=0
        _dns_guard_why="MIHOMO_DNS 链内缺少入口网卡守卫（! -i ${LAN_IFACE:-}）"
    fi
    # 受管网段列表：LAN_SUBNETS（逗号列表）优先于 LAN_SUBNET，与第 3 节
    # 及 tproxy.sh 同一条规则。
    _dns_subnets=""
    if [ -n "${LAN_SUBNETS:-}" ]; then
        _dns_subnets="$(printf '%s' "$LAN_SUBNETS" | tr ',' ' ')"
    elif [ -n "${LAN_SUBNET:-}" ]; then
        _dns_subnets="$LAN_SUBNET"
    fi
    if [ -z "$_dns_subnets" ]; then
        _dns_guard_ok=0
        _dns_guard_why="$ENV_FILE 中未指定任何受管网段"
    elif [ "$DNS_CHAIN" = "MIHOMO_DNS_DO" ]; then
        for _s in $_dns_subnets; do
            if ! printf '%s\n' "$_dns_rules" | grep -qE -- "-s $_s.*-j MIHOMO_DNS_DO"; then
                _dns_guard_ok=0
                _dns_guard_why="MIHOMO_DNS 链内缺少网段 $_s 的 DNS 分发规则"
                break
            fi
        done
    else
        for _s in $_dns_subnets; do
            if ! printf '%s\n' "$_dns_rules" | grep -qE -- "! -s $_s.*-j RETURN"; then
                _dns_guard_ok=0
                _dns_guard_why="MIHOMO_DNS 链内缺少网段守卫（! -s $_s）"
                break
            fi
        done
    fi
    if [ "$_dns_guard_ok" -eq 1 ]; then
        check_pass "DNS 规则与 tproxy.env 一致" "入口网卡 ${LAN_IFACE:-} 与受管网段 DNS 守卫/分发均与 $ENV_FILE 相符"
    else
        check_fail "DNS 规则与 tproxy.env 一致" "$_dns_guard_why" \
            "tproxy.env 改动后需重启服务重建规则：systemctl restart mihomo"
    fi
fi

# --- 5. 订阅 provider 节点数（存在性经 API 查，节点数数缓存文件；API 未就绪时跳过）---
if [ "$API_OK" -eq 0 ]; then
    check_skip "订阅 provider 有节点" "API 未就绪，无法查询（先解决上面的 API 问题）"
else
    _resp="$(curl --noproxy '*' -s -m 10 "${AUTH_HEADER[@]}" "$API/providers/proxies" 2>/dev/null || true)"
    if [ -z "$_resp" ]; then
        check_fail "订阅 provider 有节点" "API /providers/proxies 无响应" \
            "看 journalctl -u mihomo -n 50；确认面板 API 正常后重跑"
    else
        _missing=""
        for _p in $PROVIDERS; do
            if ! printf '%s' "$_resp" | grep -qF "\"$_p\""; then
                _missing="$_p"
                break
            fi
        done
        # 节点数：数 mihomo 落盘的订阅缓存 $PROVIDERS_DIR/<provider>.yaml
        # 里 proxies: 区内的节点行。只数 proxies 区：订阅文件常
        # 带 proxy-groups: 区，分组项同样是 "- name: " 开头，全数会虚高
        # （真机实测 5 节点 + 13 分组曾被报成 18）。节点有两种写法都得认：
        # 块式 "- name: XXX" 与流式 "- {name: XXX, ...}"（jd 订阅实测流式，
        # 只认块式会数出 0 节点误判失败，2026-11-14）。为什么不解析 API
        # JSON：真机实测 mihomo v1.19.34 的 /providers/proxies 响应没有
        # "count" 字段（2026-11-13，响应里另有 default 内置出口与分组
        # provider，数名字也不准），且本项目不保证 jq/python3 可用；缓存
        # 文件就是 mihomo 实际服务的节点数据，缺失说明订阅从未成功拉取
        # 过。与 auto-maintain.sh 的 provider_node_count 同一条计数规则。
        _total=0
        _cache_missing=""
        for _p in $PROVIDERS; do
            _cache="$PROVIDERS_DIR/$_p.yaml"
            if [ ! -f "$_cache" ]; then
                _cache_missing="$_p"
                break
            fi
            _n=$(awk '/^proxies:/{s=1;next} /^[A-Za-z][^:]*:/{s=0} s && /^[[:space:]]*- (\{)?name:/{n++} END{print n+0}' "$_cache" 2>/dev/null || true)
            case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
            _total=$((_total + _n))
        done
        if [ -n "$_missing" ]; then
            check_fail "订阅 provider 有节点" "provider $_missing 未在 API 响应中" \
                "检查 config.yaml 的 proxy-providers 配置；确认订阅链接有效后用面板或 auto-maintain.sh refresh 刷新一次"
        elif [ -n "$_cache_missing" ]; then
            # 安装场景宽限（VERIFY_INSTALL_MODE=1 时）：缓存文件缺失只
            # 说明首次拉取尚未完成，记 SKIP 并明说原因与复核方法，不算
            # 安装失败。独立运行本脚本时仍 FAIL。注意宽限边界：缓存存
            # 在但节点数为 0 说明拉取已完成而订阅为空，仍走下方 FAIL。
            if [ "$VERIFY_INSTALL_MODE" = "1" ]; then
                check_skip "订阅 provider 有节点" "安装场景：provider $_cache_missing 的订阅缓存文件尚未生成（首次订阅拉取尚未完成），暂不判定；待拉取完成（通常数分钟内）后重跑本脚本复核"
            else
                check_fail "订阅 provider 有节点" "provider $_cache_missing 的订阅缓存文件缺失（订阅从未成功拉取）" \
                    "刷新订阅：bash /etc/mihomo/auto-maintain.sh refresh；若反复失败，检查订阅链接是否有效、是否过期"
            fi
        elif [ "$_total" -eq 0 ]; then
            check_fail "订阅 provider 有节点" "provider 节点数为 0（订阅可能为空或全部节点不可用）" \
                "检查订阅链接是否有效、是否过期；刷新订阅：bash /etc/mihomo/auto-maintain.sh refresh"
        else
            check_pass "订阅 provider 有节点" "provider 节点总数：$_total"
        fi
    fi
fi

# --- 6. IPv6 阻断（仅 tproxy.env 启用 IPV6_BLOCK=1 时检查）---
# LAN 口当前无全局 IPv6 地址时链缺失属正常（无可阻断对象，tproxy.sh
# 只警告不建规则），记 SKIP 而非 FAIL；地址在而链缺失才是真缺失。
if [ "${IPV6_BLOCK:-0}" = "1" ]; then
    if ip6tables -t filter -n -L MIHOMO_V6 >/dev/null 2>&1 \
        && ip6tables -t filter -S FORWARD 2>/dev/null | grep -qE -- '-j MIHOMO_V6$'; then
        check_pass "IPv6 阻断规则存在" "filter 表 MIHOMO_V6 链存在且已挂 FORWARD"
    elif ! ip -6 -o addr show dev "${LAN_IFACE:-}" scope global 2>/dev/null | grep -qE 'inet6 [0-9a-fA-F:]+/[0-9]+ scope global'; then
        check_skip "IPv6 阻断规则存在" "LAN 口 ${LAN_IFACE:-} 当前无全局 IPv6 地址，无可阻断对象，链缺失属正常；地址出现后重启服务或等 auto-maintain 补建"
    else
        check_fail "IPv6 阻断规则存在" "已启用 IPv6 阻断但 MIHOMO_V6 链或 FORWARD 跳转缺失" \
            "重启服务重建：systemctl restart mihomo；也可等 auto-maintain 下个检查周期（15 分钟内）自动补建"
    fi
fi

# --- 7. 面板 9090 监听与来源限制（第二轮第 2 项）---
# 配置的 external-controller 监听地址须与实际监听（ss -tln）一致；
# 非本机绑定时，防火墙来源限制（MIHOMO_PANEL 链 + INPUT 跳转 + 逐网
# 段 RETURN + 末尾 DROP）必须存在。不一致/缺失一律 FAIL；监听本身不
# 存在时（服务未起）记 SKIP——上方 API 检查已报 FAIL，不重复报。
_panel_listen=""
if [ -f "$CONFIG_FILE" ]; then
    _panel_listen=$(grep -E '^external-controller:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed -E 's/^external-controller:[[:space:]]*([^:]+):.*/\1/' || true)
    # 未写 external-controller 时 mihomo 默认仅本机监听（127.0.0.1:9090）。
    [ -z "$_panel_listen" ] && _panel_listen="127.0.0.1"
fi
# 实际监听地址（ss -tln 的 :9090 行；ss 缺失或无监听时为空）。
_panel_actual=""
if command -v ss >/dev/null 2>&1; then
    _panel_actual=$(ss -tln 2>/dev/null | awk '$1=="LISTEN" && $4 ~ /:9090$/ {sub(/:[^:]*$/, "", $4); print $4; exit}' || true)
fi
if [ -z "$_panel_listen" ]; then
    check_skip "面板 9090 监听地址一致" "$CONFIG_FILE 缺失，无法确认面板监听地址（见上方 API 检查）"
    check_skip "面板 9090 来源限制" "$CONFIG_FILE 缺失，无法确认面板监听模式（见上方 API 检查）"
elif [ -z "$_panel_actual" ] && command -v ss >/dev/null 2>&1; then
    check_skip "面板 9090 监听地址一致" "9090 端口当前无监听（服务未运行或 API 未就绪，见上方 API 检查）"
    check_skip "面板 9090 来源限制" "9090 端口当前无监听，暂无暴露面（见上方 API 检查）"
else
    # 7a. 监听地址一致性（ss 不可用时无法核对，记 SKIP）
    if ! command -v ss >/dev/null 2>&1; then
        check_skip "面板 9090 监听地址一致" "未检测到 ss 命令，无法核对实际监听地址"
    elif [ "$_panel_actual" = "$_panel_listen" ]; then
        check_pass "面板 9090 监听地址一致" "配置监听 ${_panel_listen}:9090 与实际监听一致"
    else
        check_fail "面板 9090 监听地址一致" "配置监听 ${_panel_listen}:9090，实际监听 ${_panel_actual}:9090" \
            "配置改动后需重启服务生效：systemctl restart mihomo；若实际监听为 0.0.0.0 而配置不是，请检查配置是否被其他进程改动"
    fi
    # 7b. 来源限制（仅非本机绑定时需要）
    if [ "$_panel_listen" = "127.0.0.1" ]; then
        check_skip "面板 9090 来源限制" "面板仅本机监听（127.0.0.1:9090），外部无法直连，无需防火墙来源限制"
    elif [ -z "$_panel_actual" ] && [ "$API_OK" -eq 0 ]; then
        # ss 不可用且 API 未就绪：监听很可能不存在，API 检查已报 FAIL。
        check_skip "面板 9090 来源限制" "API 未就绪，9090 可能无监听（见上方 API 检查）"
    elif [ ! -r "$ENV_FILE" ]; then
        check_fail "面板 9090 来源限制" "$ENV_FILE 缺失，无法确认来源限制应覆盖的受管网段" \
            "请重跑 install.sh 重新生成该文件（重装默认保留配置）"
    else
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        _panel_fw_ok=1
        _panel_fw_why=""
        _panel_rules=""
        if ! iptables -t filter -n -L MIHOMO_PANEL >/dev/null 2>&1; then
            _panel_fw_ok=0
            _panel_fw_why="filter 表 MIHOMO_PANEL 链缺失（面板监听 ${_panel_listen}:9090，非本机绑定）"
        # 真实 iptables 的 -S 输出会在带 --dport 的规则里插入 "-m tcp"
        # （与第 4 节 DNS 检查同一条容忍规则），且第二轮第 1 项给全部
        # 规则加了 -m comment 标识，故用 ERE 的.*容忍中间的全部 -m 选项。
        elif ! iptables -t filter -S INPUT 2>/dev/null | grep -qE -- '-p tcp.*--dport 9090 -j MIHOMO_PANEL$'; then
            _panel_fw_ok=0
            _panel_fw_why="filter INPUT 链缺少到 MIHOMO_PANEL 的 9090 跳转"
        else
            _panel_rules="$(iptables -t filter -S MIHOMO_PANEL 2>/dev/null || true)"
            if ! printf '%s\n' "$_panel_rules" | grep -qE -- '-i lo.*-j RETURN'; then
                _panel_fw_ok=0
                _panel_fw_why="MIHOMO_PANEL 链内缺少本机回环放行规则（-i lo）"
            fi
            # 受管网段列表：LAN_SUBNETS（逗号列表）优先于 LAN_SUBNET，
            # 与第 3 节及 tproxy.sh 同一条规则。
            _panel_subnets=""
            if [ -n "${LAN_SUBNETS:-}" ]; then
                _panel_subnets="$(printf '%s' "$LAN_SUBNETS" | tr ',' ' ')"
            elif [ -n "${LAN_SUBNET:-}" ]; then
                _panel_subnets="$LAN_SUBNET"
            fi
            if [ "$_panel_fw_ok" -eq 1 ] && [ -z "$_panel_subnets" ]; then
                _panel_fw_ok=0
                _panel_fw_why="$ENV_FILE 中未指定任何受管网段"
            fi
            if [ "$_panel_fw_ok" -eq 1 ]; then
                for _s in $_panel_subnets; do
                    if ! printf '%s\n' "$_panel_rules" | grep -qE -- "-s $_s.*-j RETURN"; then
                        _panel_fw_ok=0
                        _panel_fw_why="MIHOMO_PANEL 链内缺少网段 $_s 的放行规则"
                        break
                    fi
                done
            fi
            if [ "$_panel_fw_ok" -eq 1 ] && ! printf '%s\n' "$_panel_rules" | grep -qF -- '-j DROP'; then
                _panel_fw_ok=0
                _panel_fw_why="MIHOMO_PANEL 链内缺少末尾 DROP 规则（非受管来源未被拦截）"
            fi
        fi
        if [ "$_panel_fw_ok" -eq 1 ]; then
            check_pass "面板 9090 来源限制" "MIHOMO_PANEL 链与 INPUT 跳转存在，仅受管 LAN 网段可访问 9090"
        else
            check_fail "面板 9090 来源限制" "$_panel_fw_why" \
                "面板监听非本机地址时必须有来源限制；重启服务重建规则：systemctl restart mihomo"
        fi
    fi
fi

echo "=========================================="
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "自检通过：$PASS_COUNT 项通过，$SKIP_COUNT 项跳过。"
    echo "DNS 泄漏验证：在局域网客户端打开 dnsleaktest.com 或 browserleaks.com/dns，"
    echo "看到的 DNS 服务器应为代理出口的 DNS，而非本地宽带运营商的 DNS。"
    exit 0
fi
echo "自检失败：$PASS_COUNT 项通过，$FAIL_COUNT 项未通过，$SKIP_COUNT 项跳过。"
echo "通用排查：systemctl status mihomo；journalctl -u mihomo -n 50；"
echo "维护日志：tail -n 100 /var/log/mihomo-maintain.log"
echo "规则问题通常重启服务即可重建：systemctl restart mihomo"
exit 1
