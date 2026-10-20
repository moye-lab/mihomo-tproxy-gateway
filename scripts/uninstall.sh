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
#
# 注意：此脚本只清理"安装到系统里"的文件（/etc/mihomo、systemd、cron 等），
# 不会删除 git clone 下来的项目源码目录本身。脚本自己删自己所在的目录这种
# 写法不可靠（执行到一半文件被删，行为依赖 bash 的具体读取实现），所以不
# 在脚本里做这件事。脚本跑完之后会打印一条现成的命令，如果你想连源码目录
# 也删掉，自己确认后手动执行即可。

set -e

KEEP_CONFIG=false
for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=true ;;
        *) echo "忽略未知参数: $arg（可用参数：--keep-config）" ;;
    esac
done

echo "=========================================="
echo " 开始卸载 Mihomo 旁路由服务与配置..."
echo "=========================================="

# 1. 停止并禁用 systemd 服务
if systemctl is-active --quiet mihomo 2>/dev/null; then
    echo "正在停止 mihomo 服务..."
    systemctl stop mihomo
fi

if systemctl is-enabled --quiet mihomo 2>/dev/null; then
    echo "正在禁用 mihomo 开机自启..."
    systemctl disable mihomo
fi

# 2. 清理 systemd 服务文件
if [ -f /etc/systemd/system/mihomo.service ]; then
    echo "清理 systemd 服务文件..."
    rm -f /etc/systemd/system/mihomo.service
    systemctl daemon-reload
fi

# 3. 清理 iptables 规则与策略路由（mangle + nat 两条链都要清）
echo "清理防火墙 TPROXY/DNS 规则与路由表..."
iptables -t mangle -F MIHOMO 2>/dev/null || true
iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null || true
iptables -t mangle -X MIHOMO 2>/dev/null || true

iptables -t nat -F MIHOMO_DNS 2>/dev/null || true
iptables -t nat -D PREROUTING -j MIHOMO_DNS 2>/dev/null || true
iptables -t nat -X MIHOMO_DNS 2>/dev/null || true

ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true

# 4. 删除定时维护任务
# 注意：维护任务装在系统级 /etc/cron.d/mihomo-maintain，不是 root 的
# 个人 crontab，清理时认准这个文件。
if [ -f /etc/cron.d/mihomo-maintain ]; then
    echo "删除定时维护任务 (/etc/cron.d/mihomo-maintain)..."
    rm -f /etc/cron.d/mihomo-maintain
fi

# 5. 清理程序本体、配置与缓存
if [ "$KEEP_CONFIG" = true ]; then
    echo "已保留 /etc/mihomo（--keep-config），仅清理二进制与临时文件。"
    rm -f /usr/local/bin/mihomo
else
    echo "彻底清理安装目录与残留缓存..."
    rm -rf /etc/mihomo
    rm -f /usr/local/bin/mihomo
    rm -f /var/log/mihomo-maintain.log
fi
# 无论哪种模式，/tmp 下的下载缓存都要清掉，否则下次装的还是这次的旧内核/旧 UI
rm -f /tmp/mihomo.gz /tmp/mihomo /tmp/ui.tgz /tmp/geoip.dat /tmp/geosite.dat /tmp/country.mmdb

echo "=========================================="
echo " ✓ 卸载完成！"
if [ "$KEEP_CONFIG" = true ]; then
    echo "   配置已保留在 /etc/mihomo，下次装回来直接复用。"
else
    echo "   环境已恢复干净状态，可以放心重新 install.sh。"
fi
echo "=========================================="

# 6. 提示：如果还想连项目源码目录一起清掉，给出现成命令，由用户自己手动执行
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
if [ -f "$REPO_ROOT/scripts/install.sh" ] && [ -f "$REPO_ROOT/README.md" ]; then
    echo ""
    echo "如果还想删掉 git clone 下来的项目源码目录，请自行确认后手动执行："
    echo "  sudo rm -rf \"$REPO_ROOT\""
fi

