#!/usr/bin/env bash
# 构建打了 result-only 补丁的 ds-harness-remote，产出可安装的 tgz。
# 需要：node、npm、npx、patch、tar、curl；pnpm 由 npx 临时拉取。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
META="$ROOT/upstream.json"

for tool in node npm npx patch tar curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

read_meta() {
  node -e 'const fs=require("node:fs");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(String(m[process.argv[2]]??""))' "$META" "$1"
}

PACKAGE="$(read_meta package)"
VERSION="$(read_meta version)"
SOURCE="$(read_meta source)"
SHA256="$(read_meta sha256)"
PNPM="$(read_meta pnpm)"
PATCH_REL="$(read_meta patch)"

for value in "$PACKAGE" "$VERSION" "$SOURCE" "$SHA256" "$PNPM" "$PATCH_REL"; do
  [[ -n "$value" ]] || { echo "incomplete upstream.json" >&2; exit 1; }
done

CACHE="${DSH_HOST_REMOTE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dsh-go/host-remote}"
OUT="${DSH_HOST_REMOTE_OUT:-$ROOT/dist}"
ARCHIVE="$CACHE/${PACKAGE}-${VERSION}.tar.gz"
WORK="$CACHE/build-${VERSION}"
PATCH_FILE="$ROOT/$PATCH_REL"
RESULT_TGZ="$OUT/${PACKAGE}-${VERSION}-result-only.tgz"

[[ -f "$PATCH_FILE" ]] || { echo "missing patch: $PATCH_FILE" >&2; exit 1; }
mkdir -p "$CACHE" "$OUT"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "==> download ${PACKAGE}@${VERSION} source"
  curl -fL --retry 3 --connect-timeout 20 -o "$ARCHIVE.tmp" "$SOURCE"
  mv "$ARCHIVE.tmp" "$ARCHIVE"
fi

ACTUAL="$(node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$ARCHIVE")"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "sha256 mismatch for $ARCHIVE" >&2
  echo "  expected: $SHA256" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi

echo "==> extract and patch"
rm -rf "$WORK"
mkdir -p "$WORK"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$WORK"
( cd "$WORK" && patch -p1 < "$PATCH_FILE" )

cd "$WORK"
echo "==> install workspace dependencies"
npx -y "pnpm@$PNPM" install --frozen-lockfile
echo "==> build packages"
npx -y "pnpm@$PNPM" --filter './packages/**' -r build

cd "$WORK/packages/plugin"
echo "==> type-check"
npx -y "pnpm@$PNPM" check
# 上游 acp-workspace-controls 的 hermes 用例在并行跑全量时是已知 flake；
# 串行跑既稳定，又覆盖插件全部测试文件。
echo "==> plugin tests (serial)"
npx -y "pnpm@$PNPM" exec vitest run --no-file-parallelism

rm -f "$RESULT_TGZ" "$OUT/${PACKAGE}-${VERSION}.tgz"
npm pack --pack-destination "$OUT" >/dev/null
mv "$OUT/${PACKAGE}-${VERSION}.tgz" "$RESULT_TGZ"

echo
echo "built: $RESULT_TGZ"
ls -lh "$RESULT_TGZ"
