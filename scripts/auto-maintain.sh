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
#   (127.0.0.1:7890) 拉官方源，其次直连，再次 gh-proxy 镜像。
#   新文件先落到暂存区，逐个校验（geodata 用官方 .sha256sum、内核
#   gzip 完整性 + 新二进制实跑 -v、UI 包完整性），再用待更新的组合跑一遍
#   mihomo -t 配置校验，全部通过才原子替换；替换后轮询 API 做健康检查，
#   不过就自动回滚到上一份可用版本。坏更新永远不会覆盖正在用的好文件。

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
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$MODE] $1"; }

# 读取 install.sh 生成的运行环境（API 地址、鉴权 secret、订阅 provider 名、架构）
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
API="${API:-http://127.0.0.1:9090}"
API_SECRET="${API_SECRET:-}"
PROVIDERS="${PROVIDERS:-airport1}"
BIN_ARCH="${BIN_ARCH:-amd64}"

AUTH_HEADER=()
[ -n "$API_SECRET" ] && AUTH_HEADER=(-H "Authorization: Bearer $API_SECRET")

LOCAL_PROXY="http://127.0.0.1:7890"
GEO_BASE="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
UI_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

# 更新专用下载入口：本地代理 -> 直连 -> gh-proxy 镜像，逐个尝试。
# 用法: upd_fetch <输出文件> <官方URL>
upd_fetch() {
    local out="$1" url="$2"
    if https_proxy="$LOCAL_PROXY" http_proxy="$LOCAL_PROXY" wget -q -T 30 --tries=1 -O "$out" "$url"; then
        log "下载成功（经本地代理）: $url"
        return 0
    fi
    if wget -q -T 30 --tries=2 -O "$out" "$url"; then
        log "下载成功（直连）: $url"
        return 0
    fi
    if wget -q -T 30 --tries=2 -O "$out" "https://gh-proxy.com/${url}"; then
        log "下载成功（gh-proxy 镜像）: $url"
        return 0
    fi
    rm -f "$out"
    return 1
}

# 探测 mihomo 最新官方版本号：本地代理 -> 直连 -> gh-proxy，任一成功即可
probe_latest_version() {
    local out=""
    out=$(curl -x "$LOCAL_PROXY" -m 15 -s "$MIHOMO_API" | grep '"tag_name"' | grep -oP 'v[\d.]+' | head -1 || true)
    [ -z "$out" ] && out=$(curl -m 15 -s "$MIHOMO_API" | grep '"tag_name"' | grep -oP 'v[\d.]+' | head -1 || true)
    [ -z "$out" ] && out=$(curl -m 15 -s "https://gh-proxy.com/${MIHOMO_API}" | grep '"tag_name"' | grep -oP 'v[\d.]+' | head -1 || true)
    echo "$out"
}

# 健康检查：服务 active 且 API /version 可达，轮询至多 30 秒
wait_healthy() {
    local i
    for i in $(seq 1 30); do
        if systemctl is-active --quiet mihomo 2>/dev/null \
            && curl -s -m 3 "${AUTH_HEADER[@]}" "$API/version" >/dev/null 2>&1; then
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
        log "✗ $reason；但距上次重启不足 $((CHECK_RESTART_COOLDOWN / 60)) 分钟（冷却中），跳过重启，需要人工介入"
        return 1
    fi
    log "⚠️ $reason，重启 mihomo 服务..."
    echo "$now" > "$CHECK_RESTART_FILE" 2>/dev/null || true
    rm -f "$CHECK_FAIL_FILE"
    systemctl restart mihomo
    if wait_healthy; then
        log "✓ 重启后服务恢复"
    else
        log "✗ 重启后仍异常，需要人工介入"
    fi
}

do_check() {
    # 1) 进程与本地 API：这是内核本身的健康，异常直接走重启（仍受冷却保护）
    if ! systemctl is-active --quiet mihomo 2>/dev/null; then
        maint_restart "mihomo 服务未运行"
        return
    fi
    if ! curl -s -m 3 "${AUTH_HEADER[@]}" "$API/version" >/dev/null 2>&1; then
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
        log "✓ 服务正常，代理连通性正常"
        return
    fi
    # 3) 探测失败先计数：单次失败可能只是外部网络抖动，连续 2 次才重启
    local fails=0
    [ -f "$CHECK_FAIL_FILE" ] && fails=$(cat "$CHECK_FAIL_FILE" 2>/dev/null || echo 0)
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    fails=$((fails + 1))
    echo "$fails" > "$CHECK_FAIL_FILE" 2>/dev/null || true
    if [ "$fails" -lt 2 ]; then
        log "⚠️ 代理连通性探测失败（第 $fails 次），暂不重启，下个周期复查"
        return
    fi
    maint_restart "代理连通性连续 $fails 次探测失败"
}

