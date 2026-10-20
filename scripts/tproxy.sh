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

if [ -z "${LAN_IFACE:-}" ] || [ -z "${LAN_SUBNET:-}" ]; then
    echo "错误：$ENV_FILE 中缺少 LAN_IFACE 或 LAN_SUBNET。" >&2
    exit 1
fi
if ! ip link show dev "$LAN_IFACE" >/dev/null 2>&1; then
    echo "错误：LAN 网卡 $LAN_IFACE 不存在；请检查 $ENV_FILE。" >&2
    exit 1
fi
if ! [[ "$LAN_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
    echo "错误：LAN_SUBNET 格式无效：$LAN_SUBNET" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 0. 彻底清理旧状态（幂等的关键：不管之前是什么状态，先清空）
# ------------------------------------------------------------------
# 清理本项目自身的策略路由（固定标记 1 / 表 100，与此前版本一致）。
ip rule del fwmark "$MARK" table "$ROUTING_TABLE" 2>/dev/null || true
ip route del local default dev lo table "$ROUTING_TABLE" 2>/dev/null || true
if ip route show table "$ROUTING_TABLE" 2>/dev/null | grep -q .; then
    echo "错误：路由表 $ROUTING_TABLE 已包含其他路由，拒绝覆盖；请检查 ip route show table $ROUTING_TABLE。" >&2
    exit 1
fi

iptables -t mangle -F MIHOMO 2>/dev/null || true
iptables -t mangle -D PREROUTING -j MIHOMO 2>/dev/null || true
iptables -t mangle -X MIHOMO 2>/dev/null || true

iptables -t nat -F MIHOMO_DNS 2>/dev/null || true
iptables -t nat -D PREROUTING -j MIHOMO_DNS 2>/dev/null || true
iptables -t nat -X MIHOMO_DNS 2>/dev/null || true

# ------------------------------------------------------------------
# 1. 策略路由：把打了 MARK 的包丢给本机处理（TPROXY 依赖这个）
# ------------------------------------------------------------------
ip rule add fwmark $MARK table $ROUTING_TABLE
ip route add local default dev lo table $ROUTING_TABLE

# ------------------------------------------------------------------
# 2. TCP/UDP 透明代理（mangle 表，只挂 PREROUTING —— 本机自身流量走
#    OUTPUT 链，不受影响，符合"旁路由"定位）
# ------------------------------------------------------------------
iptables -t mangle -N MIHOMO

# 限制入口：只处理指定 LAN 网卡且来源属于所配置网段的包。
# 将限制放在自定义链内部，能兼容升级前创建的无条件 PREROUTING 跳转，
# 也避免修改 LAN_IFACE/LAN_SUBNET 后留下旧跳转导致链无法重建。
iptables -t mangle -A MIHOMO ! -i "$LAN_IFACE" -j RETURN
iptables -t mangle -A MIHOMO ! -s "$LAN_SUBNET" -j RETURN

# 保留地址与局域网直连流量不走代理
iptables -t mangle -A MIHOMO -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A MIHOMO -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A MIHOMO -d 240.0.0.0/4 -j RETURN

iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"
iptables -t mangle -A MIHOMO -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK"

iptables -t mangle -A PREROUTING -j MIHOMO

# ------------------------------------------------------------------
# 3. DNS 劫持（nat 表）：把局域网设备发往任意 DNS 服务器的 53 端口
#    请求，强制拉回本机 mihomo 的 fake-ip DNS 监听端口。
#    这一步是"透明代理"名副其实的关键 —— 没有这条规则，任何自己配了
#    DNS（比如手机用运营商 DNS / DoH）的设备，fake-ip 分流对它就是
#    摆设，会直接漏到明文 DNS。
# ------------------------------------------------------------------
iptables -t nat -N MIHOMO_DNS
iptables -t nat -A MIHOMO_DNS ! -i "$LAN_IFACE" -j RETURN
iptables -t nat -A MIHOMO_DNS ! -s "$LAN_SUBNET" -j RETURN
iptables -t nat -A MIHOMO_DNS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A MIHOMO_DNS -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A MIHOMO_DNS -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A PREROUTING -j MIHOMO_DNS

echo "tproxy OK (interface=$LAN_IFACE subnet=$LAN_SUBNET)"
