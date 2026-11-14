#!/bin/bash
# 一键恢复：--keep-config 卸载或 --stop-only 停止后，把旁路由恢复运行。
#
# 用法:
#   sudo bash /path/to/mihomo-tproxy-gateway/scripts/restore.sh
#
# 前置条件：/etc/mihomo 保留完好（含 config.yaml 与 tproxy.env）。
# 本脚本只做恢复，不碰配置：重装缺失的内核二进制与服务文件（systemd
# 单元、tproxy.sh、auto-maintain.sh、cron），校验配置，通过后启动服务
# 并轮询 API 确认就绪。配置本身（订阅、规则、DNS、密钥）原样保留。
# 若 /etc/mihomo 已不存在（彻底卸载过），请改跑 install.sh 全新安装。

set -e

# 脚本所在目录（支持从任意目录调用；解析物理路径，防符号链接下锚错目录）
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ASSETS_DIR="$REPO_ROOT/assets"

# 专用资产仓库钉版批次（与 install.sh 同一默认值，可用环境变量覆盖）：
# 官方源全部失败时从这里拉兜底内核，按本地 assets/SHA256SUMS 校验。
PROJECT_ASSETS_BASE="${PROJECT_ASSETS_BASE:-https://git.edge97.dpdns.org/sg/mihomo-assets/releases/download/v1.0.1}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 统一日志接口（P1-16，五脚本同一约定：[时间] [级别] [阶段] 消息）：
#   log <级别> <消息>      级别：INFO / WARN / ERROR
# 终端按级别着色；本脚本不写日志文件（输出即终端所见）。
# 脱敏：订阅链接与面板密钥不输出（密钥只用于本次 API 校验，不打印）。
log() {
    local _level="$1"; shift
    local _color="$NC"
    case "$_level" in
        INFO)  _color="$BLUE" ;;
        WARN)  _color="$YELLOW" ;;
        ERROR) _color="$RED" ;;
    esac
    printf '%b[%s] [%s] [恢复] %s%b\n' "$_color" "$(date '+%Y-%m-%d %H:%M:%S')" "$_level" "$*" "$NC"
}

echo -e "${BLUE}====================================================${NC}"
echo -e "${GREEN} 🔄 Mihomo 旁路由一键恢复${NC}"
echo -e "${BLUE}====================================================${NC}"

if [ "$(id -u)" -ne 0 ]; then
    log ERROR "错误：必须使用 root 权限运行此脚本！"
    exit 1
fi

# 全局并发锁：与安装 / 卸载 / 切换订阅 / 自动维护共用同一把锁，
# 同一时刻只允许一个任务修改系统；拿不到锁说明已有任务在跑，直接退出。
LOCK_FILE="/var/lock/mihomo-gateway.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log ERROR "错误：另一个安装/卸载/切换订阅/恢复/维护任务正在运行（锁文件 $LOCK_FILE），请等待它完成后再试。"
    exit 1
fi

# 1. 前置检查：配置与入口限定文件必须都在，否则无从恢复
if [ ! -f /etc/mihomo/config.yaml ]; then
    log ERROR "错误：未找到 /etc/mihomo/config.yaml，没有可恢复的配置。"
    log ERROR "      这通常意味着之前做的是彻底卸载，请改跑 install.sh 全新安装。"
    exit 1
fi
if [ ! -f /etc/mihomo/tproxy.env ]; then
    log ERROR "错误：未找到 /etc/mihomo/tproxy.env，无法安全限定透明代理入口。"
    log ERROR "      请改跑 install.sh 全新安装（它会重新生成该文件）。"
    exit 1
fi
for _need in "$SCRIPT_DIR/tproxy.sh" "$SCRIPT_DIR/auto-maintain.sh" "$SCRIPT_DIR/verify.sh" "$REPO_ROOT/systemd/mihomo.service" "$REPO_ROOT/cron/mihomo-maintain.cron"; do
    if [ ! -f "$_need" ]; then
        log ERROR "错误：仓库文件缺失：$_need，请确认在完整的项目源码目录里运行本脚本。"
        exit 1
    fi
done
log INFO "✓ 恢复前置检查通过（配置、tproxy.env、仓库文件均存在）"

# 从 config.yaml 提取面板 secret：双引号、单引号、无引号三种写法都认，
# 只取引号内的值（与 install.sh 的 extract_secret 同一条规则）。
# sed 脚本里的 '"'"' 是 shell 单引号字符串内嵌单引号的标准写法。
extract_secret() { # extract_secret <config.yaml>
    grep -E '^secret:' "$1" 2>/dev/null | head -1 \
        | sed -E 's/^secret:[[:space:]]*"([^"]*)".*/\1/; s/^secret:[[:space:]]*'"'"'([^'"'"']*)'"'"'.*/\1/; s/^secret:[[:space:]]*([^"[:space:]]+).*/\1/' || true
}

