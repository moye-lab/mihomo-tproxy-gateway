#!/bin/bash
set -e

# 脚本所在目录（支持从任意目录调用；解析物理路径，防符号链接下锚错目录）
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# 钉版校验清单目录：默认用代码仓库自带的 assets/（生产校验的权威来
# 源）。可用同名环境变量覆盖（与下方三个资产仓变量、MGB_OS_RELEASE
# 同一约定，供桩测把清单指向测试生成的夹具清单——夹具文件体积小、
# 哈希与真实资产不同，不对齐则钉版路径在桩测里永远走不通，见
# tests/run-tests.sh 的 make_test_sums）。默认不覆盖时生产行为零变化：
# 校验仍按仓库真实 SHA256SUMS 执行，这里不存在跳过校验的分支；且
# 环境变量本就已能通过 FALLBACK_ASSETS_API/REPO_URL 决定最新批次的
# 字节与校验值（最新批次是自校验的），本覆盖不新增任何信任边界。
ASSETS_DIR="${ASSETS_DIR:-$REPO_ROOT/assets}"

# 专用资产仓库（sg/mihomo-assets，与代码仓库相互独立）：官方源
# （含镜像链）全部失败时，安装器统一向这个专用仓库拉兜底资产，资产
# 只维护一处、新鲜度只由它一处决定。兜底时的批次选择分两级：
#   1) 最新批次优先：先经 FALLBACK_ASSETS_API 查询该仓库的最新
#      Release，按该批次拉文件，并用该批次随附的 SHA256SUMS 校验
#      ——仓库里始终躺着最新版，任何脚本走兜底都拿到最新批次；
#   2) 钉版批次退回：查询或拉取失败时，退回 PROJECT_ASSETS_BASE
#      指向的钉版批次，按代码仓库本地 assets/SHA256SUMS 校验。
# 三个变量都可用同名环境变量覆盖，资产清单与校验值见 assets/。
PROJECT_ASSETS_BASE="${PROJECT_ASSETS_BASE:-https://git.edge97.dpdns.org/sg/mihomo-assets/releases/download/v1.0.1}"
FALLBACK_ASSETS_REPO_URL="${FALLBACK_ASSETS_REPO_URL:-https://git.edge97.dpdns.org/sg/mihomo-assets}"
FALLBACK_ASSETS_API="${FALLBACK_ASSETS_API:-https://git.edge97.dpdns.org/api/v1/repos/sg/mihomo-assets}"

# 回滚后 API 就绪轮询次数（每次间隔 1 秒）：与安装校验的 30 秒等待
# 一致。真机实测 N1 上 mihomo 冷启动拉订阅需 12 秒以上才就绪，10 秒
# 会误报"回滚未完全成功"（2026-11-13）。可用同名环境变量覆盖（测试提速）。
ROLLBACK_API_TRIES="${ROLLBACK_API_TRIES:-30}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 阶段化日志：每个阶段输出一行 [阶段名] 前缀，同时追加到安装日志文件，
# 失败时可据此定位到具体阶段。
INSTALL_LOG="/var/log/mihomo-install.log"
CURRENT_STAGE="初始化"

# 统一日志接口（P1-16，五脚本同一约定：[时间] [级别] [阶段] 消息）：
#   log <级别> <消息>      级别：INFO / WARN / ERROR
# 终端按级别着色（INFO 蓝、WARN 黄、ERROR 红），日志文件存纯文本。
# 敏感信息脱敏规则（集中说明，五个脚本共同遵守）：
#   1) 订阅链接：终端与日志只显示打码形式（mask_url：协议+主机+****），
#      完整链接只出现在 config.yaml（600 权限）与内存变量中；
#   2) 面板 secret：只在安装成功页显示一次（终端 echo，不经 log，
#      绝不进日志文件）；其余位置不出现 secret；
#   3) 下载源 URL（GitHub/资产仓）不含敏感信息，可正常记录。
# 交互展示类输出（顶部横幅、确认页、产物汇总、成功页）保留 echo，
# 不进日志文件；其中成功页含面板密钥，绝不能改走 log。
log() {
    local _level="$1"; shift
    local _ts
    local _color="$NC"
    _ts="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$_level" in
        INFO)  _color="$BLUE" ;;
        WARN)  _color="$YELLOW" ;;
        ERROR) _color="$RED" ;;
    esac
    printf '%b[%s] [%s] [%s] %s%b\n' "$_color" "$_ts" "$_level" "$CURRENT_STAGE" "$*" "$NC"
    printf '[%s] [%s] [%s] %s\n' "$_ts" "$_level" "$CURRENT_STAGE" "$*" >> "$INSTALL_LOG" 2>/dev/null || true
}

stage() {
    CURRENT_STAGE="$1"
    log INFO "${2:-}"
}

# 安装事务状态：用户确认后先备份旧状态（txn_backup），任一关键阶段失败
# 时 EXIT trap 执行回滚（txn_rollback）并明确报告回滚成败，绝不假装
# 恢复成功。UI 暂存安装也是事务的一部分（旧 UI 在回滚时恢复）。
# 唯一例外是最后的功能验证：verify 未通过时算安装失败、退出码非零，
# 但服务已正常启动，回滚反而会把能用的服务停掉，故置 TXN_COMMITTED=1
# 让 EXIT trap 跳过回滚、服务保持运行（第二轮定夺 3）。
UI_OLD=""
UI_STAGE=""
TXN_STARTED=0
TXN_COMMITTED=0
TXN_DIR=""
TXN_BIN_EXISTED=0
TXN_MIHOMO_DIR_EXISTED=0
TXN_SVC_WAS_ACTIVE=0
TXN_SVC_WAS_ENABLED=0
TXN_CONFIG_BACKUP=""
TXN_FILES_RESTORED=0
# 事务备份的小文件（备份名:系统路径）：安装前存在则备份、回滚时恢复；
# 安装前不存在则回滚时移除本次装入的副本。
TXN_FILE_PAIRS=(
    "tproxy.env:/etc/mihomo/tproxy.env"
    "maintain.env:/etc/mihomo/maintain.env"
    "tproxy.sh:/etc/mihomo/tproxy.sh"
    "auto-maintain.sh:/etc/mihomo/auto-maintain.sh"
    "verify.sh:/etc/mihomo/verify.sh"
    "mihomo.service:/etc/systemd/system/mihomo.service"
    "mihomo-maintain:/etc/cron.d/mihomo-maintain"
)

# 清理本项目 TPROXY/DNS 规则与策略路由：调用仓库 tproxy.sh 的
# stop 模式（自带归属校验与清理校验）。仓库版本过旧（无 STOP_MODE
# 标记）时明确拒绝，不再退回内联删除——第二轮整改（v1.2.2）决策：
# 旧内联回退副本只清 MIHOMO/MIHOMO_DNS 两条链，漏了 MIHOMO_DO /
# MIHOMO_DNS_DO / MIHOMO_V6 三条链，残留校验同样不查它们，却仍报
# "清干净"（exit 0）；且按链名无条件删链，会误删他人同名链。回退
# 副本只在"新 install.sh + 旧 tproxy.sh"混用时触发，git clone 永远
# 不会出现这种组合；保留第二份清理实现只会再次漂移（本次审计的教
# 训），不如明确拒绝，让用户用一致版本重跑。返回 0 表示确认清干净。
tproxy_stop() {
    if grep -q 'STOP_MODE' "$SCRIPT_DIR/tproxy.sh" 2>/dev/null; then
        if bash "$SCRIPT_DIR/tproxy.sh" stop; then
            return 0
        fi
        return 1
    fi
    log ERROR "仓库内的 tproxy.sh 版本过旧（无 STOP_MODE 标记），无法安全清理规则；请用同一版本重新克隆仓库后再试，不要混用新旧脚本。"
    return 1
}

# 安装前备份旧状态：旧二进制（/usr/local/bin/mihomo.bak）、旧服务运行
# 状态、旧运行时小文件与现有 TPROXY 规则快照（供回滚后人工比对）。
# 配置文件 config.yaml 的备份在配置阶段做（已有逻辑），路径记入
# TXN_CONFIG_BACKUP。必须在用户确认后、第一次修改系统前调用。
txn_backup() {
    local _pair _name _dest
    stage "事务" "备份安装前状态..."
    TXN_DIR="$(mktemp -d /tmp/mgb-txn.XXXXXX)"
    TXN_STARTED=1
    if [ -f /usr/local/bin/mihomo ]; then
        TXN_BIN_EXISTED=1
        if cp /usr/local/bin/mihomo /usr/local/bin/mihomo.bak; then
            log INFO "旧内核已备份到 /usr/local/bin/mihomo.bak"
        else
            log WARN "旧内核备份失败，回滚时可能无法恢复旧二进制。"
        fi
    fi
    [ -d /etc/mihomo ] && TXN_MIHOMO_DIR_EXISTED=1
    if systemctl is-active --quiet mihomo 2>/dev/null; then TXN_SVC_WAS_ACTIVE=1; fi
    if systemctl is-enabled --quiet mihomo 2>/dev/null; then TXN_SVC_WAS_ENABLED=1; fi
    mkdir -p "$TXN_DIR/files" "$TXN_DIR/rules"
    for _pair in "${TXN_FILE_PAIRS[@]}"; do
        _name="${_pair%%:*}"; _dest="${_pair#*:}"
        if [ -f "$_dest" ]; then
            cp -p "$_dest" "$TXN_DIR/files/$_name" 2>/dev/null || true
        fi
    done
    ip rule show > "$TXN_DIR/rules/ip-rule.txt" 2>&1 || true
    ip route show table 100 > "$TXN_DIR/rules/ip-route-100.txt" 2>&1 || true
    iptables -t mangle -S MIHOMO > "$TXN_DIR/rules/iptables-mangle.txt" 2>&1 || true
    iptables -t nat -S MIHOMO_DNS > "$TXN_DIR/rules/iptables-nat.txt" 2>&1 || true
    log INFO "服务状态：运行中=${TXN_SVC_WAS_ACTIVE}，开机自启=${TXN_SVC_WAS_ENABLED}；规则快照：$TXN_DIR/rules"
}

# 从 config.yaml 提取面板 secret：双引号、单引号、无引号三种写法都认，
# 只取引号内的值。v1.1.0 起的旧提取只有双引号/无引号两条分支，单引号
# 写法（secret: 'abc'）会把引号本身带进密钥，导致 API 鉴权失败。
# 无 secret 行时输出空；CHANGE_ME_SECRET 占位符由调用方自行处理。
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
# 与 verify.sh / switch-sub.sh / restore.sh 的 panel_api_host 同一条规则。
panel_api_host() { # panel_api_host <config.yaml>
    local _listen=""
    _listen=$(grep -E '^external-controller:' "$1" 2>/dev/null | head -1 | sed -E 's/^external-controller:[[:space:]]*([^:]+):.*/\1/' || true)
    case "$_listen" in
        ""|"0.0.0.0") printf '127.0.0.1' ;;
        *) printf '%s' "$_listen" ;;
    esac
}

