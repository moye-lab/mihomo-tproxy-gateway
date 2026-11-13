#!/bin/bash
# Mihomo 旁路由健康自检：只读检查，不修改任何系统状态。
#
# 用法:
#   sudo bash /etc/mihomo/verify.sh
#   sudo bash /path/to/mihomo-tproxy-gateway/scripts/verify.sh
#
# 检查项：服务运行状态、API 就绪（重试约 30 秒）、TPROXY 规则存在且
# 与 tproxy.env 一致、DNS 劫持规则存在、订阅 provider 有节点（存在性
# 经 API 查，节点数数订阅缓存文件）、IPv6 阻断规则（仅启用时）。逐项
# 输出 [PASS]/[FAIL]/[SKIP] 清单与排查指引；任一项失败退出 1，全部
# 通过退出 0。
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
# API 就绪重试：真机实测重启后 mihomo 启动（含拉订阅）可超过 10 秒
# （2026-11-13 Armbian ARM64），默认 15 次 × 2 秒 ≈ 30 秒，与
# install.sh 的就绪轮询同量级；环境变量覆盖只供测试用。
VERIFY_API_TRIES="${VERIFY_API_TRIES:-15}"
VERIFY_API_INTERVAL="${VERIFY_API_INTERVAL:-2}"
case "$VERIFY_API_TRIES" in ''|*[!0-9]*) VERIFY_API_TRIES=15 ;; esac
case "$VERIFY_API_INTERVAL" in ''|*[!0-9]*) VERIFY_API_INTERVAL=2 ;; esac

# API 地址、鉴权 secret、订阅 provider 名：优先读 maintain.env，
# secret 缺失时退回 config.yaml 提取（与 restore.sh 同一条提取规则）。
API="http://127.0.0.1:9090"
API_SECRET=""
PROVIDERS="airport1"
if [ -f "$MAINTAIN_ENV" ]; then
    # shellcheck disable=SC1090
    source "$MAINTAIN_ENV"
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
if ip rule show 2>/dev/null | grep -qE 'fwmark 0x1([ /]|$).*lookup 100$'; then
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
# TPROXY 规则无 --dport 等匹配选项，真实 iptables 不插入 -m，字面匹配
# 即可（真机实测通过；只有带 --dport 的 DNS 规则需要容忍 -m，见第 4 节）。
if iptables -t mangle -S "$TPROXY_CHAIN" 2>/dev/null | grep -qF -- '-p tcp -j TPROXY --on-port 7893' \
    && iptables -t mangle -S "$TPROXY_CHAIN" 2>/dev/null | grep -qF -- '-p udp -j TPROXY --on-port 7893'; then
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
    if ! printf '%s\n' "$_chain_rules" | grep -qF -- "! -i ${LAN_IFACE:-} -j RETURN"; then
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
            if ! printf '%s\n' "$_chain_rules" | grep -qF -- "-s $_s -j MIHOMO_DO"; then
                _guard_ok=0
                _guard_why="MIHOMO 链内缺少网段 $_s 的分发规则"
                break
            fi
        done
    else
        for _s in $_subnets; do
            if ! printf '%s\n' "$_chain_rules" | grep -qF -- "! -s $_s -j RETURN"; then
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
# （2026-11-13 真机实测：-p udp -m udp --dport 53），字面匹配会误报，
# 故用 ERE 容忍可选的 -m。
if iptables -t nat -S "$DNS_CHAIN" 2>/dev/null | grep -qE -- '-p udp( -m udp)? --dport 53 -j REDIRECT --to-ports 1053' \
    && iptables -t nat -S "$DNS_CHAIN" 2>/dev/null | grep -qE -- '-p tcp( -m tcp)? --dport 53 -j REDIRECT --to-ports 1053'; then
    check_pass "DNS 重定向规则存在" "$DNS_CHAIN 链内含 UDP/TCP 53 端口重定向到 1053"
else
    check_fail "DNS 重定向规则存在" "$DNS_CHAIN 链内缺少 UDP 或 TCP 53 端口重定向规则" \
        "规则可能被人工误删；重启服务重建：systemctl restart mihomo"
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
        # 里 proxies: 区内的 "- name: " 行。只数 proxies 区：订阅文件常
        # 带 proxy-groups: 区，分组项同样是 "- name: " 开头，全数会虚高
        # （真机实测 5 节点 + 13 分组曾被报成 18）。为什么不解析 API
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
            _n=$(awk '/^proxies:/{s=1;next} /^[A-Za-z][^:]*:/{s=0} s && /^[[:space:]]*- name: /{n++} END{print n+0}' "$_cache" 2>/dev/null || true)
            case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
            _total=$((_total + _n))
        done
        if [ -n "$_missing" ]; then
            check_fail "订阅 provider 有节点" "provider $_missing 未在 API 响应中" \
                "检查 config.yaml 的 proxy-providers 配置；确认订阅链接有效后用面板或 auto-maintain.sh refresh 刷新一次"
        elif [ -n "$_cache_missing" ]; then
            check_fail "订阅 provider 有节点" "provider $_cache_missing 的订阅缓存文件缺失（订阅从未成功拉取）" \
                "刷新订阅：bash /etc/mihomo/auto-maintain.sh refresh；若反复失败，检查订阅链接是否有效、是否过期"
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
