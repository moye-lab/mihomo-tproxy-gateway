#!/bin/bash
# check-release.sh — 发布流程一致性检查（手动在发版时运行）
#
# 定位：本脚本是发布时的人工核对工具，不是每次 push 的 CI 门禁。
# 正常开发时 main 可以包含下一版本的提交，因此本脚本不假设
# main 等于最新 tag；它只验证「给定的版本号 + 预期 tag SHA」这一组
# 发布事实是否自洽。
#
# 用法：
#   bash tests/check-release.sh <版本号> <预期 tag SHA> [选项]
#   例如：bash tests/check-release.sh v1.2.5 2c3d821...（40 位完整 SHA）
#   预期 tag SHA 取自：git rev-parse refs/tags/<版本号>^{commit}
#
# 选项：
#   --repo PATH        仓库路径（默认：本脚本所在仓库）
#   --remote NAME      远端名（默认：origin）
#   --no-api           跳过 GitHub Release API 检查（发版前离线核对时用；
#                      发版后核对请不要加此选项）
#   --api-base URL     GitHub API 根地址（默认 https://api.github.com；
#                      测试时可指向 file:// 假 API）
#   --owner OWNER      GitHub 仓库属主（默认从远端 URL 推导；测试时可指定）
#   --repo-name NAME   GitHub 仓库名（默认从远端 URL 推导；测试时可指定）
#
# 验证内容（全部从 tag 树读取，不依赖工作区状态）：
#   1. tag 存在于本地仓库
#   2. 本地 tag 指向的提交 == 预期 SHA（tag 未被意外移动）
#   3. 远端同名 tag 指向的提交 == 预期 SHA（远端 tag 未被移动；
#      远端不可达或 tag 尚未推送时为 WARN，不计失败）
#   4. GitHub Release 存在且 tag_name == 版本号（Release 指向正确 tag；
#      Release 源码包由 GitHub 按 tag_name 从 tag 生成，故 tag_name
#      正确 + 检查 2 通过即蕴含源码与 tag 对应提交一致，不另行下载
#      源码包比对）
#   5. tag 树内 assets/manifest.json 与 assets/SHA256SUMS 一致
#      （total_size_bytes 求和、每项 sha256 对应）
#   6. 版本引用一致：安装器钉住的资产仓 tag（install.sh /
#      restore.sh 的 PROJECT_ASSETS_BASE）与 manifest.json 声明、
#      README 声明相同；mihomo 兜底版本号（install.sh / restore.sh
#      的 LATEST_VERSION 默认值）与 manifest 钉版批次相同；
#      README 钉版行提及的 mihomo / MetaCubeXD 版本与 manifest 相同
#   7. tag 树内 README 版本声明与被查版本号相同
#      （v1.2.4 的教训：tag 树里 README 仍写"当前为开发版"，发布时
#      无人核对，事后才发现声明过期）
#
# 退出码：0 全部检查通过；1 任一检查失败；2 用法错误。
#
# 依赖：git、python3（manifest 核对）、curl（仅 API 检查时需要）。

set -euo pipefail

VERSION=""
EXPECTED_SHA=""
REPO="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="origin"
NO_API=0
API_BASE="https://api.github.com"
OWNER=""
REPO_NAME=""

usage() {
    echo "用法：$0 <版本号> <预期 tag SHA（40 位完整 SHA）> [选项]" >&2
    echo "选项：--repo PATH --remote NAME --no-api --api-base URL --owner OWNER --repo-name NAME" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)      [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
        --remote)    [ $# -ge 2 ] || usage; REMOTE="$2"; shift 2 ;;
        --no-api)    NO_API=1; shift ;;
        --api-base)  [ $# -ge 2 ] || usage; API_BASE="$2"; shift 2 ;;
        --owner)     [ $# -ge 2 ] || usage; OWNER="$2"; shift 2 ;;
        --repo-name) [ $# -ge 2 ] || usage; REPO_NAME="$2"; shift 2 ;;
        --help|-h)   usage ;;
        --*)         echo "未知选项：$1" >&2; usage ;;
        *)           if [ -z "$VERSION" ]; then VERSION="$1";
                     elif [ -z "$EXPECTED_SHA" ]; then EXPECTED_SHA="$1";
                     else echo "多余参数：$1" >&2; usage; fi
                     shift ;;
    esac