# 回滚后 API 就绪轮询（至多 ROLLBACK_API_TRIES 秒，默认 30 秒，与安装
# 校验一致）：secret 取自恢复后的旧配置（回滚时 install.sh 的 API_SECRET
# 变量可能尚未赋值——下载阶段失败时就是如此）；API 地址同样取自恢复后
# 的旧配置（旧配置的监听模式可能与本次新选的不同，不能用 PANEL_LISTEN）。
# 返回 0 表示 API 可达。
rollback_api_ready() {
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
    for _i in $(seq 1 "$ROLLBACK_API_TRIES"); do
        if systemctl is-active --quiet mihomo 2>/dev/null \
            && curl --noproxy '*' -s -m 3 "${_auth[@]}" "$API/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 回滚：恢复备份的旧状态。只做"恢复到安装前"，不做猜测性修复；
# 每一步都明确报告成败，任一步失败最终都如实报告，不假装恢复成功。
# 注意：本函数在 EXIT trap 里运行，所有可能失败的命令都必须显式处理
# 返回码，不能依赖 set -e（trap 内 set -e 行为不可靠，且回滚中途退出
# 会留下更糟的半成品状态）。
txn_rollback() {
    local ok=1 _pair _name _dest _i _up
    local _failed_stage="$CURRENT_STAGE"
    CURRENT_STAGE="回滚"
    log ERROR "安装在 [${_failed_stage}] 阶段失败，开始回滚到安装前状态..."

    # 1. 恢复旧面板 UI（原有逻辑：UI_OLD 存在即恢复）
    if [ -n "${UI_OLD:-}" ] && [ -d "$UI_OLD" ]; then
        rm -rf /etc/mihomo/ui
        if mv "$UI_OLD" /etc/mihomo/ui; then
            log INFO "✓ 已恢复旧面板 UI"
            TXN_FILES_RESTORED=1
        else
            log ERROR "✗ 旧面板 UI 恢复失败，旧目录仍在 $UI_OLD，请手动恢复"
            ok=0
        fi
    fi

    # 2. 恢复旧内核二进制（经临时文件 + mv 原子替换，避免覆盖运行中的
    # 二进制时触发 ETXTBSY）；全新安装（之前无二进制）则移除本次装入的
    if [ "$TXN_BIN_EXISTED" -eq 1 ]; then
        if [ ! -f /usr/local/bin/mihomo.bak ]; then
            log ERROR "✗ 旧内核备份 /usr/local/bin/mihomo.bak 不存在，无法恢复旧二进制！"
            ok=0
        elif cp /usr/local/bin/mihomo.bak /usr/local/bin/mihomo.restoring \
            && chmod +x /usr/local/bin/mihomo.restoring \
            && mv /usr/local/bin/mihomo.restoring /usr/local/bin/mihomo; then
            log INFO "✓ 已恢复旧内核二进制"
            rm -f /usr/local/bin/mihomo.bak
            TXN_FILES_RESTORED=1
        else
            rm -f /usr/local/bin/mihomo.restoring
            log ERROR "✗ 旧内核恢复失败！旧二进制仍在 /usr/local/bin/mihomo.bak，请手动执行：cp /usr/local/bin/mihomo.bak /usr/local/bin/mihomo"
            ok=0
        fi
    elif [ -f /usr/local/bin/mihomo ]; then
        rm -f /usr/local/bin/mihomo || true
        log INFO "✓ 已移除本次安装的新内核（安装前无旧内核）"
    fi

    # 3. 恢复旧配置（配置阶段的备份）
    if [ -n "$TXN_CONFIG_BACKUP" ] && [ -f "$TXN_CONFIG_BACKUP" ]; then
        if cp "$TXN_CONFIG_BACKUP" /etc/mihomo/config.yaml; then
            log INFO "✓ 已恢复旧配置 config.yaml（备份保留在 $TXN_CONFIG_BACKUP）"
            TXN_FILES_RESTORED=1
        else
            log ERROR "✗ 旧配置恢复失败，备份仍在 $TXN_CONFIG_BACKUP，请手动恢复"
            ok=0
        fi
    fi

    # 4. 恢复旧运行时小文件；安装前不存在的，移除本次装入的副本
    for _pair in "${TXN_FILE_PAIRS[@]}"; do
        _name="${_pair%%:*}"; _dest="${_pair#*:}"
        if [ -n "${TXN_DIR:-}" ] && [ -f "$TXN_DIR/files/$_name" ]; then
            if cp -p "$TXN_DIR/files/$_name" "$_dest"; then
                TXN_FILES_RESTORED=1
            else
                log ERROR "✗ $_dest 恢复失败，备份在 $TXN_DIR/files/$_name"
                ok=0
            fi
        else
            rm -f "$_dest" || true
        fi
    done
    if [ -f /etc/mihomo/tproxy.sh ]; then chmod +x /etc/mihomo/tproxy.sh || true; fi
    if [ -f /etc/mihomo/auto-maintain.sh ]; then chmod +x /etc/mihomo/auto-maintain.sh || true; fi
    systemctl daemon-reload 2>/dev/null || true

    # 5. 全新安装失败：移除本次新建的整个 /etc/mihomo，恢复"未安装"状态
    if [ "$TXN_MIHOMO_DIR_EXISTED" -eq 0 ] && [ -d /etc/mihomo ]; then
        rm -rf /etc/mihomo || true
        log INFO "✓ 已移除本次新建的 /etc/mihomo"
    fi

    # 6. 恢复服务状态
    if [ "$TXN_SVC_WAS_ACTIVE" -eq 1 ]; then
        if [ "$TXN_FILES_RESTORED" -eq 1 ]; then
            # 文件已恢复，必须重启服务才能跑回旧版本（ExecStartPost 重建规则）
            if systemctl restart mihomo 2>/dev/null; then
                _up=0
                for _i in $(seq 1 10); do
                    if systemctl is-active --quiet mihomo 2>/dev/null; then _up=1; break; fi
                    sleep 1
                done
                if [ "$_up" -eq 1 ]; then
                    # P1-13：只看 active 不够（P0 已知限制第 2 条）——
                    # 服务 active 但 API 不就绪（如端口冲突）时，回滚不
                    # 能报告成功；文件已恢复是事实，API 异常也要如实报告。
                    if rollback_api_ready; then
                        log INFO "✓ 服务已恢复运行（旧版本），API 已就绪"
                    else
                        log ERROR "✗ 服务已恢复运行（旧版本），但 API 在 ${ROLLBACK_API_TRIES} 秒内未就绪（回滚文件已恢复，服务本身可能有问题），请检查 journalctl -u mihomo"
                        ok=0
                    fi
                else
                    log ERROR "✗ 服务重启后未保持运行，请检查 journalctl -u mihomo"
                    ok=0
                fi
            else
                log ERROR "✗ 服务重启失败，请检查 journalctl -u mihomo"
                ok=0
            fi
        elif systemctl is-active --quiet mihomo 2>/dev/null; then
            log INFO "✓ 服务未受影响，仍在运行"
        elif systemctl start mihomo 2>/dev/null; then
            if rollback_api_ready; then
                log INFO "✓ 服务已重新启动，API 已就绪"
            else
                log ERROR "✗ 服务已重新启动，但 API 在 ${ROLLBACK_API_TRIES} 秒内未就绪，请检查 journalctl -u mihomo"
                ok=0
            fi
        else
            log ERROR "✗ 服务启动失败，请检查 journalctl -u mihomo"
            ok=0
        fi
    else
        # 安装前未运行：保持停止，并清掉安装中途可能建了一半的规则
        systemctl stop mihomo 2>/dev/null || true
        if [ "$TXN_SVC_WAS_ENABLED" -eq 0 ]; then
            systemctl disable mihomo 2>/dev/null || true
        fi
        if tproxy_stop; then
            log INFO "✓ 服务保持停止，残余规则已清理"
        else
            log ERROR "✗ 残余 TPROXY 规则清理未完全成功，请检查 ip rule / iptables"
            ok=0
        fi
    fi

    # 7. 如实报告回滚结果
    if [ "$ok" -eq 1 ]; then
        log INFO "回滚成功：系统已恢复到安装前状态。规则快照（供比对）保留在 ${TXN_DIR}/rules"
    else
        log ERROR "回滚未完全成功！请按上方 ✗ 提示手动处理；规则快照保留在 ${TXN_DIR}/rules"
    fi
}

# EXIT trap：成功时清理事务备份；失败时执行回滚（TXN_COMMITTED=1 时
# 除外：功能验证失败已提交事务，服务保持运行，只清理事务备份、不回
# 滚）。最后一条语句必须是 return "$rc"，保证脚本以原始退出码退出。
install_exit_cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$TXN_COMMITTED" -eq 1 ]; then
            log INFO "功能验证未通过，但事务已提交：服务保持运行，不执行回滚；安装产物与配置已保留，请按自检输出排查后重跑 verify.sh 或重跑安装。"
            rm -f /usr/local/bin/mihomo.bak
            [ -n "${TXN_DIR:-}" ] && [ -d "$TXN_DIR" ] && rm -rf "$TXN_DIR"
        elif [ "$TXN_STARTED" -eq 1 ]; then
            txn_rollback
        else
            echo "安装未开始修改系统，无需回滚。" >&2
        fi
    else
        [ -n "${UI_OLD:-}" ] && rm -rf "$UI_OLD"
        rm -f /usr/local/bin/mihomo.bak
        [ -n "${TXN_DIR:-}" ] && [ -d "$TXN_DIR" ] && rm -rf "$TXN_DIR"
    fi
    [ -n "${UI_STAGE:-}" ] && rm -rf "$UI_STAGE"
    # 迁移临时文件含完整配置（订阅链接与面板密钥）：成功时它已被 mv
    # 走、路径已不存在；中途失败时必须清掉，不让含密钥的临时文件滞留 /tmp。
    [ -n "${MIGRATE_TMP:-}" ] && rm -f "$MIGRATE_TMP"
    return "$rc"
}
trap install_exit_cleanup EXIT

# ------------------------------------------------------------------
# P1-6 系统兼容性预检（安装前全部跑完，任一必需项失败即中止安装）
# 原则（第二轮第 5 项，定夺 2）：apt 系（Debian/Ubuntu/Armbian）缺失
# 系统依赖时自动安装——预检只收集缺失清单，确认页展示安装计划，用户
# 确认后才执行 apt 安装；自动安装失败时打印完整手动命令并中止，不静
# 默继续。非 apt 系不自动安装，预检直接报错并给出针对该包管理器的完
# 整手动命令。未知发行版只警告不停装，除非明确不兼容（如 Alpine/musl，
# mihomo 官方二进制跑不起来）。
# 测试钩子：MGB_OS_RELEASE 可指向一份假的 os-release（桩测用）。
# ------------------------------------------------------------------
OS_RELEASE_FILE="${MGB_OS_RELEASE:-/etc/os-release}"

# 预检收集的依赖安装计划（全局，供确认页展示与确认后安装用）：
# MISSING_PKGS 与 MISSING_CMDS 平行（同一顺序），前者是包名、后者是
# 对应命令名；PKG_MANAGER 为检测到的包管理器（apt/dnf/yum/pacman/
# zypper，空表示未知）；IP6TABLES_OK=0 时 IPv6 阻断提问被门控禁止；
# CRON_OK：1 可用、2 已安装但未运行、0 缺失（只警告，不中止安装）。
MISSING_PKGS=()
MISSING_CMDS=()
PKG_MANAGER=""
IP6TABLES_OK=1
CRON_OK=1
IPTABLES_WAS_MISSING=0

