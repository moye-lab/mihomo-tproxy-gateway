#!/bin/bash
# TPROXY 路由、防火墙规则与 DNS 劫持配置
# 设计目标：每次执行都是"先彻底清理、再重新建立"，保证幂等 —— 无论是首次启动、
# 服务重启、还是反复重装测试，都不会有旧规则残留导致排查困难。

# 注意 set -e 的分工：下面的清理命令全都带 || true（本来就允许失败），
# 而建立规则的命令不带 —— 任何一条建不出来，脚本立刻以非零码退出，
# 作为 systemd ExecStartPost 时服务会被判定启动失败，而不是规则没建好
# 还报 "tproxy OK"、让旁路由带着半套规则假装正常。
set -e

ROUTING_TABLE=100
MARK=1
TPROXY_PORT=7893
DNS_PORT=1053

# ------------------------------------------------------------------
# 仅清理模式（STOP_MODE）：`tproxy.sh stop` 只删除本项目创建的规则与
# 路由，不读 tproxy.env（清理时 env 可能已缺失或损坏，不能因此拒绝
# 清理）。供 uninstall.sh 与 install.sh 回滚调用；install.sh 回滚与
# uninstall.sh 通过 grep 本行标记判断当前 tproxy.sh 是否支持 stop。
# ------------------------------------------------------------------
# 删除本项目自身的全部规则与路由：循环删除直到不存在为止 —— 历史版本
# 的单次删除会在重复规则已存在时残留一条；循环删除保证幂等清理干净。
cleanup_own_rules() {
    while ip rule del fwmark "$MARK" table "$ROUTING_TABLE" 2>/dev/null; do :; done
    while ip route del local default dev lo table "$ROUTING_TABLE" 2>/dev/null; do :; done

    iptables -t mangle -F MIHOMO 2>/dev/null || true
    while iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null; do :; done
    iptables -t mangle -X MIHOMO 2>/dev/null || true
    # 多网段模式的子链（单网段安装不存在，-X 失败即忽略；MIHOMO 已
    # 先清空，子链不再被引用才能删）。
    iptables -t mangle -F MIHOMO_DO 2>/dev/null || true
    iptables -t mangle -X MIHOMO_DO 2>/dev/null || true

    iptables -t nat -F MIHOMO_DNS 2>/dev/null || true
    while iptables -t nat -D PREROUTING -j MIHOMO_DNS 2>/dev/null; do :; done
    iptables -t nat -X MIHOMO_DNS 2>/dev/null || true
    iptables -t nat -F MIHOMO_DNS_DO 2>/dev/null || true
    iptables -t nat -X MIHOMO_DNS_DO 2>/dev/null || true

    # IPv6 阻断链（仅 IPV6_BLOCK=1 的安装存在；ip6tables 缺失时跳过）。
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t filter -F MIHOMO_V6 2>/dev/null || true
        while ip6tables -t filter -D FORWARD -j MIHOMO_V6 2>/dev/null; do :; done
        ip6tables -t filter -X MIHOMO_V6 2>/dev/null || true
    fi
}

# IPv6 阻断链已清除（ip6tables 不存在时视为已清除，无从残留）。
v6_chain_gone() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    ! ip6tables -t filter -n -L MIHOMO_V6 >/dev/null 2>&1
}

# 验证本项目自身的规则与路由已全部清除（只认自有产物：MIHOMO 两条链
# 与多网段子链、IPv6 阻断链、fwmark 1 + 表 100 的规则、表 100 里的
# local 路由；其他程序的规则不在此列，清理时也不应动它们）。
verify_own_rules_gone() {
    ! iptables -t mangle -n -L MIHOMO >/dev/null 2>&1 \
        && ! iptables -t mangle -n -L MIHOMO_DO >/dev/null 2>&1 \
        && ! iptables -t nat -n -L MIHOMO_DNS >/dev/null 2>&1 \
        && ! iptables -t nat -n -L MIHOMO_DNS_DO >/dev/null 2>&1 \
        && v6_chain_gone \
        && ! ip rule show 2>/dev/null | grep -qE "fwmark 0x1([ /]|$).*lookup 100$" \
        && ! ip route show table "$ROUTING_TABLE" 2>/dev/null | grep -q '^local default dev lo'
}

MODE="${1:-start}"
case "$MODE" in
    start) ;;
    stop)
        cleanup_own_rules
        if verify_own_rules_gone; then
            echo "tproxy stopped (own rules cleaned)"
            exit 0
        fi
        echo "错误：清理后仍有本项目规则残留，请检查 ip rule / iptables。" >&2
        exit 1
        ;;
    *)
        echo "用法：$0 [start|stop]" >&2
        exit 1
        ;;
esac

