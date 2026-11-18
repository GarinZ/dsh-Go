#!/usr/bin/env bash
# 安装新构建的插件，并让启用了 HMR 的主机进程原地重载它。
# 不重启 host；HMR 关闭时仍需重启。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-${DSH_PROFILE:-desktop}}"
TGZ="${2:-}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
PATCH="$PROFILE_DIR/cordis.patch.yml"
DSH_BIN="${DSH_BIN:-dsh}"

if [[ -z "$TGZ" ]]; then
  TGZ="$(ls -t "$ROOT"/dist/*-result-only.tgz 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$TGZ" || ! -f "$TGZ" ]]; then
  echo "usage: $0 [profile] [path/to/ds-harness-remote-*-result-only.tgz]" >&2
  echo "run $ROOT/build.sh first, or pass the tgz path explicitly" >&2
  exit 1
fi
command -v "$DSH_BIN" >/dev/null 2>&1 || { echo "$DSH_BIN not found in PATH" >&2; exit 1; }
[[ -f "$PATCH" ]] || { echo "profile patch not found: $PATCH" >&2; exit 1; }

echo "==> install $(basename "$TGZ") into profile $PROFILE"
"$DSH_BIN" plugin --profile "$PROFILE" add "$TGZ"

DIST="$(find "$PROFILE_DIR/node_modules" -maxdepth 4 -path '*/ds-harness-remote/dist/index.js' -type f -print -quit 2>/dev/null || true)"

if [[ -z "$DIST" || ! -f "$DIST" ]]; then
  echo "installed, but no ds-harness-remote/dist/index.js under $PROFILE_DIR/node_modules" >&2
  echo "cannot trigger HMR; restart the host process instead" >&2
  exit 1
fi

# HMR 的文件监听会忽略 node_modules；但每次 profile 重组合会重新比较
# 已加载文件。先改 mtime，再改 patch 内容让 HMR 重组合。
touch "$DIST"

TMP="$(mktemp "${TMPDIR:-/tmp}/dsh-go-hot-reload.XXXXXX")"
if [[ -s "$PATCH" ]]; then
  grep -v '^# dsh-go hot reload trigger' "$PATCH" > "$TMP" || true
  printf '\n' >> "$TMP"
else
  : > "$TMP"
fi
printf '# dsh-go hot reload trigger %s-%s\n' "$(date +%s)" "$RANDOM" >> "$TMP"
cat "$TMP" > "$PATCH"
rm -f "$TMP"

echo
echo "installed; HMR recomposition triggered via $PATCH."
echo "the host log should show the plugin stop and start again; the host PID stays the same."
echo "if HMR is disabled, restart the host process instead."
