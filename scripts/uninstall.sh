#!/bin/bash
# Mihomo 旁路由自动化卸载与清理脚本
#
# 用法:
#   uninstall.sh              默认「彻底清理」—— 适合反复安装测试的场景，
#                              保证下次 install.sh 是真正从零开始，不会被
#                              旧配置/旧缓存/旧数据库干扰。
#   uninstall.sh --keep-config     只停服务、清路由规则、清 cron，
#                              保留 /etc/mihomo（包括订阅链接和 secret），
#                              适合只是想临时下线、之后原样恢复的场景。
#                              恢复时运行同目录的 restore.sh 一键恢复。
#   uninstall.sh --stop-only       仅停服务（并禁用开机自启）、清路由规则、
#                              清 cron，保留全部文件（配置、二进制、服务
#                              文件一个都不删）。恢复时运行 restore.sh，
#                              或手动 systemctl enable --now mihomo。
#
# 注意：此脚本只清理"安装到系统里"的文件（/etc/mihomo、systemd、cron 等），
# 不会删除 git clone 下来的项目源码目录本身。脚本自己删自己所在的目录这种
# 写法不可靠（执行到一半文件被删，行为依赖 bash 的具体读取实现），所以不
# 在脚本里做这件事。脚本跑完之后会打印一条现成的命令，如果你想连源码目录
# 也删掉，自己确认后手动执行即可。

set -e

# 颜色定义
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 统一日志接口（P1-16，五脚本同一约定：[时间] [级别] [阶段] 消息）：
#   log <级别> <消息>      级别：INFO / WARN / ERROR
# 终端按级别着色；本脚本不写日志文件（输出即终端所见）。
# 卸载计划与最终汇总属交互展示类输出，保留 echo。
log() {
    local _level="$1"; shift
    local _color="$NC"
    case "$_level" in
        INFO)  _color="$BLUE" ;;
        WARN)  _color="$YELLOW" ;;
        ERROR) _color="$RED" ;;
    esac
    printf '%b[%s] [%s] [卸载] %s%b\n' "$_color" "$(date '+%Y-%m-%d %H:%M:%S')" "$_level" "$*" "$NC"
}

# 脚本所在目录（支持从任意目录调用；解析物理路径，防符号链接下锚错目录）
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

KEEP_CONFIG=false
STOP_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=true ;;
        --stop-only)   STOP_ONLY=true ;;
        *) log WARN "忽略未知参数: $arg（可用参数：--keep-config --stop-only）" ;;
    esac
done
# 同时给出两个参数时，以破坏最小的 --stop-only 为准。
MODE="full"
if [ "$STOP_ONLY" = true ]; then
    MODE="stop-only"
elif [ "$KEEP_CONFIG" = true ]; then
    MODE="keep-config"
fi

if [ "$(id -u)" -ne 0 ]; then
    log ERROR "必须使用 root 权限运行此脚本（服务、规则与系统文件都需要 root）。"
    exit 1
fi

# 全局并发锁：与安装 / 切换订阅 / 恢复 / 自动维护共用同一把锁，
# 同一时刻只允许一个任务修改系统；拿不到锁说明已有任务在跑，直接退出。
LOCK_FILE="/var/lock/mihomo-gateway.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log ERROR "另一个安装/卸载/切换订阅/恢复/维护任务正在运行（锁文件 $LOCK_FILE），请等待它完成后再试。"
    exit 1
fi

# 清理本项目 TPROXY/DNS 规则与策略路由：调用仓库 tproxy.sh 的
# stop 模式（自带归属校验与清理校验）。仓库版本过旧（无 STOP_MODE
# 标记）时明确拒绝，不再退回内联删除——第二轮整改（v1.2.2）决策：
# 旧内联回退副本只清 MIHOMO/MIHOMO_DNS 两条链，漏了 MIHOMO_DO /
# MIHOMO_DNS_DO / MIHOMO_V6 三条链，残留校验同样不查它们，却仍报
# "清干净"（exit 0）；且按链名无条件删链，会误删他人同名链。回退
# 副本只在"新 uninstall.sh + 旧 tproxy.sh"混用时触发，git clone 永远
# 不会出现这种组合；保留第二份清理实现只会再次漂移（本次审计的教
# 训），不如明确拒绝，让用户用一致版本重跑。返回 0 表示确认清干净。
cleanup_rules() {
    if grep -q 'STOP_MODE' "$SCRIPT_DIR/tproxy.sh" 2>/dev/null; then
        if bash "$SCRIPT_DIR/tproxy.sh" stop; then
            return 0
        fi
        return 1
    fi
    log ERROR "仓库内的 tproxy.sh 版本过旧（无 STOP_MODE 标记），无法安全清理规则；请用同一版本重新克隆仓库后再试，不要混用新旧脚本。"
    return 1
}

