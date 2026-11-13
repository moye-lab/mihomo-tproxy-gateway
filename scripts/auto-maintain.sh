#!/bin/bash
# Mihomo 无人值守维护脚本
#
# 用法: auto-maintain.sh <check|refresh|full> [--dry-run]
#   check    健康检查（cron 高频调用，比如每 15 分钟）：服务/API 异常，
#            或经本地代理的连通性探测连续失败 2 次，才重启服务（带 30 分钟冷却）
#   refresh  刷新订阅（走 API，几秒完成，cron 每天调用）
#   full     完整维护：刷新订阅 + 更新 GeoIP/GeoSite/MMDB、面板 UI 与 mihomo
#            内核到官方版本 + 重启服务（cron 每周调用一次即可）
#   --dry-run 仅对 full 有意义：只下载并校验、报告将要更新什么，
#            不替换文件、不重启服务（输出直接打到终端，不写日志文件）
#
# full 的更新策略（与 install.sh 的专用资产仓 Release 兜底配套）：
#   服务已经跑起来、本机已有代理的前提下，所有下载优先经本地代理
#   (127.0.0.1:7890) 拉官方源，其次直连，再次 githubproxy.cc 镜像。
#   新文件先落到暂存区，逐个校验（geodata 用官方 .sha256sum、内核
#   双源 sha256 比对 + gzip 完整性 + 新二进制实跑 -v、UI 包完整性），
#   再用待更新的组合跑一遍 mihomo -t 配置校验，全部通过才原子替换；
#   替换后轮询 API 做健康检查，不过就自动回滚到上一份可用版本。
#   坏更新永远不会覆盖正在用的好文件。
#   注意：官方 Release 不发布 checksum 文件（2026-11-13 核查最新版
#   v1.19.34，124 个资产中无任何 checksum/sig 文件），内核校验改用
#   双源哈希一致：同一文件经两条独立路线下载，sha256 一致才认可。

set -uo pipefail

LOG_FILE="/var/log/mihomo-maintain.log"
ENV_FILE="/etc/mihomo/maintain.env"
MODE="${1:-check}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

# 日志文件本身的滚动：不能只指望 journalctl --vacuum，因为这个文件是
# 脚本自己 append 出来的，journal 清不到它。超过 5MB 就只保留最后 2000 行。
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# dry-run 时不重定向，输出直接给终端看；正式运行才写日志文件。
if [ "$DRY_RUN" -eq 0 ]; then
    exec >> "$LOG_FILE" 2>&1
fi
# 统一日志接口（P1-16，五脚本同一约定：[时间] [级别] [阶段] 消息）：
#   log <级别> <消息>      级别：INFO / WARN / ERROR；阶段即运行模式
#   （check/refresh/full）。本脚本输出已重定向到日志文件，不着色。
# 脱敏：订阅链接与 secret 不进日志（provider 只记名字与节点数）。
log() {
    local _level="$1"; shift
    printf '[%s] [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_level" "$MODE" "$*"
}

# 读取 install.sh 生成的运行环境（API 地址、鉴权 secret、订阅 provider 名、架构）
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
API="${API:-http://127.0.0.1:9090}"
API_SECRET="${API_SECRET:-}"
PROVIDERS="${PROVIDERS:-airport1}"
BIN_ARCH="${BIN_ARCH:-amd64}"
# 订阅缓存目录：mihomo 把拉到的订阅落盘到
# <PROVIDERS_DIR>/<provider>.yaml，节点数就数这里（与 verify.sh 同一条
# 规则）；环境变量覆盖只供测试用。
PROVIDERS_DIR="${PROVIDERS_DIR:-/etc/mihomo/providers}"

AUTH_HEADER=()
[ -n "$API_SECRET" ] && AUTH_HEADER=(-H "Authorization: Bearer $API_SECRET")

LOCAL_PROXY="http://127.0.0.1:7890"
GEO_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
UI_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

