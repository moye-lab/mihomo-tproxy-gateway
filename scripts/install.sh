#!/bin/bash
set -e

# 脚本所在目录（支持从任意目录调用；解析物理路径，防符号链接下锚错目录）
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ASSETS_DIR="$REPO_ROOT/assets"

# 专用资产仓库（sg/mihomo-assets，与代码仓库相互独立）：官方源
# （含镜像链）全部失败时，安装器统一向这个专用仓库拉兜底资产，资产
# 只维护一处、新鲜度只由它一处决定。兜底时的批次选择分两级：
#   1) 最新批次优先：先经 FALLBACK_ASSETS_API 查询该仓库的最新
#      Release，按该批次拉文件，并用该批次随附的 SHA256SUMS 校验
#      ——仓库里始终躺着最新版，任何脚本走兜底都拿到最新批次；
#   2) 钉版批次退回：查询或拉取失败时，退回 PROJECT_ASSETS_BASE
#      指向的钉版批次，按代码仓库本地 assets/SHA256SUMS 校验。
# 三个变量都可用同名环境变量覆盖，资产清单与校验值见 assets/。
PROJECT_ASSETS_BASE="${PROJECT_ASSETS_BASE:-https://git.edge97.dpdns.org/sg/mihomo-assets/releases/download/v1.0.0}"
FALLBACK_ASSETS_REPO_URL="${FALLBACK_ASSETS_REPO_URL:-https://git.edge97.dpdns.org/sg/mihomo-assets}"
FALLBACK_ASSETS_API="${FALLBACK_ASSETS_API:-https://git.edge97.dpdns.org/api/v1/repos/sg/mihomo-assets}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}====================================================${NC}"
echo -e "${GREEN} 🚀 Universal Mihomo TPROXY 旁路由一键安装脚本${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. 检查权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：必须使用 root 权限运行此脚本！${NC}"
    exit 1
fi

# 2. 自动识别架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  BIN_ARCH="amd64" ;;
  aarch64) BIN_ARCH="arm64" ;;
  armv7l)  BIN_ARCH="armv7" ;;
  *)       echo -e "${RED}暂不支持的 CPU 架构: $ARCH${NC}"; exit 1 ;;
esac
echo -e "${GREEN}✓ 检测到系统架构: ${ARCH} (${BIN_ARCH})${NC}"

# 3. 获取交互参数
# 注意：本脚本开了 set -e，交互式 read 在输入流 EOF 时返回非零会直接杀掉
# 进程，所以可空的输入一律加 || true 走默认值；必填输入则显式报错退出，
# 避免 EOF 时陷入死循环。
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

# 通过默认路由所在网卡，读它自己的直连网段（scope link），这个输出本身
# 就是 CIDR 格式，比试图从 "default via ..." 这行硬解析要可靠得多。
DEFAULT_IFACE=$(ip route show default 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1)
DEFAULT_SUBNET=""
if [ -n "$DEFAULT_IFACE" ]; then
    DEFAULT_SUBNET=$(ip -o route show dev "$DEFAULT_IFACE" scope link 2>/dev/null | grep -oP '^\S+/\d+' | head -1)
fi

if [ -n "$DEFAULT_SUBNET" ]; then
    read -r -p "请输入局域网 CIDR 网段 [自动检测: ${DEFAULT_SUBNET}，回车使用]: " INPUT_SUBNET || true
    LAN_SUBNET=${INPUT_SUBNET:-$DEFAULT_SUBNET}
else
    # 探测失败就不要假装给个默认值，强制手动输入，避免用户以为是探测结果
    LAN_SUBNET=""
    while [ -z "$LAN_SUBNET" ]; do
        if ! read -r -p "未能自动检测局域网网段，请手动输入 CIDR (例如 192.168.1.0/24): " LAN_SUBNET; then
            echo -e "${RED}错误：无法读取输入（输入流已结束），安装中止。${NC}"
            exit 1
        fi
    done
fi