do_refresh() {
    for p in $PROVIDERS; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_HEADER[@]}" -X PUT "$API/providers/proxies/$p")
        if [ "$code" = "204" ]; then
            log "订阅 $p 刷新成功"
        else
            log "订阅 $p 刷新失败 (HTTP $code)"
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
    log "检查 GeoIP/GeoSite/MMDB 更新..."
    local geo_remotes=("geoip.dat" "geosite.dat" "country.mmdb")
    local geo_locals=("GeoIP.dat" "GeoSite.dat" "Country.mmdb")
    local geo_changed=0 i remote local_name expected actual
    for i in 0 1 2; do
        remote="${geo_remotes[$i]}"
        local_name="${geo_locals[$i]}"
        if ! upd_fetch "$stage/$local_name" "$GEO_BASE/$remote"; then
            log "✗ $remote 下载失败（代理/直连/镜像均不可用）"
            geo_failed=1
            break
        fi
        if ! upd_fetch "$stage/$remote.sha256sum" "$GEO_BASE/$remote.sha256sum"; then
            log "✗ $remote.sha256sum 下载失败，无法校验，放弃本文件"
            geo_failed=1
            break
        fi
        expected=$(awk '{print $1}' "$stage/$remote.sha256sum")
        actual=$(sha256sum "$stage/$local_name" | awk '{print $1}')
        if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
            log "✗ $remote sha256 校验不通过（期望 $expected，实际 $actual），放弃整套 geodata 更新"
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
            log "✓ geodata 新批次已下载并校验通过（待组合校验后替换）"
        else
            log "geodata 已是最新批次，无需更新"
        fi
    else
        log "geodata 本次不更新，继续使用当前版本"
    fi

    # --- 2. 面板 UI：下载 + 包完整性校验 + 与上次应用的包比 sha256 ---
    log "检查面板 UI 更新..."
    local ui_sha=""
    if upd_fetch "$stage/ui.tgz" "$UI_URL"; then
        # 注意：不要把 tar -tzf 直接管道给 grep -q——本脚本开了 pipefail，
        # grep 命中后提前退出会让 tar 吃 SIGPIPE，整条管道被判失败。
        if tar -tzf "$stage/ui.tgz" > "$stage/ui-list.txt" 2>/dev/null \
            && grep -q 'index\.html' "$stage/ui-list.txt"; then
            ui_sha=$(sha256sum "$stage/ui.tgz" | awk '{print $1}')
            if [ -f /etc/mihomo/.ui-asset-sha ] \
                && [ "$(cat /etc/mihomo/.ui-asset-sha)" = "$ui_sha" ]; then
                log "面板 UI 已是最新，无需更新"
            else
                mkdir -p "$stage/ui-new"
                tar --no-same-owner -xzf "$stage/ui.tgz" -C "$stage/ui-new"
                ui_staged=1
                log "✓ 面板 UI 新版本已下载并校验通过（待组合校验后替换）"
            fi
        else
            log "✗ 面板 UI 包完整性校验失败，本次不更新 UI"
        fi
    else
        log "✗ 面板 UI 下载失败，本次不更新 UI"
    fi

    # --- 3. mihomo 内核：有新版本才下载，gzip 校验 + 新二进制实跑 -v ---
    log "检查 mihomo 新版本..."
    local current latest
    current=$(mihomo -v 2>&1 | grep -oP 'v[\d.]+' | head -1 || true)
    latest=$(probe_latest_version)
    if [ -z "$latest" ]; then
        log "✗ 无法探测官方版本（代理/直连/镜像均失败），内核本次不更新"
    elif [ "$current" = "$latest" ]; then
        log "内核已是最新版本 $current"
    else
        log "发现新版本 $latest（当前 $current），开始下载..."
        local kernel_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest}/mihomo-linux-${BIN_ARCH}-${latest}.gz"
        if upd_fetch "$stage/mihomo.gz" "$kernel_url" \
            && gzip -t "$stage/mihomo.gz" 2>/dev/null; then
            gunzip -f "$stage/mihomo.gz"
            chmod +x "$stage/mihomo"
            local new_ver
            new_ver=$("$stage/mihomo" -v 2>&1 | grep -oP 'v[\d.]+' | head -1 || true)
            if [ "$new_ver" = "$latest" ]; then
                kernel_staged=1
                kernel_new="$latest"
                log "✓ 内核 $latest 已下载并通过完整性/版本校验（待组合校验后替换）"
            else
                log "✗ 新内核二进制版本自检异常（期望 $latest，实际 '${new_ver:-无输出}'），放弃内核更新"
            fi
        else
            log "✗ 内核 $latest 下载或完整性校验失败，保持当前版本 $current"
        fi
    fi

    # --- 4. 无任何可用更新：收尾退出，不重启 ---
    if [ "$geo_staged" -eq 0 ] && [ "$ui_staged" -eq 0 ] && [ "$kernel_staged" -eq 0 ]; then
        log "本次无可用更新，服务保持现状"
        rm -rf "$stage"
        find /var/log -maxdepth 1 -name "mihomo*.log" -mtime +30 -delete 2>/dev/null
        journalctl --vacuum-time=30d >/dev/null 2>&1
        return 0
    fi

    # --- 5. 组合校验：用"将要生效的组合"跑一遍 mihomo -t ---
    # 把当前配置拷到暂存区，换上待更新的 geodata（没更新的用当前版补齐），
    # 内核用待更新的新二进制（没更新则用当前二进制）。校验不过，全部放弃，
    # 正在运行的服务与文件一个都不动。
    log "对待更新组合做配置校验 (mihomo -t)..."
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
        log "✗ 配置校验未通过，放弃本次全部更新（当前版本保持不变）。校验输出："
        tail -n 20 "$stage/config-test.log" | while IFS= read -r line; do log "  $line"; done
        rm -rf "$stage"
        return 1
    fi
    log "✓ 组合配置校验通过"

    # --- 6. dry-run：只报告，不替换、不重启 ---
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] 将更新：$([ "$geo_staged" -eq 1 ] && echo 'geodata ')$( [ "$ui_staged" -eq 1 ] && echo '面板UI ')$( [ "$kernel_staged" -eq 1 ] && echo "内核->$kernel_new" )"
        log "[dry-run] 未替换任何文件、未重启服务"
        rm -rf "$stage"
        return 0
    fi

    # --- 7. 备份当前可用版本（回滚源），再原子替换 ---
    log "备份当前版本到 $backup ..."
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

    if [ "$geo_staged" -eq 1 ]; then
        # stage 与目标同在 /etc/mihomo 下，mv 为同文件系统原子改名
        for local_name in GeoIP.dat GeoSite.dat Country.mmdb; do
            mv "$stage/$local_name" "/etc/mihomo/$local_name"
        done
        log "✓ geodata 已替换为新批次"
    fi
    if [ "$ui_staged" -eq 1 ]; then
        rm -rf /etc/mihomo/ui.old
        [ -d /etc/mihomo/ui ] && mv /etc/mihomo/ui /etc/mihomo/ui.old
        mv "$stage/ui-new" /etc/mihomo/ui
        rm -rf /etc/mihomo/ui.old
        echo "$ui_sha" > /etc/mihomo/.ui-asset-sha
        log "✓ 面板 UI 已替换"
    fi
    if [ "$kernel_staged" -eq 1 ]; then
        # 先落到目标同目录再改名，保证替换原子性
        cp "$stage/mihomo" /usr/local/bin/mihomo.new
        chmod +x /usr/local/bin/mihomo.new
        mv /usr/local/bin/mihomo.new /usr/local/bin/mihomo
        log "✓ 内核已替换为 $kernel_new"
    fi

    # --- 8. 重启 + 健康检查，不过则自动回滚 ---
    log "重启服务使更新生效..."
    systemctl restart mihomo
    if wait_healthy; then
        log "✓ 健康检查通过，更新完成（geodata:$geo_staged UI:$ui_staged 内核:${kernel_new:-不变}）"
        rm -rf "$stage"
        find /var/log -maxdepth 1 -name "mihomo*.log" -mtime +30 -delete 2>/dev/null
        journalctl --vacuum-time=30d >/dev/null 2>&1
        log "旧日志清理完成"
        return 0
    fi

    log "✗ 更新后健康检查未通过，自动回滚到上一份可用版本..."
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
    systemctl restart mihomo
    if wait_healthy; then
        log "✓ 已回滚并恢复正常（上一份可用版本）"
    else
        log "✗ 回滚后仍未恢复，需要人工介入！"
    fi
    rm -rf "$stage"
    return 1
}

# 并发锁：cron 调用与手动运行可能撞车，同一时刻只允许一个维护进程；
# 拿不到锁说明已有维护在跑，本次直接跳过（不算错误）。
exec 9>"/var/lock/mihomo-maintain.lock"
if ! flock -n 9; then
    log "已有维护进程在运行，本次跳过"
    exit 0
fi

log "--- 开始执行 ($MODE) ---"
RC=0
case "$MODE" in
    check)   do_check ;;
    refresh) do_refresh ;;
    full)    do_full; RC=$? ;;
    *)       log "未知模式: $MODE（可选 check|refresh|full）"; exit 1 ;;
esac
log "--- 执行完成 ---"
exit $RC