# 命令→包名映射（复用 P1-6 的映射；dnf/yum 下 ip 对应 iproute 而非
# iproute2，其余包名各管理器一致）。
cmd_to_pkg() { # cmd_to_pkg <命令> [包管理器]
    local _cmd="$1" _mgr="${2:-apt}"
    case "$_cmd" in
        iptables) printf 'iptables' ;;
        ip)
            if [ "$_mgr" = "dnf" ] || [ "$_mgr" = "yum" ]; then printf 'iproute'; else printf 'iproute2'; fi
            ;;
        flock) printf 'util-linux' ;;
        sha256sum) printf 'coreutils' ;;
        *) printf '%s' "$_cmd" ;;
    esac
}

# 非 apt 系包管理器识别（按常见程度排序；只检测存在性，不执行安装）。
detect_pkg_manager() {
    local _m
    for _m in dnf yum pacman zypper; do
        if command -v "$_m" >/dev/null 2>&1; then
            printf '%s' "$_m"
            return 0
        fi
    done
    return 1
}

# 针对当前包管理器的完整手动安装命令（自动安装失败与非 apt 系报错用）。
manual_install_cmd() { # manual_install_cmd <包...>
    local _pkgs="$*"
    case "${PKG_MANAGER:-}" in
        apt) printf 'sudo apt-get install -y %s' "$_pkgs" ;;
        dnf) printf 'sudo dnf install -y %s' "$_pkgs" ;;
        yum) printf 'sudo yum install -y %s' "$_pkgs" ;;
        pacman) printf 'sudo pacman -S --noconfirm %s' "$_pkgs" ;;
        zypper) printf 'sudo zypper install -y %s' "$_pkgs" ;;
        *) printf '请用系统包管理器手动安装 %s' "$_pkgs" ;;
    esac
}

# 判断 IPv4 是否属于私有/保留段（10/8、172.16/12、192.168/16、127/8、
# 169.254/16、100.64/10），是返回 0。纯 glob 匹配，无算术比较，不怕
# 前导零被当八进制。
is_private_ipv4() {
    case "$1" in
        10.*|127.*|192.168.*|169.254.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        100.6[4-9].*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        *) return 1 ;;
    esac
}

# 校验单个 CIDR（格式 + 数值 + 前导零，与 tproxy.sh 同一条校验），
# 失败时打印原因并返回 1，由调用方决定中止。
validate_cidr_input() {
    local _cidr="$1" _o1 _o2 _o3 _o4 _pfx
    if ! [[ "$_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log ERROR "错误：局域网网段格式不对：${_cidr}（应为 CIDR 形式，如 192.168.1.0/24），安装中止。"
        return 1
    fi
    IFS='./' read -r _o1 _o2 _o3 _o4 _pfx <<< "$_cidr"
    if [ "$_o1" -gt 255 ] || [ "$_o2" -gt 255 ] || [ "$_o3" -gt 255 ] || [ "$_o4" -gt 255 ] || [ "$_pfx" -gt 32 ]; then
        log ERROR "错误：局域网网段数值超出范围：${_cidr}，安装中止。"
        return 1
    fi
    # 拒绝带前导 0 的数字（如 010）：iptables 按八进制解析它，与十进制
    # 校验结果不一致，会导致规则实际作用的网段与配置不符。
    if [[ "$_cidr" =~ (^|[./])0[0-9] ]]; then
        log ERROR "错误：局域网网段包含带前导 0 的数字：${_cidr}（请用十进制，如 192.168.1.0/24），安装中止。"
        return 1
    fi
    return 0
}

# TPROXY 内核支持探测：建一条临时链，往里挂一条 TPROXY 规则，挂得上
# 才算支持（比 lsmod 查模块名可靠：模块可能编进内核、也可能已加载但
# target 不可用）。探测链用完即删，不留残留。
tproxy_probe() {
    local chain="MGB-PROBE-$$"
    iptables -t mangle -N "$chain" 2>/dev/null || return 1
    if iptables -t mangle -A "$chain" -p tcp -j TPROXY --on-port 7893 --tproxy-mark 1 2>/dev/null; then
        iptables -t mangle -F "$chain" 2>/dev/null || true
        iptables -t mangle -X "$chain" 2>/dev/null || true
        return 0
    fi
    iptables -t mangle -F "$chain" 2>/dev/null || true
    iptables -t mangle -X "$chain" 2>/dev/null || true
    return 1
}

preflight_checks() {
    local failures=0 _os_id="" _os_version="" _os_pretty=""
    local _cmd _pkg _apt_like=0 _svc
    stage "预检" "检查系统兼容性（发行版、架构、systemd、命令、TPROXY 支持、依赖）..."

    # -- 发行版与版本：支持 Debian 12/13、Ubuntu 22.04/24.04/26.04、
    #    Armbian 及常见 ARM64 Linux；未知发行版只警告不停装。
    if [ -r "$OS_RELEASE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$OS_RELEASE_FILE"
        _os_id="${ID:-}"; _os_version="${VERSION_ID:-}"; _os_pretty="${PRETTY_NAME:-}"
    fi
    case "$_os_id" in
        debian|ubuntu) _apt_like=1 ;;
    esac
    # Armbian 的 os-release 通常仍是 ID=debian，靠标记文件或名称识别。
    if [ "$_os_id" = "armbian" ] || [ -f /etc/armbian-release ] || [[ "$_os_pretty" == *Armbian* ]]; then
        log INFO "✓ 发行版：Armbian（Debian 系，${_os_pretty:-未知版本}）"
        _apt_like=1
    elif [ "$_os_id" = "alpine" ]; then
        log ERROR "✗ 发行版：Alpine Linux 明确不受支持（musl libc 无法运行 mihomo 官方 glibc 二进制，且无 systemd）。"
        failures=$((failures + 1))
    elif [ "$_os_id" = "debian" ]; then
        case "$_os_version" in
            12|13) log INFO "✓ 发行版：Debian ${_os_version}" ;;
            *) log WARN "⚠ 发行版：Debian ${_os_version:-未知版本} 未在支持清单中（已验证：12、13），继续安装，遇到问题请反馈。" ;;
        esac
    elif [ "$_os_id" = "ubuntu" ]; then
        case "$_os_version" in
            22.04|24.04|26.04) log INFO "✓ 发行版：Ubuntu ${_os_version}" ;;
            *) log WARN "⚠ 发行版：Ubuntu ${_os_version:-未知版本} 未在支持清单中（已验证：22.04、24.04、26.04），继续安装，遇到问题请反馈。" ;;
        esac
    elif [ -z "$_os_id" ]; then
        log WARN "⚠ 无法识别发行版（${OS_RELEASE_FILE} 不可读），继续安装；后续检查仍会验证必需组件。"
    else
        log WARN "⚠ 发行版 ${_os_pretty:-$_os_id} 未在支持清单中（已验证：Debian 12/13、Ubuntu 22.04/24.04/26.04、Armbian），继续安装，遇到问题请反馈。"
    fi

    # 包管理器：apt 系固定为 apt（自动安装用）；非 apt 系识别现有管理器
    # （只用于生成完整手动命令，不自动安装）。
    if [ "$_apt_like" -eq 1 ]; then
        PKG_MANAGER="apt"
    else
        PKG_MANAGER="$(detect_pkg_manager || true)"
    fi

    # -- CPU 架构（与资产清单一致的映射：x86_64/aarch64/armv7l）
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  BIN_ARCH="amd64" ;;
      aarch64) BIN_ARCH="arm64" ;;
      armv7l)  BIN_ARCH="armv7" ;;
      *)       log ERROR "✗ 暂不支持的 CPU 架构: $ARCH（支持 x86_64、aarch64、armv7l）"; failures=$((failures + 1)) ;;
    esac
    [ -n "${BIN_ARCH:-}" ] && log INFO "✓ 检测到系统架构: ${ARCH} (${BIN_ARCH})"

    # -- systemd（服务管理必需）
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        log INFO "✓ systemd 可用"
    else
        log ERROR "✗ 未检测到可用的 systemd（需要 systemctl 命令）。本项目依赖 systemd 管理服务，请在带 systemd 的系统上安装。"
        failures=$((failures + 1))
    fi

    # -- 必需命令：iptables / ip（网络规则必需）
    # apt 系缺失时不直接失败，记入安装计划、确认后自动安装；
    # 非 apt 系无法自动安装，报错并给针对该管理器的完整手动命令。
    for _cmd in iptables ip; do
        if command -v "$_cmd" >/dev/null 2>&1; then
            log INFO "✓ 命令可用：${_cmd}"
        else
            _pkg="$(cmd_to_pkg "$_cmd" "$PKG_MANAGER")"
            if [ "$_apt_like" -eq 1 ]; then
                MISSING_PKGS+=("$_pkg")
                MISSING_CMDS+=("$_cmd")
                [ "$_cmd" = "iptables" ] && IPTABLES_WAS_MISSING=1
                log WARN "⚠ 缺少必需命令 ${_cmd}：将在确认安装后自动安装 ${_pkg}（见确认页依赖安装计划）"
            else
                log ERROR "✗ 缺少必需命令 ${_cmd}，请手动安装：$(manual_install_cmd "$_pkg")"
                failures=$((failures + 1))
            fi
        fi
    done

    # -- 可选命令：ip6tables（仅 IPv6 阻断功能需要；缺失只警告，但会门
    #    控确认页的阻断提问——见 IP6TABLES_OK）
    if command -v ip6tables >/dev/null 2>&1; then
        log INFO "✓ 命令可用：ip6tables"
    else
        IP6TABLES_OK=0
        log WARN "⚠ 未检测到 ip6tables：IPv6 阻断功能不可用（其余功能不受影响）；如需该功能请安装 iptables 包（$(manual_install_cmd iptables)）。"
    fi

    # -- TPROXY 内核支持（功能性探测；iptables 缺失时跳过，避免重复报错）
    if command -v iptables >/dev/null 2>&1; then
        if tproxy_probe; then
            log INFO "✓ 内核支持 TPROXY"
        else
            log ERROR "✗ 内核不支持 TPROXY（无法创建 TPROXY 规则）。请确认内核已启用 TPROXY 支持（xt_TPROXY 模块或编入内核），或换用支持的系统/内核。"
            failures=$((failures + 1))
        fi
    fi

    # -- 必需依赖：下载/解压/校验/锁（apt 系缺失时记入安装计划、确认后
    #    自动安装；非 apt 系报错并给完整手动命令，与必需命令同一条规则）
    for _cmd in wget curl tar gzip flock sha256sum; do
        if command -v "$_cmd" >/dev/null 2>&1; then
            log INFO "✓ 依赖可用：${_cmd}"
        else
            _pkg="$(cmd_to_pkg "$_cmd" "$PKG_MANAGER")"
            if [ "$_apt_like" -eq 1 ]; then
                MISSING_PKGS+=("$_pkg")
                MISSING_CMDS+=("$_cmd")
                log WARN "⚠ 缺少必需依赖 ${_cmd}：将在确认安装后自动安装 ${_pkg}（见确认页依赖安装计划）"
            else
                log ERROR "✗ 缺少必需依赖 ${_cmd}，请手动安装：$(manual_install_cmd "$_pkg")"
                failures=$((failures + 1))
            fi
        fi
    done

    # -- 可选依赖：openssl（缺失时密钥改走 /dev/urandom 回退路径）
    if command -v openssl >/dev/null 2>&1; then
        log INFO "✓ 依赖可用：openssl"
    else
        log WARN "⚠ 未检测到 openssl：面板密钥将改用 /dev/urandom 生成（功能不受影响）。"
    fi

    # -- cron 服务（可选但重要：15 分钟健康检查、订阅刷新与 IPv6 阻断
    #    补建都靠 cron 定时触发）。缺 cron 只大声警告、不中止安装：
    #    网关代理本身不依赖 cron，直接 fail 掉整个安装过重；警告进日
    #    志，成功页也会注明。判定：systemctl is-active（cron/crond 任
    #    一在跑）→ 可用；is-enabled（已安装并开机自启、但当前未运行）
    #    → 警告未运行；守护进程存在（pgrep，覆盖无 systemd 单元的情
    #    况）→ 可用；三者皆无 → 警告缺失。
    CRON_OK=0
    for _svc in cron crond; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then
            CRON_OK=1
            break
        fi
    done
    if [ "$CRON_OK" -eq 0 ]; then
        for _svc in cron crond; do
            if systemctl is-enabled --quiet "$_svc" 2>/dev/null; then
                CRON_OK=2
                break
            fi
        done
    fi
    if [ "$CRON_OK" -eq 0 ] && command -v pgrep >/dev/null 2>&1; then
        if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
            CRON_OK=1
        fi
    fi
    case "$CRON_OK" in
        1) log INFO "✓ cron 服务可用" ;;
        2) log WARN "⚠ cron 已安装并设为开机自启，但当前未在运行：15 分钟健康检查、订阅刷新与 IPv6 阻断补建依赖 cron 定时触发，当前不会自动运行；请运行 sudo systemctl start cron（或 crond）启动它。" ;;
        *) log WARN "⚠ 未检测到可用的 cron 服务：15 分钟健康检查、订阅刷新与 IPv6 阻断补建都靠 cron 定时触发，缺 cron 时这些维护任务不会自动运行（网关代理本身不受影响）。请安装并启动 cron，如：$(manual_install_cmd cron) && sudo systemctl enable --now cron" ;;
    esac

    # apt 系有待安装依赖、但系统连 apt-get 都没有时无法自动安装，直接
    # 报错并给完整手动命令（不在确认页展示无法执行的计划）。
    if [ "$_apt_like" -eq 1 ] && [ "${#MISSING_PKGS[@]}" -gt 0 ] && ! command -v apt-get >/dev/null 2>&1; then
        log ERROR "✗ 缺少必需命令/依赖（${MISSING_PKGS[*]}），但系统未找到 apt-get，无法自动安装；请手动安装：sudo apt-get install -y ${MISSING_PKGS[*]}"
        failures=$((failures + 1))
    fi

    if [ "$failures" -ne 0 ]; then
        log ERROR "错误：系统预检未通过（${failures} 项），安装中止。请按上方指引修复后重跑安装。"
        exit 1
    fi
    log INFO "✓ 系统预检通过"
}