read -r -p "请输入机场订阅链接 (Airport 1): " SUB_URL_1 || true
SUB_STATUS="已写入配置（订阅内容由 mihomo 运行时拉取，拉取失败不会导致安装失败）"
if [ -z "$SUB_URL_1" ]; then
    echo -e "${YELLOW}警告: 未输入订阅链接，后续请手动在 /etc/mihomo/config.yaml 中添加！${NC}"
    SUB_URL_1="YOUR_SUBSCRIPTION_URL_1"
    SUB_STATUS="未配置（已跳过，不影响安装结果；后续可用 ${REPO_ROOT}/scripts/switch-sub.sh 设置）"
fi

# 输入校验：格式不对当场中止，不要拖到 mihomo -t 才发现（报错离源头太远）
if ! [[ "$LAN_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo -e "${RED}错误：局域网网段格式不对：${LAN_SUBNET}（应为 CIDR 形式，如 192.168.1.0/24），安装中止。${NC}"
    exit 1
fi
{
    IFS='./' read -r _o1 _o2 _o3 _o4 _pfx <<< "$LAN_SUBNET"
    if [ "$_o1" -gt 255 ] || [ "$_o2" -gt 255 ] || [ "$_o3" -gt 255 ] || [ "$_o4" -gt 255 ] || [ "$_pfx" -gt 32 ]; then
        echo -e "${RED}错误：局域网网段数值超出范围：${LAN_SUBNET}，安装中止。${NC}"
        exit 1
    fi
}
if [ "$SUB_URL_1" != "YOUR_SUBSCRIPTION_URL_1" ] && ! [[ "$SUB_URL_1" =~ ^https?://[^/[:space:]]+ ]]; then
    echo -e "${RED}错误：订阅链接格式不对（应以 http:// 或 https:// 开头），安装中止。${NC}"
    exit 1
fi

echo -e "\n${YELLOW}=== 配置确认 ===${NC}"
echo -e "局域网网段: ${GREEN}${LAN_SUBNET}${NC}"
echo -e "本机 IP:     ${GREEN}${LOCAL_IP}${NC}"
# 订阅链接打码显示：只露协议与主机，路径中的令牌部分隐藏，
# 避免完整链接出现在终端回滚、截图或转发出去的日志里。
mask_url() {
    echo "$1" | sed -E 's#^(https?://[^/]+/).*#\1****#'
}

echo -e "订阅链接:   ${GREEN}$(mask_url "$SUB_URL_1")${NC}"
if [ -f /etc/mihomo/config.yaml ]; then
    echo -e "${YELLOW}检测到已有安装，旧的 config.yaml 会先备份再覆盖。${NC}"
fi
read -r -p "确认继续安装? (y/n): " CONFIRM || true
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "已取消安装。"
    exit 0
fi

# 多源下载辅助函数（防单源报错杀进程）
LAST_FETCH_SOURCE=""
smart_download() {
    local output="$1"
    shift
    for url in "$@"; do
        echo -e "${BLUE}尝试下载: ${url}${NC}"
        # -T 连接/读超时 15 秒，--tries=2 最多重试一次：GitHub 直连在部分网络
        # 环境下不是"连接失败"而是"连得上但卡住不传"，不加超时的话 wget 会
        # 无限等待，永远轮不到后面的国内镜像源，表现为卡死不动。
        if wget -q --show-progress -T 15 --tries=2 -O "$output" "$url"; then
            LAST_FETCH_SOURCE="$url"
            return 0
        fi
        echo -e "${YELLOW}当前下载源连接失败或超时，自动尝试下一个节点...${NC}"
    done
    return 1
}

# 资产完整性校验：给定文件的 sha256 与指定 SHA256SUMS 清单中记录一致
# 才算可用。清单以 assets/manifest.json 为权威记录，SHA256SUMS 由其
# 同步生成（刷新流程见 assets/README.md）。
asset_sha_ok_in() {
    local path="$1" name="$2" sums="$3" expected actual
    [ -f "$path" ] || return 1
    [ -f "$sums" ] || return 1
    expected=$(awk -v f="$name" '$2 == f {print $1}' "$sums")
    [ -n "$expected" ] || return 1
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}
# 按代码仓库本地清单校验（钉版批次退回路径用）
asset_sha_ok() {
    asset_sha_ok_in "$1" "$2" "$ASSETS_DIR/SHA256SUMS"
}

# 查询专用资产仓库的最新 Release 批次 tag（整轮安装只查一次并缓存）。
# 查不到（API 不可达、无 curl 等）时输出为空，调用方退回钉版批次。
FALLBACK_TAG_RESOLVED=0
FALLBACK_TAG=""
resolve_fallback_tag() {
    if [ "$FALLBACK_TAG_RESOLVED" -eq 0 ]; then
        FALLBACK_TAG_RESOLVED=1
        if command -v curl >/dev/null 2>&1; then
            FALLBACK_TAG=$(curl -m 10 -fsSL "${FALLBACK_ASSETS_API}/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 || true)
        fi
    fi
    printf '%s' "$FALLBACK_TAG"
}

# 专用资产仓库 Release 兜底：官方源全部失败时，按需拉取单个资产文件
# （内核只拉当前架构的那一个）。先走最新批次：拉该批次随附的
# SHA256SUMS，按它校验；最新批次拉不到或校验不过，再退回钉版批次
# （PROJECT_ASSETS_BASE）并按本地清单校验。两种路径都先落临时文件验
# sha256 再交给调用方，绝不把坏文件放行进安装流程。
fetch_from_project() {
    local name="$1" output="$2" tmp tag base sums
    tmp="$(mktemp /tmp/mgb-asset.XXXXXX)"
    tag="$(resolve_fallback_tag)"
    if [ -n "$tag" ]; then
        base="${FALLBACK_ASSETS_REPO_URL}/releases/download/${tag}"
        sums="$(mktemp /tmp/mgb-sums.XXXXXX)"
        if smart_download "$sums" "${base}/SHA256SUMS" && smart_download "$tmp" "${base}/${name}" && asset_sha_ok_in "$tmp" "$name" "$sums"; then
            echo -e "${GREEN}✓ ${name} 来自专用资产仓最新批次 ${tag}${NC}"
            rm -f "$sums"
            mv "$tmp" "$output"
            return 0
        fi
        rm -f "$sums"
        echo -e "${YELLOW}专用资产仓最新批次 (${tag}) 拉取或校验未通过，退回钉版批次...${NC}"
    fi
    if smart_download "$tmp" "${PROJECT_ASSETS_BASE}/${name}" && asset_sha_ok "$tmp" "$name"; then
        mv "$tmp" "$output"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# 统一拉取入口：所有产物都走这里。
# 用法: fetch_or_project <产物名> <输出文件> <专用资产仓资产文件名> <下载URL...>
# 策略：先按顺序尝试官方下载源（含镜像链）；官方全部失败才从专用资产仓库
# Release 按需拉取兜底资产并验 sha256。官方成功时绝不请求专用资产仓资产；
# 两种来源都可用的前提下，安装不应因网络环境差异失败。
FETCH_SUMMARY=()
fetch_or_project() {
    local label="$1" output="$2" bundle_file="$3"
    shift 3
    if smart_download "$output" "$@"; then
        FETCH_SUMMARY+=("${label}: 网络下载（官方） ($(du -h "$output" | cut -f1)，源 ${LAST_FETCH_SOURCE})")
        return 0
    fi
    echo -e "${YELLOW}${label}：官方下载源全部失败，尝试从专用资产仓库 Release 拉取兜底资产 (${bundle_file})...${NC}"
    if fetch_from_project "$bundle_file" "$output"; then
        FETCH_SUMMARY+=("${label}: 专用资产仓库兜底 ($(du -h "$output" | cut -f1)，sha256 校验通过)")
        echo -e "${GREEN}✓ ${label} 已使用专用资产仓库兜底资产${NC}"
        return 0
    fi
    echo -e "${RED}错误：${label} 获取失败——官方下载源全部不可用，且专用资产仓库兜底资产 ${bundle_file} 拉取失败或 sha256 校验不通过。${NC}"
    return 1
}

# 4. 下载并安装内核与 UI
# 拉取策略：先从官方版本拉，官方源（含镜像链）全失败则由脚本自动从
# 本专用资产仓库 Release 按需拉取钉版资产兜底（见 PROJECT_ASSETS_BASE），
# 先保证服务能装起来；版本更新交给跑起来之后的 auto-maintain.sh
# （届时本机已有代理，拉官方源不再受网络环境制约）。
echo -e "\n${BLUE}1/6 正在获取 Mihomo 内核...${NC}"
# 不能只看文件存不存在——Ctrl+C 中断下载会留下不完整的半截文件，
# 用 gzip -t 校验完整性，损坏的缓存直接扔掉重新下载，而不是留着
# 让后面的 gzip -d 报错退出。
if [ -f "/tmp/mihomo.gz" ] && gzip -t /tmp/mihomo.gz 2>/dev/null; then
    echo -e "${GREEN}✓ 检测到 /tmp/mihomo.gz 本地缓存（完整性校验通过），跳过内核下载${NC}"
    FETCH_SUMMARY+=("内核: /tmp 本地缓存")
else
    [ -f "/tmp/mihomo.gz" ] && echo -e "${YELLOW}检测到 /tmp/mihomo.gz 但文件不完整（可能是上次下载被中断），重新下载...${NC}"
    rm -f /tmp/mihomo.gz
    LATEST_VERSION=$(curl -m 10 --retry 2 -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name"' | grep -oP 'v[\d.]+' || true)
    if [ -z "$LATEST_VERSION" ]; then
        LATEST_VERSION=$(curl -m 10 -s "https://gh-proxy.com/https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" | grep '"tag_name"' | grep -oP 'v[\d.]+' || true)
    fi
    # 版本探测全失败时的兜底版本号与专用资产仓兜底资产保持一致
    [ -z "$LATEST_VERSION" ] && LATEST_VERSION="v1.19.32"

    KERNEL_FILE="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    if ! fetch_or_project "内核" "/tmp/mihomo.gz" "mihomo-linux-${BIN_ARCH}.gz" \
      "https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${KERNEL_FILE}" \
      "https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${KERNEL_FILE}" \
      "https://hub.gitmirror.com/https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${KERNEL_FILE}"; then
        echo -e "${RED}错误：内核获取失败（官方源与专用资产仓库兜底均不可用），安装中止。${NC}"
        exit 1
    fi

    if ! gzip -t /tmp/mihomo.gz 2>/dev/null; then
        echo -e "${RED}错误：内核文件完整性校验失败，安装中止。${NC}"
        rm -f /tmp/mihomo.gz
        exit 1
    fi
fi

gzip -d -f /tmp/mihomo.gz
chmod +x /tmp/mihomo
mv /tmp/mihomo /usr/local/bin/mihomo

echo -e "\n${BLUE}2/6 正在获取 metacubexd 控制面板...${NC}"
mkdir -p /etc/mihomo/ui /etc/mihomo/providers
if [ -f "/tmp/ui.tgz" ] && tar -tzf /tmp/ui.tgz >/dev/null 2>&1; then
    echo -e "${GREEN}✓ 检测到 /tmp/ui.tgz 本地缓存（完整性校验通过），跳过 UI 下载${NC}"
    FETCH_SUMMARY+=("面板 UI: /tmp 本地缓存")
else
    [ -f "/tmp/ui.tgz" ] && echo -e "${YELLOW}检测到 /tmp/ui.tgz 但文件不完整，重新下载...${NC}"
    rm -f /tmp/ui.tgz
    if ! fetch_or_project "面板 UI" "/tmp/ui.tgz" "ui.tgz" \
      "https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz" \
      "https://gh-proxy.com/https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz" \
      "https://hub.gitmirror.com/https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"; then
        echo -e "${RED}错误：面板 UI 获取失败（官方源与专用资产仓库兜底均不可用），安装中止。${NC}"
        exit 1
    fi

    if ! tar -tzf /tmp/ui.tgz >/dev/null 2>&1; then
        echo -e "${RED}错误：面板 UI 文件完整性校验失败，安装中止。${NC}"
        rm -f /tmp/ui.tgz
        exit 1
    fi
fi

# --no-same-owner：不沿用包内构建用户的 uid（目标机上可能不存在/不可 chown，
# 会让 tar 以非零码退出）；面板文件归 root 所有即可。
tar --no-same-owner -xzf /tmp/ui.tgz -C /etc/mihomo/ui
rm -f /tmp/ui.tgz

# 5. 备份旧配置、生成随机密钥
if [ -f /etc/mihomo/config.yaml ]; then
    BACKUP_NAME="/etc/mihomo/config.yaml.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/mihomo/config.yaml "$BACKUP_NAME"
    chmod 600 "$BACKUP_NAME"
    echo -e "${GREEN}✓ 旧配置已备份到 ${BACKUP_NAME}${NC}"
fi

# 重装时优先复用旧配置里的密钥：免得每次重装面板密码都变、还要到处重记
API_SECRET=""
if [ -f /etc/mihomo/config.yaml ]; then
    API_SECRET=$(grep -E '^secret:' /etc/mihomo/config.yaml | head -1 | sed -E 's/^secret:[[:space:]]*"([^"]*)".*/\1/; s/^secret:[[:space:]]*([^"[:space:]]+).*/\1/' || true)
    [ "$API_SECRET" = "CHANGE_ME_SECRET" ] && API_SECRET=""
fi
if [ -n "$API_SECRET" ]; then
    echo -e "${GREEN}✓ 复用已有配置中的面板密钥（重装不变更）${NC}"
elif command -v openssl >/dev/null 2>&1; then
    API_SECRET=$(openssl rand -hex 16)
else
    API_SECRET=$(head -c 32 /dev/urandom | md5sum | cut -d' ' -f1)
fi

# 6. 生成配置文件与运行环境
echo -e "\n${BLUE}3/6 渲染配置文件与脚本...${NC}"
# 替换值必须先转义：sed 的替换串里 & 表示“被匹配的原文”，订阅链接
# 只要带 &（多参数链接极常见）就会被悄悄改坏；| 是分隔符、\ 是转义符。
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
sed -e "s|192.168.0.0/16|$(sed_escape "$LAN_SUBNET")|g" \
    -e "s|YOUR_SUBSCRIPTION_URL_1|$(sed_escape "$SUB_URL_1")|g" \
    -e "s|CHANGE_ME_SECRET|$(sed_escape "$API_SECRET")|g" \
    "$REPO_ROOT/config/config.example.yaml" > /etc/mihomo/config.yaml
chmod 600 /etc/mihomo/config.yaml

cat > /etc/mihomo/maintain.env <<EOF
API="http://127.0.0.1:9090"
API_SECRET="${API_SECRET}"
PROVIDERS="airport1"
BIN_ARCH="${BIN_ARCH}"
EOF
chmod 600 /etc/mihomo/maintain.env

cp "$SCRIPT_DIR/tproxy.sh" /etc/mihomo/tproxy.sh
cp "$SCRIPT_DIR/auto-maintain.sh" /etc/mihomo/auto-maintain.sh
cp "$REPO_ROOT/systemd/mihomo.service" /etc/systemd/system/mihomo.service
cp "$REPO_ROOT/cron/mihomo-maintain.cron" /etc/cron.d/mihomo-maintain

chmod +x /etc/mihomo/*.sh

# 7. 预置 GeoIP/GeoSite/MMDB 数据库（必须发生在启动服务之前）
# mihomo 启动时若在 -d 目录下找不到 GeoSite.dat / GeoIP.dat / Country.mmdb，
# 会直连 github.com 下载，超时则直接 fatal 退出，导致 systemd 无限崩溃
# 循环。部分网络（如 N1）直连 GitHub 不通，这里统一走 fetch_or_project：
# 先经多源镜像拉官方版本，全失败则从专用资产仓库 Release 拉取钉版资产
# 兜底，让 mihomo 跳过自带下载、官方源不通也能首次启动。
# 注意落位文件名大小写：GeoSite.dat / GeoIP.dat / Country.mmdb，
# mihomo 按此约定名查找，写错大小写等于没放（文件系统大小写敏感）。
echo -e "\n${BLUE}4/6 预置 GeoIP/GeoSite/MMDB 数据库...${NC}"
GEO_MIRRORS=(
  "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
  "https://gh-proxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
  "https://hub.gitmirror.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
)
# 每行：落位文件名 官方资产名 专用资产仓资产名
GEO_FILES=(
  "GeoSite.dat geosite.dat GeoSite.dat"
  "GeoIP.dat geoip.dat GeoIP.dat"
  "Country.mmdb country.mmdb country.mmdb"
)
for GEO_LINE in "${GEO_FILES[@]}"; do
    read -r GEO_NAME GEO_REMOTE GEO_BUNDLE <<< "$GEO_LINE"
    if [ -f "/etc/mihomo/${GEO_NAME}" ]; then
        echo -e "${GREEN}✓ /etc/mihomo/${GEO_NAME} 已存在，跳过下载${NC}"
        FETCH_SUMMARY+=("${GEO_NAME}: 已存在，跳过")
        continue
    fi
    GEO_URLS=()
    for GEO_MIRROR in "${GEO_MIRRORS[@]}"; do
        GEO_URLS+=("${GEO_MIRROR}/${GEO_REMOTE}")
    done
    if ! fetch_or_project "${GEO_NAME}" "/tmp/${GEO_REMOTE}" "${GEO_BUNDLE}" "${GEO_URLS[@]}"; then
        echo -e "${RED}错误：${GEO_NAME} 获取失败（官方源与专用资产仓库兜底均不可用），安装中止。${NC}"
        exit 1
    fi
    # 先下载到 /tmp 再 mv，避免 wget 中断在 /etc/mihomo 留下半截文件
    # 让 mihomo 误以为数据库已就绪（半截文件不会报"找不到"，更隐蔽）。
    mv "/tmp/${GEO_REMOTE}" "/etc/mihomo/${GEO_NAME}"
    echo -e "${GREEN}✓ ${GEO_NAME} 已就绪${NC}"
done

# 8. 启动前配置自检：用刚装好的内核对最终配置做一次 mihomo -t，
# 配置或数据库有问题就在这里明确失败，而不是留给 systemd 崩溃循环。
echo -e "\n${BLUE}正在做启动前配置自检 (mihomo -t)...${NC}"
if ! /usr/local/bin/mihomo -t -d /etc/mihomo; then
    echo -e "${RED}错误：配置自检未通过，服务未启动。请根据上方输出修正后重跑安装。${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 配置自检通过${NC}"

# 9. 启动/重启服务
echo -e "\n${BLUE}5/6 启动系统服务...${NC}"
systemctl daemon-reload
if systemctl is-active --quiet mihomo 2>/dev/null; then
    # 已经在跑：enable --now 对 active 的服务不会重启，新配置不会生效，
    # 必须显式 restart，这也是"重复装测试改配置发现没生效"的坑点之一。
    systemctl restart mihomo
else
    systemctl enable --now mihomo
fi

# 10. 就绪校验：轮询 API 真正就绪才算成功，固定 sleep 不是就绪判断——
# 服务崩溃循环时 sleep 完照样打印"成功"是最难查的假阳性。
echo -e "\n${BLUE}6/6 校验服务状态...${NC}"
READY=0
for _ in $(seq 1 30); do
    if systemctl is-active --quiet mihomo 2>/dev/null \
        && curl -s -m 3 -H "Authorization: Bearer ${API_SECRET}" "http://127.0.0.1:9090/version" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done
if [ "$READY" -ne 1 ]; then
    echo -e "${RED}错误：服务启动后 30 秒内 API 未就绪，安装未完成。最近日志如下：${NC}"
    systemctl --no-pager status mihomo 2>/dev/null | head -20 || true
    journalctl -u mihomo -n 30 --no-pager 2>/dev/null || true
    exit 1
fi
echo -e "${GREEN}✓ 服务已就绪 (API http://127.0.0.1:9090 可达)${NC}"

echo -e "\n${BLUE}--- 产物获取汇总 ---${NC}"
for line in "${FETCH_SUMMARY[@]}"; do
    echo "  • $line"
done
echo -e "订阅状态: ${SUB_STATUS}"

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}🎉 Mihomo TPROXY 透明代理旁路由部署成功！${NC}"
echo -e "控制面板: ${BLUE}http://${LOCAL_IP}:9090/ui${NC}"
echo -e "面板密钥: ${YELLOW}${API_SECRET}${NC} (已写入 config.yaml 与 maintain.env)"
echo -e "日志查看: ${YELLOW}journalctl -u mihomo -f${NC}"
echo -e "维护日志: ${YELLOW}tail -f /var/log/mihomo-maintain.log${NC}"
echo -e "${GREEN}====================================================${NC}"
