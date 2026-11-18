# 个人构建的发布与应用内更新

这份流程只用于本仓库（`GarinZ/dsh-Go`）的个人构建，不适用于上游 `ccch1mneyyy/dsh-go` 的正式发版。目标：同一把个人签名证书、版本号递增、GitHub Release 作为更新源，App 内点一下就能升级。

## 首次切换

已经安装的旧版本如果还指向官方更新源，不会自动看到本仓库的 Release。需要手动安装一次带 `DSH_UPDATE_REPO=GarinZ/dsh-Go` 的版本；从这一版起，后续版本才能在 App 内更新。

## 版本号

- 版本名使用 `X.Y.Z-resultonly.N`，例如 `1.2.1-resultonly.1`。
- `app/pubspec.yaml` 的 `+1` 只是占位；真正的 versionCode 由 `tooling/build-apk.sh` 按构建时间生成。
- 新版本的版本名必须比手机上已安装的更新；同版本名不能靠加大构建号让 App 提示升级（App 只在版本名更新时提示）。

## 构建

```bash
PATH=/path/to/flutter/bin:$PATH tooling/build-apk.sh -f arm64
```

脚本默认：

- `DSH_UPDATE_REPO=GarinZ/dsh-Go`
- `DSH_UPDATE_MIRROR=`（空，禁用官方 `dl.dshtui.com`）

后一条很重要。官方下载桶的 `update.json` 会提供官方 `1.2.0`；semver 里 `1.2.1-resultonly.1` 虽然名字更大，但不能让官方清单参与竞争，否则会出现版本回退或反复提示。

产物：`app/build/app/outputs/flutter-apk/app-arm64-release.apk`。

## 校验签名

```bash
apksigner verify -v --min-sdk-version 21 --print-certs \
  app/build/app/outputs/flutter-apk/app-arm64-release.apk
```

要求 v1/v2/v3 都为 true，证书 SHA-256 与上一版一致。个人证书在 `/Users/garin/keys/dsh-go-personal.jks`，`app/android/key.properties` 指向它；这两个文件都不入库。

## 生成 Release 资产

```bash
DSH_RELEASE_REPO=GarinZ/dsh-Go python3 tooling/release_assets.py \
  --version 1.2.1-resultonly.1+<versionCode> \
  --notes /tmp/notes.md \
  --delta-from 0 \
  --out /tmp/dshgo-release
```

- `DSH_RELEASE_REPO` 必须设置，否则 `update.json` 的 `page` 和脚本打印的 `gh` 命令会指向上游。
- `--delta-from 0` 不做增量补丁：个人构建换了签名，不能复用官方 APK 的补丁。
- 产物：arm64 APK、`SHA256SUMS`、`update.json`。

## 发布

先提交并推送 `main`，再建 tag 和 Release：

```bash
git push origin main
git tag v1.2.1-resultonly.1
git push origin v1.2.1-resultonly.1
gh release create v1.2.1-resultonly.1 /tmp/dshgo-release/* \
  --repo GarinZ/dsh-Go \
  --title 'DSH Go 1.2.1-resultonly.1' \
  --notes-file /tmp/notes.md \
  --latest
```

**不要加 `--prerelease`。** 版本名里的 `-resultonly` 只是命名，不是 GitHub 预发布。`releases/latest` 会跳过预发布；一旦跳过，`releases/latest/download/update.json` 就取不到这一版，App 也就不会提示更新。

发布后核对：

```bash
curl -fsSL https://github.com/GarinZ/dsh-Go/releases/latest/download/update.json
```

返回的 `version` 应该是这一版，`assets.arm64.name` 应该指向 APK。

## App 侧条件

- 安装包的签名证书必须和已装版本一致；否则 Android 会拒绝覆盖安装并提示卸载。
- versionCode 必须比已装版本大；构建脚本按分钟生成，正常发版不会倒挂。
- `update.json` 的版本名必须比已装版本新，App 才会提示；同版本名只改构建号不会提示。
- App 的更新源由构建参数 `DSH_UPDATE_REPO` 决定，默认已在 `tooling/build-apk.sh` 里指向本仓库。

## 远程插件

App 更新和主机插件是两条线。主机插件仍用 `runtime/host-remote/build.sh` 构建、`reload.sh` 安装；不要把插件 tgz 当成 App 更新资产。