done

[ -n "$VERSION" ] && [ -n "$EXPECTED_SHA" ] || usage
case "$EXPECTED_SHA" in
    *[!0-9a-f]*|"") echo "预期 tag SHA 必须是 40 位十六进制：$EXPECTED_SHA" >&2; exit 2 ;;
esac
[ "${#EXPECTED_SHA}" -eq 40 ] || { echo "预期 tag SHA 必须是 40 位完整 SHA：$EXPECTED_SHA" >&2; exit 2; }

command -v git >/dev/null 2>&1 || { echo "缺少依赖：git" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "缺少依赖：python3（manifest 核对需要）" >&2; exit 2; }

FAILURES=0
WARNINGS=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo "WARN: $1"; WARNINGS=$((WARNINGS + 1)); }

echo "发布一致性检查：版本 $VERSION，预期 tag SHA $EXPECTED_SHA"
echo "仓库：$REPO（远端 $REMOTE）"
echo

# ---------- 1/2. 本地 tag 存在且指向预期提交 ----------
TAG_SHA=""
if ! TAG_SHA="$(git -C "$REPO" rev-parse --verify "refs/tags/$VERSION^{commit}" 2>/dev/null)"; then
    fail "本地不存在 tag $VERSION"
else
    pass "本地存在 tag $VERSION（提交 $TAG_SHA）"
    if [ "$TAG_SHA" = "$EXPECTED_SHA" ]; then
        pass "本地 tag $VERSION 指向预期提交（未被移动）"
    else
        fail "本地 tag $VERSION 已被移动：指向 $TAG_SHA，预期 $EXPECTED_SHA"
    fi
    TREE_SHA="$(git -C "$REPO" rev-parse "$TAG_SHA^{tree}" 2>/dev/null || true)"
    [ -n "$TREE_SHA" ] && echo "INFO: tag 对应 tree SHA $TREE_SHA"
fi

# ---------- 3. 远端 tag 比对（不可达时 WARN，不计失败）----------
REMOTE_OUT=""
if ! REMOTE_OUT="$(git -C "$REPO" ls-remote "$REMOTE" "refs/tags/$VERSION" 2>/dev/null)"; then
    warn "无法联系远端 $REMOTE，跳过远端 tag 比对（请确认网络与远端配置后重跑）"
elif [ -z "$REMOTE_OUT" ]; then
    warn "远端 $REMOTE 尚无 tag $VERSION（尚未推送；推送后再跑本检查确认）"
else
    REMOTE_SHA="${REMOTE_OUT%%$'\t'*}"
    if [ "$REMOTE_SHA" = "$EXPECTED_SHA" ]; then
        pass "远端 $REMOTE 的 tag $VERSION 指向预期提交"
    else
        fail "远端 tag $VERSION 已被移动：远端指向 $REMOTE_SHA，预期 $EXPECTED_SHA"
    fi
fi

# ---------- 4. GitHub Release API 检查 ----------
if [ "$NO_API" -eq 1 ]; then
    echo "SKIP: 已用 --no-api 跳过 GitHub Release API 检查（发版后请不加此选项重跑）"
