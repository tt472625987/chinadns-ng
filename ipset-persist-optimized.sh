#!/bin/sh

# chinadns-ng ipset 持久化脚本（优化版）
# 
# 变更说明：
# - 保留ipset集合的创建、保存、恢复功能
# - 禁用CHINADNS_CHN和CHINADNS_GFW链的创建
# - 原因：v2ray-tproxy的V2RAY_EXCLUDE链已经完美处理所有分流逻辑
#        CHINADNS链会造成重复检查，降低性能
#
# 优化后的架构：
# - chinadns-ng: 负责DNS分流和ipset维护
# - v2ray-tproxy: 负责流量分流（基于chinadns-ng维护的ipset）
# - 单一责任，清晰高效

# 读取统一配置（若存在）
[ -f /etc/v2ray-tproxy.conf ] && . /etc/v2ray-tproxy.conf
FWMARK_VALUE="${FW_MARK:-${MARK_VALUE:-0x1}}"
ENABLE_IPV6_EFFECTIVE="${ENABLE_IPV6:-0}"
ROUTE_TABLE_VALUE="${ROUTE_TABLE:-}"

# 集合名（需与 chinadns-ng.conf 保持一致）
CHN_IPSET4="chnip"
CHN_IPSET6="chnip6"
GFW_IPSET4="gfwip"
GFW_IPSET6="gfwip6"
CHN_ROUTE4="chnroute"
CHN_ROUTE6="chnroute6"

# 持久化文件
IPSET_SAVE_DIR="/etc/chinadns-ng/ipset"
IPSET_SAVE_FILE4="$IPSET_SAVE_DIR/ipset4.conf"
IPSET_SAVE_FILE6="$IPSET_SAVE_DIR/ipset6.conf"

# 日志
log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1"; }
log_err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"; }

check_deps() {
	for cmd in ipset iptables; do
		command -v "$cmd" >/dev/null 2>&1 || { log_err "缺少命令: $cmd"; return 1; }
	done
	return 0
}

# 容器内提示（避免误用）
is_docker() {
	[ -f /.dockerenv ] || grep -q docker /proc/1/cgroup 2>/dev/null
}

create_ipsets() {
	log_info "创建 ipset 集合..."
	if is_docker; then
		log_warn "检测到在容器内运行。请在宿主机执行本脚本以生效。"
	fi
	# IPv4
	ipset create -exist "$CHN_IPSET4" hash:ip  family inet  hashsize 1024 maxelem 65536 2>/dev/null || true
	ipset create -exist "$GFW_IPSET4" hash:ip  family inet  hashsize 1024 maxelem 65536 2>/dev/null || true
	ipset create -exist "$CHN_ROUTE4" hash:net family inet  hashsize 1024 maxelem 65536 2>/dev/null || true
	# IPv6 按需
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ]; then
		ipset create -exist "$CHN_IPSET6" hash:ip  family inet6 hashsize 1024 maxelem 65536 2>/dev/null || true
		ipset create -exist "$GFW_IPSET6" hash:ip  family inet6 hashsize 1024 maxelem 65536 2>/dev/null || true
		ipset create -exist "$CHN_ROUTE6" hash:net family inet6 hashsize 1024 maxelem 65536 2>/dev/null || true
	fi
	log_info "ipset 集合创建完成"
}

save_ipsets() {
	log_info "保存 ipset 配置..."
	mkdir -p "$IPSET_SAVE_DIR"
	# IPv4：覆盖保存
	: > "$IPSET_SAVE_FILE4"
	for set in "$CHN_IPSET4" "$GFW_IPSET4" "$CHN_ROUTE4"; do
		if ipset list "$set" >/dev/null 2>&1; then
			ipset save "$set" >> "$IPSET_SAVE_FILE4" 2>/dev/null || true
		fi
	done
	# IPv6：按需覆盖保存
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ]; then
		: > "$IPSET_SAVE_FILE6"
		for set in "$CHN_IPSET6" "$GFW_IPSET6" "$CHN_ROUTE6"; do
			if ipset list "$set" >/dev/null 2>&1; then
				ipset save "$set" >> "$IPSET_SAVE_FILE6" 2>/dev/null || true
			fi
		done
	fi
	log_info "ipset 配置保存完成"
}

restore_ipsets() {
	log_info "恢复 ipset 配置..."
	# 先创建集合（如果不存在）
	create_ipsets
	
	# 恢复IPv4集合
	if [ -f "$IPSET_SAVE_FILE4" ]; then
		ipset restore < "$IPSET_SAVE_FILE4" 2>/dev/null && log_info "恢复 IPv4 集合成功" || log_warn "恢复 IPv4 集合失败"
	else
		log_warn "IPv4 集合备份文件不存在: $IPSET_SAVE_FILE4"
	fi
	
	# 恢复IPv6集合
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ]; then
		if [ -f "$IPSET_SAVE_FILE6" ]; then
			ipset restore < "$IPSET_SAVE_FILE6" 2>/dev/null && log_info "恢复 IPv6 集合成功" || log_warn "恢复 IPv6 集合失败"
		else
			log_warn "IPv6 集合备份文件不存在: $IPSET_SAVE_FILE6"
		fi
	fi
}

