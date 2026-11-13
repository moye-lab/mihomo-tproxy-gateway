#!/bin/bash
# 安全更换机场订阅链接
#
# 用法:
#   sudo bash /tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh <新的订阅链接>
#   sudo bash /tmp/mihomo-tproxy-gateway/scripts/switch-sub.sh   # 不带参数会交互式询问
#
# 只处理 airport1 这一个 provider（目前项目本身只支持单机场，见 README
# "已知限制"）。设计上刻意不用 sed 笼统匹配 "url:" 这个关键字去替换——
# config.yaml 里 health-check 探测地址、url-test 代理组测速地址都叫这个
# 名字，笼统匹配容易改错行。这里改用缩进层级去精确定位：只有
# proxy-providers.airport1 正下方（4 个空格缩进）的 url 字段会被替换，
# health-check 里嵌套更深（6 个空格缩进）的 url 不会被碰。

set -e

# 颜色定义
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 统一日志接口（P1-16，五脚本同一约定：[时间] [级别] [阶段] 消息）：
#   log <级别> <消息>      级别：INFO / WARN / ERROR
# 终端按级别着色；本脚本不写日志文件（输出即终端所见）。
# 脱敏：订阅链接只打码显示（协议+主机+****），完整链接不输出。
log() {
    local _level="$1"; shift
    local _color="$NC"
    case "$_level" in
        INFO)  _color="$BLUE" ;;
        WARN)  _color="$YELLOW" ;;
        ERROR) _color="$RED" ;;
    esac
    printf '%b[%s] [%s] [换订阅] %s%b\n' "$_color" "$(date '+%Y-%m-%d %H:%M:%S')" "$_level" "$*" "$NC"
}

CONFIG=/etc/mihomo/config.yaml
CACHE=/etc/mihomo/providers/airport1.yaml

# API 就绪轮询次数：重启后等 API 真正就绪才算切换成功（默认 30 次 ×
# 1 秒，与 install.sh 的回滚轮询同量级）；环境变量覆盖只供测试用。
SWITCH_API_TRIES="${SWITCH_API_TRIES:-30}"
case "$SWITCH_API_TRIES" in ''|*[!0-9]*) SWITCH_API_TRIES=30 ;; esac

# 从 config.yaml 提取面板 secret：双引号、单引号、无引号三种写法都认，
# 只取引号内的值（与 install.sh / verify.sh 的 extract_secret 同一条规则）。
extract_secret() { # extract_secret <config.yaml>
    grep -E '^secret:' "$1" 2>/dev/null | head -1 \
        | sed -E 's/^secret:[[:space:]]*"([^"]*)".*/\1/; s/^secret:[[:space:]]*'"'"'([^'"'"']*)'"'"'.*/\1/; s/^secret:[[:space:]]*([^"[:space:]]+).*/\1/' || true
}

# 从 config.yaml 取面板 API 的本机访问地址：读 external-controller 的
# 监听地址；0.0.0.0 监听全部接口时本机走 127.0.0.1；无配置行或解析
# 失败时默认 127.0.0.1（mihomo 未写 external-controller 时的默认监听）。
# LAN 模式只绑 LAN IP 时 127.0.0.1:9090 根本不监听，本机 API 必须走监
# 听地址本身，硬编码 127.0.0.1 会误报 API 未就绪（第二轮第 2 项）。
# 与 install.sh / verify.sh / restore.sh 的 panel_api_host 同一条规则。
panel_api_host() { # panel_api_host <config.yaml>
    local _listen=""
    _listen=$(grep -E '^external-controller:' "$1" 2>/dev/null | head -1 | sed -E 's/^external-controller:[[:space:]]*([^:]+):.*/\1/' || true)
    case "$_listen" in
        ""|"0.0.0.0") printf '127.0.0.1' ;;
        *) printf '%s' "$_listen" ;;
    esac
}

