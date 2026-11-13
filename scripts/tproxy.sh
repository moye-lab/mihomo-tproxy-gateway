#!/bin/bash
# TPROXY 路由、防火墙规则与 DNS 劫持配置
# 设计目标：每次执行都是"先彻底清理、再重新建立"，保证幂等 —— 无论是首次启动、
# 服务重启、还是反复重装测试，都不会有旧规则残留导致排查困难。
#
# 归属机制（v1.2.2，第二轮整改第 1 项）：清理只删本项目自己的规则，
# 绝不静默删他人同名链或 fwmark 1 / 表 100 规则。归属三条判定（任一
# 成立即认领）：① 规则带本项目 comment（见 RULE_COMMENT）；② 链内含
# 本项目指纹规则（旧版无 comment 的规则）；③ 归属记录文件
# .tproxy-owned 里登记了该链/规则。ip rule/ip route 不支持 comment，
# 策略路由的归属只认记录文件——start 建规则时写记录，stop 成功后清
# 记录；无记录的 (1,100) 规则一律视为他人规则（或旧版残留），不动。

# 注意 set -e 的分工：下面的清理命令全都带 || true（本来就允许失败），
# 而建立规则的命令不带 —— 任何一条建不出来，脚本立刻以非零码退出，
# 作为 systemd ExecStartPost 时服务会被判定启动失败，而不是规则没建好
# 还报 "tproxy OK"、让旁路由带着半套规则假装正常。
# 例外：build_v6_chain() 经 `|| exit 1` 调用，set -e 在函数体内失效，
# 因此函数内每条关键命令都显式 `|| return 1`，不要省掉。
set -e

ROUTING_TABLE=100
MARK=1
TPROXY_PORT=7893
DNS_PORT=1053
# 项目专属 iptables comment 标识：每条自建规则（链内规则与 PREROUTING/
# FORWARD 跳转）都带它，放在规则最前面——这样 verify.sh / auto-maintain.sh
# 里按 `-p tcp …`、`-j MIHOMO$` 等子串匹配的旧检查不用改也能继续命中。
RULE_COMMENT="mihomo-tproxy-gateway"
# 归属记录文件：start 写、stop 成功后删；内容见第 1 节写入处。
OWNED_STATE="/etc/mihomo/.tproxy-owned"

# ------------------------------------------------------------------
# 仅清理模式（STOP_MODE）：`tproxy.sh stop` 只删除本项目创建的规则与
# 路由，不读 tproxy.env（清理时 env 可能已缺失或损坏，不能因此拒绝
# 清理）。供 uninstall.sh 与 install.sh 回滚调用；install.sh 回滚与
# uninstall.sh 通过 grep 本行标记判断当前 tproxy.sh 是否支持 stop。
# ------------------------------------------------------------------
# 归属记录查询：记录文件不存在即视为无归属（他人规则或旧版残留）。
state_owns_rule() {
    [ -f "$OWNED_STATE" ] && grep -qxF 'rule fwmark 1 table 100' "$OWNED_STATE" 2>/dev/null
}
state_owns_route() {
    [ -f "$OWNED_STATE" ] && grep -qxF 'route local default dev lo table 100' "$OWNED_STATE" 2>/dev/null
}
state_owns_chain() { # state_owns_chain <表> <链>
    [ -f "$OWNED_STATE" ] && grep -qxF "chain $1 $2" "$OWNED_STATE" 2>/dev/null
}
# 建链后登记归属（start 建链时调；repair-v6 补建 V6 链时也调）。
record_chain() { # record_chain <表> <链>
    printf 'chain %s %s\n' "$1" "$2" >> "$OWNED_STATE"
}

chain_exists() { # chain_exists <iptables|ip6tables> <表> <链>
    "$1" -t "$2" -n -L "$3" >/dev/null 2>&1
}