# ===== 优化：禁用iptables规则创建 =====
# 原因：v2ray-tproxy的V2RAY_EXCLUDE链已经完美处理所有分流
# CHINADNS链会造成重复检查和性能浪费
cleanup_iptables_rules() {
	log_info "清理旧的 CHINADNS iptables 规则（如果存在）..."
	# 从PREROUTING移除
	iptables -t mangle -D PREROUTING -j CHINADNS_CHN 2>/dev/null || true
	iptables -t mangle -D PREROUTING -j CHINADNS_GFW 2>/dev/null || true
	# 清空并删除链
	iptables -t mangle -F CHINADNS_CHN 2>/dev/null || true
	iptables -t mangle -X CHINADNS_CHN 2>/dev/null || true
	iptables -t mangle -F CHINADNS_GFW 2>/dev/null || true
	iptables -t mangle -X CHINADNS_GFW 2>/dev/null || true
	
	# IPv6同样处理
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
		ip6tables -t mangle -D PREROUTING -j CHINADNS_CHN6 2>/dev/null || true
		ip6tables -t mangle -D PREROUTING -j CHINADNS_GFW6 2>/dev/null || true
		ip6tables -t mangle -F CHINADNS_CHN6 2>/dev/null || true
		ip6tables -t mangle -X CHINADNS_CHN6 2>/dev/null || true
		ip6tables -t mangle -F CHINADNS_GFW6 2>/dev/null || true
		ip6tables -t mangle -X CHINADNS_GFW6 2>/dev/null || true
	fi
	log_info "清理完成（流量分流由 v2ray-tproxy 的 V2RAY_EXCLUDE 链统一处理）"
}

show_status() {
	log_info "===== ipset 集合状态 ====="
	for set in "$CHN_IPSET4" "$GFW_IPSET4" "$CHN_ROUTE4"; do
		if ipset list "$set" >/dev/null 2>&1; then
			printf "%-12s: %6s entries\n" "$set" "$(ipset list "$set" | grep 'Number of entries:' | awk '{print $4}')"
		else
			printf "%-12s: not exist\n" "$set"
		fi
	done
	
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ]; then
		log_info "===== IPv6 集合 ====="
		for set in "$CHN_IPSET6" "$GFW_IPSET6" "$CHN_ROUTE6"; do
			if ipset list "$set" >/dev/null 2>&1; then
				printf "%-12s: %6s entries\n" "$set" "$(ipset list "$set" | grep 'Number of entries:' | awk '{print $4}')"
			else
				printf "%-12s: not exist\n" "$set"
			fi
		done
	fi
	
	log_info "===== iptables 规则状态 ====="
	echo "注意：优化版本不再创建 CHINADNS_CHN/CHINADNS_GFW 链"
	echo "流量分流由 v2ray-tproxy 的 V2RAY_EXCLUDE 链统一处理"
	
	if iptables -t mangle -L CHINADNS_CHN -n >/dev/null 2>&1; then
		echo "⚠️  检测到旧的 CHINADNS_CHN 链，建议运行 'cleanup' 清理"
	else
		echo "✓ CHINADNS_CHN 链已清理"
	fi
	
	if iptables -t mangle -L CHINADNS_GFW -n >/dev/null 2>&1; then
		echo "⚠️  检测到旧的 CHINADNS_GFW 链，建议运行 'cleanup' 清理"
	else
		echo "✓ CHINADNS_GFW 链已清理"
	fi
	
	if iptables -t mangle -L V2RAY_EXCLUDE -n >/dev/null 2>&1; then
		echo "✓ V2RAY_EXCLUDE 链正常（负责流量分流）"
	else
		echo "⚠️  V2RAY_EXCLUDE 链不存在，请检查 v2ray-tproxy 配置"
	fi
	
	log_info "===== 路由规则 ====="
	ip rule show | sed 's/^/  /'
	if [ -n "$ROUTE_TABLE_VALUE" ]; then
		log_info "===== 路由表 $ROUTE_TABLE_VALUE ====="
		ip route show table "$ROUTE_TABLE_VALUE" | sed 's/^/  /'
	fi
}

main() {
	case "${1:-}" in
		create)
			check_deps && create_ipsets ;;
		save)
			check_deps && save_ipsets ;;
		restore)
			check_deps && restore_ipsets ;;
		cleanup)
			check_deps && cleanup_iptables_rules ;;
		status)
			check_deps && show_status ;;
		setup)
			check_deps && create_ipsets && save_ipsets && cleanup_iptables_rules ;;
		*)
			echo "用法: $0 {create|save|restore|cleanup|status|setup}"
			echo ""
			echo "命令说明："
			echo "  create  - 创建 ipset 集合"
			echo "  save    - 保存当前 ipset 集合"
			echo "  restore - 从备份恢复 ipset 集合"
			echo "  cleanup - 清理旧的 CHINADNS iptables 规则"
			echo "  status  - 显示集合/规则/路由状态"
			echo "  setup   - 一次性完成（create + save + cleanup）"
			echo ""
			echo "优化说明："
			echo "  - 本脚本仅管理 ipset 集合，不创建 iptables 规则"
			echo "  - 流量分流由 v2ray-tproxy 的 V2RAY_EXCLUDE 链统一处理"
			echo "  - 避免重复规则，提升性能"
			exit 1 ;;
	esac
}

main "$@"