# 确认后自动安装缺失的系统依赖（apt 系，见 preflight_checks 收集的
# MISSING_PKGS）：确认页已展示安装计划，用户确认后才执行；此时尚未
# 修改任何项目文件，失败时直接 exit 1（无需回滚，EXIT trap 会报告
# "安装未开始修改系统"）。安装后逐个复核命令是否可用，仍缺失时打印
# 完整手动命令并中止；iptables 曾缺失时重跑 TPROXY 探测（预检时
# iptables 缺失会跳过探测，不能默认内核支持）。
install_missing_deps() {
    local _cmd _i _still_pkgs=()
    [ "${#MISSING_PKGS[@]}" -eq 0 ] && return 0
    stage "依赖" "正在自动安装缺失的系统依赖：${MISSING_PKGS[*]}..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PKGS[@]}"; then
        log ERROR "✗ 自动安装系统依赖失败，请手动执行以下命令后重跑安装："
        log ERROR "  sudo apt-get install -y ${MISSING_PKGS[*]}"
        log ERROR "  （若提示找不到包，请先运行 sudo apt-get update 刷新软件源）"
        exit 1
    fi
    for _i in "${!MISSING_CMDS[@]}"; do
        _cmd="${MISSING_CMDS[$_i]}"
        if ! command -v "$_cmd" >/dev/null 2>&1; then
            _still_pkgs+=("${MISSING_PKGS[$_i]}")
        fi
    done
    if [ "${#_still_pkgs[@]}" -gt 0 ]; then
        log ERROR "✗ 自动安装后仍缺少依赖（${_still_pkgs[*]}），请手动安装后重跑安装："
        log ERROR "  sudo apt-get install -y ${_still_pkgs[*]}"
        exit 1
    fi
    if [ "$IPTABLES_WAS_MISSING" -eq 1 ]; then
        if tproxy_probe; then
            log INFO "✓ 内核支持 TPROXY（依赖安装后复测）"
        else
            log ERROR "✗ iptables 已安装，但内核不支持 TPROXY（无法创建 TPROXY 规则）。请确认内核已启用 TPROXY 支持（xt_TPROXY 模块或编入内核），或换用支持的系统/内核。"
            exit 1
        fi
    fi
    log INFO "✓ 系统依赖已自动安装：${MISSING_PKGS[*]}"
}

echo -e "${BLUE}====================================================${NC}"
echo -e "${GREEN} 🚀 Universal Mihomo TPROXY 旁路由一键安装脚本${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. 检查权限
if [ "$(id -u)" -ne 0 ]; then
    log ERROR "错误：必须使用 root 权限运行此脚本！"
    exit 1
fi

# 1a. 系统兼容性预检（P1-6）：安装前全部跑完，任一必需项失败即中止，
# 此时尚未修改系统，无需回滚。
preflight_checks

# 1b. 全局并发锁：安装 / 卸载 / 切换订阅 / 恢复 / 自动维护共用同一把
# 锁，同一时刻只允许一个任务修改系统；拿不到锁说明已有任务在跑，直接
# 退出（锁随进程退出自动释放，不会留下需要手动删除的 stale 锁）。
# 注意：tproxy.sh 故意不拿这把锁 —— 它由 systemd ExecStartPost 调用，
# 安装持有锁时重启服务会触发它，拿锁会自锁导致服务启动失败。
LOCK_FILE="/var/lock/mihomo-gateway.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log ERROR "错误：另一个安装/卸载/切换订阅/恢复/维护任务正在运行（锁文件 $LOCK_FILE），请等待它完成后再试。"
    exit 1
fi

# 3. 获取交互参数
# 注意：本脚本开了 set -e，交互式 read 在输入流 EOF 时返回非零会直接杀掉
# 进程，所以可空的输入一律加 || true 走默认值；必填输入则显式报错退出，
# 避免 EOF 时陷入死循环。
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

# 默认路由网卡（自动探测结果，可手动覆盖，见下文入口网卡提问）。
DEFAULT_IFACE=$(ip route show default 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1)

# Docker 网络检测：只在确认页提示，不自动排除 —— TPROXY 规则本身只
# 作用于指定的入口网卡与网段，Docker 网段（docker0 等）不在受管范围
# 内，不会被接管；提示只是让用户确认这一点。
DOCKER_NOTE=""
if ip link show dev docker0 >/dev/null 2>&1; then
    DOCKER_SUBNET=$(ip -o route show dev docker0 scope link 2>/dev/null | grep -oP '^\S+/\d+' | head -1)
    DOCKER_NOTE="docker0${DOCKER_SUBNET:+（${DOCKER_SUBNET}）}"
fi