# 归属判定：一条链属于本项目，当且仅当满足其一——
#   ① 链内任一规则带本项目 comment（v1.2.2 起新建的规则都有）；
#   ② 链内含本项目指纹规则（旧版无 comment 的规则：TPROXY 7893 /
#      REDIRECT 1053 / V6 的 IPv6 前缀 DROP / 分发子链跳转）；
#   ③ 归属记录文件里登记了该链（空链无内容可比，只能靠记录认领；
#      start 建链时逐条登记，stop 成功后清除记录）。
# 三条都不满足即视为他人链：清理不动、启动拒绝覆盖。
chain_is_ours() { # chain_is_ours <iptables|ip6tables> <表> <链>
    local _ipt="$1" _table="$2" _chain="$3" _rules=""
    state_owns_chain "$_table" "$_chain" && return 0
    _rules="$("$_ipt" -t "$_table" -S "$_chain" 2>/dev/null || true)"
    [ -n "$_rules" ] || return 1
    # ① comment：真实 iptables -S 会把 comment 值打引号，桩里不打，
    #    只 grep 值本身，两种写法都认。
    printf '%s\n' "$_rules" | grep -qF -- "$RULE_COMMENT" && return 0
    # ② 指纹：按链名匹配本项目特有的规则形态。
    case "$_chain" in
        MIHOMO)
            printf '%s\n' "$_rules" | grep -qF -- '-j TPROXY --on-port 7893 --tproxy-mark 1' && return 0
            printf '%s\n' "$_rules" | grep -qF -- '-j MIHOMO_DO' && return 0
            ;;
        MIHOMO_DO)
            printf '%s\n' "$_rules" | grep -qF -- '-j TPROXY --on-port 7893 --tproxy-mark 1' && return 0
            ;;
        MIHOMO_DNS)
            printf '%s\n' "$_rules" | grep -qF -- '-j REDIRECT --to-ports 1053' && return 0
            printf '%s\n' "$_rules" | grep -qF -- '-j MIHOMO_DNS_DO' && return 0
            ;;
        MIHOMO_DNS_DO)
            printf '%s\n' "$_rules" | grep -qF -- '-j REDIRECT --to-ports 1053' && return 0
            ;;
        MIHOMO_V6)
            printf '%s\n' "$_rules" | grep -qE -- '-s [0-9a-fA-F:]+/[0-9]+ -j DROP' && return 0
            ;;
    esac
    return 1
}

# 删一条本项目链（先验归属：非本项目链直接返回，不动）：
# 带 comment 的跳转只可能是本项目建的（comment 即归属），链在不在都删；
# 链内规则清空 → 删无 comment 的旧版跳转（循环删净历史重复）→ 删链。
cleanup_chain() { # cleanup_chain <ipt> <表> <链> [跳转所在链] [跳转匹配参数...]
    # 跳转匹配参数：跳转规则除 comment 与 -j 之外的匹配部分（如面板跳转
    # 的 -p tcp --dport 9090）。-D 要求规则精确匹配，缺了这部分删不掉跳
    # 转，随后 -X 会因链仍被引用而失败，stop 误报残留（第二轮第 2 项实测）。
    local _ipt="$1" _table="$2" _chain="$3" _jump="${4:-}"
    local _jump_args=()
    if [ "$#" -gt 4 ]; then
        shift 4
        _jump_args=("$@")
    fi
    if [ -n "$_jump" ]; then
        while "$_ipt" -t "$_table" -D "$_jump" -m comment --comment "$RULE_COMMENT" "${_jump_args[@]}" -j "$_chain" 2>/dev/null; do :; done
    fi
    chain_exists "$_ipt" "$_table" "$_chain" || return 0
    chain_is_ours "$_ipt" "$_table" "$_chain" || return 0
    "$_ipt" -t "$_table" -F "$_chain" 2>/dev/null || true
    if [ -n "$_jump" ]; then
        while "$_ipt" -t "$_table" -D "$_jump" "${_jump_args[@]}" -j "$_chain" 2>/dev/null; do :; done
    fi
    "$_ipt" -t "$_table" -X "$_chain" 2>/dev/null || true
}