# API 就绪轮询（至多 SWITCH_API_TRIES 秒）：复用 install.sh 的
# rollback_api_ready 模式——secret 取自当前配置（回滚后是恢复的旧配置），
# 每次同时确认服务在跑与 /version 可达。返回 0 表示 API 可达。
switch_api_ready() {
    local _secret=""
    local _i
    local _auth=()
    local API
    API="http://$(panel_api_host /etc/mihomo/config.yaml):9090"
    if [ -f /etc/mihomo/config.yaml ]; then
        _secret=$(extract_secret /etc/mihomo/config.yaml)
        [ "$_secret" = "CHANGE_ME_SECRET" ] && _secret=""
    fi
    [ -n "$_secret" ] && _auth=(-H "Authorization: Bearer $_secret")
    # --noproxy：本机 API 不走代理——curl 默认连 127.0.0.1 也发给 https_proxy，
    # 代理到不了本机端口（2026-11-13 真机实测：回滚轮询因此 30 秒全败误报）。
    for _i in $(seq 1 "$SWITCH_API_TRIES"); do
        if systemctl is-active --quiet mihomo 2>/dev/null \
            && curl --noproxy '*' -s -m 3 "${_auth[@]}" "$API/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 切换回滚：恢复旧配置与旧缓存，重启服务并验证 API 就绪；任一步失败
# 都如实报告，不假装恢复成功。返回 0 表示回滚完成且服务已恢复就绪，
# 返回 1 表示回滚未完全成功（调用方须如实报告并 exit 1）。
# 注意：本函数内所有可能失败的命令都显式处理返回码，不依赖 set -e。
rollback_switch() {
    local _ok=1
    if cp "$BACKUP" "$CONFIG"; then
        log INFO "✓ 已恢复旧配置"
    else
        log ERROR "✗ 旧配置恢复失败，备份仍在 $BACKUP，请手动恢复"
        _ok=0
    fi
    if [ -n "${CACHE_BACKUP:-}" ] && [ -f "$CACHE_BACKUP" ]; then
        if cp "$CACHE_BACKUP" "$CACHE"; then
            log INFO "✓ 已恢复旧节点缓存"
        else
            log ERROR "✗ 旧节点缓存恢复失败，备份仍在 $CACHE_BACKUP，请手动恢复"
            _ok=0
        fi
    fi
    if systemctl restart mihomo; then
        log INFO "✓ 服务已重启"
    else
        log ERROR "✗ 回滚后服务重启失败，请检查 systemctl status mihomo 与 journalctl -u mihomo"
        return 1
    fi
    if switch_api_ready; then
        log INFO "✓ 回滚后服务已恢复就绪（API 可达）"
    else
        log ERROR "✗ 回滚后服务已重启，但 API 在 ${SWITCH_API_TRIES} 秒内未就绪，请检查 journalctl -u mihomo"
        _ok=0
    fi
    [ "$_ok" -eq 1 ]
}

if [ "$(id -u)" -ne 0 ]; then
    log ERROR "必须使用 root 权限运行此脚本（配置文件和服务都需要 root）。"
    exit 1
fi

# 全局并发锁：与安装 / 卸载 / 恢复 / 自动维护共用同一把锁，
# 同一时刻只允许一个任务修改系统；拿不到锁说明已有任务在跑，直接退出。
LOCK_FILE="/var/lock/mihomo-gateway.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log ERROR "另一个安装/卸载/切换订阅/恢复/维护任务正在运行（锁文件 $LOCK_FILE），请等待它完成后再试。"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    log ERROR "未找到 $CONFIG，看起来还没有安装过，请先运行仓库里的 install.sh 完成安装。"
    exit 1
fi

NEW_URL="${1:-}"
if [ -z "$NEW_URL" ]; then
    read -r -p "请输入新的机场订阅链接: " NEW_URL
fi

if [[ "$NEW_URL" != http://* && "$NEW_URL" != https://* ]]; then
    log ERROR "订阅链接看起来不对，应该以 http:// 或 https:// 开头。"
    exit 1
fi

# URL 将写入双引号 YAML 字符串。拒绝引号、反斜杠和控制字符，避免
# 订阅链接意外破坏 YAML 结构；常见的 &、=、?、%、+ 等查询参数仍允许。
if [[ "$NEW_URL" == *'"'* || "$NEW_URL" == *\\* || "$NEW_URL" == *$'\n'* || "$NEW_URL" == *$'\r'* || "$NEW_URL" == *$'\t'* ]]; then
    log ERROR "订阅链接包含 YAML 字符串不支持的引号、反斜杠或控制字符。"
    exit 1
fi

# 1. 先备份，任何一步出错都能立刻恢复
BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONFIG" "$BACKUP"
log INFO "✓ 已备份当前配置到 $BACKUP"
# 旧 provider 缓存同款备份（带时间戳）：重启失败回滚时要恢复它。
# 缓存路径固定为 /etc/mihomo/providers/airport1.yaml（本项目只支持
# 单机场 airport1，见文件头注释）。切换前从未成功拉取过订阅时缓存
# 文件不存在，无备份可做，回滚时跳过缓存恢复。
CACHE_BACKUP=""
if [ -f "$CACHE" ]; then
    CACHE_BACKUP="${CACHE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CACHE" "$CACHE_BACKUP"
    log INFO "✓ 已备份旧节点缓存到 $CACHE_BACKUP"
fi

# 2. 精确替换：只匹配 airport1 正下方 4 空格缩进的 url 行
TMP=$(mktemp)
# 自检日志也走 mktemp（600）：mihomo -t 的报错原文可能回显含订阅链接的
# 配置行，固定路径 /tmp/switch-sub-check.log 默认是 644、任何本地用户可读。
CHECK_LOG=$(mktemp)
# 兜底清理：set -e 下中途退出时，含完整配置（订阅链接与密钥）的临时文件
# 不滞留 /tmp；正常路径仍在用完后立即删除，trap 只防意外退出。
cleanup_tmp() {
    rm -f "$TMP"
    [ -n "${CHECK_LOG:-}" ] && rm -f "$CHECK_LOG"
}
trap cleanup_tmp EXIT
# 新链接经环境变量传入：awk -v 会处理值里的反斜杠转义序列，可能改坏链接；
# ENVIRON 的值是原样的。& 在本脚本是 print 拼接、不是 sub 替换，不受影响。
# 是否命中由 awk 的退出码判定：END 里没命中就 exit 1。不能把标记打到
# stderr 再去输出文件里找——那样永远找不到，未命中会被误判为成功。
if ! NEW_URL="$NEW_URL" awk '
    BEGIN { new = ENVIRON["NEW_URL"] }
    /^  airport1:[[:space:]]*$/ { in_block = 1 }
    in_block && /^    url:/ && !done {
        print "    url: \"" new "\""
        done = 1
        next
    }
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ && !/^  airport1:/ { in_block = 0 }
    { print }
    END {
        if (!done) {
            exit 1
        }
    }
' "$CONFIG" > "$TMP" || [ ! -s "$TMP" ]; then
    log ERROR "未能在 config.yaml 里找到 proxy-providers.airport1.url 这一行，"
    log ERROR "可能是配置结构被手动改动过。没有对原文件做任何修改，已备份文件可以删除："
    log ERROR "  rm -f $BACKUP"
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$CONFIG"
log INFO "✓ 已将订阅链接更新为: $(echo "$NEW_URL" | sed -E 's#^(https?://[^/]+/).*#\1****#')"

# 3. 语法自查，失败立刻回滚，不让坏配置留在系统里
if ! mihomo -t -d /etc/mihomo >"$CHECK_LOG" 2>&1; then
    log ERROR "✗ 新配置语法校验失败，自动回滚到修改前的版本："
    cat "$CHECK_LOG"
    rm -f "$CHECK_LOG"
    cp "$BACKUP" "$CONFIG"
    log INFO "已回滚，配置未受影响。"
    exit 1
fi
log INFO "✓ 语法校验通过"
rm -f "$CHECK_LOG"

# 4. 重启服务生效；重启失败或 API 未就绪时回滚旧配置与缓存。
# systemctl restart 返回 0 只说明启动命令已下达，mihomo 随后可能崩溃
# 循环或 API 始终未就绪，必须等 API 真正就绪才算切换成功（install.sh
# 同款假阳性教训：服务崩溃循环时 sleep 完照样打印"成功"最难查）。
if ! systemctl restart mihomo; then
    log ERROR "✗ mihomo 重启失败，自动回滚到修改前的配置与缓存："
    if rollback_switch; then
        log INFO "已回滚，旧配置与旧缓存已恢复，服务已恢复运行。"
    else
        log ERROR "✗ 回滚未完全成功，请按上面的提示手动检查并恢复。"
    fi
    exit 1
fi
if ! switch_api_ready; then
    log ERROR "✗ mihomo 重启后 API 在 ${SWITCH_API_TRIES} 秒内未就绪，自动回滚到修改前的配置与缓存："
    if rollback_switch; then
        log INFO "已回滚，旧配置与旧缓存已恢复，服务已恢复运行。"
    else
        log ERROR "✗ 回滚未完全成功，请按上面的提示手动检查并恢复。"
    fi
    exit 1
fi

# 5. 切换已确认成功（服务在跑且 API 就绪），再清旧缓存：重启失败时
# 旧缓存仍在原处（且有备份），回滚有东西可恢复。mihomo 重启后可能已
# 拉到新订阅并覆写缓存文件——内容已与备份不同说明是新缓存，留着不删，
# 只删内容仍与备份一致的旧缓存。
if [ -f "$CACHE" ]; then
    if [ -n "$CACHE_BACKUP" ] && [ -f "$CACHE_BACKUP" ] && cmp -s "$CACHE" "$CACHE_BACKUP"; then
        rm -f "$CACHE"
        log INFO "✓ 已清理旧的节点缓存 ($CACHE)"
    else
        log INFO "节点缓存已由新订阅刷新或为重启后新拉取，已保留 ($CACHE)"
    fi
fi

log INFO "✓ mihomo 已重启，新订阅生效（API 已就绪）"

echo ""
echo "可以去面板确认节点列表: http://<本机IP>:9090/ui"