# 入口网卡：默认使用自动探测的默认路由网卡，回车即用；多网卡用户可
# 手动指定。网卡不存在时当场重问，不拖到建规则时才失败。
# 防 WAN 误认：所选网卡若有公网 IP，它可能是 WAN 口而非 LAN 口，
# 必须由用户显式确认它是 LAN 口才继续（否则回到手动指定）。
LAN_IFACE=""
while [ -z "$LAN_IFACE" ]; do
    if [ -n "$DEFAULT_IFACE" ]; then
        read -r -p "请输入入口网卡 [自动检测: ${DEFAULT_IFACE}，回车使用]: " INPUT_IFACE || true
        LAN_IFACE=${INPUT_IFACE:-$DEFAULT_IFACE}
    else
        # 探测失败就不要假装给个默认值，强制手动输入
        if ! read -r -p "未能自动检测默认路由网卡，请手动输入入口网卡 (例如 eth0): " LAN_IFACE; then
            log ERROR "错误：无法读取输入（输入流已结束），安装中止。"
            exit 1
        fi
    fi
    if ! ip link show dev "$LAN_IFACE" >/dev/null 2>&1; then
        log ERROR "错误：网卡 $LAN_IFACE 不存在，请重新输入。"
        LAN_IFACE=""
        continue
    fi
    # 所选网卡的 IPv4（公网检查与面板 LAN 绑定共用；取不到时不做公网判
    # 断，面板局域网选项也不可选——见面板提问）。
    LAN_IFACE_IP=$(ip -o -4 addr show dev "$LAN_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
    # 防 WAN 误认：所选网卡若有公网 IP，它可能是 WAN 口而非 LAN 口，
    # 必须由用户显式确认它是 LAN 口才继续（否则回到手动指定）。检查对
    # 所选网卡做（第二轮第 2 项：旧检查只查默认路由网卡，手动指定网
    # 卡不查）；警告须明确提 9090——面板监听非本机地址时也会暴露在
    # 该公网接口上，不只是 TPROXY 接管问题。
    if [ -n "$LAN_IFACE_IP" ] && ! is_private_ipv4 "$LAN_IFACE_IP"; then
        log WARN "警告：所选入口网卡 ${LAN_IFACE} 的 IP ${LAN_IFACE_IP} 是公网地址，它可能是 WAN 口而非 LAN 口；透明代理接管 WAN 口入站流量会把公网流量也拉进代理，且面板 9090 若监听非本机地址也会暴露在该公网接口上。"
        read -r -p "确认 ${LAN_IFACE} 是 LAN 口（透明代理将接管它的入站流量）？(y/N): " WAN_CONFIRM || true
        if [[ "$WAN_CONFIRM" != "y" && "$WAN_CONFIRM" != "Y" ]]; then
            echo "请重新指定入口网卡。"
            LAN_IFACE=""
            continue
        fi
    fi
done

# 通过所选入口网卡读它自己的直连网段（scope link），这个输出本身就
# 是 CIDR 格式，比试图从 "default via ..." 这行硬解析要可靠得多。
DEFAULT_SUBNET=""
if [ -n "$LAN_IFACE" ]; then
    DEFAULT_SUBNET=$(ip -o route show dev "$LAN_IFACE" scope link 2>/dev/null | grep -oP '^\S+/\d+' | head -1)
fi

# 局域网网段：支持多网段（逗号分隔）；单网段时行为与 v1.1.0 一致。
LAN_SUBNET_INPUT=""
if [ -n "$DEFAULT_SUBNET" ]; then
    read -r -p "请输入局域网 CIDR 网段（多个网段用逗号分隔）[自动检测: ${DEFAULT_SUBNET}，回车使用]: " LAN_SUBNET_INPUT || true
    LAN_SUBNET_INPUT=${LAN_SUBNET_INPUT:-$DEFAULT_SUBNET}
else
    # 探测失败就不要假装给个默认值，强制手动输入，避免用户以为是探测结果
    while [ -z "$LAN_SUBNET_INPUT" ]; do
        if ! read -r -p "未能自动检测局域网网段，请手动输入 CIDR（多个网段用逗号分隔，例如 192.168.1.0/24）: " LAN_SUBNET_INPUT; then
            log ERROR "错误：无法读取输入（输入流已结束），安装中止。"
            exit 1
        fi
    done
fi

# 解析网段列表：按逗号切分、去首尾空白、去重；主网段 LAN_SUBNET 为
# 第一项（供配置模板与迁移式合并使用）。
LAN_SUBNET_LIST=()
_old_ifs="$IFS"
IFS=','
read -ra _subnet_parts <<< "$LAN_SUBNET_INPUT"
IFS="$_old_ifs"
for _s in "${_subnet_parts[@]}"; do
    _s="${_s#"${_s%%[![:space:]]*}"}"
    _s="${_s%"${_s##*[![:space:]]}"}"
    [ -z "$_s" ] && continue
    _dup=0
    for _u in "${LAN_SUBNET_LIST[@]}"; do
        if [ "$_s" = "$_u" ]; then _dup=1; break; fi
    done
    [ "$_dup" -eq 0 ] && LAN_SUBNET_LIST+=("$_s")
done
if [ "${#LAN_SUBNET_LIST[@]}" -eq 0 ]; then
    log ERROR "错误：未指定任何有效局域网网段，安装中止。"
    exit 1
fi
LAN_SUBNET="${LAN_SUBNET_LIST[0]}"
LAN_SUBNETS_JOINED="$(IFS=,; echo "${LAN_SUBNET_LIST[*]}")"

# 区分首次安装与重装：已有 config.yaml 时默认保留用户配置（订阅、
# 自定义规则、DNS），只做迁移式合并；覆盖须用户在确认页显式选择。
REINSTALL=0
[ -f /etc/mihomo/config.yaml ] && REINSTALL=1
SUB_KEEP=0
OVERWRITE_CONFIG=0

if [ "$REINSTALL" -eq 1 ]; then
    read -r -p "请输入机场订阅链接 (Airport 1) [回车保留现有订阅]: " SUB_URL_1 || true
else
    read -r -p "请输入机场订阅链接 (Airport 1): " SUB_URL_1 || true
fi
SUB_STATUS="已写入配置（订阅内容由 mihomo 运行时拉取，拉取失败不会导致安装失败）"
if [ -z "$SUB_URL_1" ]; then
    if [ "$REINSTALL" -eq 1 ]; then
        # 重装留空 = 保留现有订阅，不再用占位符覆盖掉旧订阅地址
        SUB_KEEP=1
        SUB_STATUS="保留现有订阅（本次未输入新链接）"
    else
        log WARN "警告: 未输入订阅链接，后续请手动在 /etc/mihomo/config.yaml 中添加！"
        SUB_URL_1="YOUR_SUBSCRIPTION_URL_1"
        SUB_STATUS="未配置（已跳过，不影响安装结果；后续可用 ${REPO_ROOT}/scripts/switch-sub.sh 设置）"
    fi
fi

# 输入校验：格式不对当场中止，不要拖到 mihomo -t 才发现（报错离源头太远）
for _c in "${LAN_SUBNET_LIST[@]}"; do
    validate_cidr_input "$_c" || exit 1
done
if [ "$SUB_KEEP" -eq 0 ] && [ "$SUB_URL_1" != "YOUR_SUBSCRIPTION_URL_1" ] && ! [[ "$SUB_URL_1" =~ ^https?://[^/[:space:]]+ ]]; then
    log ERROR "错误：订阅链接格式不对（应以 http:// 或 https:// 开头），安装中止。"
    exit 1
fi
# 与 switch-sub.sh 同一条规矩：链接将写入双引号 YAML 字符串，引号、
# 反斜杠和控制字符会破坏结构，当场拒绝，不要拖到渲染或预检阶段。
if [ "$SUB_KEEP" -eq 0 ] && [[ "$SUB_URL_1" == *'"'* || "$SUB_URL_1" == *\\* || "$SUB_URL_1" == *$'\n'* || "$SUB_URL_1" == *$'\r'* || "$SUB_URL_1" == *$'\t'* ]]; then
    log ERROR "错误：订阅链接包含引号、反斜杠或控制字符，安装中止。"
    exit 1
fi

# P1-8 IPv6 检测：系统是否启用 IPv6、LAN 口是否分配了全局 IPv6 地址。
# mihomo 配置 ipv6:false，不代理 IPv6；LAN 口有公网 IPv6 时客户端可
# 经 IPv6 绕过代理，必须在确认页明确警告。检测只读不改，绝不关闭
# 系统 IPv6、不动默认路由。
IPV6_ENABLED=0
IPV6_LAN=0
IPV6_LAN_PREFIXES=""
if ip -6 addr show 2>/dev/null | grep -q .; then
    IPV6_ENABLED=1
    IPV6_LAN_PREFIXES=$(ip -6 -o addr show dev "$LAN_IFACE" scope global 2>/dev/null | awk '{print $4}' | tr '\n' ',' | sed 's/,$//')
    [ -n "$IPV6_LAN_PREFIXES" ] && IPV6_LAN=1
fi
IPV6_BLOCK=0
# 重装时沿用旧 tproxy.env 里的阻断选择（有旧选择则默认保持，无则默认不启用）。
if [ -f /etc/mihomo/tproxy.env ] && grep -qE '^IPV6_BLOCK="1"' /etc/mihomo/tproxy.env; then
    IPV6_BLOCK=1
fi

echo -e "\n${YELLOW}=== 配置确认 ===${NC}"
stage "确认" "显示安装计划，等待用户确认..."
echo -e "局域网网段: ${GREEN}${LAN_SUBNETS_JOINED}${NC}"
echo -e "本机 IP:     ${GREEN}${LOCAL_IP}${NC}"
if [ "$LAN_IFACE" = "$DEFAULT_IFACE" ]; then
    echo -e "入口网卡:   ${GREEN}${LAN_IFACE}（自动检测）${NC}"
else
    echo -e "入口网卡:   ${GREEN}${LAN_IFACE}（手动指定）${NC}"
fi
if [ -n "$DOCKER_NOTE" ]; then
    echo -e "Docker 网络: ${GREEN}检测到 ${DOCKER_NOTE}；TPROXY 规则仅作用于上方入口网卡与网段，不会接管 Docker 网段。${NC}"
fi
if [ "$IPV6_LAN" -eq 1 ]; then
    echo -e "IPv6:       ${YELLOW}LAN 口已分配 IPv6 地址（${IPV6_LAN_PREFIXES}），IPv6 流量不受代理保护、可绕过代理策略！${NC}"
elif [ "$IPV6_ENABLED" -eq 1 ]; then
    echo -e "IPv6:       ${GREEN}系统已启用 IPv6，但 LAN 口未分配 IPv6 地址，暂无绕过风险。${NC}"
else
    echo -e "IPv6:       ${GREEN}系统未启用 IPv6，无需处理。${NC}"
fi
# 订阅链接打码显示：只露协议与主机，路径中的令牌部分隐藏，
# 避免完整链接出现在终端回滚、截图或转发出去的日志里。
mask_url() {
    echo "$1" | sed -E 's#^(https?://[^/]+/).*#\1****#'
}

if [ "$SUB_KEEP" -eq 1 ]; then
    echo -e "订阅链接:   ${GREEN}（保留现有订阅）${NC}"
else
    echo -e "订阅链接:   ${GREEN}$(mask_url "$SUB_URL_1")${NC}"
fi
# P1-8：LAN 有 IPv6 时给出阻断选项（默认不启用；仅丢弃经本机转发的
# 受管前缀流量，旁路由模式下客户端 IPv6 通常走主路由，彻底防绕过
# 需在主路由上处理）。门控（第二轮第 5 项）：缺 ip6tables 时禁止启用
# 该功能——旧行为是让用户选完、装完，服务启动时才失败（晚失败）；
# 现在提问时直接说明原因、不提供启用选项；重装沿用的旧选择同样失效
# （旧服务在缺 ip6tables 时本就起不来，沿用只会复现启动失败）。
if [ "$IPV6_LAN" -eq 1 ]; then
    if [ "$IP6TABLES_OK" -eq 0 ]; then
        IPV6_BLOCK=0
        echo -e "IPv6 阻断:   ${YELLOW}不可用：系统缺少 ip6tables，无法启用阻断；请先安装 iptables 包（$(manual_install_cmd iptables)），再重跑安装。${NC}"
    else
        echo -e "${YELLOW}IPv6 阻断（可选）：启用后将丢弃经本机转发的、来自上述 IPv6 前缀的流量；不关闭系统 IPv6、不动默认路由。${NC}"
        if [ "$IPV6_BLOCK" -eq 1 ]; then
            read -r -p "是否启用 IPv6 阻断？(Y/n，当前已启用，回车保持): " IPV6_BLOCK_ASK || true
            if [[ "$IPV6_BLOCK_ASK" == "n" || "$IPV6_BLOCK_ASK" == "N" ]]; then
                IPV6_BLOCK=0
            fi
        else
            read -r -p "是否启用 IPv6 阻断？(y/N，默认不启用): " IPV6_BLOCK_ASK || true
            if [[ "$IPV6_BLOCK_ASK" == "y" || "$IPV6_BLOCK_ASK" == "Y" ]]; then
                IPV6_BLOCK=1
            fi
        fi
        if [ "$IPV6_BLOCK" -eq 1 ]; then
            echo -e "IPv6 阻断:   ${GREEN}已启用${NC}"
        else
            echo -e "IPv6 阻断:   ${GREEN}不启用（IPv6 流量仍可绕过代理）${NC}"
        fi
    fi
fi
# P1-9 面板监听范围（第二轮第 2 项，定夺 1）：三选项，默认仅本机
# （127.0.0.1:9090，回车即选）；1=局域网访问，绑定所选 LAN 网卡的真
# 实 IP（LAN_IFACE_IP），不再绑 0.0.0.0；3=全部接口（0.0.0.0:9090）
# 仍可显式选择，但会同时监听 WAN/公网接口，确认页与成功页都有针对
# 这一选择的专属警告。重装时默认沿用现有选择：旧 127.0.0.1 沿用为仅
# 本机，旧 0.0.0.0 或 LAN IP 沿用为局域网访问（同一意图、更安全的绑
# 定）。LAN IP 取不到时选项 1 不可选（回车与选 1 都按仅本机处理，并
# 明确告知）；注意不用 LOCAL_IP 兜底——LOCAL_IP 是默认路由的源地址，
# 手动选了非默认网卡时它是另一张网卡的地址，绑它会把面板放到错误的网段上。
PANEL_DEFAULT="local"
if [ -f /etc/mihomo/config.yaml ]; then
    _old_listen=$(grep -E '^external-controller:' /etc/mihomo/config.yaml | head -1 | sed -E 's/^external-controller:[[:space:]]*([^:]+):.*/\1/' || true)
    if [ -n "$_old_listen" ] && [ "$_old_listen" != "127.0.0.1" ]; then
        PANEL_DEFAULT="lan"
    fi
fi
PANEL_DEFAULT_NUM=2
if [ "$PANEL_DEFAULT" = "lan" ] && [ -n "${LAN_IFACE_IP:-}" ]; then
    PANEL_DEFAULT_NUM=1
fi
if [ -n "${LAN_IFACE_IP:-}" ]; then
    _lan_opt="1=局域网访问(${LAN_IFACE_IP}:9090)"
else
    _lan_opt="1=局域网访问（未检测到 LAN 口 IP，不可选）"
fi
if [ "$REINSTALL" -eq 1 ]; then
    if [ "$PANEL_DEFAULT_NUM" -eq 1 ]; then
        _panel_keep="当前局域网访问，回车保持"
    elif [ "$PANEL_DEFAULT" = "lan" ]; then
        _panel_keep="当前局域网访问，但未检测到 LAN 口 IP，默认仅本机"
    else
        _panel_keep="当前仅本机，回车保持"
    fi
    read -r -p "面板监听范围 [${_lan_opt} / 2=仅本机(127.0.0.1:9090) / 3=全部接口(0.0.0.0:9090)，${_panel_keep}]: " PANEL_ASK || true
else
    read -r -p "面板监听范围 [${_lan_opt} / 2=仅本机(127.0.0.1:9090，默认) / 3=全部接口(0.0.0.0:9090)]: " PANEL_ASK || true
fi
case "$PANEL_ASK" in
    1)
        if [ -n "${LAN_IFACE_IP:-}" ]; then
            PANEL_LISTEN="$LAN_IFACE_IP"
        else
            log WARN "未检测到 LAN 口 IP，局域网访问不可选，已改用仅本机（127.0.0.1:9090）。"
            PANEL_LISTEN="127.0.0.1"
        fi
        ;;
    2) PANEL_LISTEN="127.0.0.1" ;;
    3) PANEL_LISTEN="0.0.0.0" ;;
    *)
        if [ "$PANEL_DEFAULT_NUM" -eq 1 ]; then
            PANEL_LISTEN="$LAN_IFACE_IP"
        else
            PANEL_LISTEN="127.0.0.1"
        fi
        ;;
