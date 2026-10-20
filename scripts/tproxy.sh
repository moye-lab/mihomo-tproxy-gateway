#!/bin/bash
# TPROXY 路由、防火墙规则与 DNS 劫持配置
# 设计目标：每次执行都是"先彻底清理、再重新建立"，保证幂等 —— 无论是首次启动、
# 服务重启、还是反复重装测试，都不会有旧规则残留导致排查困难。

ROUTING_TABLE=100
MARK=1
TPROXY_PORT=7893
DNS_PORT=1053

# ------------------------------------------------------------------
# 0. 彻底清理旧状态（幂等的关键：不管之前是什么状态，先清空）
# ------------------------------------------------------------------
ip rule del fwmark $MARK table $ROUTING_TABLE 2>/dev/null || true
ip route del local default dev lo table $ROUTING_TABLE 2>/dev/null || true

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

# 保留地址与局域网直连流量不走代理
iptables -t mangle -A MIHOMO -d 0.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 10.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 127.0.0.0/8 -j RETURN
iptables -t mangle -A MIHOMO -d 169.254.0.0/16 -j RETURN
iptables -t mangle -A MIHOMO -d 172.16.0.0/12 -j RETURN
iptables -t mangle -A MIHOMO -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A MIHOMO -d 224.0.0.0/4 -j RETURN
iptables -t mangle -A MIHOMO -d 240.0.0.0/4 -j RETURN

iptables -t mangle -A MIHOMO -p tcp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK
iptables -t mangle -A MIHOMO -p udp -j TPROXY --on-port $TPROXY_PORT --tproxy-mark $MARK

iptables -t mangle -A PREROUTING -j MIHOMO

# ------------------------------------------------------------------
# 3. DNS 劫持（nat 表）：把局域网设备发往任意 DNS 服务器的 53 端口
#    请求，强制拉回本机 mihomo 的 fake-ip DNS 监听端口。
#    这一步是"透明代理"名副其实的关键 —— 没有这条规则，任何自己配了
#    DNS（比如手机用运营商 DNS / DoH）的设备，fake-ip 分流对它就是
#    摆设，会直接漏到明文 DNS。
# ------------------------------------------------------------------
iptables -t nat -N MIHOMO_DNS
iptables -t nat -A MIHOMO_DNS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A MIHOMO_DNS -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A MIHOMO_DNS -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT
iptables -t nat -A PREROUTING -j MIHOMO_DNS

echo "tproxy OK"