# 删除本项目自身的全部规则与路由：循环删除直到不存在为止 —— 历史版本
# 的单次删除会在重复规则已存在时残留一条；循环删除保证幂等清理干净。
# 每条删除前先验归属（链看 comment/指纹/记录，策略路由只看记录），
# 非本项目规则一律不动。
cleanup_own_rules() {
    if state_owns_rule; then
        while ip rule del fwmark "$MARK" table "$ROUTING_TABLE" 2>/dev/null; do :; done
    fi
    if state_owns_route; then
        while ip route del local default dev lo table "$ROUTING_TABLE" 2>/dev/null; do :; done
    fi

    cleanup_chain iptables mangle MIHOMO PREROUTING
    # 多网段模式的子链（单网段安装不存在；MIHOMO 已先清空，子链不再
    # 被引用才能删）。
    cleanup_chain iptables mangle MIHOMO_DO
    cleanup_chain iptables nat MIHOMO_DNS PREROUTING
    cleanup_chain iptables nat MIHOMO_DNS_DO

    # 面板 9090 来源限制链（仅非本机监听的安装存在；与上面四条链同
    # 一归属机制，跳转在 INPUT 链，跳转规则含 -p tcp --dport 9090 匹
    # 配条件，须传给 cleanup_chain 否则 -D 删不掉跳转）。
    cleanup_chain iptables filter MIHOMO_PANEL INPUT -p tcp --dport 9090

    # IPv6 阻断链（仅 IPV6_BLOCK=1 的安装存在；ip6tables 缺失时跳过）。
    if command -v ip6tables >/dev/null 2>&1; then
        cleanup_chain ip6tables filter MIHOMO_V6 FORWARD
    fi
}

# 本项目链是否仍存在（存在且属于本项目才算残留；他人同名链不是残留）。
chain_ours_exists() { # chain_ours_exists <ipt> <表> <链>
    chain_exists "$1" "$2" "$3" && chain_is_ours "$1" "$2" "$3"
}

# IPv6 阻断链已清除（ip6tables 不存在时视为已清除，无从残留；
# 他人同名链存在也不算本项目残留）。
v6_chain_gone() {
    command -v ip6tables >/dev/null 2>&1 || return 0
    ! chain_ours_exists ip6tables filter MIHOMO_V6
}

# 归属在案的策略路由是否仍残留（无记录的同值规则是他人的，不算残留）。
owned_rule_remains() {
    state_owns_rule || return 1
    ip rule show 2>/dev/null | grep -qE "fwmark 0x1([ /]|$).*lookup 100$"
}
owned_route_remains() {
    state_owns_route || return 1
    ip route show table "$ROUTING_TABLE" 2>/dev/null | grep -q '^local default dev lo'
}

# 验证本项目自身的规则与路由已全部清除（只认自有产物：归属在案的
# 六条链、fwmark 1 + 表 100 的规则、表 100 里的 local 路由；其他程序
# 的规则不在此列，清理时也不动它们，残留检查同样不把它们算作残留）。
verify_own_rules_gone() {
    ! chain_ours_exists iptables mangle MIHOMO \
        && ! chain_ours_exists iptables mangle MIHOMO_DO \
        && ! chain_ours_exists iptables nat MIHOMO_DNS \
        && ! chain_ours_exists iptables nat MIHOMO_DNS_DO \
        && ! chain_ours_exists iptables filter MIHOMO_PANEL \
        && v6_chain_gone \
        && ! owned_rule_remains \
        && ! owned_route_remains
}

# stop 前预检（与 start 的冲突预检对称）：清理只删归属本项目的规则，
# 这里先盘点会保留的他人规则并明确告知，不静默。预检本身不拒绝停止
# （停止不需要独占 fwmark/链名，与启动不同）。
note_foreign_chain() { # note_foreign_chain <ipt> <表> <链>
    if chain_exists "$1" "$2" "$3" && ! chain_is_ours "$1" "$2" "$3"; then
        echo "注意：$2 表的 $3 链无归属记录（其他程序或旧版残留），停止时将保留，不删除。" >&2
    fi
}
stop_precheck() {
    if ip rule show 2>/dev/null | grep -qE 'fwmark 0x1([ /]|$).*lookup 100$' && ! state_owns_rule; then
        echo "注意：fwmark 1 / 表 100 规则无归属记录（其他程序或旧版残留），停止时将保留，不删除。" >&2
    fi
    if ip route show table "$ROUTING_TABLE" 2>/dev/null | grep -q '^local default dev lo' && ! state_owns_route; then
        echo "注意：表 100 内的 local default 路由无归属记录（其他程序或旧版残留），停止时将保留，不删除。" >&2
    fi
    note_foreign_chain iptables mangle MIHOMO
    note_foreign_chain iptables mangle MIHOMO_DO
    note_foreign_chain iptables nat MIHOMO_DNS
    note_foreign_chain iptables nat MIHOMO_DNS_DO
    note_foreign_chain iptables filter MIHOMO_PANEL
    if command -v ip6tables >/dev/null 2>&1; then
        note_foreign_chain ip6tables filter MIHOMO_V6
    fi
}