# 卸载计划里的一行：文件存在显示"删除"，不存在显示"跳过"，避免用户
# 对着清单找不到文件而困惑。
plan_file() {
    if [ -e "$1" ]; then
        echo "  删除：$1（$2）"
    else
        echo "  跳过：$1（不存在）"
    fi
}

case "$MODE" in
    stop-only)   MODE_NAME="仅停止（--stop-only）" ;;
    keep-config) MODE_NAME="保留配置卸载（--keep-config）" ;;
    *)           MODE_NAME="彻底清理（默认）" ;;
esac

echo "=========================================="
echo " Mihomo 旁路由卸载（模式：${MODE_NAME}）"
echo "=========================================="
echo ""
echo "卸载计划："
echo "  停止并禁用 mihomo 服务，清理本项目 TPROXY/DNS 规则与策略路由。"
case "$MODE" in
    stop-only)
        plan_file /etc/cron.d/mihomo-maintain "定时维护任务（不清除的话，15 分钟内的健康检查会自动重启服务）"
        echo "  保留：全部文件（/etc/mihomo、二进制、systemd 服务文件、日志）"
        ;;
    keep-config)
        plan_file /usr/local/bin/mihomo "内核二进制"
        plan_file /usr/local/bin/mihomo.bak "失败安装留下的旧内核备份（如有）"
        plan_file /etc/systemd/system/mihomo.service "systemd 服务文件"
        plan_file /etc/cron.d/mihomo-maintain "定时维护任务"
        echo "  删除：/tmp 下的下载缓存（mihomo.gz、ui.tgz、geodata）、安装事务残留（/tmp/mgb-*）与 UI 安装暂存目录"
        echo "  保留：/etc/mihomo（配置、订阅、密钥、面板、地数据库）"
        ;;
    *)
        plan_file /etc/mihomo "全部配置与数据"
        plan_file /usr/local/bin/mihomo "内核二进制"
        plan_file /usr/local/bin/mihomo.bak "失败安装留下的旧内核备份（如有）"
        plan_file /etc/systemd/system/mihomo.service "systemd 服务文件"
        plan_file /etc/cron.d/mihomo-maintain "定时维护任务"
        plan_file /var/log/mihomo-maintain.log "维护日志"
        plan_file /var/log/mihomo-install.log "安装日志"
        echo "  删除：/tmp 下的下载缓存（mihomo.gz、ui.tgz、geodata）、安装事务残留（/tmp/mgb-*）与 UI 安装暂存目录"
        ;;
esac
echo ""

CLEANUP_OK=1

# 1. 停止并禁用 systemd 服务
if systemctl is-active --quiet mihomo 2>/dev/null; then
    log INFO "正在停止 mihomo 服务..."
    systemctl stop mihomo
fi

if systemctl is-enabled --quiet mihomo 2>/dev/null; then
    log INFO "正在禁用 mihomo 开机自启..."
    systemctl disable mihomo
fi

# 2. 清理 systemd 服务文件（仅停止模式保留，之后恢复直接可用）
if [ "$MODE" != "stop-only" ] && [ -f /etc/systemd/system/mihomo.service ]; then
    log INFO "清理 systemd 服务文件..."
    rm -f /etc/systemd/system/mihomo.service
    systemctl daemon-reload
fi

# 3. 清理 iptables 规则与策略路由（走 tproxy.sh stop，同一条安全清理
# 路径：按 comment/指纹/归属记录验明本项目规则再删，循环删除直到不
# 存在，保证历史重复规则也不残留；他人同名链与 (fwmark 1, 表 100)
# 规则一律保留、不动）
log INFO "清理防火墙 TPROXY/DNS 规则与路由表..."
if cleanup_rules; then
    log INFO "✓ 本项目网络规则已清理干净"
