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

CONFIG=/etc/mihomo/config.yaml
CACHE=/etc/mihomo/providers/airport1.yaml

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行此脚本（配置文件和服务都需要 root）。"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "错误：未找到 $CONFIG，看起来还没有安装过，请先运行仓库里的 install.sh 完成安装。"
    exit 1
fi

NEW_URL="${1:-}"
if [ -z "$NEW_URL" ]; then
    read -r -p "请输入新的机场订阅链接: " NEW_URL
fi

if [[ "$NEW_URL" != http://* && "$NEW_URL" != https://* ]]; then
    echo "错误：订阅链接看起来不对，应该以 http:// 或 https:// 开头。"
    exit 1
fi

# 1. 先备份，任何一步出错都能立刻恢复
BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONFIG" "$BACKUP"
echo "✓ 已备份当前配置到 $BACKUP"

# 2. 精确替换：只匹配 airport1 正下方 4 空格缩进的 url 行
TMP=$(mktemp)
awk -v new="$NEW_URL" '
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
            print "REPLACE_FAILED" > "/dev/stderr"
        }
    }
' "$CONFIG" > "$TMP"

if grep -q "^REPLACE_FAILED$" "$TMP" 2>/dev/null || [ ! -s "$TMP" ]; then
    echo "错误：未能在 config.yaml 里找到 proxy-providers.airport1.url 这一行，"
    echo "可能是配置结构被手动改动过。没有对原文件做任何修改，已备份文件可以删除："
    echo "  rm -f $BACKUP"
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$CONFIG"
echo "✓ 已将订阅链接更新为: $(echo "$NEW_URL" | sed -E 's#^(https?://[^/]+/).*#\1****#')"

# 3. 语法自查，失败立刻回滚，不让坏配置留在系统里
if ! mihomo -t -d /etc/mihomo >/tmp/switch-sub-check.log 2>&1; then
    echo "✗ 新配置语法校验失败，自动回滚到修改前的版本："
    cat /tmp/switch-sub-check.log
    cp "$BACKUP" "$CONFIG"
    echo "已回滚，配置未受影响。"
    exit 1
fi
echo "✓ 语法校验通过"

# 4. 清掉旧订阅的节点缓存，避免短时间内还在用旧节点
if [ -f "$CACHE" ]; then
    rm -f "$CACHE"
    echo "✓ 已清理旧的节点缓存 ($CACHE)"
fi

# 5. 重启服务生效
systemctl restart mihomo
echo "✓ mihomo 已重启，新订阅生效"

echo ""
echo "可以去面板确认节点列表: http://<本机IP>:9090/ui"