# 建链前链名冲突检测（启动前调用）：同名链已存在且非本项目时直接
# 报错退出，绝不静默删他人链。本项目自己的旧链（带 comment / 指纹 /
# 归属记录）不触发，由随后的清理正常处理。
check_chain_conflict() { # check_chain_conflict <ipt> <表> <链>
    if chain_exists "$1" "$2" "$3" && ! chain_is_ours "$1" "$2" "$3"; then
        echo "错误：$2 表的 $3 链已存在且不属于本项目（可能为其他程序所建），拒绝覆盖；请先停用对方或手动清理后再启动。" >&2
        exit 1
    fi
}

# 建（或重建）IPv6 阻断链 MIHOMO_V6 与 FORWARD 跳转：start 第 4 节与
# repair-v6 模式共用。只动 V6：不清理、不重建任何 IPv4 规则。
#   - 等待 LAN 口全局 IPv6 前缀出现（最多 V6_WAIT_SECS 秒，默认 60；
#     repair-v6 模式调用方置 0，不等）；
#   - 等满仍无前缀时只警告、返回 0（无可阻断对象，不是失败）；
#   - 链已存在且属于本项目时清空后重建（前缀可能已变；repair-v6 靠
#     这条更新滞留的旧 DROP 规则）；
#   - 链已存在且非本项目时拒绝（返回 1），绝不覆盖他人链；
#   - FORWARD 跳转已有（带 comment 的新版或无 comment 的旧版都算）
#     时不重复加。
# 返回 0 表示阻断链已就绪（或无地址无需建链）；返回 1 表示建链失败。
# 注意：本函数经 `|| exit 1` 调用，set -e 在函数体内失效，每条关键
# 命令都必须显式 `|| return 1`。
build_v6_chain() {
    if ! command -v ip6tables >/dev/null 2>&1; then
        echo "错误：已启用 IPv6 阻断（IPV6_BLOCK=1）但系统缺少 ip6tables，无法建立阻断规则；请安装 ip6tables 或将 tproxy.env 中的 IPV6_BLOCK 改为 0。" >&2
        return 1
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
        return 0
    fi
    if chain_exists ip6tables filter MIHOMO_V6; then
        if ! chain_is_ours ip6tables filter MIHOMO_V6; then
            echo "错误：filter 表的 MIHOMO_V6 链已存在且不属于本项目，拒绝覆盖；请先停用对方或手动清理后再修复。" >&2
            return 1
        fi
        ip6tables -t filter -F MIHOMO_V6 || return 1
    else
        ip6tables -t filter -N MIHOMO_V6 || return 1
        state_owns_chain filter MIHOMO_V6 || record_chain filter MIHOMO_V6 || return 1
    fi
    ip6tables -t filter -A MIHOMO_V6 -m comment --comment "$RULE_COMMENT" ! -i "$LAN_IFACE" -j RETURN || return 1
    for _pfx in "${V6_PREFIXES[@]}"; do
        ip6tables -t filter -A MIHOMO_V6 -m comment --comment "$RULE_COMMENT" -s "$_pfx" -j DROP || return 1
    done
    if ! ip6tables -t filter -S FORWARD 2>/dev/null | grep -q -- '-j MIHOMO_V6'; then
        ip6tables -t filter -A FORWARD -m comment --comment "$RULE_COMMENT" -j MIHOMO_V6 || return 1
    fi
    echo "IPv6 阻断已启用（前缀：$(IFS=,; echo "${V6_PREFIXES[*]}")）"
    return 0
}