else
    log WARN "本项目网络规则清理未完全成功，请检查 ip rule / iptables，手动清理残留后再确认卸载完成。"
    CLEANUP_OK=0
fi

# 4. 删除定时维护任务
# 注意：维护任务装在系统级 /etc/cron.d/mihomo-maintain，不是 root 的
# 个人 crontab，清理时认准这个文件。三种模式都要清：留着它，15 分钟
# 内的健康检查就会把刚停掉的服务自动重启。
if [ -f /etc/cron.d/mihomo-maintain ]; then
    log INFO "删除定时维护任务 (/etc/cron.d/mihomo-maintain)..."
    rm -f /etc/cron.d/mihomo-maintain
fi

# 5. 清理程序本体、配置与缓存
if [ "$MODE" = "stop-only" ]; then
    log INFO "已保留全部文件（--stop-only），仅停止服务并清理规则与定时任务。"
elif [ "$MODE" = "keep-config" ]; then
    log INFO "已保留 /etc/mihomo（--keep-config），仅清理二进制与临时文件。"
    rm -f /usr/local/bin/mihomo
    # 失败安装/维护可能留下的二进制暂存文件（.bak 是回滚失败时保留的旧
    # 内核备份，.new/.restoring 是原子替换的中途产物），一并清掉。
    rm -f /usr/local/bin/mihomo.bak /usr/local/bin/mihomo.new /usr/local/bin/mihomo.restoring
    rm -f /tmp/mihomo.gz /tmp/mihomo /tmp/ui.tgz /tmp/geoip.dat /tmp/geosite.dat /tmp/country.mmdb
    rm -rf /tmp/mgb-txn.* /tmp/mgb-asset.* /tmp/mgb-sums.* 2>/dev/null || true
    rm -rf /etc/mihomo/.ui-install.* /etc/mihomo/.ui-old.* 2>/dev/null || true
else
    log INFO "彻底清理安装目录与残留缓存..."
    rm -rf /etc/mihomo
    rm -f /usr/local/bin/mihomo
    rm -f /usr/local/bin/mihomo.bak /usr/local/bin/mihomo.new /usr/local/bin/mihomo.restoring
    rm -f /var/log/mihomo-maintain.log /var/log/mihomo-install.log
    # 无论哪种模式，/tmp 下的下载缓存都要清掉，否则下次装的还是这次的旧内核/旧 UI
    rm -f /tmp/mihomo.gz /tmp/mihomo /tmp/ui.tgz /tmp/geoip.dat /tmp/geosite.dat /tmp/country.mmdb
    rm -rf /tmp/mgb-txn.* /tmp/mgb-asset.* /tmp/mgb-sums.* 2>/dev/null || true
fi

echo "=========================================="
if [ "$CLEANUP_OK" -eq 1 ]; then
    echo " ✓ 卸载完成！"
else
    echo " ✗ 卸载未完全完成：网络规则有残留（见上方警告），文件清理已完成。"
fi
if [ "$MODE" = "stop-only" ]; then
    echo "   服务已停止，全部文件保留在原处。"
    echo "   恢复方法（任选其一）："
    echo "     完整恢复（含定时维护）：sudo bash \"$REPO_ROOT/scripts/restore.sh\""
    echo "     仅启动服务（定时维护仍缺失）：sudo systemctl enable --now mihomo"
elif [ "$MODE" = "keep-config" ]; then
    echo "   配置已保留在 /etc/mihomo。"
    echo "   恢复方法：sudo bash \"$REPO_ROOT/scripts/restore.sh\"（重装二进制与服务文件，配置原样保留）"
else
    echo "   环境已恢复干净状态，可以放心重新 install.sh。"
fi
echo "=========================================="

# 6. 提示：如果还想连项目源码目录一起清掉，给出现成命令，由用户自己手动执行
if [ -f "$REPO_ROOT/scripts/install.sh" ] && [ -f "$REPO_ROOT/README.md" ]; then
    echo ""
    echo "如果还想删掉 git clone 下来的项目源码目录，请自行确认后手动执行："
    echo "  sudo rm -rf \"$REPO_ROOT\""
fi

if [ "$CLEANUP_OK" -ne 1 ]; then
    exit 1
fi
