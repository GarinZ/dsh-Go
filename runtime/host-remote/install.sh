#!/usr/bin/env bash
# 把 build.sh 产出的插件装进本机 DSH profile。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-${DSH_PROFILE:-desktop}}"
TGZ="${2:-}"

if [[ -z "$TGZ" ]]; then
  TGZ="$(ls -t "$ROOT"/dist/*-result-only.tgz 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$TGZ" || ! -f "$TGZ" ]]; then
  echo "usage: $0 [profile] [path/to/ds-harness-remote-*-result-only.tgz]" >&2
  echo "run $ROOT/build.sh first, or pass the tgz path explicitly" >&2
  exit 1
fi

command -v dsh >/dev/null 2>&1 || { echo "dsh not found in PATH" >&2; exit 1; }

echo "==> install $(basename "$TGZ") into profile $PROFILE"
dsh plugin --profile "$PROFILE" add "$TGZ"
echo
echo "installed. restart the host process (dsh web / desktop app) to load the new bundle,"
echo "then reconnect DSH Go. The host should advertise remote.result.only.v1."