esac
if [ "$PANEL_LISTEN" = "127.0.0.1" ]; then
    echo -e "面板监听:   ${GREEN}仅本机（127.0.0.1:9090）${NC}"
elif [ "$PANEL_LISTEN" = "0.0.0.0" ]; then
    echo -e "面板监听:   ${GREEN}全部接口（0.0.0.0:9090）${NC}"
    echo -e "${YELLOW}警告：你选择了全部接口（0.0.0.0:9090）——面板将同时监听 WAN/公网接口，任何能连通本机公网 IP 的人都可尝试访问面板（仅靠 32 位随机密钥保护）；防火墙会限制为仅受管 LAN 网段可访问，但仍建议改选局域网访问或仅本机。${NC}"
else
    echo -e "面板监听:   ${GREEN}局域网访问（${PANEL_LISTEN}:9090）${NC}"
fi
# 所选网卡本身就是公网 IP、且面板又监听非本机地址时，面板确定会暴露
# 在公网接口上（防火墙来源限制仍会生效，但须让用户明确知道这一点）。
if [ "$PANEL_LISTEN" != "127.0.0.1" ] && [ -n "${LAN_IFACE_IP:-}" ] && ! is_private_ipv4 "$LAN_IFACE_IP"; then
    echo -e "${YELLOW}警告：所选 LAN 网卡 ${LAN_IFACE} 的 IP ${LAN_IFACE_IP} 是公网地址，面板（${PANEL_LISTEN}:9090）将暴露在公网接口上；防火墙会限制为仅受管 LAN 网段可访问，但请确认这是你想要的。${NC}"
fi
# 依赖安装计划（第二轮第 5 项）：apt 系缺失的依赖将在确认后自动安装，
# 这里先展示计划；不缺则不显示本节。回答 n 取消安装则不执行安装。
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    echo -e "依赖安装:   ${YELLOW}将自动安装缺失的系统依赖：${MISSING_PKGS[*]}（apt-get install -y）${NC}"
fi
echo -e "${YELLOW}提醒：如需远程访问面板，请走可信网络或安全隧道（如 SSH 端口转发），不要直接向公网开放 9090 端口。${NC}"
if [ "$REINSTALL" -eq 1 ]; then
    echo -e "${YELLOW}检测到已有配置：默认保留现有 config.yaml（订阅、自定义规则、DNS 不变），仅按本次输入更新入口网段与订阅链接（如有新输入）。${NC}"
    read -r -p "是否改用模板重新生成配置并覆盖现有配置？(y/N，默认保留): " OVERWRITE_ASK || true
    if [[ "$OVERWRITE_ASK" == "y" || "$OVERWRITE_ASK" == "Y" ]]; then
        OVERWRITE_CONFIG=1
        echo -e "${YELLOW}已选择覆盖：现有 config.yaml 将先备份再用模板重新生成。${NC}"
    fi
fi
read -r -p "确认继续安装? (y/n): " CONFIRM || true
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "已取消安装。"
    exit 0
fi

# 确认页已展示依赖安装计划（见上），用户确认后才自动安装缺失依赖
# （apt 系；失败时打印完整手动命令并中止，此时尚未修改项目文件）。
install_missing_deps

# 确认后、第一次修改系统前：备份安装前状态（事务起点）。此后任一
# 关键阶段失败，EXIT trap 都会执行回滚并报告回滚成败（最后的功能
# 验证除外：verify 未通过时事务已提交，服务保持运行、不回滚）。
txn_backup

# 多源下载辅助函数（防单源报错杀进程）
LAST_FETCH_SOURCE=""
smart_download() {
    local output="$1"
    shift
    for url in "$@"; do
        log INFO "尝试下载: ${url}"
        # -T 连接/读超时 15 秒，--tries=2 最多重试一次：GitHub 直连在部分网络
        # 环境下不是"连接失败"而是"连得上但卡住不传"，不加超时的话 wget 会
        # 无限等待，永远轮不到后面的国内镜像源，表现为卡死不动。
        if wget -q --show-progress --progress=bar:force:noscroll -T 15 --tries=2 -O "$output" "$url"; then
            LAST_FETCH_SOURCE="$url"
            return 0
        fi
        log WARN "当前下载源连接失败或超时，自动尝试下一个节点..."
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
            log INFO "✓ ${name} 来自专用资产仓最新批次 ${tag}"
            rm -f "$sums"
            mv "$tmp" "$output"
            return 0
        fi
        rm -f "$sums"
        log WARN "专用资产仓最新批次 (${tag}) 拉取或校验未通过，退回钉版批次..."
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
    log WARN "${label}：官方下载源全部失败，尝试从专用资产仓库 Release 拉取兜底资产 (${bundle_file})..."
    if fetch_from_project "$bundle_file" "$output"; then
        FETCH_SUMMARY+=("${label}: 专用资产仓库兜底 ($(du -h "$output" | cut -f1)，sha256 校验通过)")
        log INFO "✓ ${label} 已使用专用资产仓库兜底资产"
        return 0
    fi
    log ERROR "错误：${label} 获取失败——官方下载源全部不可用，且专用资产仓库兜底资产 ${bundle_file} 拉取失败或 sha256 校验不通过。"
    return 1
}

# 4. 下载并安装内核与 UI
# 拉取策略：先从官方版本拉，官方源（含镜像链）全失败则由脚本自动从
# 本专用资产仓库 Release 按需拉取钉版资产兜底（见 PROJECT_ASSETS_BASE），
# 先保证服务能装起来；版本更新交给跑起来之后的 auto-maintain.sh
# （届时本机已有代理，拉官方源不再受网络环境制约）。
stage "下载" "1/6 正在获取 Mihomo 内核..."
# 不能只看文件存不存在——Ctrl+C 中断下载会留下不完整的半截文件，
# 用 gzip -t 校验完整性，损坏的缓存直接扔掉重新下载，而不是留着
# 让后面的 gzip -d 报错退出。
KERNEL_READY=0
if [ -f "/tmp/mihomo.gz" ] && gzip -t /tmp/mihomo.gz 2>/dev/null; then
    # gzip 完整不等于就是可用的内核：旧版本包、错架构包一样能通过。
    # 真解压出来跑一下，能执行且报得出版本号才准复用，否则丢弃重下。
    if gzip -dc /tmp/mihomo.gz > /tmp/.mihomo-probe 2>/dev/null \
        && chmod +x /tmp/.mihomo-probe \
        && /tmp/.mihomo-probe -v 2>&1 | grep -q "Mihomo"; then
        log INFO "✓ 检测到 /tmp/mihomo.gz 本地缓存（完整且可运行），跳过内核下载"
        FETCH_SUMMARY+=("内核: /tmp 本地缓存")
        KERNEL_READY=1
    else
        log WARN "检测到 /tmp/mihomo.gz 但不是可用的 mihomo 内核（旧包或错架构），丢弃并重新下载..."
        rm -f /tmp/mihomo.gz
    fi
    rm -f /tmp/.mihomo-probe
