#!/bin/bash
# 域名列表自动更新脚本
# 功能：从上游拉取最新列表，与本地增量合并

set -e

CONFIG_DIR="/home/chinadns-ng/config"
GITHUB_BASE="https://raw.githubusercontent.com/zfl9/chinadns-ng/master/res"
TMP_DIR="/tmp/chinadns-update-$$"
LOG_FILE="/tmp/chinadns-update.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

log "开始更新域名列表..."

# 下载上游列表
log "下载 chnlist.txt..."
if curl -fsSL --connect-timeout 30 "$GITHUB_BASE/chnlist.txt" -o "$TMP_DIR/chnlist.txt"; then
    log "✓ chnlist.txt 下载成功"
else
    log "✗ chnlist.txt 下载失败"
    exit 1
fi

log "下载 gfwlist.txt..."
if curl -fsSL --connect-timeout 30 "$GITHUB_BASE/gfwlist.txt" -o "$TMP_DIR/gfwlist.txt"; then
    log "✓ gfwlist.txt 下载成功"
else
    log "✗ gfwlist.txt 下载失败"
    exit 1
fi

# 备份当前列表
BACKUP_SUFFIX="$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_DIR/chnlist.txt" "$CONFIG_DIR/chnlist.txt.bak.$BACKUP_SUFFIX"
cp "$CONFIG_DIR/gfwlist.txt" "$CONFIG_DIR/gfwlist.txt.bak.$BACKUP_SUFFIX"
log "✓ 已备份当前列表"

# 合并并去重（保留本地自定义域名）
merge_lists() {
    local upstream="$1"
    local local_file="$2"
    local output="$3"
    
    # 合并上游和本地，去重，排序
    cat "$upstream" "$local_file" 2>/dev/null | \
        sed '/^\s*$/d' | \
        sed 's/\r$//' | \
        sort -u > "$output"
}

merge_lists "$TMP_DIR/chnlist.txt" "$CONFIG_DIR/chnlist.txt" "$TMP_DIR/chnlist_merged.txt"
merge_lists "$TMP_DIR/gfwlist.txt" "$CONFIG_DIR/gfwlist.txt" "$TMP_DIR/gfwlist_merged.txt"

# 统计变化
OLD_CHN=$(wc -l < "$CONFIG_DIR/chnlist.txt" | tr -d ' ')
NEW_CHN=$(wc -l < "$TMP_DIR/chnlist_merged.txt" | tr -d ' ')
OLD_GFW=$(wc -l < "$CONFIG_DIR/gfwlist.txt" | tr -d ' ')
NEW_GFW=$(wc -l < "$TMP_DIR/gfwlist_merged.txt" | tr -d ' ')

log "chnlist: $OLD_CHN → $NEW_CHN (+$((NEW_CHN - OLD_CHN)))"
log "gfwlist: $OLD_GFW → $NEW_GFW (+$((NEW_GFW - OLD_GFW)))"

# 应用更新
mv "$TMP_DIR/chnlist_merged.txt" "$CONFIG_DIR/chnlist.txt"
mv "$TMP_DIR/gfwlist_merged.txt" "$CONFIG_DIR/gfwlist.txt"
log "✓ 列表已更新"

# 重启 ChinaDNS-NG
log "重启 ChinaDNS-NG..."
docker restart chinadns-ng >/dev/null 2>&1
log "✓ ChinaDNS-NG 已重启"

# 清理旧备份（保留最近7天）
find "$CONFIG_DIR" -name "*.bak.*" -mtime +7 -delete 2>/dev/null || true
log "✓ 已清理7天前的备份"

log "域名列表更新完成！"