MODE="${1:-start}"
case "$MODE" in
    start|repair-v6) ;;
    stop)
        stop_precheck
        cleanup_own_rules
        if verify_own_rules_gone; then
            rm -f "$OWNED_STATE"
            echo "tproxy stopped (own rules cleaned)"
            exit 0
        fi
        echo "错误：清理后仍有本项目规则残留，请检查 ip rule / iptables。" >&2
        exit 1
        ;;
    *)
        echo "用法：$0 [start|stop|repair-v6]" >&2
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

if [ -z "${LAN_IFACE:-}" ]; then
    echo "错误：$ENV_FILE 中缺少 LAN_IFACE。" >&2
    exit 1
fi
if ! ip link show dev "$LAN_IFACE" >/dev/null 2>&1; then
    echo "错误：LAN 网卡 $LAN_IFACE 不存在；请检查 $ENV_FILE。" >&2
    exit 1
fi

# repair-v6 模式：只重建 MIHOMO_V6 链与 FORWARD 跳转，不清理、不重建
# 任何 IPv4 规则（不走第 0 节清理与第 1–3 节）。供 auto-maintain check
# 在"地址已在但链缺失/前缀已变"时调用；IPv4 正在工作时补建 V6 不应有
# 规则空窗。只需要 LAN_IFACE/IPV6_BLOCK，不需要网段配置，因此分发点
# 放在网段校验之前（网段配置损坏也不应挡住 V6 修复）。
if [ "$MODE" = "repair-v6" ]; then
    if [ "${IPV6_BLOCK:-0}" != "1" ]; then
        echo "IPv6 阻断未启用（IPV6_BLOCK≠1），无需修复。"
        exit 0
    fi
    # 触发方已确认地址存在（auto-maintain 先查地址再调用），这里不等；
    # 地址恰好消失时 build_v6_chain 只警告、不建链，调用方复查后处理。
    V6_WAIT_SECS=0
    build_v6_chain || exit 1
    exit 0
fi

if [ -z "${LAN_SUBNET:-}" ] && [ -z "${LAN_SUBNETS:-}" ]; then
    echo "错误：$ENV_FILE 中缺少 LAN_SUBNET/LAN_SUBNETS。" >&2
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
# LAN_SUBNET 的老配置走单网段路径，规则布局与 v1.1.0 一致（v1.2.2 起
# 每条规则前多了 -m comment 归属标识，规则文本因此多了 comment 一段，
# 见 P7h 断言与文件头归属机制说明）。
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

# (fwmark 1, table 100) 归属预检：规则已存在但归属记录里没有，说明是
# 其他程序的（或本项目旧版残留——旧版不写归属记录），拒绝覆盖。旧版
# 残留请手动执行 ip rule del fwmark 1 table 100 后重试（正常升级流程
# 里旧版 stop 已清掉规则，不会走到这里）。
if ip rule show 2>/dev/null | grep -qE 'fwmark 0x1([ /]|$).*lookup 100$' && ! state_owns_rule; then
    echo "错误：fwmark 1 / 表 100 已被其他程序占用（或为本项目旧版本残留），拒绝覆盖；请先停用对方，或确认是旧版残留后手动执行 ip rule del fwmark 1 table 100 再重试。" >&2
    exit 1
fi
if ip route show table "$ROUTING_TABLE" 2>/dev/null | grep -q '^local default dev lo' && ! state_owns_route; then
    echo "错误：路由表 $ROUTING_TABLE 内已有其他程序的 local default 路由（或为本项目旧版本残留），拒绝覆盖；请先停用对方，或确认是旧版残留后手动执行 ip route del local default dev lo table $ROUTING_TABLE 再重试。" >&2
    exit 1
fi

# 链名冲突检测（清理前做）：同名链已存在且非本项目时拒绝启动，绝不
# 静默删他人链；本项目自己的旧链由随后的清理正常处理。
check_chain_conflict iptables mangle MIHOMO
check_chain_conflict iptables mangle MIHOMO_DO
check_chain_conflict iptables nat MIHOMO_DNS
check_chain_conflict iptables nat MIHOMO_DNS_DO
check_chain_conflict iptables filter MIHOMO_PANEL
if command -v ip6tables >/dev/null 2>&1; then
    check_chain_conflict ip6tables filter MIHOMO_V6
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