# 更新专用下载入口：本地代理 -> 直连 -> githubproxy.cc 镜像，逐个尝试。
# 用法: upd_fetch <输出文件> <官方URL>
# 成功时 UPD_FETCH_SOURCE 记录命中的路线（proxy/direct/mirror），供
# upd_fetch_secondary 跳过该路线、走另一条独立路线做双源哈希比对。
UPD_FETCH_SOURCE=""
upd_fetch_route() {
    local route="$1" out="$2" url="$3"
    case "$route" in
        proxy)  https_proxy="$LOCAL_PROXY" http_proxy="$LOCAL_PROXY" wget -q -T 30 --tries=1 -O "$out" "$url" ;;
        direct) wget -q -T 30 --tries=2 -O "$out" "$url" ;;
        mirror) wget -q -T 30 --tries=2 -O "$out" "https://githubproxy.cc/${url}" ;;
    esac
}
upd_fetch() {
    local out="$1" url="$2" route label
    for route in proxy direct mirror; do
        case "$route" in
            proxy)  label="经本地代理" ;;
            direct) label="直连" ;;
            mirror) label="githubproxy.cc 镜像" ;;
        esac
        if upd_fetch_route "$route" "$out" "$url"; then
            UPD_FETCH_SOURCE="$route"
            log INFO "下载成功（$label）: $url"
            return 0
        fi
    done
    rm -f "$out"
    return 1
}

# 第二下载源：按与首选源不同的路线重新下载同一文件，供双源哈希比对
# 用。首选源已用的路线不再尝试；全部路线都失败返回 1（调用方降级处理）。
upd_fetch_secondary() {
    local out="$1" url="$2" route
    for route in proxy direct mirror; do
        [ "$route" = "$UPD_FETCH_SOURCE" ] && continue
        if upd_fetch_route "$route" "$out" "$url"; then
            return 0
        fi
    done
    rm -f "$out"
    return 1
}

# 探测 mihomo 最新官方版本号：本地代理 -> 直连，任一成功即可
probe_latest_version() {
    local out=""
    out=$(curl -x "$LOCAL_PROXY" -m 15 -s "$MIHOMO_API" | grep '"tag_name"' | grep -oP 'v[\d.]+' | head -1 || true)
    [ -z "$out" ] && out=$(curl -m 15 -s "$MIHOMO_API" | grep '"tag_name"' | grep -oP 'v[\d.]+' | head -1 || true)
    echo "$out"
}

# 查 provider 当前节点数：数 mihomo 落盘的订阅缓存
# $PROVIDERS_DIR/<provider>.yaml 里 proxies: 区内的 "- name: " 行。只数
# proxies 区：订阅文件常带 proxy-groups: 区，分组项同样是 "- name: "
# 开头，全数会虚高（真机实测 5 节点 + 13 分组曾被报成 18）。为什么不
# 解析 API JSON：真机实测 mihomo v1.19.34 的 /providers/proxies 响应没有
# "count" 字段（2026-11-13），且本项目不保证 jq/python3 可用；缓存文件
# 就是 mihomo 实际服务的节点数据。与 verify.sh 同一条计数规则。成功
# 打印节点数（含 0），缓存缺失返回 1。
provider_node_count() { # provider_node_count <provider>
    local _cache _n
    _cache="${PROVIDERS_DIR}/$1.yaml"
    [ -f "$_cache" ] || return 1
    _n=$(awk '/^proxies:/{s=1;next} /^[A-Za-z][^:]*:/{s=0} s && /^[[:space:]]*- name: /{n++} END{print n+0}' "$_cache" 2>/dev/null || true)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    printf '%s' "$_n"
}

# full 更新后网络规则验证：服务健康检查通过后，再确认 TPROXY/DNS
# 规则与策略路由都在（ExecStartPost 失败时服务本应判启动失败，但
# 服务文件被手动改动、规则被人工误删等情况下规则可能缺失）。缺失只
# 记日志告警，不触发回滚——更新本身已成功，规则问题需要人工检查。
verify_network_rules() {
    local missing=0
    if ! iptables -t mangle -n -L MIHOMO >/dev/null 2>&1; then
        log WARN "网络规则验证：mangle 表 MIHOMO 链缺失"
        missing=1
    fi
    if ! iptables -t nat -n -L MIHOMO_DNS >/dev/null 2>&1; then
        log WARN "网络规则验证：nat 表 MIHOMO_DNS 链缺失"
        missing=1
    fi
    if ! ip rule show 2>/dev/null | grep -qE 'fwmark 0x1([ /]|$).*lookup 100$'; then
        log WARN "网络规则验证：fwmark 1 / 表 100 策略路由缺失"
        missing=1
    fi
    if ! ip route show table 100 2>/dev/null | grep -q '^local default dev lo'; then
        log WARN "网络规则验证：表 100 本地路由缺失"
        missing=1
    fi
    if [ "$missing" -eq 0 ]; then
        log INFO "网络规则验证通过（TPROXY/DNS 规则与策略路由均存在）"
        return 0
    fi
    log WARN "网络规则验证未通过：服务已更新并运行，但部分网络规则缺失，请检查 systemctl status mihomo 与 /etc/mihomo/tproxy.env"
    return 1
}

