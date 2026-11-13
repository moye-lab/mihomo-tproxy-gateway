#!/bin/bash
# mihomo-tproxy-gateway 桩测总入口（P0+P1+P1/P2+P2）
#
# 用法（从仓库根目录运行）：sudo bash tests/run-tests.sh [测试名过滤子串]
#   不带参数跑全部；带参数只跑名字包含该子串的测试（例如 T6、rollback）。
#
# 原理：真实文件路径（/etc/mihomo、/usr/local/bin、/etc/systemd/system、
# /etc/cron.d、/var/lock）+ 桩命令（stubs/ 下的 ip/iptables/ip6tables/
# systemctl/curl/wget/mihomo 覆盖 PATH）。systemctl 桩在 start/restart 时
# 真的执行 /etc/mihomo/tproxy.sh（ExecStartPost 模拟），在 stop/restart
# 时按单元文件内容执行 ExecStopPost（tproxy.sh stop），因此 tproxy 失败
# -> 服务启动失败 -> 安装回滚 这条链路是真实走通的，不是 grep 断言。
# 每个测试前后都重置系统状态与桩状态；结束时恢复干净环境。
# 注意：数据面（真实流量经 TPROXY）与真实发行版安装沙箱无法验证，
# 见 tests/README.md 的沙箱限制与待真机项。
#
# shellcheck disable=SC2317
# （上行：测试函数经 ALL_TESTS 列表间接调用，ShellCheck 的可达分析看不
# 到间接调用，会把全部测试函数体误报为 unreachable；已知误报，非死代码）

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO="$(dirname "$TESTS_DIR")"
STUBS="$TESTS_DIR/stubs"
FIXTURES="$TESTS_DIR/fixtures"
STATE="$TESTS_DIR/state"
OUTPUTS="$TESTS_DIR/outputs"
export STUB_STATE="$STATE" STUB_FIXTURES="$FIXTURES"
export PATH="$STUBS:$PATH"

FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_TESTS=()
CURRENT_TEST=""
OUT=""
HOLDER_PID=""

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：桩测需要 root（读写 /etc/mihomo 等真实路径），请用 sudo 运行。"
    exit 1
fi

# ------------------------------------------------------------------
# 断言与输出
# ------------------------------------------------------------------
ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; FAILED_TESTS+=("$CURRENT_TEST: $1"); }