# 安装器生成此文件，明确限定只处理指定 LAN 网卡和来源网段。
# 旧安装若没有该文件，不再无条件接管所有 PREROUTING 流量，而是安全失败。
ENV_FILE="/etc/mihomo/tproxy.env"
if [ ! -r "$ENV_FILE" ]; then
    echo "错误：缺少 $ENV_FILE，无法安全限定透明代理入口；请重新运行新版安装脚本。" >&2
    exit 1
fi
# 此文件由 root 安装脚本创建，只能由管理员修改。
# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -z "${LAN_IFACE:-}" ] || { [ -z "${LAN_SUBNET:-}" ] && [ -z "${LAN_SUBNETS:-}" ]; }; then
    echo "错误：$ENV_FILE 中缺少 LAN_IFACE 或 LAN_SUBNET/LAN_SUBNETS。" >&2
    exit 1
fi
if ! ip link show dev "$LAN_IFACE" >/dev/null 2>&1; then
    echo "错误：LAN 网卡 $LAN_IFACE 不存在；请检查 $ENV_FILE。" >&2
    exit 1
fi

# CIDR 校验（格式 + 数值 + 前导零，与 install.sh 的校验保持一致）：
# 正则只拦格式，999.999.999.999/24 这类数值越界的 CIDR 也能通过，
# 这里补数值校验；带前导 0 的数字（如 010）会被 iptables 按八进制
# 解析，与十进制校验结果不一致，同样拒绝。
validate_cidr() {
    local _cidr="$1" _o1 _o2 _o3 _o4 _pfx
    if ! [[ "$_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
        echo "错误：LAN 子网格式无效：$_cidr" >&2
        return 1
    fi
    IFS='./' read -r _o1 _o2 _o3 _o4 _pfx <<< "$_cidr"
    if [ "$_o1" -gt 255 ] || [ "$_o2" -gt 255 ] || [ "$_o3" -gt 255 ] || [ "$_o4" -gt 255 ] || [ "$_pfx" -gt 32 ]; then
        echo "错误：LAN 子网数值超出范围：$_cidr" >&2
        return 1
    fi
    if [[ "$_cidr" =~ (^|[./])0[0-9] ]]; then
        echo "错误：LAN 子网包含带前导 0 的数字：$_cidr（请用十进制，如 10.0.0.0/24）" >&2
        return 1
    fi
    return 0
}

# 受管网段列表：LAN_SUBNETS（逗号列表）优先于 LAN_SUBNET；只写了
# LAN_SUBNET 的老配置走单网段路径，规则布局与 v1.1.0 逐字节一致。
SUBNETS=()
if [ -n "${LAN_SUBNETS:-}" ]; then
    _old_ifs="$IFS"
    IFS=','
    read -ra _parts <<< "$LAN_SUBNETS"
    IFS="$_old_ifs"
    for _s in "${_parts[@]}"; do
        # 去掉每项首尾空白（"10.0.0.0/24, 192.168.1.0/24" 也能用）
        _s="${_s#"${_s%%[![:space:]]*}"}"
        _s="${_s%"${_s##*[![:space:]]}"}"
        [ -n "$_s" ] && SUBNETS+=("$_s")
    done
elif [ -n "${LAN_SUBNET:-}" ]; then
    SUBNETS=("$LAN_SUBNET")
fi
if [ "${#SUBNETS[@]}" -eq 0 ]; then
    echo "错误：$ENV_FILE 中 LAN_SUBNETS 为空，未指定任何受管网段。" >&2
    exit 1
fi
for _s in "${SUBNETS[@]}"; do
    validate_cidr "$_s" || exit 1
done
# 去重：同一网段写两次不产生重复规则。
_unique=()
for _s in "${SUBNETS[@]}"; do
    _dup=0
    for _u in "${_unique[@]}"; do
        if [ "$_s" = "$_u" ]; then _dup=1; break; fi
    done
    [ "$_dup" -eq 0 ] && _unique+=("$_s")
done
SUBNETS=("${_unique[@]}")
SUBNETS_JOINED="$(IFS=,; echo "${SUBNETS[*]}")"

# ------------------------------------------------------------------
# 0. 彻底清理旧状态（幂等的关键：不管之前是什么状态，先清空）
# ------------------------------------------------------------------
# fwmark 冲突检测（清理前做）：任何 fwmark 1 但不指向表 100 的规则都
# 是其他程序的 —— 本项目只用 1/100 这一组固定值（2026-10-21 真机证明
# 换值会断网，不做静默换值），检测到占用就拒绝启动，且不碰对方规则。
if ip rule show 2>/dev/null | grep -E 'fwmark 0x1([ /]|$)' | grep -qvE 'lookup 100$'; then
    echo "错误：检测到其他程序已使用 fwmark 1（见 ip rule show），拒绝覆盖；请先停用对方或手动清理后再启动。" >&2
    exit 1
fi

# 清理本项目自身的策略路由与防火墙规则（固定标记 1 / 表 100，与此前版本一致）。
cleanup_own_rules

# 清理后复查：仍有 fwmark 1 规则残留（例如带掩码、按 (mark, table)
# 删不掉的形态），说明清理不彻底，拒绝启动而不是带着残留建新规则。
if ip rule show 2>/dev/null | grep -qE 'fwmark 0x1([ /]|$)'; then
    echo "错误：清理后仍有 fwmark 1 规则残留（见 ip rule show），拒绝启动；请手动清理后再启动。" >&2
    exit 1
fi
if ip route show table "$ROUTING_TABLE" 2>/dev/null | grep -q .; then
    echo "错误：路由表 $ROUTING_TABLE 已包含其他路由，拒绝覆盖；请检查 ip route show table $ROUTING_TABLE。" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 1. 策略路由：把打了 MARK 的包丢给本机处理（TPROXY 依赖这个）
# ------------------------------------------------------------------
ip rule add fwmark $MARK table $ROUTING_TABLE
ip route add local default dev lo table $ROUTING_TABLE

# ------------------------------------------------------------------
# 2. TCP/UDP 透明代理（mangle 表，只挂 PREROUTING —— 本机自身流量走
#    OUTPUT 链，不受影响，符合"旁路由"定位）
# ------------------------------------------------------------------
# 单网段：代理规则直接建在 MIHOMO 链内，链头两条 ! -i / ! -s 守卫，
# 与 v1.1.0 真机验证过的布局逐字节一致。
# 多网段：连续的 ! -s 守卫是"与"关系 —— 来自 A 的包会被 "! -s B"
# 守卫挡掉，所以不能直接叠加。改用正向分发：MIHOMO 只做分发（任一
# 网段命中即跳入 MIHOMO_DO 子链，都不命中则 RETURN），实际代理规
# 则放子链里；非 TCP/UDP 的包从子链落回后同样被 MIHOMO 末尾的
# RETURN 放行，不会被误代理。
iptables -t mangle -N MIHOMO
if [ "${#SUBNETS[@]}" -eq 1 ]; then
    PROXY_CHAIN="MIHOMO"
    # 限制入口：只处理指定 LAN 网卡且来源属于所配置网段的包。
    # 将限制放在自定义链内部，能兼容升级前创建的无条件 PREROUTING 跳转，
    # 也避免修改 LAN_IFACE/LAN_SUBNET 后留下旧跳转导致链无法重建。
    iptables -t mangle -A MIHOMO ! -i "$LAN_IFACE" -j RETURN
    iptables -t mangle -A MIHOMO ! -s "${SUBNETS[0]}" -j RETURN
else
    PROXY_CHAIN="MIHOMO_DO"
    iptables -t mangle -N MIHOMO_DO
    iptables -t mangle -A MIHOMO ! -i "$LAN_IFACE" -j RETURN
    for _s in "${SUBNETS[@]}"; do
        iptables -t mangle -A MIHOMO -s "$_s" -j MIHOMO_DO
    done
    iptables -t mangle -A MIHOMO -j RETURN
fi

# 保留地址与局域网直连流量不走代理
iptables -t mangle -A "$PROXY_CHAIN" -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -d 240.0.0.0/4 -j RETURN

iptables -t mangle -A "$PROXY_CHAIN" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
iptables -t mangle -A "$PROXY_CHAIN" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"

iptables -t mangle -A PREROUTING -j MIHOMO

# ------------------------------------------------------------------
# 3. DNS 劫持（nat 表）：把局域网设备发往任意 DNS 服务器的 53 端口
#    请求，强制拉回本机 mihomo 的 fake-ip DNS 监听端口。
#    这一步是"透明代理"名副其实的关键 —— 没有这条规则，任何自己配了
#    DNS（比如手机用运营商 DNS / DoH）的设备，fake-ip 分流对它就是
#    摆设，会直接漏到明文 DNS。
#    多网段时与第 2 节同样用分发子链（MIHOMO_DNS_DO），单网段布局不变。
# ------------------------------------------------------------------
iptables -t nat -N MIHOMO_DNS
if [ "${#SUBNETS[@]}" -eq 1 ]; then
    DNS_CHAIN="MIHOMO_DNS"
    iptables -t nat -A MIHOMO_DNS ! -i "$LAN_IFACE" -j RETURN
    iptables -t nat -A MIHOMO_DNS ! -s "${SUBNETS[0]}" -j RETURN
else
    DNS_CHAIN="MIHOMO_DNS_DO"
    iptables -t nat -N MIHOMO_DNS_DO
    iptables -t nat -A MIHOMO_DNS ! -i "$LAN_IFACE" -j RETURN
    for _s in "${SUBNETS[@]}"; do
        iptables -t nat -A MIHOMO_DNS -s "$_s" -j MIHOMO_DNS_DO
    done
    iptables -t nat -A MIHOMO_DNS -j RETURN
fi
iptables -t nat -A "$DNS_CHAIN" -d 127.0.0.0/8 -j RETURN
iptables -t nat -A "$DNS_CHAIN" -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A "$DNS_CHAIN" -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A PREROUTING -j MIHOMO_DNS

# ------------------------------------------------------------------
# 4. IPv6 阻断（可选，仅安装时显式启用 IPV6_BLOCK=1 才建规则）
#    mihomo 配置 ipv6:false，不代理 IPv6；LAN 口若有公网 IPv6，
#    客户端可经 IPv6 绕过代理。本节只丢弃"经本机转发、来自 LAN 口
#    全局 IPv6 前缀"的包（filter 表 FORWARD 链）；旁路由模式下客户
#    端 IPv6 通常不经过本机（走主路由），此时本节规则不生效也不碍
#    事，彻底防绕过需在主路由上处理 —— 安装器的警告会明说这一点。
#    绝不关闭系统 IPv6、不动默认路由；LAN 口当前无全局 IPv6 地址时
#    先等后警告（见下），等满仍无才不建规则（无可阻断对象，不是失败）。
#    开机时序：服务可能在 LAN 口拿到全局 IPv6 地址（SLAAC/DHCPv6）
#    之前启动，只查一次会漏建阻断链（2026-11-13 真机实测：重启后
#    MIHOMO_V6 缺失，手动重启服务才恢复；同日 x86 VM 实测地址晚到
#    超过 30 秒，等满仍未出现）。地址已在时立即建链零等待；不在时
#    最多等 V6_WAIT_SECS 秒（默认 60，可用环境变量覆盖，0 为不等）。
#    等待发生在 IPv4 规则建成之后，不影响代理；等满仍无地址时由
#    auto-maintain check（每 15 分钟）在地址出现后补建，不再永久漏建。
# ------------------------------------------------------------------
if [ "${IPV6_BLOCK:-0}" = "1" ]; then
    if ! command -v ip6tables >/dev/null 2>&1; then
        echo "错误：已启用 IPv6 阻断（IPV6_BLOCK=1）但系统缺少 ip6tables，拒绝以无阻断状态启动；请安装 ip6tables 或将 tproxy.env 中的 IPV6_BLOCK 改为 0。" >&2
        exit 1
    fi
    # 取 LAN 口全部全局 IPv6 前缀（地址自带前缀长度，如 2408:xxxx/64）。
    # 无地址时轮询等待：开机时 SLAAC/DHCPv6 地址可能晚到（x86 VM 真机
    # 实测超过 30 秒，v1.2.1 起默认等 60 秒）。
    V6_WAIT_SECS="${V6_WAIT_SECS:-60}"
    _v6_waited=0
    V6_PREFIXES=()
    while [ "$_v6_waited" -le "$V6_WAIT_SECS" ]; do
        V6_PREFIXES=()
        while IFS= read -r _line; do
            _pfx="${_line##*inet6 }"
            _pfx="${_pfx%% *}"
            # 只认带冒号与前缀长度的 IPv6 前缀，脏行直接跳过
            case "$_pfx" in
                *:*/*) V6_PREFIXES+=("$_pfx") ;;
            esac
        done < <(ip -6 -o addr show dev "$LAN_IFACE" scope global 2>/dev/null || true)
        [ "${#V6_PREFIXES[@]}" -gt 0 ] && break
        [ "$_v6_waited" -ge "$V6_WAIT_SECS" ] && break
        sleep 2
        _v6_waited=$((_v6_waited + 2))
    done
    if [ "${#V6_PREFIXES[@]}" -eq 0 ]; then
        echo "警告：已启用 IPv6 阻断，但 LAN 口 $LAN_IFACE 在 ${V6_WAIT_SECS} 秒内未出现全局 IPv6 地址，未建立阻断规则（IPv6 流量暂无可阻断对象）。" >&2
    else
        ip6tables -t filter -N MIHOMO_V6
        ip6tables -t filter -A MIHOMO_V6 ! -i "$LAN_IFACE" -j RETURN
        for _pfx in "${V6_PREFIXES[@]}"; do
            ip6tables -t filter -A MIHOMO_V6 -s "$_pfx" -j DROP
        done
        ip6tables -t filter -A FORWARD -j MIHOMO_V6
        echo "IPv6 阻断已启用（前缀：$(IFS=,; echo "${V6_PREFIXES[*]}")）"
    fi
fi

echo "tproxy OK (interface=$LAN_IFACE subnet=$SUBNETS_JOINED)"