# 健康检查：服务 active 且 API /version 可达，轮询至多 30 秒
# --noproxy：本机 API 不走代理——curl 默认连 127.0.0.1 也发给 https_proxy，
# 代理到不了本机端口（2026-11-13 真机实测：回滚轮询因此 30 秒全败误报）。
wait_healthy() {
    local i
    for i in $(seq 1 30); do
        if systemctl is-active --quiet mihomo 2>/dev/null \
            && curl --noproxy '*' -s -m 3 "${AUTH_HEADER[@]}" "$API/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

CHECK_FAIL_FILE="/etc/mihomo/.check-failures"
CHECK_RESTART_FILE="/etc/mihomo/.check-last-restart"
CHECK_RESTART_COOLDOWN=1800

# 统一的重启入口：带冷却（距上次重启不足冷却时长则跳过，只记日志）。
maint_restart() {
    local reason="$1"
    local now last=0
    now=$(date +%s)
    [ -f "$CHECK_RESTART_FILE" ] && last=$(cat "$CHECK_RESTART_FILE" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt "$CHECK_RESTART_COOLDOWN" ]; then
        log ERROR "✗ $reason；但距上次重启不足 $((CHECK_RESTART_COOLDOWN / 60)) 分钟（冷却中），跳过重启，需要人工介入"
        return 1
    fi
    log WARN "⚠️ $reason，重启 mihomo 服务..."
    echo "$now" > "$CHECK_RESTART_FILE" 2>/dev/null || true
    rm -f "$CHECK_FAIL_FILE"
    systemctl restart mihomo
    if wait_healthy; then
        log INFO "✓ 重启后服务恢复"
    else
        log ERROR "✗ 重启后仍异常，需要人工介入"
    fi
}

# 取 LAN 口全部全局 IPv6 前缀（排序去重，每行一个；与 tproxy.sh 同一条
# ip 查询与提取规则，供补建触发条件比对链内 DROP 前缀用）。
v6_lan_prefixes() { # v6_lan_prefixes <iface>
    ip -6 -o addr show dev "$1" scope global 2>/dev/null | while IFS= read -r _line; do
        _pfx="${_line##*inet6 }"
        _pfx="${_pfx%% *}"
        case "$_pfx" in
            *:*/*) printf '%s\n' "$_pfx" ;;
        esac
    done | sort -u
}

# IPv6 阻断链补建（v1.2.1）：开机时 SLAAC/DHCPv6 地址晚到、等满
# V6_WAIT_SECS 仍未出现时，tproxy.sh 会跳过建链且之后无人补建
# （2026-11-13 x86 VM 真机实测：reboot 后 MIHOMO_V6 缺失，重启服务才
# 恢复）。check 每 15 分钟跑一次，这里发现"地址已在但链缺失"就补建，
# 最迟 15 分钟生效。v1.2.2 起补建调 `tproxy.sh repair-v6`（只重建 V6
# 链与 FORWARD 跳转，不清理、不重建 IPv4 规则），不再复用全量 start
# （全量重建会拆掉正常工作的 TPROXY/DNS 规则，且清理后失败会留空）。
# 触发条件（任一即动作，其余直接返回，不动系统）：
#   1. IPV6_BLOCK=1、LAN 口已有全局 IPv6 地址（前置，缺一直接返回）；
#   2. MIHOMO_V6 链或 FORWARD 跳转缺失；
#   3. 链内 DROP 前缀与当前 LAN 前缀不一致（前缀变更/重编号：只看链
#      存在发现不了滞留的旧 DROP 规则，新前缀会一直无阻断）。
repair_v6_chain() {
    local tproxy_env="/etc/mihomo/tproxy.env"
    [ -r "$tproxy_env" ] || return 0
    # tproxy.env 由 root 安装脚本生成，source 它与 tproxy.sh /
    # verify.sh 同一条路；先声明 local 再 source，取到的变量只留在
    # 本函数内，不污染本脚本（本脚本的 ENV_FILE 指 maintain.env）。
    local IPV6_BLOCK LAN_IFACE
    # shellcheck disable=SC1090
    source "$tproxy_env"
    [ "${IPV6_BLOCK:-0}" = "1" ] || return 0
    [ -n "${LAN_IFACE:-}" ] || return 0
    if ! ip -6 -o addr show dev "$LAN_IFACE" scope global 2>/dev/null | grep -qE 'inet6 [0-9a-fA-F:]+/[0-9]+ scope global'; then
        return 0
    fi
    local _need_repair=0 _repair_why="" _cur _old
    if ! ip6tables -t filter -n -L MIHOMO_V6 >/dev/null 2>&1 \
        || ! ip6tables -t filter -S FORWARD 2>/dev/null | grep -qE -- '-j MIHOMO_V6$'; then
        _need_repair=1
        _repair_why="链或 FORWARD 跳转缺失"
    else
        # 链与跳转都在时，还要比对链内 DROP 前缀与当前 LAN 前缀。
        _cur="$(v6_lan_prefixes "$LAN_IFACE")"
        _old="$(ip6tables -t filter -S MIHOMO_V6 2>/dev/null | grep -- '-j DROP' | grep -oE -- '-s [0-9a-fA-F:]+/[0-9]+' | awk '{print $2}' | sort -u)"
        if [ "$_cur" != "$_old" ]; then
            _need_repair=1
            _repair_why="LAN IPv6 前缀已变更，链内旧 DROP 规则滞留"
        fi
    fi
    [ "$_need_repair" -eq 0 ] && return 0
    log WARN "IPv6 阻断链需要修复（$_repair_why），调用 tproxy.sh repair-v6 补建（仅重建 V6 链，不动 IPv4 规则）..."
    if ! /bin/bash /etc/mihomo/tproxy.sh repair-v6; then
        log ERROR "✗ IPv6 阻断链补建失败（tproxy.sh repair-v6 退出非零），需要人工介入"
        return 1
    fi
    if ip6tables -t filter -n -L MIHOMO_V6 >/dev/null 2>&1 \
        && ip6tables -t filter -S FORWARD 2>/dev/null | grep -qE -- '-j MIHOMO_V6$'; then
        log INFO "✓ IPv6 阻断链已补建"
        return 0
    fi
    # 补建命令成功但链仍缺失：触发后地址恰好消失时属正常（无可阻断对象，
    # repair-v6 只警告不建链），不报 ERROR；地址还在才是真失败。
    if ! ip -6 -o addr show dev "$LAN_IFACE" scope global 2>/dev/null | grep -qE 'inet6 [0-9a-fA-F:]+/[0-9]+ scope global'; then
        log INFO "IPv6 阻断链补建跳过：LAN 口全局 IPv6 地址已消失，无可阻断对象"
        return 0
    fi
    log ERROR "✗ IPv6 阻断链补建后复查仍缺失，需要人工介入"
    return 1
}

do_check() {
    # 1) 进程与本地 API：这是内核本身的健康，异常直接走重启（仍受冷却保护）
    if ! systemctl is-active --quiet mihomo 2>/dev/null; then
        maint_restart "mihomo 服务未运行"
        return
    fi
    if ! curl --noproxy '*' -s -m 3 "${AUTH_HEADER[@]}" "$API/version" >/dev/null 2>&1; then
        maint_restart "本地 API 无响应"
        return
    fi
    # 2) 经本地代理探测外网（这才是局域网设备实际走的路径）：
    #    两个目标任一返回 200/204 即视为通。
    local t code ok=0
    for t in "https://www.gstatic.com/generate_204" "https://cp.cloudflare.com/generate_204"; do
        code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 -x "$LOCAL_PROXY" "$t" || echo "000")
        if [ "$code" = "204" ] || [ "$code" = "200" ]; then ok=1; break; fi
    done
    if [ "$ok" -eq 1 ]; then
        rm -f "$CHECK_FAIL_FILE"
        log INFO "✓ 服务正常，代理连通性正常"
        # 服务健康时顺带补建可能缺失的 IPv6 阻断链（开机时地址晚到
        # 未建链的情况）；补建失败只记日志，不影响本次检查结论。
        repair_v6_chain || true
        return
    fi
    # 3) 探测失败先计数：单次失败可能只是外部网络抖动，连续 2 次才重启
    local fails=0
    [ -f "$CHECK_FAIL_FILE" ] && fails=$(cat "$CHECK_FAIL_FILE" 2>/dev/null || echo 0)
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    fails=$((fails + 1))
    echo "$fails" > "$CHECK_FAIL_FILE" 2>/dev/null || true
    if [ "$fails" -lt 2 ]; then
        log WARN "⚠️ 代理连通性探测失败（第 $fails 次），暂不重启，下个周期复查"
        return
    fi
    maint_restart "代理连通性连续 $fails 次探测失败"
}

do_refresh() {
    for p in $PROVIDERS; do
        local code count
        code=$(curl --noproxy '*' -s -m 15 -o /dev/null -w "%{http_code}" "${AUTH_HEADER[@]}" -X PUT "$API/providers/proxies/$p")
        if [ "$code" = "204" ]; then
            # 刷新成功后查一次 provider 状态（节点数），记入日志供排障；
            # 查不到节点数只警告，不影响"刷新成功"本身的结论。
            if count=$(provider_node_count "$p"); then
                if [ "$count" -eq 0 ]; then
                    log WARN "订阅 $p 刷新成功，但节点数为 0（订阅可能为空或全部节点不可用），请检查订阅内容"
                else
                    log INFO "订阅 $p 刷新成功，当前节点数：$count"
                fi
            else
                log WARN "订阅 $p 刷新成功，但无法查询节点数（订阅缓存文件缺失）"
            fi
        else
            log WARN "订阅 $p 刷新失败 (HTTP $code)，保留旧订阅缓存"
        fi
    done
}

do_full() {
    do_refresh

    local stage="/etc/mihomo/.update-stage"
    local backup="/etc/mihomo/backup"
    rm -rf "$stage"
    mkdir -p "$stage" "$backup"

    local geo_staged=0 geo_failed=0
    local ui_staged=0 kernel_staged=0 kernel_new=""

    # --- 1. geodata 三件套：整套下载 + 逐个按官方 .sha256sum 校验 ---
    # 三件套同批次才有意义：任一失败整套放弃，绝不部分替换；
    # 与当前文件逐个比 sha256，全相同视为无更新。
    log INFO "检查 GeoIP/GeoSite/MMDB 更新..."
    local geo_remotes=("geoip.dat" "geosite.dat" "country.mmdb")
    local geo_locals=("GeoIP.dat" "GeoSite.dat" "Country.mmdb")
    local geo_changed=0 i remote local_name expected actual
    for i in 0 1 2; do
        remote="${geo_remotes[$i]}"
        local_name="${geo_locals[$i]}"
        if ! upd_fetch "$stage/$local_name" "$GEO_BASE/$remote"; then
            log ERROR "✗ $remote 下载失败（代理/直连/镜像均不可用）"
            geo_failed=1
            break
        fi
        if ! upd_fetch "$stage/$remote.sha256sum" "$GEO_BASE/$remote.sha256sum"; then
            log ERROR "✗ $remote.sha256sum 下载失败，无法校验，放弃本文件"
            geo_failed=1
            break
        fi
        expected=$(awk '{print $1}' "$stage/$remote.sha256sum")
        actual=$(sha256sum "$stage/$local_name" | awk '{print $1}')
        if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
            log ERROR "✗ $remote sha256 校验不通过（期望 $expected，实际 $actual），放弃整套 geodata 更新"
            geo_failed=1
            break
        fi
        if [ -f "/etc/mihomo/$local_name" ] \
            && [ "$(sha256sum "/etc/mihomo/$local_name" | awk '{print $1}')" != "$actual" ]; then
            geo_changed=1
        fi
        if [ ! -f "/etc/mihomo/$local_name" ]; then
            geo_changed=1
        fi
    done
    if [ "$geo_failed" -eq 0 ]; then
        if [ "$geo_changed" -eq 1 ]; then
            geo_staged=1
            log INFO "✓ geodata 新批次已下载并校验通过（待组合校验后替换）"
        else
            log INFO "geodata 已是最新批次，无需更新"
        fi
    else
        log INFO "geodata 本次不更新，继续使用当前版本"
    fi

    # --- 2. 面板 UI：下载 + 包完整性校验 + 与上次应用的包比 sha256 ---
    log INFO "检查面板 UI 更新..."
    local ui_sha=""
    if upd_fetch "$stage/ui.tgz" "$UI_URL"; then
        # 注意：不要把 tar -tzf 直接管道给 grep -q——本脚本开了 pipefail，
        # grep 命中后提前退出会让 tar 吃 SIGPIPE，整条管道被判失败。
        if tar -tzf "$stage/ui.tgz" > "$stage/ui-list.txt" 2>/dev/null \
            && grep -q 'index\.html' "$stage/ui-list.txt" \
            && ! grep -Eq '(^/|(^|/)\.\.(/|$))' "$stage/ui-list.txt"; then
            ui_sha=$(sha256sum "$stage/ui.tgz" | awk '{print $1}')
            if [ -f /etc/mihomo/.ui-asset-sha ] \
                && [ "$(cat /etc/mihomo/.ui-asset-sha)" = "$ui_sha" ]; then
                log INFO "面板 UI 已是最新，无需更新"
            else
                mkdir -p "$stage/ui-new"
                tar --no-same-owner -xzf "$stage/ui.tgz" -C "$stage/ui-new"
                ui_staged=1
                log INFO "✓ 面板 UI 新版本已下载并校验通过（待组合校验后替换）"
            fi
        else
            log ERROR "✗ 面板 UI 包校验失败（不完整或含不安全路径），本次不更新 UI"
        fi
    else
        log ERROR "✗ 面板 UI 下载失败，本次不更新 UI"
    fi

    # --- 3. mihomo 内核：有新版本才下载，双源 sha256 比对 + gzip 校验 + 新二进制实跑 -v ---
    log INFO "检查 mihomo 新版本..."
    local current latest
    current=$(mihomo -v 2>&1 | grep -oP 'v[\d.]+' | head -1 || true)
    latest=$(probe_latest_version)
    if [ -z "$latest" ]; then
        log ERROR "无法探测官方版本（代理/直连/镜像均失败），内核本次不更新"
    elif [ "$current" = "$latest" ]; then
        log INFO "内核已是最新版本 $current"
    else
        log INFO "发现新版本 $latest（当前 $current），开始下载..."
        local kernel_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest}/mihomo-linux-${BIN_ARCH}-${latest}.gz"
        if upd_fetch "$stage/mihomo.gz" "$kernel_url" \
            && gzip -t "$stage/mihomo.gz" 2>/dev/null; then
            # 双源哈希校验：官方 Release 不发布 checksum 文件，改用第二
            # 下载源的同一文件做 sha256 比对 —— 两条独立路线下载的文
            # 件哈希一致，才认为未被篡改。哈希不一致则放弃本次内核更
            # 新（不触碰正在运行的旧内核）；第二源全部不可达时降级为
            # gzip 完整性 + 版本自检，并明确记日志，不假装已校验。
            local kernel_sha1 kernel_sha2 kernel_hash_ok=1
            kernel_sha1=$(sha256sum "$stage/mihomo.gz" | awk '{print $1}')
            if upd_fetch_secondary "$stage/mihomo-2nd.gz" "$kernel_url"; then
                kernel_sha2=$(sha256sum "$stage/mihomo-2nd.gz" | awk '{print $1}')
                rm -f "$stage/mihomo-2nd.gz"
                if [ "$kernel_sha1" != "$kernel_sha2" ]; then
                    log ERROR "新内核双源 sha256 不一致（首选源 $kernel_sha1，第二源 $kernel_sha2），可能遭遇篡改或损坏，放弃内核更新"
                    kernel_hash_ok=0
                else
                    log INFO "新内核双源 sha256 一致（$kernel_sha1），校验通过"
                fi
            else
                log WARN "第二下载源全部不可达，无法做双源哈希比对；内核校验降级为 gzip 完整性 + 版本自检"
            fi
            if [ "$kernel_hash_ok" -eq 1 ]; then
                gunzip -f "$stage/mihomo.gz"
                chmod +x "$stage/mihomo"
                local new_ver
                new_ver=$("$stage/mihomo" -v 2>&1 | grep -oP 'v[\d.]+' | head -1 || true)
                if [ "$new_ver" = "$latest" ]; then
                    kernel_staged=1
                    kernel_new="$latest"
                    log INFO "内核 $latest 已下载并通过完整性/版本校验（待组合校验后替换）"
                else
                    log ERROR "新内核二进制版本自检异常（期望 $latest，实际 '${new_ver:-无输出}'），放弃内核更新"
                fi
            fi
        else
            log ERROR "内核 $latest 下载或完整性校验失败，保持当前版本 $current"
        fi
    fi

    # --- 4. 无任何可用更新：收尾退出，不重启 ---
    if [ "$geo_staged" -eq 0 ] && [ "$ui_staged" -eq 0 ] && [ "$kernel_staged" -eq 0 ]; then
        log INFO "本次无可用更新，服务保持现状"
        rm -rf "$stage"
        find /var/log -maxdepth 1 -name "mihomo*.log" -mtime +30 -delete 2>/dev/null
        journalctl --vacuum-time=30d >/dev/null 2>&1
        return 0
    fi

    # --- 5. 组合校验：用"将要生效的组合"跑一遍 mihomo -t ---
    # 把当前配置拷到暂存区，换上待更新的 geodata（没更新的用当前版补齐），
    # 内核用待更新的新二进制（没更新则用当前二进制）。校验不过，全部放弃，
    # 正在运行的服务与文件一个都不动。
    log INFO "对待更新组合做配置校验 (mihomo -t)..."
    local vdir="$stage/validate"
    mkdir -p "$vdir/ui"
    cp /etc/mihomo/config.yaml "$vdir/config.yaml"
    [ -d /etc/mihomo/providers ] && cp -r /etc/mihomo/providers "$vdir/providers"
    # external-ui 必须是 -d 目录的子路径，否则 -t 直接报错（与真实安装一致处理）
    sed -i "s|^external-ui:.*|external-ui: $vdir/ui|" "$vdir/config.yaml"
    for local_name in GeoIP.dat GeoSite.dat Country.mmdb; do
        if [ -f "$stage/$local_name" ] && [ "$geo_staged" -eq 1 ]; then
            cp "$stage/$local_name" "$vdir/$local_name"
        elif [ -f "/etc/mihomo/$local_name" ]; then
            cp "/etc/mihomo/$local_name" "$vdir/$local_name"
        fi
    done
    local vbin="/usr/local/bin/mihomo"
    [ "$kernel_staged" -eq 1 ] && vbin="$stage/mihomo"
    if ! "$vbin" -t -d "$vdir" > "$stage/config-test.log" 2>&1; then
        log ERROR "✗ 配置校验未通过，放弃本次全部更新（当前版本保持不变）。校验输出："
        tail -n 20 "$stage/config-test.log" | while IFS= read -r line; do log INFO "  $line"; done
        rm -rf "$stage"
        return 1
    fi
    log INFO "✓ 组合配置校验通过"

    # --- 6. dry-run：只报告，不替换、不重启 ---
    if [ "$DRY_RUN" -eq 1 ]; then
        log INFO "[dry-run] 将更新：$([ "$geo_staged" -eq 1 ] && echo 'geodata ')$( [ "$ui_staged" -eq 1 ] && echo '面板UI ')$( [ "$kernel_staged" -eq 1 ] && echo "内核->$kernel_new" )"
        log INFO "[dry-run] 未替换任何文件、未重启服务"
        rm -rf "$stage"
        return 0
    fi

    # --- 7. 备份当前可用版本（回滚源），再原子替换 ---
    log INFO "备份当前版本到 $backup ..."
    rm -f "$backup"/*.absent 2>/dev/null || true
    for local_name in GeoIP.dat GeoSite.dat Country.mmdb; do
        if [ -f "/etc/mihomo/$local_name" ]; then
            cp "/etc/mihomo/$local_name" "$backup/$local_name"
        else
            # 记下“原本不存在”：回滚时要删掉新放进去的，而不是留着它
            touch "$backup/$local_name.absent"
        fi
    done
    cp /usr/local/bin/mihomo "$backup/mihomo"
    if [ -d /etc/mihomo/ui ]; then
        rm -rf "$backup/ui.prev"
        cp -r /etc/mihomo/ui "$backup/ui.prev"
    else
        touch "$backup/ui.absent"
    fi
    # UI 资产目录与其 SHA 记录属于同一更新事务，回滚时必须一并恢复。
    if [ -f /etc/mihomo/.ui-asset-sha ]; then
        cp -p /etc/mihomo/.ui-asset-sha "$backup/ui-asset-sha.prev"
    else
        touch "$backup/ui-asset-sha.absent"
    fi

    if [ "$geo_staged" -eq 1 ]; then
        # stage 与目标同在 /etc/mihomo 下，mv 为同文件系统原子改名
        for local_name in GeoIP.dat GeoSite.dat Country.mmdb; do
            mv "$stage/$local_name" "/etc/mihomo/$local_name"
        done
        log INFO "✓ geodata 已替换为新批次"
    fi
    if [ "$ui_staged" -eq 1 ]; then
        rm -rf /etc/mihomo/ui.old
        [ -d /etc/mihomo/ui ] && mv /etc/mihomo/ui /etc/mihomo/ui.old
        mv "$stage/ui-new" /etc/mihomo/ui
        rm -rf /etc/mihomo/ui.old
        echo "$ui_sha" > /etc/mihomo/.ui-asset-sha
        log INFO "✓ 面板 UI 已替换"
    fi
    if [ "$kernel_staged" -eq 1 ]; then
        # 先落到目标同目录再改名，保证替换原子性
        cp "$stage/mihomo" /usr/local/bin/mihomo.new
        chmod +x /usr/local/bin/mihomo.new
        mv /usr/local/bin/mihomo.new /usr/local/bin/mihomo
        log INFO "✓ 内核已替换为 $kernel_new"
    fi

    # --- 8. 重启 + 健康检查，不过则自动回滚 ---
    log INFO "重启服务使更新生效..."
    systemctl restart mihomo
    if wait_healthy; then
        log INFO "✓ 健康检查通过，更新完成（geodata:$geo_staged UI:$ui_staged 内核:${kernel_new:-不变}）"
        verify_network_rules || true
        rm -rf "$stage"
        find /var/log -maxdepth 1 -name "mihomo*.log" -mtime +30 -delete 2>/dev/null
        journalctl --vacuum-time=30d >/dev/null 2>&1
        log INFO "旧日志清理完成"
        return 0
    fi

    log ERROR "✗ 更新后健康检查未通过，自动回滚到上一份可用版本..."
    for local_name in GeoIP.dat GeoSite.dat Country.mmdb; do
        if [ -f "$backup/$local_name.absent" ]; then
            rm -f "/etc/mihomo/$local_name"
        elif [ -f "$backup/$local_name" ]; then
            cp "$backup/$local_name" "/etc/mihomo/$local_name"
        fi
    done
    cp "$backup/mihomo" /usr/local/bin/mihomo
    chmod +x /usr/local/bin/mihomo
    if [ -f "$backup/ui.absent" ]; then
        rm -rf /etc/mihomo/ui
    elif [ -d "$backup/ui.prev" ]; then
        rm -rf /etc/mihomo/ui
        cp -r "$backup/ui.prev" /etc/mihomo/ui
    fi
    if [ -f "$backup/ui-asset-sha.absent" ]; then
        rm -f /etc/mihomo/.ui-asset-sha
    elif [ -f "$backup/ui-asset-sha.prev" ]; then
        cp -p "$backup/ui-asset-sha.prev" /etc/mihomo/.ui-asset-sha
    fi
    systemctl restart mihomo
    if wait_healthy; then
        log INFO "✓ 已回滚并恢复正常（上一份可用版本）"
        verify_network_rules || true
    else
        log ERROR "✗ 回滚后仍未恢复，需要人工介入！"
    fi
    rm -rf "$stage"
    return 1
}

# 并发锁：与安装 / 卸载 / 切换订阅 / 恢复共用同一把全局锁，同一时刻
# 只允许一个任务修改系统；cron 调用与手动运行可能撞车，拿不到锁说明
# 已有安装/卸载/维护在跑，本次直接跳过（不算错误，下个周期再来）。
exec 9>"/var/lock/mihomo-gateway.lock"
if ! flock -n 9; then
    log INFO "已有安装/卸载/维护任务在运行，本次跳过"
    exit 0
fi

log INFO "--- 开始执行 ($MODE) ---"
RC=0
case "$MODE" in
    check)   do_check ;;
    refresh) do_refresh ;;
    full)    do_full; RC=$? ;;
    *)       log ERROR "未知模式: $MODE（可选 check|refresh|full）"; exit 1 ;;
esac
log INFO "--- 执行完成 ---"
exit $RC
