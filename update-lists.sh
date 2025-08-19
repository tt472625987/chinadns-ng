#!/bin/bash

set -euo pipefail

# 目标目录：优先 CLI 第一个参数，其次环境变量 LIST_DIR，默认 /home/chinadns-ng
LIST_DIR="${1:-${LIST_DIR:-/home/chinadns-ng}}"
mkdir -p "${LIST_DIR}"

RAW_BASE="https://raw.githubusercontent.com/zfl9/chinadns-ng/master/res"

fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "需要 curl 或 wget 以下载规则列表" >&2
    exit 1
  fi
}

fetch "${RAW_BASE}/chnlist.txt" "${LIST_DIR}/chnlist.txt"
fetch "${RAW_BASE}/gfwlist.txt" "${LIST_DIR}/gfwlist.txt"

echo "已更新:"
echo "  ${LIST_DIR}/chnlist.txt"
echo "  ${LIST_DIR}/gfwlist.txt" 