check() { # check <描述> <命令...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
check_contains() { # check_contains <描述> <文件> <字面子串>
    if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1（在 $2 中未找到：$3）"; fi
}
check_not_contains() {
    if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1（在 $2 中不应出现：$3）"; else ok "$1"; fi
}
check_exit() { # check_exit <描述> <期望码> <实际码>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望退出码 $2，实际 $3）"; fi
}
check_eq() { # check_eq <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2]，实际 [$3]）"; fi
}

rule_count() { # 本项目 fwmark 1 / 表 100 规则条数
    local n
    n=$(grep -cE 'fwmark 0x1([ /]|$).*lookup 100$' "$STATE/ip-rules.txt" 2>/dev/null || true)
    echo "${n:-0}"
}
route100_count() { # 表 100 里 local 路由条数
    local n
    n=$(grep -c '^local default dev lo' "$STATE/ip-route-100.txt" 2>/dev/null || true)
    echo "${n:-0}"
}
jump_count() { # jump_count <表> <链>：PREROUTING 跳转条数
    local n
    n=$(grep -c -- "-j $2" "$STATE/ipt-$1-PREROUTING.txt" 2>/dev/null || true)
    echo "${n:-0}"
}
chain_exists() { [ -f "$STATE/ipt-$1-$2.txt" ]; }

begin_test() {
    CURRENT_TEST="$1"
    OUT="$OUTPUTS/$1.log"
    mkdir -p "$OUTPUTS"
    : > "$OUT"
    echo ""
    echo "=== $1 ==="
}

# ------------------------------------------------------------------
# 状态重置与场景播种
# ------------------------------------------------------------------
reset_system() {
    rm -rf /etc/mihomo /usr/local/bin/mihomo /usr/local/bin/mihomo.bak \
        /usr/local/bin/mihomo.restoring /usr/local/bin/mihomo.new \
        /etc/systemd/system/mihomo.service /etc/cron.d/mihomo-maintain \
        /var/log/mihomo-maintain.log /var/log/mihomo-install.log \
        /var/lock/mihomo-gateway.lock /var/lock/mihomo-maintain.lock \
        /tmp/mihomo.gz /tmp/mihomo /tmp/.mihomo-probe /tmp/ui.tgz \
        /tmp/geoip.dat /tmp/geosite.dat /tmp/country.mmdb \
        /tmp/switch-sub-check.log
    rm -rf /tmp/mgb-txn.* /tmp/mgb-asset.* /tmp/mgb-sums.*
    rm -rf "$STATE"
    mkdir -p "$STATE"
    printf '%s\n' "0:	from all lookup local" "32766:	from all lookup main" "32767:	from all lookup default" > "$STATE/ip-rules.txt"
    : > "$STATE/ip-route-100.txt"
    printf '%s\n' "eth0" "lo" > "$STATE/ifaces.txt"
    echo 0 > "$STATE/svc-active"
    echo 0 > "$STATE/svc-enabled"
    echo 0 > "$STATE/api-up"
}

write_seed_config() {
    cat > /etc/mihomo/config.yaml <<'EOF'
mixed-port: 7890
tproxy-port: 7893
allow-lan: true
bind-address: "*"
mode: rule
log-level: warning
ipv6: false

external-controller: 0.0.0.0:9090
external-ui: /etc/mihomo/ui
secret: "OLDSECRET1234567890abcdef"

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "+.stun.*.*"
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
    - 8.8.8.8
  proxy-server-nameserver:
    - https://1.1.1.1/dns-query
  nameserver-policy:
    "geosite:cn": [223.5.5.5, 119.29.29.29]

proxy-providers:
  airport1:
    type: http
    url: "https://old-sub.example.com/sub?token=OLD123&x=1"
    interval: 86400
    path: ./providers/airport1.yaml
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "⚡ 自动最优"
    use:
      - airport1
  - name: "⚡ 自动最优"
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    use:
      - airport1

rules:
  - IP-CIDR,10.0.0.0/24,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - DOMAIN-SUFFIX,custom.example.com,DIRECT
  - GEOSITE,private,DIRECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,🚀 节点选择
EOF
    chmod 600 /etc/mihomo/config.yaml
}

# 播种一份"旧版本已安装"状态：旧二进制 + 旧配置 + 旧 UI + 旧服务文件；
# 不启动服务（调用方按需启动）。
seed_installed_files() {
    mkdir -p /etc/mihomo/ui /etc/mihomo/providers
    write_seed_config
    # 订阅缓存：mihomo 拉取订阅后落盘的节点数据（verify.sh 与
    # auto-maintain.sh 数节点数的来源）；3 个节点，与 curl 桩的
    # /providers/proxies 响应里 airport1 的节点数一致。另带 2 个分组
    # （回归锚点：计数只数 proxies 区，分组不计入；真机实测 5 节点 +
    # 13 分组曾被全数报成 18）。
    cat > /etc/mihomo/providers/airport1.yaml <<'EOF'
proxies:
  - name: "node1"
    type: vless
    server: 1.2.3.4
    port: 443
  - name: "node2"
    type: vless
    server: 5.6.7.8
    port: 443
  - name: "node3"
    type: trojan
    server: 9.10.11.12
    port: 443
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "node1"
      - "node2"
  - name: "⚡ 自动最优"
    type: url-test
    proxies:
      - "node1"
EOF
    cat > /etc/mihomo/tproxy.env <<'EOF'
LAN_IFACE="eth0"
LAN_SUBNET="10.0.0.0/24"
EOF
    chmod 600 /etc/mihomo/tproxy.env
    cat > /etc/mihomo/maintain.env <<'EOF'
API="http://127.0.0.1:9090"
API_SECRET="OLDSECRET1234567890abcdef"
PROVIDERS="airport1"
BIN_ARCH="amd64"
EOF
    chmod 600 /etc/mihomo/maintain.env
    cp "$REPO/scripts/tproxy.sh" /etc/mihomo/tproxy.sh
    cp "$REPO/scripts/auto-maintain.sh" /etc/mihomo/auto-maintain.sh
    cp "$REPO/scripts/verify.sh" /etc/mihomo/verify.sh
    chmod +x /etc/mihomo/*.sh
    printf '<html>OLD-UI-MARKER</html>\n' > /etc/mihomo/ui/index.html
    cp "$FIXTURES/GeoSite.dat" /etc/mihomo/GeoSite.dat
    cp "$FIXTURES/GeoIP.dat" /etc/mihomo/GeoIP.dat
    cp "$FIXTURES/Country.mmdb" /etc/mihomo/Country.mmdb
    cp "$FIXTURES/fake-mihomo-old" /usr/local/bin/mihomo
    chmod +x /usr/local/bin/mihomo
    cp "$REPO/systemd/mihomo.service" /etc/systemd/system/mihomo.service
    cp "$REPO/cron/mihomo-maintain.cron" /etc/cron.d/mihomo-maintain
    cp /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    sha256sum /usr/local/bin/mihomo | awk '{print $1}' > "$STATE/old-bin.sha256"
}

# 播种运行中的旧安装：文件 + 服务 active/enabled + 规则已建
seed_running_install() {
    reset_system
    seed_installed_files
    echo 1 > "$STATE/svc-enabled"
    systemctl start mihomo >> "$OUT" 2>&1
}

# 播种停止的旧安装：文件齐全，服务 inactive、无规则
seed_stopped_install() {
    reset_system
    seed_installed_files
}

# 播种 --keep-config 卸载后的状态：只剩 /etc/mihomo，无二进制/服务文件/cron
seed_keep_config_uninstalled() {
    seed_stopped_install
    rm -f /usr/local/bin/mihomo /etc/systemd/system/mihomo.service /etc/cron.d/mihomo-maintain
}

# 播种 --stop-only 后的状态：文件齐全，服务 inactive/disabled、无规则、无 cron
seed_stop_only_state() {
    seed_stopped_install
    rm -f /etc/cron.d/mihomo-maintain
}

# 占用全局锁（后台进程持锁 120 秒），测试后由 release_lock 释放。
# 持锁进程自身就是 bash（fd 9 上 flock 后 sleep），kill 它即释放锁且
# 无残留子进程；stdio 全部脱离，避免残留进程拖住测试输出管道。
hold_lock() {
    bash -c 'exec 9>/var/lock/mihomo-gateway.lock; flock 9; sleep 120' </dev/null >/dev/null 2>&1 &
    HOLDER_PID=$!
    sleep 0.5
}
release_lock() {
    if [ -n "$HOLDER_PID" ]; then
        kill "$HOLDER_PID" 2>/dev/null || true
        wait "$HOLDER_PID" 2>/dev/null || true
        HOLDER_PID=""
    fi
}
trap release_lock EXIT

# ------------------------------------------------------------------
# T 组：tproxy.sh（P0-1 / P0-2）
# ------------------------------------------------------------------
write_tproxy_env() { # write_tproxy_env <iface> <subnet>
    mkdir -p /etc/mihomo
    printf 'LAN_IFACE="%s"\nLAN_SUBNET="%s"\n' "$1" "$2" > /etc/mihomo/tproxy.env
    chmod 600 /etc/mihomo/tproxy.env
}

t_T1_missing_env() {
    begin_test "T1_缺env失败关闭"
    reset_system
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "缺 tproxy.env 时 exit 1" 1 "$?"
    check_contains "报错明确提到 tproxy.env" "$OUT" "tproxy.env"
}

t_T2_cidr_octet_overflow() {
    begin_test "T2_CIDR数值越界拒绝"
    reset_system
    write_tproxy_env eth0 "999.999.999.999/24"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "999.999.999.999/24 时 exit 1" 1 "$?"
    check_contains "报错提到数值超出范围" "$OUT" "数值超出范围"
    check_eq "越界时未建任何规则" 0 "$(rule_count)"
}

t_T3_cidr_prefix_overflow() {
    begin_test "T3_CIDR前缀越界拒绝"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/33"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "10.0.0.0/33 时 exit 1" 1 "$?"
}

t_T4_cidr_leading_zero() {
    begin_test "T4_CIDR前导零拒绝"
    reset_system
    write_tproxy_env eth0 "010.0.0.0/24"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "010.0.0.0/24 时 exit 1" 1 "$?"
    check_contains "报错提到前导 0" "$OUT" "前导 0"
}

t_T5_happy_path() {
    begin_test "T5_正常建规则_守卫在前"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "合法 env 时 exit 0" 0 "$?"
    check_eq "fwmark 1/表 100 规则恰 1 条" 1 "$(rule_count)"
    check_eq "表 100 local 路由恰 1 条" 1 "$(route100_count)"
    check_eq "mangle PREROUTING 跳转恰 1 条" 1 "$(jump_count mangle MIHOMO)"
    check_eq "nat PREROUTING 跳转恰 1 条" 1 "$(jump_count nat MIHOMO_DNS)"
    check "MIHOMO 链存在" chain_exists mangle MIHOMO
    check "MIHOMO_DNS 链存在" chain_exists nat MIHOMO_DNS
    first_two="$(sed -n '1,2p' "$STATE/ipt-mangle-MIHOMO.txt" | tr '\n' '|')"
    check_eq "MIHOMO 链前两条为入口守卫" "! -i eth0 -j RETURN|! -s 10.0.0.0/24 -j RETURN|" "$first_two"
    first_two_dns="$(sed -n '1,2p' "$STATE/ipt-nat-MIHOMO_DNS.txt" | tr '\n' '|')"
    check_eq "MIHOMO_DNS 链前两条为入口守卫" "! -i eth0 -j RETURN|! -s 10.0.0.0/24 -j RETURN|" "$first_two_dns"
    check_contains "成功输出 tproxy OK" "$OUT" "tproxy OK"
}

t_T6_duplicate_cleanup() {
    begin_test "T6_历史重复规则清理干净"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    # 预置重复：两条不同优先级的 fwmark 规则、两条跳转、残留链
    printf '%s\n' "32765: from all fwmark 0x1 lookup 100" "32764: from all fwmark 0x1 lookup 100" >> "$STATE/ip-rules.txt"
    printf '%s\n' "local default dev lo scope host" >> "$STATE/ip-route-100.txt"
    printf '%s\n' "-j MIHOMO" "-j MIHOMO" > "$STATE/ipt-mangle-PREROUTING.txt"
    printf '%s\n' "-j MIHOMO_DNS" "-j MIHOMO_DNS" > "$STATE/ipt-nat-PREROUTING.txt"
    : > "$STATE/ipt-mangle-MIHOMO.txt"
    : > "$STATE/ipt-nat-MIHOMO_DNS.txt"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "有重复残留时仍 exit 0" 0 "$?"
    check_eq "清理后 fwmark 规则恰 1 条" 1 "$(rule_count)"
    check_eq "清理后表 100 路由恰 1 条" 1 "$(route100_count)"
    check_eq "清理后 mangle 跳转恰 1 条" 1 "$(jump_count mangle MIHOMO)"
    check_eq "清理后 nat 跳转恰 1 条" 1 "$(jump_count nat MIHOMO_DNS)"
    # 幂等：再跑一次，仍恰 1 条
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "重复执行 exit 0" 0 "$?"
    check_eq "重复执行后 fwmark 规则仍恰 1 条" 1 "$(rule_count)"
    check_eq "重复执行后 mangle 跳转仍恰 1 条" 1 "$(jump_count mangle MIHOMO)"
}

t_T7_foreign_fwmark_refused() {
    begin_test "T7_外部fwmark占用拒绝且不碰对方"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf '%s\n' "100: from all fwmark 0x1 lookup 200" >> "$STATE/ip-rules.txt"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "外部 fwmark 1 占用时 exit 1" 1 "$?"
    check_contains "报错提到 fwmark 1 被占用" "$OUT" "fwmark 1"
    check "对方规则原样保留" grep -qF "fwmark 0x1 lookup 200" "$STATE/ip-rules.txt"
    check_eq "拒绝后未建本项目规则" 0 "$(rule_count)"
    check "拒绝后未建 MIHOMO 链" test ! -f "$STATE/ipt-mangle-MIHOMO.txt"
}

t_T8_foreign_table100_refused() {
    begin_test "T8_表100外部路由拒绝"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf '%s\n' "10.9.9.0/24 dev eth1 scope link" >> "$STATE/ip-route-100.txt"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "表 100 有外部路由时 exit 1" 1 "$?"
    check_contains "报错提到路由表 100" "$OUT" "路由表 100"
}

t_T9_own_rule_not_conflict() {
    begin_test "T9_自有规则重入不误判冲突"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf '%s\n' "32765: from all fwmark 0x1 lookup 100" >> "$STATE/ip-rules.txt"
    printf '%s\n' "local default dev lo scope host" >> "$STATE/ip-route-100.txt"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "自有规则已存在时 exit 0（升级/重启路径）" 0 "$?"
    check_eq "重建后 fwmark 规则恰 1 条" 1 "$(rule_count)"
}

t_T10_stop_mode() {
    begin_test "T10_stop模式清理与幂等"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf '%s\n' "100: from all fwmark 0x10 lookup 200" >> "$STATE/ip-rules.txt"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "先建规则 exit 0" 0 "$?"
    check_eq "建规则后 fwmark 恰 1 条" 1 "$(rule_count)"
    bash "$REPO/scripts/tproxy.sh" stop >> "$OUT" 2>&1
    check_exit "stop exit 0" 0 "$?"
    check_eq "stop 后 fwmark 规则 0 条" 0 "$(rule_count)"
    check_eq "stop 后表 100 路由 0 条" 0 "$(route100_count)"
    check "stop 后 MIHOMO 链已删" test ! -f "$STATE/ipt-mangle-MIHOMO.txt"
    check "stop 后 MIHOMO_DNS 链已删" test ! -f "$STATE/ipt-nat-MIHOMO_DNS.txt"
    check_eq "stop 后 mangle 跳转 0 条" 0 "$(jump_count mangle MIHOMO)"
    check "stop 不动外部 fwmark 0x10 规则" grep -qF "fwmark 0x10 lookup 200" "$STATE/ip-rules.txt"
    bash "$REPO/scripts/tproxy.sh" stop >> "$OUT" 2>&1
    check_exit "stop 幂等：第二次仍 exit 0" 0 "$?"
}

t_T11_stop_without_env() {
    begin_test "T11_stop不需要env"
    reset_system
    printf '%s\n' "32765: from all fwmark 0x1 lookup 100" >> "$STATE/ip-rules.txt"
    bash "$REPO/scripts/tproxy.sh" stop >> "$OUT" 2>&1
    check_exit "无 env 时 stop 仍 exit 0" 0 "$?"
    check_eq "无 env 时 stop 仍清掉规则" 0 "$(rule_count)"
}

t_T12_fwmark_0x10_not_conflict() {
    begin_test "T12_fwmark0x10不误判为0x1"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf '%s\n' "100: from all fwmark 0x10 lookup 200" >> "$STATE/ip-rules.txt"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "仅有 fwmark 0x10 时 exit 0" 0 "$?"
    check_eq "本项目规则正常建成" 1 "$(rule_count)"
}

t_T13_bad_arg() {
    begin_test "T13_非法参数报错"
    reset_system
    bash "$REPO/scripts/tproxy.sh" bogus >> "$OUT" 2>&1
    check_exit "非法参数 exit 1" 1 "$?"
    check_contains "打印用法" "$OUT" "用法"
}

t_T14_iface_missing() {
    begin_test "T14_网卡不存在失败关闭"
    reset_system
    write_tproxy_env eth99 "10.0.0.0/24"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "网卡不存在时 exit 1" 1 "$?"
}

# ------------------------------------------------------------------
# U 组：uninstall.sh（P0-3）
# ------------------------------------------------------------------
t_U1_stop_only() {
    begin_test "U1_stop-only停服务保文件"
    seed_running_install
    plant_bin_leftovers
    bash "$REPO/scripts/uninstall.sh" --stop-only >> "$OUT" 2>&1
    check_exit "--stop-only exit 0" 0 "$?"
    check "服务已停" test "$(cat "$STATE/svc-active")" = "0"
    check "服务已禁用自启" test "$(cat "$STATE/svc-enabled")" = "0"
    check_eq "规则已清" 0 "$(rule_count)"
    check "二进制保留" test -f /usr/local/bin/mihomo
    check ".bak 暂存保留（stop-only 不删任何文件）" test -f /usr/local/bin/mihomo.bak
    check "事务残留保留（stop-only 不删任何文件）" test -d /tmp/mgb-txn.testdir
    check "配置保留" test -f /etc/mihomo/config.yaml
    check "服务文件保留" test -f /etc/systemd/system/mihomo.service
    check "UI 保留" test -f /etc/mihomo/ui/index.html
    check "cron 已清（防自动重启）" test ! -f /etc/cron.d/mihomo-maintain
    check_contains "输出删除清单" "$OUT" "卸载计划"
    check_contains "输出 restore.sh 恢复指引" "$OUT" "restore.sh"
    check_contains "输出手动恢复命令" "$OUT" "systemctl enable --now mihomo"
}

t_U2_keep_config() {
    begin_test "U2_keep-config保留配置删二进制"
    seed_running_install
    bash "$REPO/scripts/uninstall.sh" --keep-config >> "$OUT" 2>&1
    check_exit "--keep-config exit 0" 0 "$?"
    check "服务已停" test "$(cat "$STATE/svc-active")" = "0"
    check_eq "规则已清" 0 "$(rule_count)"
    check "配置保留" test -f /etc/mihomo/config.yaml
    check "配置内容原样" cmp -s /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    check "tproxy.env 保留" test -f /etc/mihomo/tproxy.env
    check "二进制已删" test ! -f /usr/local/bin/mihomo
    check "服务文件已删" test ! -f /etc/systemd/system/mihomo.service
    check "cron 已删" test ! -f /etc/cron.d/mihomo-maintain
    check_contains "输出删除清单" "$OUT" "卸载计划"
    check_contains "清单含二进制" "$OUT" "/usr/local/bin/mihomo"
    check_contains "输出 restore.sh 恢复指引" "$OUT" "restore.sh"
}

t_U3_full() {
    begin_test "U3_彻底卸载清干净"
    seed_running_install
    echo "fake maintain log" > /var/log/mihomo-maintain.log
    echo "fake install log" > /var/log/mihomo-install.log
    bash "$REPO/scripts/uninstall.sh" >> "$OUT" 2>&1
    check_exit "默认彻底卸载 exit 0" 0 "$?"
    check "服务已停" test "$(cat "$STATE/svc-active")" = "0"
    check_eq "规则已清" 0 "$(rule_count)"
    check "/etc/mihomo 已删" test ! -d /etc/mihomo
    check "二进制已删" test ! -f /usr/local/bin/mihomo
    check "服务文件已删" test ! -f /etc/systemd/system/mihomo.service
    check "cron 已删" test ! -f /etc/cron.d/mihomo-maintain
    check "维护日志已删" test ! -f /var/log/mihomo-maintain.log
    check "安装日志已删" test ! -f /var/log/mihomo-install.log
    check_contains "输出删除清单" "$OUT" "卸载计划"
}

t_U4_uninstall_idempotent() {
    begin_test "U4_未安装时卸载幂等"
    reset_system
    bash "$REPO/scripts/uninstall.sh" >> "$OUT" 2>&1
    check_exit "未安装时卸载 exit 0" 0 "$?"
    check_contains "清单标注不存在项为跳过" "$OUT" "跳过"
}

t_U5_uninstall_clears_duplicates() {
    begin_test "U5_卸载清掉历史重复规则"
    seed_running_install
    # 模拟历史重复残留：再加一条同 mark/table 不同优先级的规则与一条跳转
    printf '%s\n' "32764: from all fwmark 0x1 lookup 100" >> "$STATE/ip-rules.txt"
    printf '%s\n' "-j MIHOMO" >> "$STATE/ipt-mangle-PREROUTING.txt"
    bash "$REPO/scripts/uninstall.sh" >> "$OUT" 2>&1
    check_exit "有重复残留时卸载 exit 0" 0 "$?"
    check_eq "重复规则全部清掉" 0 "$(rule_count)"
    check_eq "重复跳转全部清掉" 0 "$(jump_count mangle MIHOMO)"
}

# ------------------------------------------------------------------
# R 组：restore.sh（P0-3）
# ------------------------------------------------------------------
t_R1_restore_after_keep_config() {
    begin_test "R1_keep-config后一键恢复"
    seed_keep_config_uninstalled
    bash "$REPO/scripts/restore.sh" >> "$OUT" 2>&1
    check_exit "restore exit 0" 0 "$?"
    check "二进制已恢复" test -x /usr/local/bin/mihomo
    check_contains "恢复的是新版二进制" /usr/local/bin/mihomo "NEW-BINARY-MARKER"
    check "服务文件已恢复" test -f /etc/systemd/system/mihomo.service
    check "cron 已恢复" test -f /etc/cron.d/mihomo-maintain
    check "verify.sh 已恢复" test -x /etc/mihomo/verify.sh
    check "配置原样未动" cmp -s /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    check "服务已启动" test "$(cat "$STATE/svc-active")" = "1"
    check "服务已启用自启" test "$(cat "$STATE/svc-enabled")" = "1"
    check_eq "规则已重建" 1 "$(rule_count)"
    check_contains "输出恢复成功" "$OUT" "已恢复运行"
}

t_R2_restore_no_config() {
    begin_test "R2_无配置时恢复明确拒绝"
    reset_system
    bash "$REPO/scripts/restore.sh" >> "$OUT" 2>&1
    check_exit "无配置时 restore exit 1" 1 "$?"
    check_contains "指引用户跑 install.sh" "$OUT" "install.sh"
}

t_R3_restore_already_running() {
    begin_test "R3_服务已在跑时恢复直接返回"
    seed_running_install
    bash "$REPO/scripts/restore.sh" >> "$OUT" 2>&1
    check_exit "已在运行时 restore exit 0" 0 "$?"
    check_contains "提示无需恢复" "$OUT" "无需恢复"
}

t_R4_restore_after_stop_only() {
    begin_test "R4_stop-only后恢复"
    seed_stop_only_state
    bash "$REPO/scripts/restore.sh" >> "$OUT" 2>&1
    check_exit "stop-only 后 restore exit 0" 0 "$?"
    check "服务已启动" test "$(cat "$STATE/svc-active")" = "1"
    check "cron 已恢复" test -f /etc/cron.d/mihomo-maintain
    check "旧二进制复用（未重下）" grep -q "OLD-BINARY-MARKER" /usr/local/bin/mihomo
}

t_R5_restore_bad_config() {
    begin_test "R5_配置自检失败时恢复拒绝启动"
    seed_keep_config_uninstalled
    touch "$STATE/mihomo-t-fail"
    bash "$REPO/scripts/restore.sh" >> "$OUT" 2>&1
    check_exit "自检失败时 restore exit 1" 1 "$?"
    check "服务未启动" test "$(cat "$STATE/svc-active")" = "0"
    check_contains "报错提到自检" "$OUT" "自检"
}

# ------------------------------------------------------------------
# S 组：switch-sub.sh（P0-4 锁 + 回归）
# ------------------------------------------------------------------
t_S1_switch_sub_happy() {
    begin_test "S1_switch-sub正常换链"
    seed_running_install
    bash "$REPO/scripts/switch-sub.sh" "https://new-sub.example.com/x?token=NEW9&y=2" >> "$OUT" 2>&1
    check_exit "switch-sub exit 0" 0 "$?"
    check_contains "新订阅已写入" /etc/mihomo/config.yaml "https://new-sub.example.com/x?token=NEW9&y=2"
    check_contains "health-check 的 url 未被误改" /etc/mihomo/config.yaml "https://www.gstatic.com/generate_204"
    check "服务已重启仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    check "备份文件已生成" test -n "$(ls /etc/mihomo/config.yaml.bak.* 2>/dev/null)"
    check "未产生固定路径自检日志" test ! -e /tmp/switch-sub-check.log
}

# ------------------------------------------------------------------
# A 组：auto-maintain.sh（P0-4 共享锁）
# ------------------------------------------------------------------
t_A1_maintain_skips_when_locked() {
    begin_test "A1_全局锁被占时维护跳过"
    seed_running_install
    hold_lock
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    rc=$?
    release_lock
    check_exit "锁被占时 check exit 0（跳过不算错）" 0 "$rc"
    check_contains "日志记录跳过原因" /var/log/mihomo-maintain.log "已有安装/卸载/维护任务在运行，本次跳过"
}

t_A2_maintain_runs_when_free() {
    begin_test "A2_锁空闲时维护正常跑"
    seed_running_install
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    check_exit "锁空闲时 check exit 0" 0 "$?"
    check_contains "健康检查通过" /var/log/mihomo-maintain.log "服务正常，代理连通性正常"
}

# ------------------------------------------------------------------
# I 组：install.sh（P0-3 配置保留 / P0-4 事务回滚）
# 输入顺序：入口网卡 / 网段 / 订阅 / [LAN 有 IPv6 时阻断确认] /
#           面板监听 / [重装时覆盖确认] / 确认安装
# ------------------------------------------------------------------
run_install() { # run_install <stdin内容>：跑安装，输出记 $OUT，返回退出码
    printf '%b' "$1" | bash "$REPO/scripts/install.sh" >> "$OUT" 2>&1
    return $?
}

t_I1_fresh_install() {
    begin_test "I1_全新安装成功"
    reset_system
    run_install '\n\nhttps://sub.example.com/api?token=abc&flag=1\n\ny\n'
    check_exit "全新安装 exit 0" 0 "$?"
    check "二进制已装" test -x /usr/local/bin/mihomo
    check_contains "装的是新版二进制" /usr/local/bin/mihomo "NEW-BINARY-MARKER"
    check "配置已生成" test -f /etc/mihomo/config.yaml
    check_contains "订阅链接含 & 逐字渲染（sed 转义未回退）" /etc/mihomo/config.yaml "https://sub.example.com/api?token=abc&flag=1"
    check_contains "网段已渲染进规则" /etc/mihomo/config.yaml "IP-CIDR,10.0.0.0/24,DIRECT,no-resolve"
    check_contains "secret 已生成非占位" /etc/mihomo/config.yaml "secret: "
    check_not_contains "secret 不再是占位符" /etc/mihomo/config.yaml "CHANGE_ME_SECRET"
    check "tproxy.env 已生成" test -f /etc/mihomo/tproxy.env
    check_contains "tproxy.env 网卡正确" /etc/mihomo/tproxy.env 'LAN_IFACE="eth0"'
    check_contains "tproxy.env 网段正确" /etc/mihomo/tproxy.env 'LAN_SUBNET="10.0.0.0/24"'
    check "UI 已装" test -f /etc/mihomo/ui/index.html
    check "地数据库已预置" test -f /etc/mihomo/Country.mmdb
    check "服务已启动" test "$(cat "$STATE/svc-active")" = "1"
    check_eq "规则已建" 1 "$(rule_count)"
    check_contains "阶段日志含 [下载]" "$OUT" "[下载]"
    check_contains "阶段日志含 [配置]" "$OUT" "[配置]"
    check_contains "阶段日志含 [校验]" "$OUT" "[校验]"
    check_contains "阶段日志含 [预检]（P1-6）" "$OUT" "[预检]"
    check_contains "预检通过" "$OUT" "系统预检通过"
    check_eq "单网段 tproxy.env 仍为两行格式（P1-7/P1-8 默认）" 2 "$(wc -l < /etc/mihomo/tproxy.env)"
    check_contains "确认页显示入口网卡自动检测" "$OUT" "自动检测"
    check_contains "确认页显示 IPv6 状态" "$OUT" "系统未启用 IPv6"
    check "安装日志文件已写" test -s /var/log/mihomo-install.log
    check_contains "安装日志含阶段前缀" /var/log/mihomo-install.log "[校验]"
    check "verify.sh 已装到 /etc/mihomo" test -x /etc/mihomo/verify.sh
    check "成功后无 .bak 残留" test ! -f /usr/local/bin/mihomo.bak
    check "成功后无事务目录残留" test -z "$(ls -d /tmp/mgb-txn.* 2>/dev/null)"
}

t_I2_reinstall_keeps_config() {
    begin_test "I2_重装默认保留配置"
    seed_running_install
    run_install '\n\n\n\n\ny\n'
    check_exit "重装（留空订阅、默认保留）exit 0" 0 "$?"
    check_contains "旧订阅保留" /etc/mihomo/config.yaml "https://old-sub.example.com/sub?token=OLD123&x=1"
    check_contains "自定义规则保留" /etc/mihomo/config.yaml "DOMAIN-SUFFIX,custom.example.com,DIRECT"
    check_contains "自定义 DNS 保留" /etc/mihomo/config.yaml "8.8.8.8"
    check_contains "旧密钥复用" /etc/mihomo/config.yaml 'secret: "OLDSECRET1234567890abcdef"'
    check_contains "maintain.env 密钥无引号复用（双引号基线）" /etc/mihomo/maintain.env 'API_SECRET="OLDSECRET1234567890abcdef"'
    check_contains "网段规则保留" /etc/mihomo/config.yaml "IP-CIDR,10.0.0.0/24,DIRECT,no-resolve"
    check "配置备份已生成" test -n "$(ls /etc/mihomo/config.yaml.bak.* 2>/dev/null)"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    check_eq "规则重建后恰 1 条" 1 "$(rule_count)"
    check_contains "输出保留提示" "$OUT" "保留现有配置"
}

t_I3_reinstall_new_subnet() {
    begin_test "I3_重装换网段只改网段规则"
    seed_running_install
    run_install '\n192.168.5.0/24\n\n\n\ny\n'
    check_exit "重装换网段 exit 0" 0 "$?"
    check_contains "网段规则已更新" /etc/mihomo/config.yaml "IP-CIDR,192.168.5.0/24,DIRECT,no-resolve"
    check_not_contains "旧网段规则已移除" /etc/mihomo/config.yaml "IP-CIDR,10.0.0.0/24,DIRECT,no-resolve"
    check_contains "tproxy.env 已更新" /etc/mihomo/tproxy.env 'LAN_SUBNET="192.168.5.0/24"'
    check_contains "旧订阅仍保留" /etc/mihomo/config.yaml "https://old-sub.example.com/sub?token=OLD123&x=1"
    check_contains "自定义规则仍保留" /etc/mihomo/config.yaml "DOMAIN-SUFFIX,custom.example.com,DIRECT"
}

t_I4_reinstall_overwrite() {
    begin_test "I4_重装显式覆盖重渲染但订阅沿用"
    seed_running_install
    run_install '\n\n\n\ny\ny\n'
    check_exit "重装显式覆盖 exit 0" 0 "$?"
    check_not_contains "自定义规则已被模板覆盖" /etc/mihomo/config.yaml "DOMAIN-SUFFIX,custom.example.com,DIRECT"
    check_not_contains "自定义 DNS 已被模板覆盖" /etc/mihomo/config.yaml "8.8.8.8"
    check_contains "旧订阅沿用未丢" /etc/mihomo/config.yaml "https://old-sub.example.com/sub?token=OLD123&x=1"
    check_contains "旧密钥复用" /etc/mihomo/config.yaml 'secret: "OLDSECRET1234567890abcdef"'
    check "旧配置备份仍在" test -n "$(ls /etc/mihomo/config.yaml.bak.* 2>/dev/null)"
}

t_I5_reinstall_new_sub() {
    begin_test "I5_重装换订阅只改订阅行"
    seed_running_install
    run_install '\n\nhttps://brand-new.example.com/s?k=NEW&z=9\n\n\ny\n'
    check_exit "重装换订阅 exit 0" 0 "$?"
    check_contains "新订阅已写入" /etc/mihomo/config.yaml "https://brand-new.example.com/s?k=NEW&z=9"
    check_contains "health-check url 未被误改" /etc/mihomo/config.yaml "https://www.gstatic.com/generate_204"
    check_contains "自定义规则仍保留" /etc/mihomo/config.yaml "DOMAIN-SUFFIX,custom.example.com,DIRECT"
    check_contains "自定义 DNS 仍保留" /etc/mihomo/config.yaml "8.8.8.8"
}

t_I6_rollback_on_config_test_fail() {
    begin_test "I6_自检失败回滚恢复旧版"
    seed_running_install
    touch "$STATE/mihomo-t-fail"
    run_install '\n\n\n\n\ny\n'
    check_exit "自检失败时安装 exit 1" 1 "$?"
    check_contains "输出回滚开始" "$OUT" "[回滚]"
    check_contains "报告失败阶段为自检" "$OUT" "[自检]"
    check_contains "报告回滚成功" "$OUT" "回滚成功"
    check_contains "回滚后确认 API 已就绪（P1-13）" "$OUT" "API 已就绪"
    check_contains "旧二进制已恢复" /usr/local/bin/mihomo "OLD-BINARY-MARKER"
    check_eq "旧二进制哈希与安装前一致" "$(cat "$STATE/old-bin.sha256")" "$(sha256sum /usr/local/bin/mihomo | awk '{print $1}')"
    check "旧配置已恢复（与安装前逐字节一致）" cmp -s /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    check_contains "旧 UI 已恢复" /etc/mihomo/ui/index.html "OLD-UI-MARKER"
    check "服务已恢复运行" test "$(cat "$STATE/svc-active")" = "1"
    check_eq "规则已重建" 1 "$(rule_count)"
    check "回滚后无 .bak 残留" test ! -f /usr/local/bin/mihomo.bak
    check "事务快照目录保留供比对" test -n "$(ls -d /tmp/mgb-txn.* 2>/dev/null)"
    rm -f "$STATE/mihomo-t-fail"
}

t_I7_rollback_on_tproxy_fail() {
    begin_test "I7_TPROXY失败回滚恢复旧版"
    seed_running_install
    touch "$STATE/ip-rule-add-fail-once"
    run_install '\n\n\n\n\ny\n'
    check_exit "TPROXY 失败时安装 exit 1" 1 "$?"
    check_contains "输出回滚开始" "$OUT" "[回滚]"
    check_contains "报告回滚成功" "$OUT" "回滚成功"
    check_contains "回滚后确认 API 已就绪（P1-13）" "$OUT" "API 已就绪"
    check_contains "旧二进制已恢复" /usr/local/bin/mihomo "OLD-BINARY-MARKER"
    check "旧配置已恢复" cmp -s /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    check "服务已恢复运行" test "$(cat "$STATE/svc-active")" = "1"
    check_eq "规则已重建" 1 "$(rule_count)"
}

t_I8_rollback_on_api_fail() {
    begin_test "I8_API未就绪回滚恢复旧版但如实报告API异常（30秒轮询+30秒回滚API轮询）"
    seed_running_install
    touch "$STATE/api-fail"
    # 回滚 API 轮询默认 30 秒（与安装校验一致；真机实测 N1 冷启动需
    # 12 秒以上，10 秒会误报）；测试用 3 次提速，默认值用静态断言锁定。
    ROLLBACK_API_TRIES=3 run_install '\n\n\n\n\ny\n'
    check_exit "API 未就绪时安装 exit 1" 1 "$?"
    check_contains "输出回滚开始" "$OUT" "[回滚]"
    # P1-13 行为变化（修复 P0 已知限制第 2 条）：回滚后服务 active 但
    # API 仍未就绪时，不再报告"回滚成功"，而是如实报告未完全成功。
    check_contains "报告回滚未完全成功（API 未就绪）" "$OUT" "回滚未完全成功"
    check_contains "报告 API 未就绪" "$OUT" "API 在 3 秒内未就绪"
    check "回滚 API 默认轮询 30 次" grep -q 'ROLLBACK_API_TRIES="${ROLLBACK_API_TRIES:-30}"' "$REPO/scripts/install.sh"
    check_contains "旧二进制已恢复" /usr/local/bin/mihomo "OLD-BINARY-MARKER"
    check "旧配置已恢复" cmp -s /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    check "服务已恢复运行" test "$(cat "$STATE/svc-active")" = "1"
    rm -f "$STATE/api-fail"
}

t_I9_fresh_install_rollback() {
    begin_test "I9_全新安装失败回滚到未安装"
    reset_system
    touch "$STATE/mihomo-t-fail"
    run_install '\n\nhttps://sub.example.com/api?token=abc&flag=1\n\ny\n'
    check_exit "全新安装自检失败 exit 1" 1 "$?"
    check_contains "报告回滚成功" "$OUT" "回滚成功"
    check "/etc/mihomo 已移除" test ! -d /etc/mihomo
    check "新内核已移除" test ! -f /usr/local/bin/mihomo
    check "服务文件已移除" test ! -f /etc/systemd/system/mihomo.service
    check "cron 已移除" test ! -f /etc/cron.d/mihomo-maintain
    check "服务未运行" test "$(cat "$STATE/svc-active")" = "0"
    check_eq "无残留规则" 0 "$(rule_count)"
    rm -f "$STATE/mihomo-t-fail"
}

t_I10_fresh_install_rollback_stopped() {
    begin_test "I10_旧服务未运行时失败保持停止并清规则"
    seed_stopped_install
    touch "$STATE/mihomo-t-fail"
    run_install '\n\n\n\n\ny\n'
    check_exit "旧服务未运行时安装失败 exit 1" 1 "$?"
    check_contains "报告回滚成功" "$OUT" "回滚成功"
    check "服务保持停止" test "$(cat "$STATE/svc-active")" = "0"
    check_eq "无残留规则" 0 "$(rule_count)"
    check_contains "旧二进制已恢复" /usr/local/bin/mihomo "OLD-BINARY-MARKER"
    check "旧配置已恢复" cmp -s /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    rm -f "$STATE/mihomo-t-fail"
}

t_I11_install_rejects_leading_zero() {
    begin_test "I11_安装时前导零网段当场拒绝且零修改"
    reset_system
    run_install '\n010.0.0.0/24\nhttps://sub.example.com/x\n\ny\n'
    check_exit "前导零网段安装 exit 1" 1 "$?"
    check_contains "报错提到前导 0" "$OUT" "前导 0"
    check_contains "未修改系统无需回滚" "$OUT" "无需回滚"
    check "未创建 /etc/mihomo" test ! -d /etc/mihomo
    check "未安装二进制" test ! -f /usr/local/bin/mihomo
}

t_I12_install_rejects_bad_cidr() {
    begin_test "I12_安装时越界网段当场拒绝"
    reset_system
    run_install '\n999.1.1.0/24\nhttps://sub.example.com/x\n\ny\n'
    check_exit "越界网段安装 exit 1" 1 "$?"
    check_contains "报错提到数值超出范围" "$OUT" "数值超出范围"
}

t_I13_install_cancel() {
    begin_test "I13_确认页取消零修改"
    reset_system
    run_install '\n\nhttps://sub.example.com/x\n\nn\n'
    check_exit "取消安装 exit 0" 0 "$?"
    check "未创建 /etc/mihomo" test ! -d /etc/mihomo
    check_contains "输出已取消" "$OUT" "已取消安装"
}

t_I14_install_bad_sub_url() {
    begin_test "I14_非法订阅链接当场拒绝"
    reset_system
    run_install '\n\nnot-a-url\n\ny\n'
    check_exit "非法订阅链接安装 exit 1" 1 "$?"
    check_contains "报错提到订阅链接格式" "$OUT" "订阅链接格式不对"
}

# ------------------------------------------------------------------
# L 组：全局锁冲突（P0-4）
# ------------------------------------------------------------------
t_L1_install_locked() {
    begin_test "L1_锁被占时安装明示拒绝"
    reset_system
    hold_lock
    run_install '\nhttps://sub.example.com/x\ny\n'
    rc=$?
    release_lock
    check_exit "锁被占时安装 exit 1" 1 "$rc"
    check_contains "报错提到锁与等待" "$OUT" "正在运行"
    check "锁冲突时未创建 /etc/mihomo" test ! -d /etc/mihomo
}

t_L2_uninstall_locked() {
    begin_test "L2_锁被占时卸载明示拒绝"
    seed_running_install
    hold_lock
    bash "$REPO/scripts/uninstall.sh" >> "$OUT" 2>&1
    rc=$?
    release_lock
    check_exit "锁被占时卸载 exit 1" 1 "$rc"
    check_contains "报错提到锁" "$OUT" "正在运行"
    check "锁冲突时服务未被停" test "$(cat "$STATE/svc-active")" = "1"
}

t_L3_switch_sub_locked() {
    begin_test "L3_锁被占时换订阅明示拒绝"
    seed_running_install
    hold_lock
    bash "$REPO/scripts/switch-sub.sh" "https://x.example.com/y" >> "$OUT" 2>&1
    rc=$?
    release_lock
    check_exit "锁被占时换订阅 exit 1" 1 "$rc"
    check_contains "报错提到锁" "$OUT" "正在运行"
    check_contains "配置未被改动" /etc/mihomo/config.yaml "https://old-sub.example.com/sub?token=OLD123&x=1"
}

t_L4_restore_locked() {
    begin_test "L4_锁被占时恢复明示拒绝"
    seed_keep_config_uninstalled
    hold_lock
    bash "$REPO/scripts/restore.sh" >> "$OUT" 2>&1
    rc=$?
    release_lock
    check_exit "锁被占时恢复 exit 1" 1 "$rc"
    check_contains "报错提到锁" "$OUT" "正在运行"
}

# ------------------------------------------------------------------
# P5 组：模板新增键迁移（P1-5）
# ------------------------------------------------------------------
t_P5a_template_keys_merged() {
    begin_test "P5a_模板新增键合并进旧配置"
    seed_running_install
    # 模拟"旧配置缺模板键"：删掉两个单行键与整个 dns 块
    sed -i '/^mode: rule$/d; /^log-level: warning$/d' /etc/mihomo/config.yaml
    sed -i '/^dns:/,/^proxy-providers:/{ /^proxy-providers:/!d }' /etc/mihomo/config.yaml
    run_install '\n\n\n\n\ny\n'
    check_exit "缺键重装 exit 0" 0 "$?"
    check_contains "mode 键已合并" /etc/mihomo/config.yaml "mode: rule"
    check_contains "log-level 键已合并" /etc/mihomo/config.yaml "log-level: warning"
    check_contains "dns 块已合并" /etc/mihomo/config.yaml "fake-ip-range: 198.18.0.0/15"
    check_contains "合并的 dns 块用模板上游" /etc/mihomo/config.yaml "223.5.5.5"
    check_eq "mode 键无重复" 1 "$(grep -c '^mode:' /etc/mihomo/config.yaml)"
    check_eq "dns 键无重复" 1 "$(grep -c '^dns:' /etc/mihomo/config.yaml)"
    check_contains "旧订阅仍保留" /etc/mihomo/config.yaml "https://old-sub.example.com/sub?token=OLD123&x=1"
    check_contains "自定义规则仍保留" /etc/mihomo/config.yaml "DOMAIN-SUFFIX,custom.example.com,DIRECT"
    check_contains "旧密钥仍复用" /etc/mihomo/config.yaml 'secret: "OLDSECRET1234567890abcdef"'
    check_contains "输出合并提示" "$OUT" "合并新增配置项"
}

t_P5b_no_missing_keys_no_merge() {
    begin_test "P5b_无缺失键时不合并也不重复"
    seed_running_install
    run_install '\n\n\n\n\ny\n'
    check_exit "全键重装 exit 0" 0 "$?"
    check_not_contains "无缺失键时不输出合并提示" "$OUT" "合并新增配置项"
    check_eq "dns 键仍恰 1 个" 1 "$(grep -c '^dns:' /etc/mihomo/config.yaml)"
    check_contains "自定义 DNS 未被模板覆盖" /etc/mihomo/config.yaml "8.8.8.8"
}

# ------------------------------------------------------------------
# P6 组：系统兼容性预检（P1-6）
# ------------------------------------------------------------------
t_P6a_missing_wget_fails_preflight() {
    begin_test "P6a_缺wget预检失败并给手动指引"
    reset_system
    # 造一个不含 wget 的 PATH：常用命令 + 除 wget 外的桩全部软链进来，
    # 真实 /usr/bin/wget 也被排除在外。
    local bindir="$STATE/bin-nowget"
    mkdir -p "$bindir"
    local c p
    for c in bash id date grep uname sed awk cat cp mv rm mkdir chmod sleep seq head tail tr cut sort wc du tar gzip sha256sum flock openssl stat ls find env dirname pwd touch tee mktemp diff; do
        p=$(command -v "$c" 2>/dev/null || true)
        [ -n "$p" ] && ln -sf "$p" "$bindir/$c"
    done
    local s
    for s in ip iptables ip6tables systemctl curl mihomo; do
        ln -sf "$STUBS/$s" "$bindir/$s"
    done
    PATH="$bindir" run_install '\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "缺 wget 时安装 exit 1" 1 "$?"
    check_contains "报错提到 wget" "$OUT" "wget"
    check_contains "给出手动安装指引" "$OUT" "手动安装"
    check_contains "声明不自动安装依赖" "$OUT" "不自动安装系统依赖"
    check_contains "未修改系统无需回滚" "$OUT" "无需回滚"
    check "预检失败时未创建 /etc/mihomo" test ! -d /etc/mihomo
}

t_P6b_tproxy_probe_fail() {
    begin_test "P6b_TPROXY探测失败预检中止且无残留"
    reset_system
    touch "$STATE/iptables-tproxy-fail"
    run_install '\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "TPROXY 不支持时安装 exit 1" 1 "$?"
    check_contains "报错提到 TPROXY" "$OUT" "TPROXY"
    check_contains "未修改系统无需回滚" "$OUT" "无需回滚"
    check "预检失败时未创建 /etc/mihomo" test ! -d /etc/mihomo
    check "探测链无残留" test -z "$(ls "$STATE"/ipt-mangle-MGB-PROBE-* 2>/dev/null)"
}

t_P6c_unknown_distro_warns_and_continues() {
    begin_test "P6c_未知发行版警告后继续安装"
    reset_system
    MGB_OS_RELEASE="$FIXTURES/os-release-unknown" run_install '\n\nhttps://sub.example.com/api?token=abc&flag=1\n\ny\n'
    check_exit "未知发行版安装 exit 0" 0 "$?"
    check_contains "输出未在支持清单警告" "$OUT" "未在支持清单中"
    check "服务已启动" test "$(cat "$STATE/svc-active")" = "1"
}

t_P6d_alpine_rejected() {
    begin_test "P6d_Alpine明确不兼容被拒绝"
    reset_system
    MGB_OS_RELEASE="$FIXTURES/os-release-alpine" run_install '\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "Alpine 安装 exit 1" 1 "$?"
    check_contains "报错提到 Alpine 不受支持" "$OUT" "明确不受支持"
    check "拒绝时未创建 /etc/mihomo" test ! -d /etc/mihomo
}

t_P6e_armbian_supported() {
    begin_test "P6e_Armbian识别为支持"
    reset_system
    MGB_OS_RELEASE="$FIXTURES/os-release-armbian" run_install '\n\nhttps://sub.example.com/api?token=abc&flag=1\n\ny\n'
    check_exit "Armbian 安装 exit 0" 0 "$?"
    check_contains "识别为 Armbian" "$OUT" "Armbian"
    check "服务已启动" test "$(cat "$STATE/svc-active")" = "1"
}

# ------------------------------------------------------------------
# P7 组：多网卡与多网段（P1-7）
# ------------------------------------------------------------------
t_P7a_multi_subnet_tproxy() {
    begin_test "P7a_多网段走分发子链"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'LAN_SUBNETS="10.0.0.0/24,192.168.5.0/24"\n' >> /etc/mihomo/tproxy.env
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "多网段 exit 0" 0 "$?"
    check_eq "MIHOMO 分发链内容" "$(printf '%s\n' '! -i eth0 -j RETURN' '-s 10.0.0.0/24 -j MIHOMO_DO' '-s 192.168.5.0/24 -j MIHOMO_DO' '-j RETURN')" "$(cat "$STATE/ipt-mangle-MIHOMO.txt")"
    check_eq "MIHOMO_DO 子链共 10 条规则" 10 "$(wc -l < "$STATE/ipt-mangle-MIHOMO_DO.txt")"
    check_contains "MIHOMO_DO 含 TCP TPROXY" "$STATE/ipt-mangle-MIHOMO_DO.txt" "-p tcp -j TPROXY --on-port 7893 --tproxy-mark 1"
    check_contains "MIHOMO_DO 含 UDP TPROXY" "$STATE/ipt-mangle-MIHOMO_DO.txt" "-p udp -j TPROXY --on-port 7893 --tproxy-mark 1"
    check_eq "MIHOMO_DNS 分发链内容" "$(printf '%s\n' '! -i eth0 -j RETURN' '-s 10.0.0.0/24 -j MIHOMO_DNS_DO' '-s 192.168.5.0/24 -j MIHOMO_DNS_DO' '-j RETURN')" "$(cat "$STATE/ipt-nat-MIHOMO_DNS.txt")"
    check_eq "MIHOMO_DNS_DO 子链共 3 条规则" 3 "$(wc -l < "$STATE/ipt-nat-MIHOMO_DNS_DO.txt")"
    check_eq "fwmark 规则恰 1 条" 1 "$(rule_count)"
    check_eq "mangle 跳转恰 1 条" 1 "$(jump_count mangle MIHOMO)"
    bash "$REPO/scripts/tproxy.sh" stop >> "$OUT" 2>&1
    check_exit "stop exit 0" 0 "$?"
    check "stop 后 MIHOMO_DO 已删" test ! -f "$STATE/ipt-mangle-MIHOMO_DO.txt"
    check "stop 后 MIHOMO_DNS_DO 已删" test ! -f "$STATE/ipt-nat-MIHOMO_DNS_DO.txt"
    check_eq "stop 后 fwmark 规则 0 条" 0 "$(rule_count)"
}

t_P7b_multi_subnet_bad_entry() {
    begin_test "P7b_多网段中一项非法则整体拒绝"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'LAN_SUBNETS="10.0.0.0/24,999.1.1.0/24"\n' >> /etc/mihomo/tproxy.env
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "含非法网段时 exit 1" 1 "$?"
    check_contains "报错提到数值超出范围" "$OUT" "数值超出范围"
    check_eq "拒绝后未建任何规则" 0 "$(rule_count)"
}

t_P7c_multi_subnet_dedup() {
    begin_test "P7c_重复网段去重后走单网段布局"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'LAN_SUBNETS="10.0.0.0/24,10.0.0.0/24"\n' >> /etc/mihomo/tproxy.env
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "重复网段 exit 0" 0 "$?"
    check "去重后不建 MIHOMO_DO" test ! -f "$STATE/ipt-mangle-MIHOMO_DO.txt"
    check_contains "去重后仍为单网段守卫" "$STATE/ipt-mangle-MIHOMO.txt" "! -s 10.0.0.0/24 -j RETURN"
}

t_P7d_install_manual_iface_multi_subnet() {
    begin_test "P7d_安装手动指定网卡与多网段"
    reset_system
    printf '%s\n' "eth1" >> "$STATE/ifaces.txt"
    run_install 'eth1\n192.168.5.0/24,10.0.0.0/24\nhttps://sub.example.com/x\n\ny\n'
    check_exit "手动网卡+多网段安装 exit 0" 0 "$?"
    check_contains "tproxy.env 网卡为手动指定" /etc/mihomo/tproxy.env 'LAN_IFACE="eth1"'
    check_contains "tproxy.env 主网段为第一项" /etc/mihomo/tproxy.env 'LAN_SUBNET="192.168.5.0/24"'
    check_contains "tproxy.env 含多网段列表" /etc/mihomo/tproxy.env 'LAN_SUBNETS="192.168.5.0/24,10.0.0.0/24"'
    check_contains "配置规则用主网段" /etc/mihomo/config.yaml "IP-CIDR,192.168.5.0/24,DIRECT,no-resolve"
    check_contains "确认页标注手动指定" "$OUT" "手动指定"
    check "服务启动后已建 MIHOMO_DO" test -f "$STATE/ipt-mangle-MIHOMO_DO.txt"
    check "服务已启动" test "$(cat "$STATE/svc-active")" = "1"
}

t_P7e_public_ip_respecify() {
    begin_test "P7e_公网IP警告后改指定网卡"
    reset_system
    printf '%s\n' "eth1" >> "$STATE/ifaces.txt"
    touch "$STATE/public-ip"
    run_install '\nn\neth1\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "改指定后安装 exit 0" 0 "$?"
    check_contains "输出公网地址警告" "$OUT" "公网地址"
    check_contains "警告提到 WAN 口" "$OUT" "WAN"
    check_contains "tproxy.env 网卡为改指定的 eth1" /etc/mihomo/tproxy.env 'LAN_IFACE="eth1"'
    check_contains "tproxy.env 网段取 eth1 直连网段" /etc/mihomo/tproxy.env 'LAN_SUBNET="192.168.5.0/24"'
}

t_P7f_public_ip_confirm() {
    begin_test "P7f_公网IP警告后显式确认继续"
    reset_system
    touch "$STATE/public-ip"
    run_install '\ny\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "显式确认后安装 exit 0" 0 "$?"
    check_contains "输出公网地址警告" "$OUT" "公网地址"
    check_contains "tproxy.env 网卡仍为默认 eth0" /etc/mihomo/tproxy.env 'LAN_IFACE="eth0"'
}

t_P7g_docker_noted_not_excluded() {
    begin_test "P7g_Docker网络只提示不自动排除"
    reset_system
    printf '%s\n' "docker0" >> "$STATE/ifaces.txt"
    run_install '\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "有 Docker 时安装 exit 0" 0 "$?"
    check_contains "确认页提示 Docker 网络" "$OUT" "docker0"
    check_contains "提示不接管 Docker 网段" "$OUT" "不会接管 Docker 网段"
    check_not_contains "MIHOMO 链不含 Docker 网段" "$STATE/ipt-mangle-MIHOMO.txt" "172.17"
}

t_P7h_single_subnet_byte_identical() {
    begin_test "P7h_单网段规则与v1.1.0布局逐字节一致"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "单网段 exit 0" 0 "$?"
    check_eq "MIHOMO 链逐字节一致" "$(printf '%s\n' '! -i eth0 -j RETURN' '! -s 10.0.0.0/24 -j RETURN' '-d 0.0.0.0/8 -j RETURN' '-d 10.0.0.0/8 -j RETURN' '-d 127.0.0.0/8 -j RETURN' '-d 169.254.0.0/16 -j RETURN' '-d 172.16.0.0/12 -j RETURN' '-d 192.168.0.0/16 -j RETURN' '-d 224.0.0.0/4 -j RETURN' '-d 240.0.0.0/4 -j RETURN' '-p tcp -j TPROXY --on-port 7893 --tproxy-mark 1' '-p udp -j TPROXY --on-port 7893 --tproxy-mark 1')" "$(cat "$STATE/ipt-mangle-MIHOMO.txt")"
    check_eq "MIHOMO_DNS 链逐字节一致" "$(printf '%s\n' '! -i eth0 -j RETURN' '! -s 10.0.0.0/24 -j RETURN' '-d 127.0.0.0/8 -j RETURN' '-p udp --dport 53 -j REDIRECT --to-ports 1053' '-p tcp --dport 53 -j REDIRECT --to-ports 1053')" "$(cat "$STATE/ipt-nat-MIHOMO_DNS.txt")"
    check "单网段不建 MIHOMO_DO" test ! -f "$STATE/ipt-mangle-MIHOMO_DO.txt"
    check "单网段不建 MIHOMO_DNS_DO" test ! -f "$STATE/ipt-nat-MIHOMO_DNS_DO.txt"
    check "单网段不建 MIHOMO_V6" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
}

# ------------------------------------------------------------------
# P8 组：IPv6 安全策略（P1-8）
# ------------------------------------------------------------------
t_P8a_v6_block_builds_rules() {
    begin_test "P8a_启用IPv6阻断建规则"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "启用阻断时 exit 0" 0 "$?"
    check "MIHOMO_V6 链已建" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check_eq "MIHOMO_V6 链内容" "$(printf '%s\n' '! -i eth0 -j RETURN' '-s 2408:8207:1234:5678::5/64 -j DROP')" "$(cat "$STATE/ip6-ipt-filter-MIHOMO_V6.txt")"
    check_eq "FORWARD 跳转恰 1 条" 1 "$(grep -c -- '-j MIHOMO_V6' "$STATE/ip6-ipt-filter-FORWARD.txt" 2>/dev/null || true)"
    check_contains "输出阻断已启用" "$OUT" "IPv6 阻断已启用"
    check_eq "IPv4 规则同时正常建成" 1 "$(rule_count)"
}

t_P8b_v6_block_no_prefix() {
    begin_test "P8b_启用阻断但无LAN前缀时警告不建规则"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    # V6_WAIT_SECS=0：不等，零等待走警告分支（等满超时的行为由 P8g 测）。
    V6_WAIT_SECS=0 bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "无前缀时仍 exit 0" 0 "$?"
    check_contains "警告无全局 IPv6 地址" "$OUT" "未出现全局 IPv6 地址"
    check "未建 MIHOMO_V6 链" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check_eq "IPv4 规则仍正常建成" 1 "$(rule_count)"
}

t_P8c_v6_block_stop_cleans() {
    begin_test "P8c_stop清理IPv6阻断规则"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "先建规则 exit 0" 0 "$?"
    check "建规则后 MIHOMO_V6 存在" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    bash "$REPO/scripts/tproxy.sh" stop >> "$OUT" 2>&1
    check_exit "stop exit 0" 0 "$?"
    check "stop 后 MIHOMO_V6 已删" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check_not_contains "stop 后 FORWARD 无 MIHOMO_V6 跳转" "$STATE/ip6-ipt-filter-FORWARD.txt" "-j MIHOMO_V6"
    bash "$REPO/scripts/tproxy.sh" stop >> "$OUT" 2>&1
    check_exit "stop 幂等：第二次仍 exit 0" 0 "$?"
}

t_P8d_install_v6_block_on() {
    begin_test "P8d_安装时LAN有IPv6且启用阻断"
    reset_system
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    run_install '\n\nhttps://sub.example.com/x\ny\n\ny\n'
    check_exit "启用阻断安装 exit 0" 0 "$?"
    check_contains "确认页警告可绕过" "$OUT" "可绕过"
    check_contains "确认页显示 IPv6 前缀" "$OUT" "2408:8207:1234:5678::5/64"
    check_contains "tproxy.env 含 IPV6_BLOCK=1" /etc/mihomo/tproxy.env 'IPV6_BLOCK="1"'
    check "服务启动后已建 MIHOMO_V6" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
}

t_P8e_install_v6_block_off() {
    begin_test "P8e_安装时LAN有IPv6但不启用阻断"
    reset_system
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    run_install '\n\nhttps://sub.example.com/x\n\n\ny\n'
    check_exit "不启用阻断安装 exit 0" 0 "$?"
    check_contains "确认页警告可绕过" "$OUT" "可绕过"
    check_contains "安装结束再次警告" "$OUT" "IPv6 流量不受代理保护"
    check_not_contains "tproxy.env 不含 IPV6_BLOCK" /etc/mihomo/tproxy.env "IPV6_BLOCK"
    check "未建 MIHOMO_V6 链" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
}

t_P8f_v6_block_waits_for_prefix() {
    begin_test "P8f_开机时序：IPv6地址晚到时等待后建链（2026-11-13真机重启复现）"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled"
    # 地址两次查询后出现（模拟 SLAAC 晚到）；等待上限 10 秒足够覆盖。
    printf '2' > "$STATE/ipv6-lan-delayed"
    V6_WAIT_SECS=10 bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "晚到地址时 exit 0" 0 "$?"
    check "MIHOMO_V6 链已建" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check_eq "MIHOMO_V6 链内容" "$(printf '%s\n' '! -i eth0 -j RETURN' '-s 2408:8207:1234:5678::5/64 -j DROP')" "$(cat "$STATE/ip6-ipt-filter-MIHOMO_V6.txt")"
    check_contains "输出阻断已启用" "$OUT" "IPv6 阻断已启用"
}

t_P8g_v6_block_wait_timeout() {
    begin_test "P8g_等满超时仍无地址时警告不建规则"
    reset_system
    write_tproxy_env eth0 "10.0.0.0/24"
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled"
    V6_WAIT_SECS=2 bash "$REPO/scripts/tproxy.sh" >> "$OUT" 2>&1
    check_exit "超时时仍 exit 0" 0 "$?"
    check_contains "警告等满超时" "$OUT" "在 2 秒内未出现全局 IPv6 地址"
    check "未建 MIHOMO_V6 链" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check "等待默认 60 秒" grep -q 'V6_WAIT_SECS="${V6_WAIT_SECS:-60}"' "$REPO/scripts/tproxy.sh"
}

# ------------------------------------------------------------------
# P9 组：面板监听选项（P1-9）
# ------------------------------------------------------------------
t_P9a_fresh_install_local_only() {
    begin_test "P9a_全新安装选仅本机面板"
    reset_system
    run_install '\n\nhttps://sub.example.com/x\n2\ny\n'
    check_exit "仅本机安装 exit 0" 0 "$?"
    check_contains "配置监听 127.0.0.1:9090" /etc/mihomo/config.yaml "external-controller: 127.0.0.1:9090"
    check_contains "输出仅本机可访问" "$OUT" "仅本机可访问"
    check_contains "输出本机面板地址" "$OUT" "http://127.0.0.1:9090/ui"
    check_contains "输出远程访问提醒" "$OUT" "不要直接向公网开放 9090 端口"
    check_contains "维护 API 仍走本机" /etc/mihomo/maintain.env 'API="http://127.0.0.1:9090"'
}

t_P9b_fresh_install_lan_default() {
    begin_test "P9b_全新安装默认局域网面板"
    reset_system
    run_install '\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "默认 LAN 安装 exit 0" 0 "$?"
    check_contains "配置监听 0.0.0.0:9090" /etc/mihomo/config.yaml "external-controller: 0.0.0.0:9090"
    check_contains "输出局域网面板地址" "$OUT" "http://10.0.0.201:9090/ui"
    check_contains "输出远程访问提醒" "$OUT" "不要直接向公网开放 9090 端口"
}

t_P9c_reinstall_switch_to_local() {
    begin_test "P9c_重装把面板从LAN切到仅本机"
    seed_running_install
    run_install '\n\n\n2\n\ny\n'
    check_exit "重装切仅本机 exit 0" 0 "$?"
    check_contains "配置已切到 127.0.0.1:9090" /etc/mihomo/config.yaml "external-controller: 127.0.0.1:9090"
    check_contains "输出监听更新提示" "$OUT" "已更新面板监听地址"
    check_contains "旧订阅仍保留" /etc/mihomo/config.yaml "https://old-sub.example.com/sub?token=OLD123&x=1"
    check_contains "自定义规则仍保留" /etc/mihomo/config.yaml "DOMAIN-SUFFIX,custom.example.com,DIRECT"
}

t_P9d_reinstall_keeps_local() {
    begin_test "P9d_重装默认沿用仅本机面板"
    seed_running_install
    sed -i 's|external-controller: 0.0.0.0:9090|external-controller: 127.0.0.1:9090|' /etc/mihomo/config.yaml
    run_install '\n\n\n\n\ny\n'
    check_exit "沿用仅本机重装 exit 0" 0 "$?"
    check_contains "配置仍为 127.0.0.1:9090" /etc/mihomo/config.yaml "external-controller: 127.0.0.1:9090"
    check_contains "确认页显示面板监听仅本机" "$OUT" "仅本机（127.0.0.1:9090）"
}

# ------------------------------------------------------------------
# P10 组：armv7 资产一致（P1-10）
# ------------------------------------------------------------------
t_P10a_manifest_consistent() {
    begin_test "P10a_资产清单与架构映射一致"
    python3 - "$REPO" >> "$OUT" 2>&1 <<'PYEOF'
import json, sys
repo = sys.argv[1]
m = json.load(open(f"{repo}/assets/manifest.json"))
sums = {}
for line in open(f"{repo}/assets/SHA256SUMS"):
    h, f = line.split()
    sums[f] = h
assert sum(a["size_bytes"] for a in m["assets"]) == m["total_size_bytes"], "total_size_bytes 不一致"
names = [a["name"] for a in m["assets"]]
assert "mihomo-linux-armv7" in names, "清单缺 armv7"
for a in m["assets"]:
    assert sums.get(a["filename"]) == a["sha256"], f"SHA256SUMS 与清单不一致：{a['filename']}"
print("manifest/SHA256SUMS 一致，含 armv7")
PYEOF
    check_exit "清单一致性检查 exit 0" 0 "$?"
    check_contains "清单含 armv7" "$OUT" "含 armv7"
    check "install.sh 架构映射含 armv7l" grep -q 'armv7l) *BIN_ARCH="armv7"' "$REPO/scripts/install.sh"
    check "restore.sh 架构映射含 armv7l" grep -q 'armv7l) *BIN_ARCH="armv7"' "$REPO/scripts/restore.sh"
    check "auto-maintain 用 BIN_ARCH 拼内核名" grep -q 'mihomo-linux-${BIN_ARCH}-' "$REPO/scripts/auto-maintain.sh"
    check "清单含 amd64/arm64/armv7 三档内核" test "$(grep -c 'mihomo-linux-' "$REPO/assets/manifest.json")" -ge 3
}

# ------------------------------------------------------------------
# M11 组：自动更新双源校验与规则验证（P1/P2-11）
# 说明：种子旧二进制为 v1.18.0，桩 curl 报告最新版 v1.19.32，因此
# full 更新总会触发内核更新路径；mihomo 桩委托给已安装二进制，
# `mihomo -v` 反映已安装版本（与真机一致）。
# ------------------------------------------------------------------
t_M11a_full_dual_source_match() {
    begin_test "M11a_full更新双源哈希一致_内核升级"
    seed_running_install
    bash "$REPO/scripts/auto-maintain.sh" full >> "$OUT" 2>&1
    check_exit "full exit 0" 0 "$?"
    check_contains "日志记录双源哈希一致" /var/log/mihomo-maintain.log "双源 sha256 一致"
    check_contains "新内核已替换" /usr/local/bin/mihomo "NEW-BINARY-MARKER"
    check_contains "面板 UI 已更新" /etc/mihomo/ui/index.html "fake metacubexd"
    check_not_contains "旧 UI 标记已消失" /etc/mihomo/ui/index.html "OLD-UI-MARKER"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    check_eq "规则仍在" 1 "$(rule_count)"
    check_contains "日志记录网络规则验证通过" /var/log/mihomo-maintain.log "网络规则验证通过"
    check_contains "日志记录订阅节点数" /var/log/mihomo-maintain.log "节点数：3"
    check_contains "更新日志含版本与结果" /var/log/mihomo-maintain.log "内核:v1.19.32"
}

t_M11b_full_dual_source_mismatch() {
    begin_test "M11b_双源哈希不一致_放弃内核更新"
    seed_running_install
    touch "$STATE/wget-kernel-second-differ"
    bash "$REPO/scripts/auto-maintain.sh" full >> "$OUT" 2>&1
    check_exit "full exit 0（内核放弃，UI 仍更新）" 0 "$?"
    check_contains "日志记录双源不一致" /var/log/mihomo-maintain.log "双源 sha256 不一致"
    check_contains "旧内核保留未被替换" /usr/local/bin/mihomo "OLD-BINARY-MARKER"
    check_contains "面板 UI 仍正常更新" /etc/mihomo/ui/index.html "fake metacubexd"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    rm -f "$STATE/wget-kernel-second-differ"
}

t_M11c_full_second_source_unreachable() {
    begin_test "M11c_第二源不可达_降级校验仍更新"
    seed_running_install
    touch "$STATE/wget-kernel-second-fail"
    bash "$REPO/scripts/auto-maintain.sh" full >> "$OUT" 2>&1
    check_exit "full exit 0" 0 "$?"
    check_contains "日志记录降级校验" /var/log/mihomo-maintain.log "降级为 gzip 完整性 + 版本自检"
    check_contains "新内核已替换（降级校验通过）" /usr/local/bin/mihomo "NEW-BINARY-MARKER"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    rm -f "$STATE/wget-kernel-second-fail"
}

t_M11e_full_rules_missing_warns() {
    begin_test "M11e_full更新后规则缺失记日志告警"
    seed_running_install
    touch "$STATE/drop-rules-after-start"
    bash "$REPO/scripts/auto-maintain.sh" full >> "$OUT" 2>&1
    check_exit "full exit 0（规则缺失只告警，不失败）" 0 "$?"
    check_contains "日志记录规则缺失告警" /var/log/mihomo-maintain.log "网络规则验证未通过"
    check_contains "日志点名缺失的链" /var/log/mihomo-maintain.log "MIHOMO 链缺失"
    check_eq "规则确实缺失（注入生效）" 0 "$(rule_count)"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    rm -f "$STATE/drop-rules-after-start"
}

# ------------------------------------------------------------------
# M12 组：全局锁覆盖核查（P1/P2-12）
# 行为部分由 L1–L4（手动明示拒绝）与 A1（cron 跳过）覆盖；本组做
# 静态一致性核查：五脚本同一锁路径、同一 flock 用法、无旧锁残留。
# ------------------------------------------------------------------
t_M12a_lock_coverage() {
    begin_test "M12a_五脚本共用同一把全局锁"
    local s
    for s in install.sh uninstall.sh switch-sub.sh restore.sh auto-maintain.sh; do
        check "$s 引用全局锁路径" grep -q 'mihomo-gateway\.lock' "$REPO/scripts/$s"
        check "$s 用 flock -n 非阻塞拿锁" grep -q 'flock -n 9' "$REPO/scripts/$s"
    done
    check "旧锁路径已无引用" test -z "$(grep -rl 'mihomo-maintain\.lock' "$REPO/scripts" "$REPO/systemd" "$REPO/cron" 2>/dev/null)"
    check "auto-maintain 拿不到锁时跳过（cron 语义）" grep -q '本次跳过' "$REPO/scripts/auto-maintain.sh"
    check "tproxy.sh 不拿锁（防 ExecStartPost 自锁）" test -z "$(grep 'flock' "$REPO/scripts/tproxy.sh" || true)"
    check "verify.sh 不拿锁（只读检查）" test -z "$(grep 'flock' "$REPO/scripts/verify.sh" || true)"
}

# ------------------------------------------------------------------
# M13 组：systemd 停止清理与启动限制（P1/P2-13）
# ------------------------------------------------------------------
t_M13a_stop_cleans_rules() {
    begin_test "M13a_停服务后ExecStopPost清掉规则"
    seed_running_install
    check_eq "停之前规则存在" 1 "$(rule_count)"
    systemctl stop mihomo >> "$OUT" 2>&1
    check "服务已停" test "$(cat "$STATE/svc-active")" = "0"
    check_eq "停服务后 fwmark 规则 0 条" 0 "$(rule_count)"
    check_eq "停服务后表 100 路由 0 条" 0 "$(route100_count)"
    check "停服务后 MIHOMO 链已删" test ! -f "$STATE/ipt-mangle-MIHOMO.txt"
    check "停服务后 MIHOMO_DNS 链已删" test ! -f "$STATE/ipt-nat-MIHOMO_DNS.txt"
}

t_M13b_restart_rebuilds_rules() {
    begin_test "M13b_重启先清后建规则仍在"
    seed_running_install
    systemctl restart mihomo >> "$OUT" 2>&1
    check_exit "restart exit 0" 0 "$?"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    check_eq "重启后 fwmark 规则恰 1 条（无重复）" 1 "$(rule_count)"
    check_eq "重启后 mangle 跳转恰 1 条" 1 "$(jump_count mangle MIHOMO)"
    check "重启后 MIHOMO 链存在" test -f "$STATE/ipt-mangle-MIHOMO.txt"
}

t_M13c_old_unit_leaves_rules() {
    begin_test "M13c_旧版单元无ExecStopPost_停服务后规则残留（修复前对照）"
    seed_running_install
    sed -i '/ExecStopPost/d' /etc/systemd/system/mihomo.service
    systemctl stop mihomo >> "$OUT" 2>&1
    check "服务已停" test "$(cat "$STATE/svc-active")" = "0"
    check_eq "旧版单元停服务后规则仍残留 1 条（黑洞）" 1 "$(rule_count)"
    check "旧版单元停服务后 MIHOMO 链仍在" test -f "$STATE/ipt-mangle-MIHOMO.txt"
}

t_M13d_unit_limits() {
    begin_test "M13d_单元含ExecStopPost与启动限制"
    check "单元含 ExecStopPost 清理规则" grep -q 'ExecStopPost=/bin/bash /etc/mihomo/tproxy.sh stop' "$REPO/systemd/mihomo.service"
    check "单元含 StartLimitBurst" grep -q 'StartLimitBurst=5' "$REPO/systemd/mihomo.service"
    check "单元含 StartLimitIntervalSec" grep -q 'StartLimitIntervalSec=300' "$REPO/systemd/mihomo.service"
    check "ExecStartPost 仍在" grep -q 'ExecStartPost=/bin/bash /etc/mihomo/tproxy.sh$' "$REPO/systemd/mihomo.service"
    check "Restart=always 仍在" grep -q 'Restart=always' "$REPO/systemd/mihomo.service"
    check "CapabilityBoundingSet 未动" grep -q 'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW' "$REPO/systemd/mihomo.service"
}

# ------------------------------------------------------------------
# V 组：verify.sh 健康自检（P1/P2-14）
# ------------------------------------------------------------------
t_V1_verify_healthy() {
    begin_test "V1_verify健康状态全通过"
    seed_running_install
    bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "健康时 verify exit 0" 0 "$?"
    check_contains "服务检查通过" "$OUT" "[PASS] 服务运行中"
    check_contains "API 检查通过" "$OUT" "[PASS] API 就绪"
    check_contains "TPROXY 链检查通过" "$OUT" "[PASS] TPROXY 规则链存在"
    check_contains "规则一致性检查通过" "$OUT" "[PASS] 规则与 tproxy.env 一致"
    check_contains "DNS 检查通过" "$OUT" "[PASS] DNS 劫持链存在"
    check_contains "DNS 重定向检查通过" "$OUT" "[PASS] DNS 重定向规则存在"
    check_contains "订阅检查通过" "$OUT" "[PASS] 订阅 provider 有节点"
    check_contains "订阅节点数来自缓存文件" "$OUT" "provider 节点总数：3"
    check_contains "汇总全通过" "$OUT" "自检通过"
    check_contains "输出 DNS 泄漏验证指引" "$OUT" "dnsleaktest.com"
}

t_V2_verify_service_down() {
    begin_test "V2_verify服务停止时失败并给指引"
    seed_stopped_install
    # 同 V6：API 永远不通，测试缩短重试，不空等默认的约 30 秒。
    VERIFY_API_TRIES=2 VERIFY_API_INTERVAL=0 bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "服务停止时 verify exit 1" 1 "$?"
    check_contains "服务检查失败" "$OUT" "[FAIL] 服务运行中"
    check_contains "API 检查失败" "$OUT" "[FAIL] API 就绪"
    check_contains "给出排查指引" "$OUT" "journalctl -u mihomo"
    check_contains "汇总失败" "$OUT" "自检失败"
}

t_V3_verify_rules_missing() {
    begin_test "V3_verify服务在跑但规则缺失"
    seed_running_install
    bash /etc/mihomo/tproxy.sh stop >> "$OUT" 2>&1
    bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "规则缺失时 verify exit 1" 1 "$?"
    check_contains "服务检查仍通过" "$OUT" "[PASS] 服务运行中"
    check_contains "API 检查仍通过" "$OUT" "[PASS] API 就绪"
    check_contains "TPROXY 链检查失败" "$OUT" "[FAIL] TPROXY 规则链存在"
    check_contains "策略路由检查失败" "$OUT" "[FAIL] 策略路由存在"
    check_contains "DNS 链检查失败" "$OUT" "[FAIL] DNS 劫持链存在"
    check_contains "订阅检查仍通过" "$OUT" "[PASS] 订阅 provider 有节点"
    check_contains "给出重建指引" "$OUT" "systemctl restart mihomo"
}

t_V4_verify_env_mismatch() {
    begin_test "V4_verify规则与tproxy.env不一致"
    seed_running_install
    printf 'LAN_IFACE="eth0"\nLAN_SUBNET="192.168.9.0/24"\n' > /etc/mihomo/tproxy.env
    bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "env 不一致时 verify exit 1" 1 "$?"
    check_contains "一致性检查失败" "$OUT" "[FAIL] 规则与 tproxy.env 一致"
    check_contains "点名缺失的网段守卫" "$OUT" "192.168.9.0/24"
    check_contains "TPROXY 链本身仍存在" "$OUT" "[PASS] TPROXY 规则链存在"
}

t_V5_verify_providers_empty() {
    begin_test "V5_verify订阅节点数为0"
    seed_running_install
    # 节点数为 0 走缓存文件：缓存存在但无 "- name: " 行（订阅为空）。
    printf 'proxies: []\n' > /etc/mihomo/providers/airport1.yaml
    bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "节点数为 0 时 verify exit 1" 1 "$?"
    check_contains "订阅检查失败" "$OUT" "[FAIL] 订阅 provider 有节点"
    check_contains "点名节点数为 0" "$OUT" "节点数为 0"
    check_contains "服务检查仍通过" "$OUT" "[PASS] 服务运行中"
}

t_V6_verify_api_down() {
    begin_test "V6_verify_API不可达时订阅检查跳过"
    seed_running_install
    touch "$STATE/api-fail"
    # API 永远不通时默认重试要等约 30 秒；测试用环境变量缩到 2 次，
    # 循环逻辑不变，只是不空等。
    VERIFY_API_TRIES=2 VERIFY_API_INTERVAL=0 bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "API 不可达时 verify exit 1" 1 "$?"
    check_contains "API 检查失败" "$OUT" "[FAIL] API 就绪"
    check_contains "订阅检查跳过而非误报" "$OUT" "[SKIP] 订阅 provider 有节点"
    rm -f "$STATE/api-fail"
}

t_V7_verify_dns_tolerates_m_match() {
    begin_test "V7_verify容忍真机iptables的-m写法输出"
    seed_running_install
    # 回归锚点：先证实桩的 -S 输出确实含 -m（否则本测试在旧 strict
    # 匹配下也能过，抓不到 bug）；再跑 verify，DNS 重定向必须 PASS。
    check "桩 -S 输出含 -m udp（归一化生效）" \
        bash -c 'iptables -t nat -S MIHOMO_DNS | grep -q -- "-p udp -m udp --dport 53"'
    check "桩 -S 输出含 -m tcp（归一化生效）" \
        bash -c 'iptables -t nat -S MIHOMO_DNS | grep -q -- "-p tcp -m tcp --dport 53"'
    check "桩 -S 的 TPROXY 规则不插 -m（真实行为）" \
        bash -c 'iptables -t mangle -S MIHOMO | grep -qF -- "-p tcp -j TPROXY --on-port 7893"'
    bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "归一化输出下 verify exit 0" 0 "$?"
    check_contains "DNS 重定向检查通过" "$OUT" "[PASS] DNS 重定向规则存在"
}

t_V8_verify_provider_cache_missing() {
    begin_test "V8_verify订阅缓存缺失时失败并给刷新指引"
    seed_running_install
    # PROVIDERS_DIR 指到空目录：缓存文件缺失（订阅从未成功拉取）。
    mkdir -p /tmp/v8-empty-providers
    PROVIDERS_DIR=/tmp/v8-empty-providers bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "缓存缺失时 verify exit 1" 1 "$?"
    check_contains "订阅检查失败" "$OUT" "[FAIL] 订阅 provider 有节点"
    check_contains "点名缓存文件缺失" "$OUT" "缓存文件缺失"
    check_contains "给出刷新指引" "$OUT" "auto-maintain.sh refresh"
    check_contains "服务检查仍通过" "$OUT" "[PASS] 服务运行中"
    rm -rf /tmp/v8-empty-providers
}

t_V9_verify_api_retry_recovers() {
    begin_test "V9_verify_API中途就绪时重试后通过"
    seed_running_install
    echo 0 > "$STATE/api-up"
    # API 在 1 秒后就绪：verify 必须靠重试等到它，而不是首试失败就判死。
    ( sleep 1; echo 1 > "$STATE/api-up" ) &
    local _flipper=$!
    VERIFY_API_TRIES=5 VERIFY_API_INTERVAL=1 bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    local _rc=$?
    wait "$_flipper" 2>/dev/null || true
    check_exit "重试等到 API 后 verify exit 0" 0 "$_rc"
    check_contains "API 检查通过" "$OUT" "[PASS] API 就绪"
    check_contains "订阅检查随后通过" "$OUT" "[PASS] 订阅 provider 有节点"
    # 生产默认值仍是 15 次 × 2 秒（约 30 秒），测试缩短只是提速。
    check "默认重试 15 次" grep -q 'VERIFY_API_TRIES="${VERIFY_API_TRIES:-15}"' "$REPO/scripts/verify.sh"
    check "默认重试间隔 2 秒" grep -q 'VERIFY_API_INTERVAL="${VERIFY_API_INTERVAL:-2}"' "$REPO/scripts/verify.sh"
}

t_V10_verify_api_bypasses_proxy() {
    begin_test "V10_verify代理环境下API检查仍通过（--noproxy）"
    seed_running_install
    # 死代理环境：本机 API 检查必须绕过代理，否则 curl 把 127.0.0.1 发给
    # 代理即失败（2026-11-13 真机实测：回滚轮询因此 30 秒全败误报）。
    https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "代理环境下 verify exit 0" 0 "$?"
    check_contains "API 检查通过" "$OUT" "[PASS] API 就绪"
    check_contains "订阅检查通过" "$OUT" "[PASS] 订阅 provider 有节点"
}

t_V11_verify_v6_no_address_skip() {
    begin_test "V11_verify无全局IPv6地址时IPv6项跳过而非失败（v1.2.1）"
    seed_running_install
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled"
    # 不 touch ipv6-lan：LAN 口无全局地址，链缺失属正常。
    bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "无地址+链缺失时 verify exit 0" 0 "$?"
    check_contains "IPv6 项为 SKIP" "$OUT" "[SKIP] IPv6 阻断规则存在"
    check_contains "SKIP 说明无可阻断对象" "$OUT" "无可阻断对象"
    check_contains "汇总仍为通过" "$OUT" "自检通过"
}

t_V12_verify_v6_address_chain_missing_fail() {
    begin_test "V12_verify地址在但链缺失时IPv6项仍失败（v1.2.1）"
    seed_running_install
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    # 链缺失（启动时未启用阻断）、地址在：与 x86 VM reboot 后状态一致。
    bash "$REPO/scripts/verify.sh" >> "$OUT" 2>&1
    check_exit "地址在+链缺失时 verify exit 1" 1 "$?"
    check_contains "IPv6 项为 FAIL" "$OUT" "[FAIL] IPv6 阻断规则存在"
    check_contains "FAIL 指引提 auto-maintain 补建" "$OUT" "auto-maintain"
    check_contains "其他项仍通过" "$OUT" "[PASS] 服务运行中"
    check_contains "汇总为失败" "$OUT" "自检失败"
}

# ------------------------------------------------------------------
# M15 组：订阅状态可见性与脱敏（P1/P2-15）
# ------------------------------------------------------------------
t_M15a_refresh_logs_node_count() {
    begin_test "M15a_刷新订阅后日志含节点数"
    seed_running_install
    bash "$REPO/scripts/auto-maintain.sh" refresh >> "$OUT" 2>&1
    check_exit "refresh exit 0" 0 "$?"
    check_contains "日志记录刷新成功与节点数" /var/log/mihomo-maintain.log "订阅 airport1 刷新成功，当前节点数：3"
}

t_M15b_refresh_empty_warns() {
    begin_test "M15b_刷新后节点数为0记警告"
    seed_running_install
    # 节点数为 0 走缓存文件：缓存存在但无 "- name: " 行（订阅为空）。
    printf 'proxies: []\n' > /etc/mihomo/providers/airport1.yaml
    bash "$REPO/scripts/auto-maintain.sh" refresh >> "$OUT" 2>&1
    check_exit "refresh exit 0" 0 "$?"
    check_contains "日志警告节点数为 0" /var/log/mihomo-maintain.log "节点数为 0"
}

t_M15c_no_secrets_in_logs() {
    begin_test "M15c_终端与日志不含完整订阅链接与密钥"
    reset_system
    run_install '\n\nhttps://sub.example.com/secret-path?token=SECRETTOKEN123\n\ny\n'
    check_exit "安装 exit 0" 0 "$?"
    local _secret
    _secret=$(grep -E '^secret:' /etc/mihomo/config.yaml | head -1 | sed -E 's/^secret:[[:space:]]*"([^"]*)".*/\1/')
    check "能从配置中取出密钥" test -n "$_secret"
    check_not_contains "安装日志不含完整订阅链接" /var/log/mihomo-install.log "https://sub.example.com/secret-path?token=SECRETTOKEN123"
    check_not_contains "安装日志不含面板密钥" /var/log/mihomo-install.log "$_secret"
    check_not_contains "终端输出不含完整订阅链接" "$OUT" "https://sub.example.com/secret-path?token=SECRETTOKEN123"
    check_contains "终端输出只含打码订阅链接" "$OUT" "https://sub.example.com/****"
    check_eq "面板密钥在终端输出中仅出现一次（成功页）" 1 "$(grep -cF "$_secret" "$OUT")"
    bash /etc/mihomo/auto-maintain.sh refresh >> "$OUT" 2>&1
    check_not_contains "维护日志不含面板密钥" /var/log/mihomo-maintain.log "$_secret"
    check_not_contains "维护日志不含订阅链接" /var/log/mihomo-maintain.log "sub.example.com"
}

# ------------------------------------------------------------------
# M16 组：统一日志格式（P1/P2-16）
# 格式：[YYYY-MM-DD HH:MM:SS] [INFO|WARN|ERROR] [阶段] 消息
# ------------------------------------------------------------------
t_M16a_install_log_format() {
    begin_test "M16a_安装日志全部行符合统一格式"
    reset_system
    run_install '\n\nhttps://sub.example.com/x\n\ny\n'
    check_exit "安装 exit 0" 0 "$?"
    check "安装日志非空" test -s /var/log/mihomo-install.log
    check "安装日志全部行符合统一格式" test -z "$(grep -vE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[(INFO|WARN|ERROR)\] \[[^]]+\] ' /var/log/mihomo-install.log)"
    check_contains "安装日志含 [预检] 阶段行" /var/log/mihomo-install.log "[预检]"
    check_contains "安装日志含 [下载] 阶段行" /var/log/mihomo-install.log "[下载]"
    check_contains "安装日志含级别标记" /var/log/mihomo-install.log "[INFO]"
}

t_M16b_maintain_log_format() {
    begin_test "M16b_维护日志全部行符合统一格式"
    seed_running_install
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    bash "$REPO/scripts/auto-maintain.sh" refresh >> "$OUT" 2>&1
    check "维护日志非空" test -s /var/log/mihomo-maintain.log
    check "维护日志全部行符合统一格式" test -z "$(grep -vE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[(INFO|WARN|ERROR)\] \[(check|refresh|full)\] ' /var/log/mihomo-maintain.log)"
    check_contains "维护日志含 [check] 阶段行" /var/log/mihomo-maintain.log "[check]"
    check_contains "维护日志含 [refresh] 阶段行" /var/log/mihomo-maintain.log "[refresh]"
}

t_M16c_other_scripts_log_format() {
    begin_test "M16c_恢复卸载换订阅终端输出用统一格式"
    local out1="$OUTPUTS/M16c-restore.log" out2="$OUTPUTS/M16c-uninstall.log" out3="$OUTPUTS/M16c-switch.log"
    seed_keep_config_uninstalled
    bash "$REPO/scripts/restore.sh" > "$out1" 2>&1
    check_exit "恢复 exit 0" 0 "$?"
    check_contains "恢复输出含 [INFO] [恢复]" "$out1" "[INFO] [恢复]"
    seed_running_install
    bash "$REPO/scripts/uninstall.sh" --stop-only > "$out2" 2>&1
    check_exit "卸载 exit 0" 0 "$?"
    check_contains "卸载输出含 [INFO] [卸载]" "$out2" "[INFO] [卸载]"
    seed_running_install
    bash "$REPO/scripts/switch-sub.sh" "https://new.example.com/s" > "$out3" 2>&1
    check_exit "换订阅 exit 0" 0 "$?"
    check_contains "换订阅输出含 [INFO] [换订阅]" "$out3" "[INFO] [换订阅]"
    check_contains "换订阅输出订阅打码" "$out3" "https://new.example.com/****"
    check_not_contains "换订阅输出不含完整链接" "$out3" "https://new.example.com/s"
}

# ------------------------------------------------------------------
# M17 组：check 补建缺失的 IPv6 阻断链（v1.2.1）
# 背景：x86 VM 真机实测 reboot 后 MIHOMO_V6 缺失——开机时 SLAAC 地址
# 晚到超 30 秒等待，等满跳过建链且之后无人补建。check 每 15 分钟跑
# 一次，"IPV6_BLOCK=1 + 地址已在 + 链/跳转缺失"时复用 tproxy.sh
# start 补建（幂等，不重启 mihomo）；任一条件不满足则不动系统。
# ------------------------------------------------------------------
t_M17a_check_repairs_v6_chain() {
    begin_test "M17a_check补建缺失的IPv6阻断链（地址在+链缺失）"
    seed_running_install
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    check "补建前 MIHOMO_V6 缺失（场景已播种）" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    check_exit "check exit 0" 0 "$?"
    check_contains "日志记录补建触发" /var/log/mihomo-maintain.log "复用 tproxy.sh 补建规则"
    check_contains "日志记录补建成功" /var/log/mihomo-maintain.log "IPv6 阻断链已补建"
    check "MIHOMO_V6 链已补建" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check_eq "MIHOMO_V6 链内容" "$(printf '%s\n' '! -i eth0 -j RETURN' '-s 2408:8207:1234:5678::5/64 -j DROP')" "$(cat "$STATE/ip6-ipt-filter-MIHOMO_V6.txt")"
    check_eq "FORWARD 跳转已补建恰 1 条" 1 "$(grep -c -- '-j MIHOMO_V6' "$STATE/ip6-ipt-filter-FORWARD.txt" 2>/dev/null || true)"
    check_not_contains "补建不重启服务" /var/log/mihomo-maintain.log "重启 mihomo 服务"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
    check_eq "IPv4 规则仍恰 1 条（重建无重复）" 1 "$(rule_count)"
}

t_M17b_check_skips_v6_repair_when_chain_present() {
    begin_test "M17b_check链在时不补建"
    reset_system
    seed_installed_files
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    systemctl start mihomo >> "$OUT" 2>&1
    check "启动后 MIHOMO_V6 已建" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    check_exit "check exit 0" 0 "$?"
    check_not_contains "日志无补建动作" /var/log/mihomo-maintain.log "补建"
    check "MIHOMO_V6 链仍在" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check_eq "FORWARD 跳转仍恰 1 条" 1 "$(grep -c -- '-j MIHOMO_V6' "$STATE/ip6-ipt-filter-FORWARD.txt" 2>/dev/null || true)"
}

t_M17c_check_skips_v6_repair_when_no_address() {
    begin_test "M17c_check无地址时不补建"
    seed_running_install
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled"
    # 不 touch ipv6-lan：LAN 口无全局 IPv6 地址，无可阻断对象。
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    check_exit "check exit 0" 0 "$?"
    check_not_contains "日志无补建动作" /var/log/mihomo-maintain.log "补建"
    check "MIHOMO_V6 链仍未建" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    check "服务仍在跑" test "$(cat "$STATE/svc-active")" = "1"
}

t_M17d_check_skips_v6_repair_when_block_off() {
    begin_test "M17d_check未启用阻断时不补建"
    seed_running_install
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    # tproxy.env 无 IPV6_BLOCK（seed 默认）：地址在、链缺失也不动作。
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    check_exit "check exit 0" 0 "$?"
    check_not_contains "日志无补建动作" /var/log/mihomo-maintain.log "补建"
    check "MIHOMO_V6 链仍未建" test ! -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
}

t_M17e_check_repairs_v6_jump_missing() {
    begin_test "M17e_check链在但跳转缺失时补建"
    reset_system
    seed_installed_files
    printf 'IPV6_BLOCK="1"\n' >> /etc/mihomo/tproxy.env
    touch "$STATE/ipv6-enabled" "$STATE/ipv6-lan"
    systemctl start mihomo >> "$OUT" 2>&1
    check "启动后 MIHOMO_V6 已建" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
    # 只删 FORWARD 跳转，链本身保留。
    sed -i '/-j MIHOMO_V6/d' "$STATE/ip6-ipt-filter-FORWARD.txt"
    check_eq "跳转已删（场景已播种）" 0 "$(grep -c -- '-j MIHOMO_V6' "$STATE/ip6-ipt-filter-FORWARD.txt" 2>/dev/null || true)"
    bash "$REPO/scripts/auto-maintain.sh" check >> "$OUT" 2>&1
    check_exit "check exit 0" 0 "$?"
    check_contains "日志记录补建成功" /var/log/mihomo-maintain.log "IPv6 阻断链已补建"
    check_eq "FORWARD 跳转已补建恰 1 条" 1 "$(grep -c -- '-j MIHOMO_V6' "$STATE/ip6-ipt-filter-FORWARD.txt" 2>/dev/null || true)"
    check "MIHOMO_V6 链仍在" test -f "$STATE/ip6-ipt-filter-MIHOMO_V6.txt"
}

# ------------------------------------------------------------------
# Q 组：P2-18 单引号 secret/订阅提取与临时文件清理（P2）
# 背景：P0 已知限制第 5 条——配置里 secret: 'abc'（单引号）时，旧提取
# 会把引号本身带进 API_SECRET，导致 API 鉴权失败；同类问题也存在于
# 覆盖重装时的订阅 url 提取。curl 桩不校验 Authorization 头，因此
# "值正确"一级的证明在 Q4 单元测试里做，Q1/Q2/Q3/Q5 断言落盘文件内容。
# ------------------------------------------------------------------
t_Q1_secret_single_quote_reinstall() {
    begin_test "Q1_单引号密钥重装复用不带引号"
    seed_running_install
    sed -i -E "s|^secret:.*|secret: 'OLDSECRET1234567890abcdef'|" /etc/mihomo/config.yaml
    check_contains "种子已改为单引号密钥" /etc/mihomo/config.yaml "secret: 'OLDSECRET1234567890abcdef'"
    run_install '\n\n\n\n\ny\n'
    check_exit "重装 exit 0" 0 "$?"
    check_contains "maintain.env 密钥无引号" /etc/mihomo/maintain.env 'API_SECRET="OLDSECRET1234567890abcdef"'
    check_not_contains "maintain.env 密钥未带单引号" /etc/mihomo/maintain.env "'OLDSECRET"
    check_contains "配置仍保留单引号密钥原文" /etc/mihomo/config.yaml "secret: 'OLDSECRET1234567890abcdef'"
    check_contains "日志记录复用密钥" /var/log/mihomo-install.log "复用已有配置中的面板密钥"
}

t_Q2_secret_unquoted_reinstall() {
    begin_test "Q2_无引号密钥重装复用"
    seed_running_install
    sed -i -E "s|^secret:.*|secret: OLDSECRET1234567890abcdef|" /etc/mihomo/config.yaml
    check_contains "种子已改为无引号密钥" /etc/mihomo/config.yaml "secret: OLDSECRET1234567890abcdef"
    run_install '\n\n\n\n\ny\n'
    check_exit "重装 exit 0" 0 "$?"
    check_contains "maintain.env 密钥无引号" /etc/mihomo/maintain.env 'API_SECRET="OLDSECRET1234567890abcdef"'
    check_contains "配置仍保留无引号密钥原文" /etc/mihomo/config.yaml "secret: OLDSECRET1234567890abcdef"
    check_contains "日志记录复用密钥" /var/log/mihomo-install.log "复用已有配置中的面板密钥"
}

t_Q3_secret_single_quote_placeholder() {
    begin_test "Q3_单引号占位密钥重装时被替换"
    seed_running_install
    sed -i -E "s|^secret:.*|secret: 'CHANGE_ME_SECRET'|" /etc/mihomo/config.yaml
    run_install '\n\n\n\n\ny\n'
    check_exit "重装 exit 0" 0 "$?"
    check_not_contains "配置不再含占位密钥" /etc/mihomo/config.yaml "CHANGE_ME_SECRET"
    local _k
    _k=$(grep -E '^secret:' /etc/mihomo/config.yaml | head -1 | sed -E 's/^secret:[[:space:]]*"([^"]*)".*/\1/')
    check "新密钥长度 32" test "${#_k}" -eq 32
    check "新密钥为 hex" test -z "$(printf '%s' "$_k" | tr -d '0-9a-f')"
    check_contains "maintain.env 与配置密钥一致" /etc/mihomo/maintain.env "API_SECRET=\"$_k\""
}

t_Q4_extract_secret_unit() {
    begin_test "Q4_extract_secret三种引号写法单元测试"
    local _f _fn="/tmp/q4-fn.sh" _cfg="/tmp/q4-cfg.yaml"
    for _f in install.sh restore.sh verify.sh; do
        sed -n '/^extract_secret()/,/^}/p' "$REPO/scripts/$_f" > "$_fn"
        check "$_f 含 extract_secret 函数" test -s "$_fn"
        (
            # shellcheck disable=SC1090
            source "$_fn"
            printf 'secret: "K1"\n' > "$_cfg"
            [ "$(extract_secret "$_cfg")" = "K1" ] || exit 1
            printf "secret: 'K2'\n" > "$_cfg"
            [ "$(extract_secret "$_cfg")" = "K2" ] || exit 2
            printf 'secret: K3\n' > "$_cfg"
            [ "$(extract_secret "$_cfg")" = "K3" ] || exit 3
            printf 'other: 1\n' > "$_cfg"
            [ -z "$(extract_secret "$_cfg")" ] || exit 4
        )
        check_exit "$_f extract_secret 双/单/无引号与缺行均正确" 0 "$?"
    done
    # 三处函数体逐字节一致（同一条规则，不漂移）
    check "install 与 restore 的 extract_secret 一致" test "$(sed -n '/^extract_secret()/,/^}/p' "$REPO/scripts/install.sh" | md5sum | cut -d' ' -f1)" = "$(sed -n '/^extract_secret()/,/^}/p' "$REPO/scripts/restore.sh" | md5sum | cut -d' ' -f1)"
    check "restore 与 verify 的 extract_secret 一致" test "$(sed -n '/^extract_secret()/,/^}/p' "$REPO/scripts/restore.sh" | md5sum | cut -d' ' -f1)" = "$(sed -n '/^extract_secret()/,/^}/p' "$REPO/scripts/verify.sh" | md5sum | cut -d' ' -f1)"
    rm -f "$_fn" "$_cfg"
}

t_Q5_url_single_quote_overwrite() {
    begin_test "Q5_单引号订阅覆盖重装时正确沿用"
    seed_running_install
    python3 - <<'PYEOF'
p = "/etc/mihomo/config.yaml"
s = open(p).read()
s = s.replace('url: "https://old-sub.example.com/sub?token=OLD123&x=1"', "url: 'https://old-sub.example.com/sub?token=OLD123&x=1'", 1)
open(p, "w").write(s)
PYEOF
    check_contains "种子已改为单引号订阅" /etc/mihomo/config.yaml "url: 'https://old-sub.example.com/sub?token=OLD123&x=1'"
    run_install '\n\n\n\ny\ny\n'
    check_exit "覆盖重装 exit 0" 0 "$?"
    check_contains "旧订阅正确沿用（双引号重渲染）" /etc/mihomo/config.yaml 'url: "https://old-sub.example.com/sub?token=OLD123&x=1"'
    check_not_contains "未渲染出整行原文垃圾" /etc/mihomo/config.yaml 'url: "    url:'
}

t_Q6_p2_static_checks() {
    begin_test "Q6_P2静态核查_临时文件与红线"
    check "switch-sub 代码不再引用固定路径自检日志（注释提及除外）" test -z "$(grep -F '/tmp/switch-sub-check.log' "$REPO/scripts/switch-sub.sh" | grep -v '^[[:space:]]*#' || true)"
    check "switch-sub 自检日志走 mktemp" grep -q 'CHECK_LOG=$(mktemp)' "$REPO/scripts/switch-sub.sh"
    check "switch-sub 有 EXIT 清理 trap" grep -q 'trap cleanup_tmp EXIT' "$REPO/scripts/switch-sub.sh"
    check "安装 EXIT 清理会删迁移临时文件" grep -q 'rm -f "$MIGRATE_TMP"' "$REPO/scripts/install.sh"
    check "卸载清理 .bak 暂存二进制" grep -q 'mihomo.bak' "$REPO/scripts/uninstall.sh"
    check "MARK 仍为 1（红线）" grep -q '^MARK=1$' "$REPO/scripts/tproxy.sh"
    check "路由表仍为 100（红线）" grep -q '^ROUTING_TABLE=100$' "$REPO/scripts/tproxy.sh"
    check "1062 全仓 0 命中（红线）" test -z "$(grep -rl '1062' "$REPO/scripts" "$REPO/systemd" "$REPO/cron" "$REPO/config" 2>/dev/null || true)"
    # 本机 API curl 必须全部带 --noproxy（否则代理环境变量毒化 localhost
    # 检查；2026-11-13 真机实测回滚轮询因此误报）。数打本机 API 的 curl
    # 行数与带 --noproxy 的行数，两者必须相等。
    _noproxy_total=$(grep -rh 'curl -' "$REPO"/scripts | grep -cE '127\.0\.0\.1|\$API/' || true)
    _noproxy_ok=$(grep -rh 'curl -' "$REPO"/scripts | grep -E '127\.0\.0\.1|\$API/' | grep -c -- '--noproxy' || true)
    check_eq "本机 API curl 全部带 --noproxy（${_noproxy_total} 处）" "$_noproxy_total" "$_noproxy_ok"
}

# ------------------------------------------------------------------
# R6：单引号密钥恢复（值级证明见 Q4；此处只证恢复流程不被单引号打断）
# ------------------------------------------------------------------
t_R6_restore_single_quote_secret() {
    begin_test "R6_单引号密钥时恢复正常"
    seed_keep_config_uninstalled
    sed -i -E "s|^secret:.*|secret: 'OLDSECRET1234567890abcdef'|" /etc/mihomo/config.yaml
    bash "$REPO/scripts/restore.sh" >> "$OUT" 2>&1
    check_exit "单引号密钥时 restore exit 0" 0 "$?"
    check "服务已启动" test "$(cat "$STATE/svc-active")" = "1"
    check_contains "配置原样保留单引号密钥" /etc/mihomo/config.yaml "secret: 'OLDSECRET1234567890abcdef'"
}

# ------------------------------------------------------------------
# U6/U7：卸载清理二进制暂存与事务残留（P2-18 审计发现）
# ------------------------------------------------------------------
plant_bin_leftovers() {
    cp /usr/local/bin/mihomo /usr/local/bin/mihomo.bak
    : > /usr/local/bin/mihomo.new
    : > /usr/local/bin/mihomo.restoring
    mkdir -p /tmp/mgb-txn.testdir/rules
    : > /tmp/mgb-asset.testfile
    : > /tmp/mgb-sums.testfile
}

t_U6_full_removes_leftovers() {
    begin_test "U6_彻底卸载清掉二进制暂存与事务残留"
    seed_running_install
    plant_bin_leftovers
    bash "$REPO/scripts/uninstall.sh" >> "$OUT" 2>&1
    check_exit "彻底卸载 exit 0" 0 "$?"
    check "mihomo.bak 已删" test ! -e /usr/local/bin/mihomo.bak
    check "mihomo.new 已删" test ! -e /usr/local/bin/mihomo.new
    check "mihomo.restoring 已删" test ! -e /usr/local/bin/mihomo.restoring
    check "/tmp/mgb-txn 残留已删" test ! -e /tmp/mgb-txn.testdir
    check "/tmp/mgb-asset 残留已删" test ! -e /tmp/mgb-asset.testfile
    check "/tmp/mgb-sums 残留已删" test ! -e /tmp/mgb-sums.testfile
}

t_U7_keep_config_removes_leftovers() {
    begin_test "U7_keep-config卸载清掉二进制暂存与事务残留"
    seed_running_install
    plant_bin_leftovers
    bash "$REPO/scripts/uninstall.sh" --keep-config >> "$OUT" 2>&1
    check_exit "--keep-config exit 0" 0 "$?"
    check "mihomo.bak 已删" test ! -e /usr/local/bin/mihomo.bak
    check "mihomo.new 已删" test ! -e /usr/local/bin/mihomo.new
    check "mihomo.restoring 已删" test ! -e /usr/local/bin/mihomo.restoring
    check "/tmp/mgb-txn 残留已删" test ! -e /tmp/mgb-txn.testdir
    check "配置仍保留" test -f /etc/mihomo/config.yaml
}

# ------------------------------------------------------------------
# S2：switch-sub 自检失败回滚（P2-18 临时文件加固的回归）
# ------------------------------------------------------------------
t_S2_switch_sub_rollback() {
    begin_test "S2_switch-sub自检失败回滚且无固定路径日志"
    seed_running_install
    touch "$STATE/mihomo-t-fail"
    bash "$REPO/scripts/switch-sub.sh" "https://new-sub.example.com/x" >> "$OUT" 2>&1
    check_exit "自检失败时 switch-sub exit 1" 1 "$?"
    check "配置已回滚（与安装前逐字节一致）" cmp -s /etc/mihomo/config.yaml "$STATE/old-config.yaml"
    check_not_contains "新订阅未写入配置" /etc/mihomo/config.yaml "new-sub.example.com"
    check "备份文件已生成" test -n "$(ls /etc/mihomo/config.yaml.bak.* 2>/dev/null)"
    check "未产生固定路径自检日志" test ! -e /tmp/switch-sub-check.log
    check_contains "报错提到回滚" "$OUT" "回滚"
    rm -f "$STATE/mihomo-t-fail"
}

# ------------------------------------------------------------------
# 主入口
# ------------------------------------------------------------------
ALL_TESTS=(
    t_T1_missing_env t_T2_cidr_octet_overflow t_T3_cidr_prefix_overflow
    t_T4_cidr_leading_zero t_T5_happy_path t_T6_duplicate_cleanup
    t_T7_foreign_fwmark_refused t_T8_foreign_table100_refused
    t_T9_own_rule_not_conflict t_T10_stop_mode t_T11_stop_without_env
    t_T12_fwmark_0x10_not_conflict t_T13_bad_arg t_T14_iface_missing
    t_U1_stop_only t_U2_keep_config t_U3_full t_U4_uninstall_idempotent
    t_U5_uninstall_clears_duplicates t_U6_full_removes_leftovers
    t_U7_keep_config_removes_leftovers
    t_R1_restore_after_keep_config t_R2_restore_no_config
    t_R3_restore_already_running t_R4_restore_after_stop_only
    t_R5_restore_bad_config t_R6_restore_single_quote_secret
    t_S1_switch_sub_happy t_S2_switch_sub_rollback
    t_A1_maintain_skips_when_locked t_A2_maintain_runs_when_free
    t_I1_fresh_install t_I2_reinstall_keeps_config t_I3_reinstall_new_subnet
    t_I4_reinstall_overwrite t_I5_reinstall_new_sub
    t_I6_rollback_on_config_test_fail t_I7_rollback_on_tproxy_fail
    t_I8_rollback_on_api_fail t_I9_fresh_install_rollback
    t_I10_fresh_install_rollback_stopped
    t_I11_install_rejects_leading_zero t_I12_install_rejects_bad_cidr
    t_I13_install_cancel t_I14_install_bad_sub_url
    t_L1_install_locked t_L2_uninstall_locked t_L3_switch_sub_locked
    t_L4_restore_locked
    t_P5a_template_keys_merged t_P5b_no_missing_keys_no_merge
    t_P6a_missing_wget_fails_preflight t_P6b_tproxy_probe_fail
    t_P6c_unknown_distro_warns_and_continues t_P6d_alpine_rejected
    t_P6e_armbian_supported
    t_P7a_multi_subnet_tproxy t_P7b_multi_subnet_bad_entry
    t_P7c_multi_subnet_dedup t_P7d_install_manual_iface_multi_subnet
    t_P7e_public_ip_respecify t_P7f_public_ip_confirm
    t_P7g_docker_noted_not_excluded t_P7h_single_subnet_byte_identical
    t_P8a_v6_block_builds_rules t_P8b_v6_block_no_prefix
    t_P8c_v6_block_stop_cleans t_P8d_install_v6_block_on
    t_P8e_install_v6_block_off t_P8f_v6_block_waits_for_prefix
    t_P8g_v6_block_wait_timeout
    t_P9a_fresh_install_local_only t_P9b_fresh_install_lan_default
    t_P9c_reinstall_switch_to_local t_P9d_reinstall_keeps_local
    t_P10a_manifest_consistent
    t_M11a_full_dual_source_match t_M11b_full_dual_source_mismatch
    t_M11c_full_second_source_unreachable t_M11e_full_rules_missing_warns
    t_M12a_lock_coverage
    t_M13a_stop_cleans_rules t_M13b_restart_rebuilds_rules
    t_M13c_old_unit_leaves_rules t_M13d_unit_limits
    t_V1_verify_healthy t_V2_verify_service_down t_V3_verify_rules_missing
    t_V4_verify_env_mismatch t_V5_verify_providers_empty t_V6_verify_api_down
    t_V7_verify_dns_tolerates_m_match t_V8_verify_provider_cache_missing
    t_V9_verify_api_retry_recovers t_V10_verify_api_bypasses_proxy
    t_V11_verify_v6_no_address_skip t_V12_verify_v6_address_chain_missing_fail
    t_M15a_refresh_logs_node_count t_M15b_refresh_empty_warns
    t_M15c_no_secrets_in_logs
    t_M16a_install_log_format t_M16b_maintain_log_format
    t_M16c_other_scripts_log_format
    t_M17a_check_repairs_v6_chain t_M17b_check_skips_v6_repair_when_chain_present
    t_M17c_check_skips_v6_repair_when_no_address
    t_M17d_check_skips_v6_repair_when_block_off
    t_M17e_check_repairs_v6_jump_missing
    t_Q1_secret_single_quote_reinstall t_Q2_secret_unquoted_reinstall
    t_Q3_secret_single_quote_placeholder t_Q4_extract_secret_unit
    t_Q5_url_single_quote_overwrite t_Q6_p2_static_checks
)

echo "P0+P1+P1/P2+P2 桩测开始（仓库：$REPO）"
echo "桩命令：$STUBS ；状态：$STATE"
for t in "${ALL_TESTS[@]}"; do
    if [ -n "$FILTER" ]; then
        case "$t" in
            *"$FILTER"*) ;;
            *) continue ;;
        esac
    fi
    "$t"
done

reset_system
echo ""
echo "===================================================="
echo "桩测结果：通过 $PASS，失败 $FAIL"
if [ "$FAIL" -ne 0 ]; then
    echo "失败项："
    for f in "${FAILED_TESTS[@]}"; do echo "  - $f"; done
    echo "各测试完整输出见：$OUTPUTS/"
    exit 1
fi
echo "全部通过。"
exit 0