# 归属记录（见文件头）：ip rule/ip route 不支持 comment，(1,100) 与表
# 100 路由的归属只认本文件；写在建链之前——start 中途失败时 stop 与
# 下次 start 仍能认出并清理已建的一半规则（安装回滚依赖这一点）。
# 链行由建链处逐条追加（record_chain），只登记实际建出的链。
# 写失败时 set -e 直接退出（失败关闭：记不了归属就不要建规则，否则
# 之后清理认不出自有规则）。
{
    echo "# mihomo-tproxy-gateway owned rules (start 时生成，stop 成功后清除)"
    echo "rule fwmark 1 table 100"
    echo "route local default dev lo table 100"
} > "$OWNED_STATE"
chmod 600 "$OWNED_STATE" 2>/dev/null || true

# ------------------------------------------------------------------
# 2. TCP/UDP 透明代理（mangle 表，只挂 PREROUTING —— 本机自身流量走
#    OUTPUT 链，不受影响，符合"旁路由"定位）
# ------------------------------------------------------------------
# 单网段：代理规则直接建在 MIHOMO 链内，链头两条 ! -i / ! -s 守卫，
# 与 v1.1.0 真机验证过的布局一致（仅每条规则前多了 -m comment 归属标识）。
# 多网段：连续的 ! -s 守卫是"与"关系 —— 来自 A 的包会被 "! -s B"
# 守卫挡掉，所以不能直接叠加。改用正向分发：MIHOMO 只做分发（任一
# 网段命中即跳入 MIHOMO_DO 子链，都不命中则 RETURN），实际代理规
# 则放子链里；非 TCP/UDP 的包从子链落回后同样被 MIHOMO 末尾的
# RETURN 放行，不会被误代理。
iptables -t mangle -N MIHOMO
record_chain mangle MIHOMO
if [ "${#SUBNETS[@]}" -eq 1 ]; then
    PROXY_CHAIN="MIHOMO"
    # 限制入口：只处理指定 LAN 网卡且来源属于所配置网段的包。
    # 将限制放在自定义链内部，能兼容升级前创建的无条件 PREROUTING 跳转，
    # 也避免修改 LAN_IFACE/LAN_SUBNET 后留下旧跳转导致链无法重建。
    iptables -t mangle -A MIHOMO -m comment --comment "$RULE_COMMENT" ! -i "$LAN_IFACE" -j RETURN
    iptables -t mangle -A MIHOMO -m comment --comment "$RULE_COMMENT" ! -s "${SUBNETS[0]}" -j RETURN
else
    PROXY_CHAIN="MIHOMO_DO"
    iptables -t mangle -N MIHOMO_DO
    record_chain mangle MIHOMO_DO
    iptables -t mangle -A MIHOMO -m comment --comment "$RULE_COMMENT" ! -i "$LAN_IFACE" -j RETURN
    for _s in "${SUBNETS[@]}"; do
        iptables -t mangle -A MIHOMO -m comment --comment "$RULE_COMMENT" -s "$_s" -j MIHOMO_DO
    done
    iptables -t mangle -A MIHOMO -m comment --comment "$RULE_COMMENT" -j RETURN
fi

# 保留地址与局域网直连流量不走代理
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -d 240.0.0.0/4 -j RETURN

iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
iptables -t mangle -A "$PROXY_CHAIN" -m comment --comment "$RULE_COMMENT" -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"

iptables -t mangle -A PREROUTING -m comment --comment "$RULE_COMMENT" -j MIHOMO

# ------------------------------------------------------------------
# 3. DNS 劫持（nat 表）：把局域网设备发往任意 DNS 服务器的 53 端口
#    请求，强制拉回本机 mihomo 的 fake-ip DNS 监听端口。
#    这一步是"透明代理"名副其实的关键 —— 没有这条规则，任何自己配了
#    DNS（比如手机用运营商 DNS / DoH）的设备，fake-ip 分流对它就是
#    摆设，会直接漏到明文 DNS。
#    多网段时与第 2 节同样用分发子链（MIHOMO_DNS_DO），单网段布局不变。
# ------------------------------------------------------------------
iptables -t nat -N MIHOMO_DNS
record_chain nat MIHOMO_DNS
if [ "${#SUBNETS[@]}" -eq 1 ]; then
    DNS_CHAIN="MIHOMO_DNS"
    iptables -t nat -A MIHOMO_DNS -m comment --comment "$RULE_COMMENT" ! -i "$LAN_IFACE" -j RETURN
    iptables -t nat -A MIHOMO_DNS -m comment --comment "$RULE_COMMENT" ! -s "${SUBNETS[0]}" -j RETURN