# 从 config.yaml 取面板 API 的本机访问地址：读 external-controller 的
# 监听地址；0.0.0.0 监听全部接口时本机走 127.0.0.1；无配置行或解析
# 失败时默认 127.0.0.1（mihomo 未写 external-controller 时的默认监听）。
# LAN 模式只绑 LAN IP 时 127.0.0.1:9090 根本不监听，本机 API 必须走监
# 听地址本身，硬编码 127.0.0.1 会误报 API 未就绪（第二轮第 2 项）。
# 与 install.sh / verify.sh / switch-sub.sh 的 panel_api_host 同一条规则。
panel_api_host() { # panel_api_host <config.yaml>
    local _listen=""
    _listen=$(grep -E '^external-controller:' "$1" 2>/dev/null | head -1 | sed -E 's/^external-controller:[[:space:]]*([^:]+):.*/\1/' || true)
    case "$_listen" in
        ""|"0.0.0.0") printf '127.0.0.1' ;;
        *) printf '%s' "$_listen" ;;
    esac
}

# 面板密钥取自现有配置（只用于本次恢复的 API 就绪校验，不打印、不改写）
API_SECRET=""
API_SECRET=$(extract_secret /etc/mihomo/config.yaml)
[ "$API_SECRET" = "CHANGE_ME_SECRET" ] && API_SECRET=""
AUTH_HEADER=()
[ -n "$API_SECRET" ] && AUTH_HEADER=(-H "Authorization: Bearer $API_SECRET")
# API 地址取自现有配置的监听地址（panel_api_host 规则），恢复不改配置，
# 监听模式就是配置里写的那一个。
API="http://$(panel_api_host /etc/mihomo/config.yaml):9090"

# 2. 服务已经正常跑着就不用恢复
# --noproxy：本机 API 不走代理（curl 默认连 127.0.0.1 也发给代理，代理到不了本机端口）。
if systemctl is-active --quiet mihomo 2>/dev/null \
    && curl --noproxy '*' -s -m 3 "${AUTH_HEADER[@]}" "$API/version" >/dev/null 2>&1; then
    log INFO "✓ mihomo 服务已在运行且 API 就绪，无需恢复。"
    exit 0
fi

# 3. 恢复内核二进制：现有二进制能跑就复用，否则重新下载
# （下载策略与 install.sh 一致：官方最新 -> 镜像 -> 专用资产仓钉版兜底，
#  全程 gzip 完整性 + 新二进制 -v 自检，兜底资产另验 sha256）
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  BIN_ARCH="amd64" ;;
  aarch64) BIN_ARCH="arm64" ;;
  armv7l)  BIN_ARCH="armv7" ;;
  *)       log ERROR "暂不支持的 CPU 架构: $ARCH"; exit 1 ;;
esac

BIN_OK=0
if [ -x /usr/local/bin/mihomo ] && /usr/local/bin/mihomo -v 2>&1 | grep -q "Mihomo"; then
    log INFO "✓ 现有内核二进制完好，跳过下载"
    BIN_OK=1