fi
if [ "$KERNEL_READY" -eq 0 ]; then
    [ -f "/tmp/mihomo.gz" ] && log WARN "检测到 /tmp/mihomo.gz 但文件不完整（可能是上次下载被中断），重新下载..."
    rm -f /tmp/mihomo.gz
    LATEST_VERSION=$(curl -m 10 --retry 2 -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name"' | grep -oP 'v[\d.]+' | head -1 || true)
    # 版本探测全失败时的兜底版本号与专用资产仓兜底资产保持一致
    [ -z "$LATEST_VERSION" ] && LATEST_VERSION="v1.19.32"

    KERNEL_FILE="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    if ! fetch_or_project "内核" "/tmp/mihomo.gz" "mihomo-linux-${BIN_ARCH}.gz" \
      "https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${KERNEL_FILE}" \
      "https://githubproxy.cc/https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${KERNEL_FILE}"; then
        log ERROR "错误：内核获取失败（官方源与专用资产仓库兜底均不可用），安装中止。"
        exit 1
    fi

    if ! gzip -t /tmp/mihomo.gz 2>/dev/null; then
        log ERROR "错误：内核文件完整性校验失败，安装中止。"
        rm -f /tmp/mihomo.gz
        exit 1
    fi
fi

gzip -d -f /tmp/mihomo.gz
chmod +x /tmp/mihomo
mv /tmp/mihomo /usr/local/bin/mihomo

stage "下载" "2/6 正在获取 metacubexd 控制面板..."
mkdir -p /etc/mihomo/ui /etc/mihomo/providers
if [ -f "/tmp/ui.tgz" ] && tar -tzf /tmp/ui.tgz >/dev/null 2>&1; then
    log INFO "✓ 检测到 /tmp/ui.tgz 本地缓存（完整性校验通过），跳过 UI 下载"
    FETCH_SUMMARY+=("面板 UI: /tmp 本地缓存")
else
    [ -f "/tmp/ui.tgz" ] && log WARN "检测到 /tmp/ui.tgz 但文件不完整，重新下载..."
    rm -f /tmp/ui.tgz
    if ! fetch_or_project "面板 UI" "/tmp/ui.tgz" "ui.tgz" \
      "https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz" \
      "https://githubproxy.cc/https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"; then
        log ERROR "错误：面板 UI 获取失败（官方源与专用资产仓库兜底均不可用），安装中止。"
        exit 1
    fi

    if ! tar -tzf /tmp/ui.tgz >/dev/null 2>&1; then
        log ERROR "错误：面板 UI 文件完整性校验失败，安装中止。"
        rm -f /tmp/ui.tgz
        exit 1
    fi
fi

# UI 先解压到临时目录并检查路径与入口文件，再切换目录，避免旧版本残留文件。
# 同时拒绝绝对路径或包含 .. 的成员名，降低不可信压缩包写出目标目录的风险。
UI_STAGE="/etc/mihomo/.ui-install.$$"
UI_OLD="/etc/mihomo/.ui-old.$$"
rm -rf "$UI_STAGE" "$UI_OLD"
mkdir -p "$UI_STAGE"
if ! tar -tzf /tmp/ui.tgz > "$UI_STAGE/archive.list"; then
    log ERROR "错误：无法读取 UI 压缩包目录，安装中止。"
    rm -rf "$UI_STAGE" /tmp/ui.tgz
    exit 1
fi
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$UI_STAGE/archive.list"; then
    log ERROR "错误：UI 压缩包包含不安全路径，安装中止。"
    rm -rf "$UI_STAGE" /tmp/ui.tgz
    exit 1
fi
# --no-same-owner：不沿用包内构建用户的 uid。
if ! tar --no-same-owner -xzf /tmp/ui.tgz -C "$UI_STAGE"; then
    log ERROR "错误：UI 解压失败，安装中止。"
    rm -rf "$UI_STAGE" /tmp/ui.tgz
    exit 1
fi
rm -f "$UI_STAGE/archive.list"
if ! find "$UI_STAGE" -type f -name index.html -print -quit | grep -q .; then
    log ERROR "错误：UI 压缩包中未找到 index.html，安装中止。"
    rm -rf "$UI_STAGE" /tmp/ui.tgz
    exit 1
fi
if [ -d /etc/mihomo/ui ]; then mv /etc/mihomo/ui "$UI_OLD"; fi
if mv "$UI_STAGE" /etc/mihomo/ui; then
    # 保留旧目录直到整次安装成功；EXIT trap 会在后续失败时恢复它。
    :
else
    [ -d "$UI_OLD" ] && mv "$UI_OLD" /etc/mihomo/ui
    rm -rf "$UI_STAGE" /tmp/ui.tgz
    log ERROR "错误：切换 UI 目录失败，已尝试恢复旧目录。"
    exit 1
fi
rm -f /tmp/ui.tgz

# 5. 备份旧配置、生成随机密钥
if [ -f /etc/mihomo/config.yaml ]; then
    BACKUP_NAME="/etc/mihomo/config.yaml.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/mihomo/config.yaml "$BACKUP_NAME"
    chmod 600 "$BACKUP_NAME"
    TXN_CONFIG_BACKUP="$BACKUP_NAME"
    log INFO "✓ 旧配置已备份到 ${BACKUP_NAME}"
fi

# 重装时优先复用旧配置里的密钥：免得每次重装面板密码都变、还要到处重记
API_SECRET=""
if [ -f /etc/mihomo/config.yaml ]; then
    API_SECRET=$(extract_secret /etc/mihomo/config.yaml)
    [ "$API_SECRET" = "CHANGE_ME_SECRET" ] && API_SECRET=""
fi
if [ -n "$API_SECRET" ]; then
    log INFO "✓ 复用已有配置中的面板密钥（重装不变更）"
elif command -v openssl >/dev/null 2>&1; then
    API_SECRET=$(openssl rand -hex 16)
else
    API_SECRET=$(head -c 32 /dev/urandom | md5sum | cut -d' ' -f1)
fi

# 6. 生成配置文件与运行环境
stage "配置" "3/6 生成配置文件与运行环境..."
# 替换值必须先转义：sed 的替换串里 & 表示“被匹配的原文”，订阅链接
# 只要带 &（多参数链接极常见）就会被悄悄改坏；| 是分隔符、\ 是转义符。
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# 重装保留模式的迁移式合并：以现有 config.yaml 为底（临时文件编辑，
# 最后原子 mv），只更新安装必须控制的三处 —— 订阅链接（本次新输入才
# 动）、入口网段规则（能精确找到旧规则行才动）、缺失/占位的 secret；
# 自定义规则、DNS、代理组等其余内容一律不动。
# 用法：migrate_config <临时配置副本> <新订阅链接或空>
migrate_config() {
    local tmp_cfg="$1" new_url="$2" old_subnet=""
    # 0) 模板新增键合并（P1-5）：模板里有、旧配置里缺的顶层键，把模板
    # 中该键的完整块追加进来（块内占位符按本次输入替换：网段用主网段、
    # 密钥用本次密钥、订阅用本次新链接，未给新链接时保留占位符，与首
    # 次安装跳过订阅的行为一致）；旧配置已有的键一律不动，旧配置多出
    # 的自定义键同样保留。只认顶层键（行首无缩进的 key:）。
    local _tpl="$REPO_ROOT/config/config.example.yaml" _key
    for _key in $(grep -oE '^[a-zA-Z0-9_-]+:' "$_tpl" | sed 's/:$//' | awk '!seen[$0]++'); do
        if ! grep -qE "^${_key}:" "$tmp_cfg"; then
            # 取模板中该键的块：从 key: 行起到下一个顶层键（或文件尾）之前。
            awk -v key="$_key" '
                BEGIN { in_block = 0 }
                /^[a-zA-Z0-9_-]+:/ {
                    if ($0 ~ ("^" key ":")) { in_block = 1; print; next }
                    else if (in_block) { exit }
                }
                in_block { print }
            ' "$_tpl" > "${tmp_cfg}.keyblock"
            sed -i -e "s|192.168.0.0/16|$(sed_escape "$LAN_SUBNET")|g" \
                   -e "s|CHANGE_ME_SECRET|$(sed_escape "$API_SECRET")|g" "${tmp_cfg}.keyblock"
            if [ -n "$new_url" ]; then
                sed -i -e "s|YOUR_SUBSCRIPTION_URL_1|$(sed_escape "$new_url")|g" "${tmp_cfg}.keyblock"
            fi
            # 追加前保证文件以换行结尾，避免块粘到上一行末尾。
            if [ -n "$(tail -c 1 "$tmp_cfg" 2>/dev/null)" ]; then
                printf '\n' >> "$tmp_cfg"
            fi
            cat "${tmp_cfg}.keyblock" >> "$tmp_cfg"
            rm -f "${tmp_cfg}.keyblock"
            log INFO "✓ 已从模板合并新增配置项：${_key}"
        fi
    done
    # 1) 订阅：本次给了新链接才替换 airport1 的 url 行（与 switch-sub.sh
    # 同一条精确匹配规矩：只动 airport1 块下 4 空格缩进的 url 行，
    # health-check 里更深缩进的 url 不碰；找不到就警告并保持原样，
    # 不让一次订阅更新失败拖垮整个安装）。
    if [ -n "$new_url" ]; then
        if ! NEW_URL="$new_url" awk '
            BEGIN { new = ENVIRON["NEW_URL"] }
            /^  airport1:[[:space:]]*$/ { in_block = 1 }
            in_block && /^    url:/ && !done {
                print "    url: \"" new "\""
                done = 1
                next
            }
            /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ && !/^  airport1:/ { in_block = 0 }
            { print }
            END { if (!done) exit 1 }
        ' "$tmp_cfg" > "${tmp_cfg}.new"; then
            log WARN "警告：现有配置中未找到 proxy-providers.airport1.url，订阅链接未更新；请稍后用 switch-sub.sh 手动更换。"
            rm -f "${tmp_cfg}.new"
        else
            mv "${tmp_cfg}.new" "$tmp_cfg"
            log INFO "✓ 已更新订阅链接（airport1）"
        fi
    fi
    # 2) 入口网段规则：旧网段取自上次安装写入的 tproxy.env，只有能
    # 精确找到旧规则行时才替换；找不到（用户已自定义规则）就保持原样。
    if [ -f /etc/mihomo/tproxy.env ]; then
        # 注意：不能用 s/^LAN_SUBNET="?(.*)"?$/\1/ —— (.*) 贪婪匹配会把
        # 尾引号也吃进去，导致 old_subnet 带引号、后续 grep 永远找不到。
        old_subnet=$(grep -E '^LAN_SUBNET=' /etc/mihomo/tproxy.env | head -1 | sed -E 's/^LAN_SUBNET=//; s/^"//; s/"$//' || true)
    fi
    if [ -n "$old_subnet" ] && [ "$old_subnet" != "$LAN_SUBNET" ]; then
        if grep -qF -- "- IP-CIDR,${LAN_SUBNET},DIRECT,no-resolve" "$tmp_cfg"; then
            # 新网段规则已存在（模板合并刚补的），无需处理也不警告。
            :
        elif grep -qF -- "- IP-CIDR,${old_subnet},DIRECT,no-resolve" "$tmp_cfg"; then
            sed -i -e "s|- IP-CIDR,$(sed_escape "$old_subnet"),DIRECT,no-resolve|- IP-CIDR,$(sed_escape "$LAN_SUBNET"),DIRECT,no-resolve|" "$tmp_cfg"
            log INFO "✓ 已更新入口网段规则：${old_subnet} -> ${LAN_SUBNET}"
        else
            log WARN "警告：现有配置中未找到旧网段规则行（${old_subnet}），规则保持原样；如需更新请手动编辑 config.yaml。"
        fi
    fi
    # 3) secret：缺失或仍为占位符时补上本次密钥；已有真实密钥则不动
    # （API_SECRET 在重装时已复用旧密钥，见上文）。
    if ! grep -qE '^secret:' "$tmp_cfg"; then
        printf 'secret: "%s"\n' "$API_SECRET" >> "$tmp_cfg"
        log INFO "✓ 已补写缺失的面板密钥"
    elif grep -qE "^secret:[[:space:]]*[\"']?CHANGE_ME_SECRET[\"']?[[:space:]]*$" "$tmp_cfg"; then
        sed -i -E "s|^secret:.*|secret: \"$(sed_escape "$API_SECRET")\"|" "$tmp_cfg"
        log INFO "✓ 已替换占位面板密钥"
    fi
    # 4) 面板监听（P1-9）：本次选择与旧配置不一致时，只改监听地址，
    # 端口与用户自定义保持不动；当前值不是 IPv4 时不碰（避免改坏
    # IPv6 等自定义写法）。
    local _cur_listen=""
    if grep -qE '^external-controller:' "$tmp_cfg"; then
        _cur_listen=$(grep -E '^external-controller:' "$tmp_cfg" | head -1 | sed -E 's/^external-controller:[[:space:]]*([^:]+):.*/\1/')
        if [[ "$_cur_listen" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$_cur_listen" != "$PANEL_LISTEN" ]; then
            sed -i -E "s|^(external-controller:[[:space:]]*)[^:]+:|\1${PANEL_LISTEN}:|" "$tmp_cfg"
            log INFO "✓ 已更新面板监听地址：${_cur_listen} -> ${PANEL_LISTEN}"
        fi
    fi
}

if [ "$REINSTALL" -eq 1 ] && [ "$OVERWRITE_CONFIG" -eq 0 ]; then
    # 重装默认保留：以现有配置为底做迁移式合并，不重渲染模板。
    log INFO "保留现有配置，仅做迁移式合并（网段/订阅/密钥）..."
    MIGRATE_TMP="$(mktemp)"
    cp /etc/mihomo/config.yaml "$MIGRATE_TMP"
    if [ "$SUB_KEEP" -eq 1 ]; then
        migrate_config "$MIGRATE_TMP" ""
    else
        migrate_config "$MIGRATE_TMP" "$SUB_URL_1"
    fi
    mv "$MIGRATE_TMP" /etc/mihomo/config.yaml
    chmod 600 /etc/mihomo/config.yaml
else
    # 首次安装，或用户在确认页显式选择覆盖：按模板重新渲染。
    # 覆盖模式下若本次未输入订阅链接，仍沿用旧配置里的订阅地址，
    # 避免渲染出空 url 导致订阅丢失。
    if [ "$SUB_KEEP" -eq 1 ]; then
        # 三种引号写法都认（与 extract_secret 同一条规则）：只取双引号
        # 写法时，单引号 url 会把整行原文当作订阅地址渲染进新配置。
        SUB_URL_1=$(grep -A2 '^  airport1:' /etc/mihomo/config.yaml | grep -E '^    url:' | head -1 | sed -E 's/^    url:[[:space:]]*"([^"]*)".*/\1/; s/^    url:[[:space:]]*'"'"'([^'"'"']*)'"'"'.*/\1/; s/^    url:[[:space:]]*([^"[:space:]]+).*/\1/' || true)
        if [ -z "$SUB_URL_1" ]; then
            SUB_URL_1="YOUR_SUBSCRIPTION_URL_1"
            SUB_STATUS="未配置（旧订阅地址无法读取，已留空占位；后续可用 ${REPO_ROOT}/scripts/switch-sub.sh 设置）"
        elif [ "$SUB_URL_1" = "YOUR_SUBSCRIPTION_URL_1" ]; then
            SUB_STATUS="未配置（旧配置中也没有订阅链接；后续可用 ${REPO_ROOT}/scripts/switch-sub.sh 设置）"
        else
            SUB_STATUS="已沿用旧配置中的订阅链接"
        fi
    fi
    sed -e "s|192.168.0.0/16|$(sed_escape "$LAN_SUBNET")|g" \
        -e "s|YOUR_SUBSCRIPTION_URL_1|$(sed_escape "$SUB_URL_1")|g" \
        -e "s|CHANGE_ME_SECRET|$(sed_escape "$API_SECRET")|g" \
        -e "s|external-controller: 127.0.0.1:9090|external-controller: ${PANEL_LISTEN}:9090|" \
        "$REPO_ROOT/config/config.example.yaml" > /etc/mihomo/config.yaml
    chmod 600 /etc/mihomo/config.yaml
fi

# 本机 API 访问地址取自刚生成的配置（panel_api_host 规则）：LAN 模式
# 只绑 LAN IP 时 127.0.0.1:9090 不监听，auto-maintain/verify 必须走监
# 听地址本身；0.0.0.0 监听全部接口时本机走 127.0.0.1。
cat > /etc/mihomo/maintain.env <<EOF
API="http://$(panel_api_host /etc/mihomo/config.yaml):9090"
API_SECRET="${API_SECRET}"
PROVIDERS="airport1"
BIN_ARCH="${BIN_ARCH}"
EOF
chmod 600 /etc/mihomo/maintain.env

# 透明代理只接管安装时指定的入口网卡及 LAN 来源网段，不再无条件挂到
# 全部 PREROUTING 流量。多网段时 LAN_SUBNETS 为逗号列表（主网段仍写
# LAN_SUBNET，供老版 tproxy.sh 兼容读取）；IPv6 阻断仅在用户显式启用
# 时写入 IPV6_BLOCK=1；PANEL_LISTEN 告诉 tproxy.sh 面板监听模式，非
# 本机监听时建 MIHOMO_PANEL 来源限制链（第二轮第 2 项，v1.2.2 起新增，
# 单网段 + 不阻断时文件因此为三行，不再与 v1.1.0 的两行格式相同）。
{
    echo "LAN_IFACE=\"${LAN_IFACE}\""
    echo "LAN_SUBNET=\"${LAN_SUBNET}\""
    if [ "${#LAN_SUBNET_LIST[@]}" -gt 1 ]; then
        echo "LAN_SUBNETS=\"${LAN_SUBNETS_JOINED}\""
    fi
    if [ "$IPV6_BLOCK" -eq 1 ]; then
        echo "IPV6_BLOCK=\"1\""
    fi
    echo "PANEL_LISTEN=\"${PANEL_LISTEN}\""
} > /etc/mihomo/tproxy.env
chmod 600 /etc/mihomo/tproxy.env

cp "$SCRIPT_DIR/tproxy.sh" /etc/mihomo/tproxy.sh
cp "$SCRIPT_DIR/auto-maintain.sh" /etc/mihomo/auto-maintain.sh
cp "$SCRIPT_DIR/verify.sh" /etc/mihomo/verify.sh
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
stage "数据" "4/6 预置 GeoIP/GeoSite/MMDB 数据库..."
GEO_MIRRORS=(
  "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
  "https://githubproxy.cc/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
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
        log INFO "✓ /etc/mihomo/${GEO_NAME} 已存在，跳过下载"
        FETCH_SUMMARY+=("${GEO_NAME}: 已存在，跳过")
        continue
    fi
    GEO_URLS=()
    for GEO_MIRROR in "${GEO_MIRRORS[@]}"; do
        GEO_URLS+=("${GEO_MIRROR}/${GEO_REMOTE}")
    done
    if ! fetch_or_project "${GEO_NAME}" "/tmp/${GEO_REMOTE}" "${GEO_BUNDLE}" "${GEO_URLS[@]}"; then
        log ERROR "错误：${GEO_NAME} 获取失败（官方源与专用资产仓库兜底均不可用），安装中止。"
        exit 1
    fi
    # 先下载到 /tmp 再 mv，避免 wget 中断在 /etc/mihomo 留下半截文件
    # 让 mihomo 误以为数据库已就绪（半截文件不会报"找不到"，更隐蔽）。
    mv "/tmp/${GEO_REMOTE}" "/etc/mihomo/${GEO_NAME}"
    log INFO "✓ ${GEO_NAME} 已就绪"
done

# 8. 启动前配置自检：用刚装好的内核对最终配置做一次 mihomo -t，
# 配置或数据库有问题就在这里明确失败，而不是留给 systemd 崩溃循环。
stage "自检" "正在做启动前配置自检 (mihomo -t)..."
if ! /usr/local/bin/mihomo -t -d /etc/mihomo; then
    log ERROR "错误：配置自检未通过，服务未启动。请根据上方输出修正后重跑安装。"
    exit 1
fi
log INFO "✓ 配置自检通过"

# 9. 启动/重启服务
stage "服务" "5/6 启动系统服务..."
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
stage "校验" "6/6 校验服务状态..."
READY=0
# API 地址取自刚生成的配置（panel_api_host 规则）：LAN 模式只绑 LAN
# IP 时 127.0.0.1:9090 不监听，必须走监听地址本身。
API="http://$(panel_api_host /etc/mihomo/config.yaml):9090"
# --noproxy：本机 API 不走代理（同回滚轮询；curl 默认连 127.0.0.1 也发给代理）。
for _ in $(seq 1 30); do
    if systemctl is-active --quiet mihomo 2>/dev/null \
        && curl --noproxy '*' -s -m 3 -H "Authorization: Bearer ${API_SECRET}" "$API/version" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done
if [ "$READY" -ne 1 ]; then
    log ERROR "错误：服务启动后 30 秒内 API 未就绪，安装未完成。最近日志如下："
    systemctl --no-pager status mihomo 2>/dev/null | head -20 || true
    journalctl -u mihomo -n 30 --no-pager 2>/dev/null || true
    exit 1
fi
log INFO "✓ 服务已就绪 (API $API 可达)"
# 直到服务真正就绪才提交 UI 更新；失败退出时 EXIT trap 会恢复旧目录。
[ -n "$UI_OLD" ] && rm -rf "$UI_OLD"
UI_OLD=""
UI_STAGE=""

# 11. 功能验证：服务就绪（API 可达）不等于网关功能正常——规则由
# ExecStartPost 建，建失败时服务仍可 active、API 仍可达，第 10 步只
# 验服务与 API，这里跑完整自检（TPROXY/DNS 规则、策略路由、规则范
# 围、订阅 provider）。verify.sh 只读不拿锁，安装持锁期间调用无自锁
# 风险；VERIFY_INSTALL_MODE=1 见 verify.sh 第 5 节注释（首次订阅拉
# 取尚未完成、缓存未生成时 provider 项记 SKIP 而非误报失败）。
# 注意 set -e：verify 失败返回非零时必须显式接住退出码再 exit 1，
# 否则脚本静默退出、定夺 3 的文案打印不出来。失败时先置
# TXN_COMMITTED=1 再退出，让 EXIT trap 跳过回滚（服务保持运行）。
stage "验证" "运行安装后功能验证 (verify.sh)..."
if ! VERIFY_INSTALL_MODE=1 bash /etc/mihomo/verify.sh; then
    TXN_COMMITTED=1
    log ERROR "服务已启动但功能验证未通过：mihomo 服务已在运行、API 已就绪，但网关功能验证（见上方自检输出）未通过，安装按失败处理。服务保持运行，不回滚、不删除配置；请按上方排查指引修复后重跑 sudo bash /etc/mihomo/verify.sh，或重跑安装。"
    exit 1
fi
log INFO "✓ 功能验证通过（verify.sh 全部检查通过）"

echo -e "\n${BLUE}--- 产物获取汇总 ---${NC}"
for line in "${FETCH_SUMMARY[@]}"; do
    echo "  • $line"
done
echo -e "订阅状态: ${SUB_STATUS}"

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}🎉 Mihomo TPROXY 透明代理旁路由部署成功！${NC}"
if [ "$PANEL_LISTEN" = "127.0.0.1" ]; then
    echo -e "控制面板: ${BLUE}http://127.0.0.1:9090/ui${NC}（仅本机可访问）"
elif [ "$PANEL_LISTEN" = "0.0.0.0" ]; then
    echo -e "控制面板: ${BLUE}http://${LOCAL_IP}:9090/ui${NC}"
    echo -e "${YELLOW}警告：面板监听全部接口（0.0.0.0:9090），同时绑定 WAN/公网接口；任何能连通本机公网 IP 的人都可尝试访问面板（仅靠下方密钥保护），防火墙已限制为仅受管 LAN 网段可访问，但仍建议改用局域网访问或仅本机模式（重跑安装修改）。${NC}"
else
    echo -e "控制面板: ${BLUE}http://${PANEL_LISTEN}:9090/ui${NC}"
fi
echo -e "面板密钥: ${YELLOW}${API_SECRET}${NC} (已写入 config.yaml 与 maintain.env)"
echo -e "日志查看: ${YELLOW}journalctl -u mihomo -f${NC}"
echo -e "维护日志: ${YELLOW}tail -f /var/log/mihomo-maintain.log${NC}"
echo -e "远程访问面板请走可信网络或安全隧道（如 SSH 端口转发），不要直接向公网开放 9090 端口。"
if [ "$IPV6_LAN" -eq 1 ] && [ "$IPV6_BLOCK" -eq 0 ]; then
    echo -e "${YELLOW}警告：LAN 口已分配 IPv6 地址（${IPV6_LAN_PREFIXES}），IPv6 流量不受代理保护、可绕过代理策略；如需阻断请重跑安装并在确认页启用 IPv6 阻断（彻底防绕过需在主路由上处理）。${NC}"
fi
# cron 不可用时成功页注明（预检警告的复述：网关本身不受影响，但定时
# 维护不会自动运行；CRON_OK=2 为已安装但未运行，=0 为缺失）。
if [ "${CRON_OK:-1}" -eq 2 ]; then
    echo -e "${YELLOW}注意：cron 服务当前未在运行，15 分钟健康检查、订阅刷新与 IPv6 阻断补建不会自动运行；请运行 sudo systemctl start cron（或 crond）启动它。${NC}"
elif [ "${CRON_OK:-1}" -eq 0 ]; then
    echo -e "${YELLOW}注意：未检测到可用的 cron 服务，15 分钟健康检查、订阅刷新与 IPv6 阻断补建不会自动运行；请安装并启动 cron（见预检警告），否则定时维护需手动执行。${NC}"
fi
echo -e "${GREEN}====================================================${NC}"