else
    DNS_CHAIN="MIHOMO_DNS_DO"
    iptables -t nat -N MIHOMO_DNS_DO
    record_chain nat MIHOMO_DNS_DO
    iptables -t nat -A MIHOMO_DNS -m comment --comment "$RULE_COMMENT" ! -i "$LAN_IFACE" -j RETURN
    for _s in "${SUBNETS[@]}"; do
        iptables -t nat -A MIHOMO_DNS -m comment --comment "$RULE_COMMENT" -s "$_s" -j MIHOMO_DNS_DO
    done
    iptables -t nat -A MIHOMO_DNS -m comment --comment "$RULE_COMMENT" -j RETURN
fi
iptables -t nat -A "$DNS_CHAIN" -m comment --comment "$RULE_COMMENT" -d 127.0.0.0/8 -j RETURN
iptables -t nat -A "$DNS_CHAIN" -m comment --comment "$RULE_COMMENT" -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A "$DNS_CHAIN" -m comment --comment "$RULE_COMMENT" -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A PREROUTING -m comment --comment "$RULE_COMMENT" -j MIHOMO_DNS

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
#    建链逻辑在 build_v6_chain()（与 repair-v6 模式共用，见文件头函数区）。
# ------------------------------------------------------------------
if [ "${IPV6_BLOCK:-0}" = "1" ]; then
    build_v6_chain || exit 1
fi

# ------------------------------------------------------------------
# 5. 面板 9090 来源限制（第二轮第 2 项）：面板监听非本机地址时
#    （LAN IP 或 0.0.0.0），只允许受管 LAN 网段访问 9090，其余来源
#    一律 DROP；仅本机监听（127.0.0.1）时无需限制——外部本就连不上。
#    规则放专用链 MIHOMO_PANEL（filter 表）+ INPUT 跳转，而不用直接
#    写 INPUT 的零散规则：专用链与 TPROXY/DNS 链走同一归属机制
#    （comment + 归属记录 + 冲突检测 + 清理），stop/卸载/回滚时随其
#    他自有规则一起清理，不留零散规则；链内规则自成一体，verify.sh
#    核对与人工排查都只要看一条链。
#    PANEL_LISTEN 缺失（v1.2.2 之前的旧 tproxy.env）时按非本机处理：
#    旧版默认绑 0.0.0.0，fail-safe——宁可多限制，不可少限制。
#    链内首条 -i lo RETURN：本机 API（auto-maintain/verify 走
#    127.0.0.1:9090）必须放行，否则维护与自检会被自己的防火墙挡掉。
#    限制范围取受管 LAN 网段（SUBNETS，与 TPROXY/DNS 同一来源）；
#    网段配错会把用户自己锁在面板外——真实锁定风险列为待真机验证项。
#    跳转只匹配 TCP 9090（面板是 TCP 服务），不碰其他端口。
# ------------------------------------------------------------------
if [ "${PANEL_LISTEN:-}" != "127.0.0.1" ]; then
    iptables -t filter -N MIHOMO_PANEL
    record_chain filter MIHOMO_PANEL
    iptables -t filter -A MIHOMO_PANEL -m comment --comment "$RULE_COMMENT" -i lo -j RETURN
    for _s in "${SUBNETS[@]}"; do
        iptables -t filter -A MIHOMO_PANEL -m comment --comment "$RULE_COMMENT" -s "$_s" -j RETURN
    done
    iptables -t filter -A MIHOMO_PANEL -m comment --comment "$RULE_COMMENT" -j DROP
    iptables -t filter -A INPUT -m comment --comment "$RULE_COMMENT" -p tcp --dport 9090 -j MIHOMO_PANEL
fi

echo "tproxy OK (interface=$LAN_IFACE subnet=$SUBNETS_JOINED)"