fi
if [ "$BIN_OK" -eq 0 ]; then
    log INFO "正在获取 Mihomo 内核..."
    rm -f /tmp/mihomo.gz
    LATEST_VERSION=$(curl -m 10 --retry 2 -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name"' | grep -oP 'v[\d.]+' | head -1 || true)
    # 版本探测全失败时的兜底版本号与专用资产仓兜底资产保持一致
    [ -z "$LATEST_VERSION" ] && LATEST_VERSION="v1.19.32"
    KERNEL_FILE="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    KERNEL_OK=0
    for url in \
        "https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${KERNEL_FILE}" \
        "https://githubproxy.cc/https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${KERNEL_FILE}"; do
        log INFO "尝试下载: ${url}"
        if wget -q --show-progress -T 15 --tries=2 -O /tmp/mihomo.gz "$url" \
            && gzip -t /tmp/mihomo.gz 2>/dev/null; then
            KERNEL_OK=1
            break
        fi
        log WARN "当前下载源连接失败或超时，自动尝试下一个节点..."
        rm -f /tmp/mihomo.gz
    done
    if [ "$KERNEL_OK" -eq 0 ]; then
        log WARN "官方下载源全部失败，尝试从专用资产仓库拉取兜底资产..."
        if wget -q -T 15 --tries=2 -O /tmp/mihomo.gz "${PROJECT_ASSETS_BASE}/mihomo-linux-${BIN_ARCH}.gz" \
            && [ -f "$ASSETS_DIR/SHA256SUMS" ] \
            && [ "$(sha256sum /tmp/mihomo.gz | awk '{print $1}')" = "$(awk -v f="mihomo-linux-${BIN_ARCH}.gz" '$2 == f {print $1}' "$ASSETS_DIR/SHA256SUMS")" ] \
            && gzip -t /tmp/mihomo.gz 2>/dev/null; then
            log INFO "✓ 已使用专用资产仓库兜底资产（sha256 校验通过）"
            KERNEL_OK=1
        else
            rm -f /tmp/mihomo.gz
        fi
    fi
    if [ "$KERNEL_OK" -eq 0 ]; then
        log ERROR "错误：内核获取失败（官方源与专用资产仓库兜底均不可用），恢复中止。"
        exit 1
    fi
    gzip -d -f /tmp/mihomo.gz
    chmod +x /tmp/mihomo
    if ! /tmp/mihomo -v 2>&1 | grep -q "Mihomo"; then
        log ERROR "错误：下载的内核无法运行（版本自检失败），恢复中止。"
        rm -f /tmp/mihomo
        exit 1
    fi
    mv /tmp/mihomo /usr/local/bin/mihomo
    log INFO "✓ 内核二进制已恢复"
fi

# 4. 恢复服务文件与脚本（仓库版本为准，幂等重拷）
cp "$SCRIPT_DIR/tproxy.sh" /etc/mihomo/tproxy.sh
cp "$SCRIPT_DIR/auto-maintain.sh" /etc/mihomo/auto-maintain.sh
cp "$SCRIPT_DIR/verify.sh" /etc/mihomo/verify.sh
cp "$REPO_ROOT/systemd/mihomo.service" /etc/systemd/system/mihomo.service
cp "$REPO_ROOT/cron/mihomo-maintain.cron" /etc/cron.d/mihomo-maintain
chmod +x /etc/mihomo/*.sh
systemctl daemon-reload
log INFO "✓ 服务文件与脚本已恢复"

# 5. 地数据库缺失只警告：--keep-config 卸载本应保留它们；若用户手动
# 删过，mihomo -t 会明确失败，届时请改跑 install.sh 补齐。
for _geo in GeoIP.dat GeoSite.dat Country.mmdb; do
    if [ ! -f "/etc/mihomo/$_geo" ]; then
        log WARN "警告：/etc/mihomo/$_geo 缺失；若随后自检失败，请改跑 install.sh 补齐地数据库。"
    fi
done

# 6. 启动前配置自检：用恢复好的内核对保留的配置做一次 mihomo -t
log INFO "正在做启动前配置自检 (mihomo -t)..."
if ! /usr/local/bin/mihomo -t -d /etc/mihomo; then
    log ERROR "错误：保留的配置自检未通过，服务未启动。请修正 /etc/mihomo/config.yaml 后重跑恢复，或改跑 install.sh 重新生成配置。"
    exit 1
fi
log INFO "✓ 配置自检通过"

# 7. 启动服务并轮询 API 就绪
log INFO "正在启动 mihomo 服务..."
if systemctl is-active --quiet mihomo 2>/dev/null; then
    systemctl restart mihomo
else
    systemctl enable --now mihomo
fi
READY=0
# --noproxy：本机 API 不走代理（同上）。
for _ in $(seq 1 30); do
    if systemctl is-active --quiet mihomo 2>/dev/null \
        && curl --noproxy '*' -s -m 3 "${AUTH_HEADER[@]}" "$API/version" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done
if [ "$READY" -ne 1 ]; then
    log ERROR "错误：服务启动后 30 秒内 API 未就绪，恢复未完成。最近日志如下："
    systemctl --no-pager status mihomo 2>/dev/null | head -20 || true
    journalctl -u mihomo -n 30 --no-pager 2>/dev/null || true
    exit 1
fi
log INFO "✓ 服务已就绪 (API $API 可达)"

# 8. TPROXY 规则存在性提示（仅警告）：ExecStartPost 失败时 systemd 会
# 判服务启动失败、API 也不会就绪，走到这里规则正常应在；若缺失，通常
# 是服务文件被手动改动过，需要人工检查。
if ! iptables -t mangle -n -L MIHOMO >/dev/null 2>&1 \
    || ! ip rule show 2>/dev/null | grep -qE 'fwmark 0x1([ /]|$).*lookup 100$'; then
    log WARN "警告：服务已启动，但未检测到 TPROXY 规则，请检查 systemctl status mihomo 与 /etc/mihomo/tproxy.env。"
fi

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}🎉 Mihomo 旁路由已恢复运行！（配置原样保留）${NC}"
echo -e "控制面板: ${BLUE}http://<本机IP>:9090/ui${NC}"
echo -e "日志查看: ${YELLOW}journalctl -u mihomo -f${NC}"
echo -e "${GREEN}====================================================${NC}"