else
    if [ -z "$OWNER" ] || [ -z "$REPO_NAME" ]; then
        REMOTE_URL="$(git -C "$REPO" remote get-url "$REMOTE" 2>/dev/null || true)"
        case "$REMOTE_URL" in
            *github.com[:/]*)
                GH_PATH="${REMOTE_URL##*github.com}"
                GH_PATH="${GH_PATH#/}"; GH_PATH="${GH_PATH#:}"
                GH_PATH="${GH_PATH%.git}"
                OWNER="${OWNER:-${GH_PATH%%/*}}"
                REPO_NAME="${REPO_NAME:-${GH_PATH#*/}}"
                ;;
            *)
                warn "远端 $REMOTE 不是 GitHub 地址（$REMOTE_URL），跳过 Release API 检查"
                OWNER=""; REPO_NAME=""
                ;;
        esac
    fi
    if [ -n "$OWNER" ] && [ -n "$REPO_NAME" ]; then
        if ! command -v curl >/dev/null 2>&1; then
            fail "缺少 curl，无法验证 GitHub Release（安装 curl 或用 --no-api 跳过）"
        else
            API_URL="$API_BASE/repos/$OWNER/$REPO_NAME/releases/tags/$VERSION"
            RELEASE_JSON="$(curl -m 10 -fsSL "$API_URL" 2>/dev/null || true)"
            if [ -z "$RELEASE_JSON" ]; then
                fail "GitHub 上不存在 $OWNER/$REPO_NAME 的 Release $VERSION（或 API 不可达）"
            else
                RELEASE_TAG="$(printf '%s' "$RELEASE_JSON" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 || true)"
                if [ "$RELEASE_TAG" = "$VERSION" ]; then
                    pass "GitHub Release 存在且 tag_name 为 $VERSION（指向正确 tag）"
                    TARGET="$(printf '%s' "$RELEASE_JSON" | grep -oP '"target_commitish":\s*"\K[^"]+' | head -1 || true)"
                    [ -n "$TARGET" ] && echo "INFO: Release target_commitish 为 $TARGET"
                else
                    fail "GitHub Release 的 tag_name 为 ${RELEASE_TAG:-（空）}，不是 $VERSION"
                fi
            fi
        fi
    fi
fi

# ---------- 5/6/7. 从 tag 树提取文件并核对内容 ----------
if [ -n "$TAG_SHA" ]; then
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT
    EXTRACT_OK=1
    for f in assets/manifest.json assets/SHA256SUMS scripts/install.sh scripts/restore.sh README.md; do
        mkdir -p "$TMPDIR/$(dirname "$f")"
        if ! git -C "$REPO" show "$VERSION:$f" > "$TMPDIR/$f" 2>/dev/null; then
            fail "tag $VERSION 的树中缺少 $f"
            EXTRACT_OK=0
        fi
    done

    if [ "$EXTRACT_OK" -eq 1 ]; then
        MANIFEST="$TMPDIR/assets/manifest.json"
        SUMS="$TMPDIR/assets/SHA256SUMS"
        INSTALL="$TMPDIR/scripts/install.sh"
        RESTORE="$TMPDIR/scripts/restore.sh"
        README="$TMPDIR/README.md"

        # 5. manifest.json 与 SHA256SUMS 一致性（python 核对）
        MANIFEST_OUT=""
        if ! MANIFEST_OUT="$(python3 - "$MANIFEST" "$SUMS" <<'PYEOF'
import json, sys
manifest_path, sums_path = sys.argv[1], sys.argv[2]
with open(manifest_path, encoding="utf-8") as f:
    m = json.load(f)
sums = {}
with open(sums_path, encoding="utf-8") as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 2:
            sums[parts[1]] = parts[0]
errors = []
total = sum(a["size_bytes"] for a in m["assets"])
if total != m["total_size_bytes"]:
    errors.append("total_size_bytes 为 %s，实际求和 %s" % (m["total_size_bytes"], total))
for a in m["assets"]:
    fn, sha = a["filename"], a["sha256"]
    if fn not in sums:
        errors.append("SHA256SUMS 缺少 %s" % fn)
    elif sums[fn] != sha:
        errors.append("%s 的 sha256 与 SHA256SUMS 不一致" % fn)
mihomo_versions = {a["version"] for a in m["assets"] if a["name"].startswith("mihomo-")}
if len(mihomo_versions) != 1:
    errors.append("manifest 内 mihomo 各架构版本号不一致：%s" % sorted(mihomo_versions))
ui_versions = {a["version"] for a in m["assets"] if a["name"] == "metacubexd-dist"}
if len(ui_versions) != 1:
    errors.append("manifest 内 MetaCubeXD 版本缺失或不一致：%s" % sorted(ui_versions))
if errors:
    print("；".join(errors))
    sys.exit(1)
print("MIHOMO_VERSION=%s" % mihomo_versions.pop())
print("UI_VERSION=%s" % ui_versions.pop())
PYEOF
)"; then
            fail "manifest.json 与 SHA256SUMS 不一致：$MANIFEST_OUT"
        else
            pass "manifest.json 与 SHA256SUMS 一致（total_size_bytes 求和、每项 sha256 均对应）"
            MIHOMO_VERSION="${MANIFEST_OUT#*MIHOMO_VERSION=}"
            MIHOMO_VERSION="${MIHOMO_VERSION%%$'\n'*}"
            UI_VERSION="${MANIFEST_OUT#*UI_VERSION=}"
            UI_VERSION="${UI_VERSION%%$'\n'*}"

            # 6a. 资产仓钉版 tag 四处一致
            PINNED_TAG="$(grep -oE 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+' "$INSTALL" | head -1 | sed 's|releases/download/||' || true)"
            if [ -z "$PINNED_TAG" ]; then
                fail "install.sh 中未找到 PROJECT_ASSETS_BASE 的钉版 tag"
            else
                PIN_OK=1
                grep -qF "releases/download/$PINNED_TAG" "$RESTORE" || { fail "restore.sh 的资产仓钉版 tag 不是 $PINNED_TAG"; PIN_OK=0; }
                grep -qF "tag $PINNED_TAG" "$MANIFEST" || { fail "manifest.json 未声明资产仓 tag $PINNED_TAG"; PIN_OK=0; }
                grep -qF "Release \`$PINNED_TAG\`" "$README" || { fail "README 未提及资产仓 Release $PINNED_TAG"; PIN_OK=0; }
                [ "$PIN_OK" -eq 1 ] && pass "资产仓钉版 tag $PINNED_TAG 四处一致（install.sh / restore.sh / manifest.json / README）"
            fi

            # 6b. mihomo 兜底版本号与 manifest 钉版批次一致
            MIHOMO_OK=1
            for f in "$INSTALL" "$RESTORE"; do
                FB="$(grep -oE 'LATEST_VERSION="v[0-9]+\.[0-9]+\.[0-9]+"' "$f" | head -1 | cut -d'"' -f2 || true)"
                if [ -z "$FB" ]; then
                    fail "$(basename "$f") 中未找到 LATEST_VERSION 兜底版本号"
                    MIHOMO_OK=0
                elif [ "$FB" != "$MIHOMO_VERSION" ]; then
                    fail "$(basename "$f") 的 mihomo 兜底版本号为 $FB，与 manifest 钉版 $MIHOMO_VERSION 不一致"
                    MIHOMO_OK=0
                fi
            done
            [ "$MIHOMO_OK" -eq 1 ] && pass "mihomo 兜底版本号 $MIHOMO_VERSION 与 manifest 钉版批次一致（install.sh / restore.sh）"

            # 6c. README 钉版行提及的 mihomo / MetaCubeXD 版本与 manifest 一致
            if grep -qF "mihomo 内核 $MIHOMO_VERSION、MetaCubeXD $UI_VERSION" "$README"; then
                pass "README 钉版行与 manifest 一致（mihomo $MIHOMO_VERSION、MetaCubeXD $UI_VERSION）"
            else
                fail "README 钉版行未提及 mihomo $MIHOMO_VERSION、MetaCubeXD $UI_VERSION"
            fi
        fi

        # 7. README 版本声明与被查版本号相同
        if grep -qF "已发布正式版 **$VERSION**" "$README"; then
            pass "tag 树内 README 声明已发布正式版 $VERSION"
        else
            fail "tag 树内 README 未声明已发布正式版 $VERSION（声明过期或缺失）"
        fi
    fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "全部检查通过（$WARNINGS 个警告）"
    exit 0
else
    echo "检查失败：$FAILURES 项未通过（$WARNINGS 个警告）"
    exit 1
fi
