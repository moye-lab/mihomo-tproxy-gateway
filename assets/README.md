# 专用资产仓库兜底资产清单

本目录**只放清单，不放二进制文件**。兜底用的二进制资产托管在专用资产仓库（`sg/mihomo-assets`，
与代码仓库相互独立）的 Release 附件里，代码仓库本体只放脚本与清单，
克隆很快；资产只在专用仓库维护一处。

## 拉取逻辑

安装器（`scripts/install.sh`）获取每个关键文件时走同一条链：

1. **官方优先**：先从官方源（含 gh-proxy、gitmirror 镜像链）拉最新版本。
   官方成功时，**绝不请求专用资产仓库的资产**。
2. **专用资产仓兜底**：官方源全部失败时，脚本自动改从专用资产仓库
   按需拉取文件（内核按当前 CPU 架构只拉对应的那一个包），批次分两级：
   - **最新批次优先**：先向专用资产仓库查询最新 Release 批次，按该
     批次拉文件，并用该批次随附的 `SHA256SUMS` 验 sha256。专用资产
     仓库由自动刷新脚本保持新鲜（见其仓库的 `tools/refresh-assets.sh`），
     所以任何脚本走兜底，拿到的都是仓库里躺着的最新批次；
   - **钉版批次退回**：查询失败、最新批次拉不到或校验不过时，退回
     `PROJECT_ASSETS_BASE` 指向的钉版批次，按本目录清单验 sha256。
   两个批次都拉不到或校验不过，会明确报错到具体步骤并中止，不留
   半成品。

兜底地址在 `install.sh` 里定义：最新批次经 `FALLBACK_ASSETS_API`
查询、按 `FALLBACK_ASSETS_REPO_URL` 拉取；钉版批次基地址
`PROJECT_ASSETS_BASE` 默认值：

```
https://git.edge97.dpdns.org/sg/mihomo-assets/releases/download/v1.0.0
```

三者都可用同名环境变量覆盖。注意兜底地址刻意不随代码仓库走：即使
代码仓库迁移到 GitHub，兜底仍指向独立的专用资产仓库，避免官方源
与兜底同灭。

## 清单与校验

- `manifest.json` 是**权威记录**：每项的版本、来源、大小与 sha256，
  记录的是钉版批次（退回路径用）。
- `SHA256SUMS` 由 `manifest.json` 同步生成，是钉版批次退回时安装器
  实际读取的校验文件；走最新批次时改用该批次随附的 `SHA256SUMS`。
  两者内容必须一致，刷新资产时按下方流程同时更新。

## 钉版清单（资产批次 2026-10-20，托管于 Release `v1.0.0`）

| Release 附件名 | 组件 | 钉定版本 | 官方原始资产名 |
|---|---|---|---|
| `mihomo-linux-amd64.gz` | mihomo 内核（amd64） | v1.19.32 | `mihomo-linux-amd64-v1.19.32.gz` |
| `mihomo-linux-arm64.gz` | mihomo 内核（arm64） | v1.19.32 | `mihomo-linux-arm64-v1.19.32.gz` |
| `ui.tgz` | MetaCubeXD 面板 dist | v1.273.1 | `compressed-dist.tgz` |
| `GeoIP.dat` | GeoIP 数据库 | meta-rules-dat `latest`（2026-10-20） | `geoip.dat` |
| `GeoSite.dat` | GeoSite 数据库 | meta-rules-dat `latest`（2026-10-20） | `geosite.dat` |
| `country.mmdb` | GeoIP MMDB 数据库 | meta-rules-dat `latest`（2026-10-20） | `country.mmdb` |

说明：附件以仓库内命名托管（与官方资产名不同），内容与官方发布文件
逐字节一致，未解压、未改包（`.gz` / `.tgz` 保持官方原始形态）。
`country.mmdb` 安装落位时按 mihomo 约定改名为 `Country.mmdb`。

兜底资产仅覆盖 amd64 / arm64 两个架构；其他架构无兜底资产，
官方源不可用时安装器会明确报错。

## 选版理由

- **mihomo v1.19.32**：官方版本线最新稳定版（2026-09-30 发布，距钉版日 20 天，
  已过新版观察期），且为当前在役设备实测稳定运行的版本。
- **MetaCubeXD v1.273.1**：官方版本线最新稳定版（2026-09-10 发布）。
- **geodata**：MetaCubeX/meta-rules-dat 为滚动发布（release 标签恒为 `latest`，每日更新），
  无法按版本号钉定，故以「抓取日期 + sha256」双钉：本次抓取 2026-10-20 发布批次，
  校验值见 `manifest.json`。geodata 时效性要求低，兜底批次仅用于把服务
  先装起来，服务跑通后由自动维护脚本更新到最新。

## 刷新资产的发版步骤（维护者）

1. 从各官方 release 下载新版本文件（保持上表的仓库内命名）：
   - mihomo：https://github.com/MetaCubeX/mihomo/releases
   - MetaCubeXD：https://github.com/MetaCubeX/metacubexd/releases （取 `compressed-dist.tgz`）
   - geodata：https://github.com/MetaCubeX/meta-rules-dat/releases （`latest` 标签）
2. 更新清单（在本目录）：
   - `sha256sum mihomo-linux-amd64.gz mihomo-linux-arm64.gz ui.tgz GeoIP.dat GeoSite.dat country.mmdb > SHA256SUMS`（对新文件计算）
   - 同步更新 `manifest.json` 中各条目的 version、source_url、size_bytes、sha256，
     以及本文件钉版清单中的版本号与批次日期；把改好的 `manifest.json` 与
     `SHA256SUMS` 提交进 git；专用资产仓库内的同名清单同步更新为
     同一批校验值。
3. 真机验证新二进制可运行（`-v` 输出版本正确）且兜底 geodata 可被加载
   （最小配置 `mihomo -t` 通过）。
4. 在专用资产仓库（`sg/mihomo-assets`）新建一个 Release
   （tag 递增，如 `v1.0.1`），把 6 个资产文件作为附件上传。
   日常刷新由专用资产仓库的自动刷新脚本完成，新批次发布后安装器
   走兜底时自动使用最新批次，**不需要改代码仓库**；本目录的钉版
   批次只是查询不到最新批次时的退路，只在代码仓库发新版本时顺手
   同步更新 `PROJECT_ASSETS_BASE` 的默认 tag 与本目录清单即可。
