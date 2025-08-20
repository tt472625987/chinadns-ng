#!/bin/sh

# chinadns-ng ipset 持久化与规则管理（宿主机执行）
# 作用：
# - 创建/保存/恢复 ipset 集合（chnip/gfwip/chnroute，IPv4/IPv6按需）
# - 创建/挂载 chinadns 专用 iptables 规则链（CHINADNS_CHN/CHINADNS_GFW）
# - 与 v2ray-tproxy 配置统一（FW_MARK、ENABLE_IPV6、ROUTE_TABLE）

# 读取统一配置（若存在）
[ -f /etc/v2ray-tproxy.conf ] && . /etc/v2ray-tproxy.conf
FWMARK_VALUE="${FW_MARK:-${MARK_VALUE:-0x1}}"
ENABLE_IPV6_EFFECTIVE="${ENABLE_IPV6:-0}"
ROUTE_TABLE_VALUE="${ROUTE_TABLE:-}" # 仅用于 status 展示

# 可选：为调试开启限速日志（0=关闭，1=开启）
LOG_CHINADNS="${LOG_CHINADNS:-0}"
LOG_PREFIX_CHN="[CHN]"
LOG_PREFIX_GFW="[GFW]"

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
	# 先销毁目标集合，避免 restore 时因已存在而失败
	for set in "$CHN_IPSET4" "$GFW_IPSET4" "$CHN_ROUTE4"; do
		ipset destroy "$set" 2>/dev/null || true
	done
	if [ -f "$IPSET_SAVE_FILE4" ]; then
		ipset restore < "$IPSET_SAVE_FILE4" 2>/dev/null && log_info "恢复 IPv4 集合成功" || log_warn "恢复 IPv4 集合失败"
	else
		log_warn "IPv4 集合备份文件不存在: $IPSET_SAVE_FILE4"
	fi
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ]; then
		for set in "$CHN_IPSET6" "$GFW_IPSET6" "$CHN_ROUTE6"; do
			ipset destroy "$set" 2>/dev/null || true
		done
		if [ -f "$IPSET_SAVE_FILE6" ]; then
			ipset restore < "$IPSET_SAVE_FILE6" 2>/dev/null && log_info "恢复 IPv6 集合成功" || log_warn "恢复 IPv6 集合失败"
		else
			log_warn "IPv6 集合备份文件不存在: $IPSET_SAVE_FILE6"
		fi
	fi
}

create_iptables_rules() {
	log_info "创建/刷新 iptables 规则..."
	# 幂等清理
	iptables -t mangle -D PREROUTING -j CHINADNS_CHN 2>/dev/null || true
	iptables -t mangle -D PREROUTING -j CHINADNS_GFW 2>/dev/null || true
	iptables -t mangle -F CHINADNS_CHN 2>/dev/null || true
	iptables -t mangle -X CHINADNS_CHN 2>/dev/null || true
	iptables -t mangle -F CHINADNS_GFW 2>/dev/null || true
	iptables -t mangle -X CHINADNS_GFW 2>/dev/null || true
	# CHN：国内直连
	iptables -t mangle -N CHINADNS_CHN 2>/dev/null || true
	iptables -t mangle -F CHINADNS_CHN
	if [ "$LOG_CHINADNS" = "1" ]; then
		iptables -t mangle -A CHINADNS_CHN -m limit --limit 5/min -j LOG --log-prefix "$LOG_PREFIX_CHN " --log-level 6 2>/dev/null || true
	fi
	iptables -t mangle -A CHINADNS_CHN -m set --match-set "$CHN_IPSET4" dst -j RETURN
	# GFW：国外打标（供 v2ray 使用）
	iptables -t mangle -N CHINADNS_GFW 2>/dev/null || true
	iptables -t mangle -F CHINADNS_GFW
	if [ "$LOG_CHINADNS" = "1" ]; then
		iptables -t mangle -A CHINADNS_GFW -m limit --limit 5/min -j LOG --log-prefix "$LOG_PREFIX_GFW " --log-level 6 2>/dev/null || true
	fi
	iptables -t mangle -A CHINADNS_GFW -m set --match-set "$GFW_IPSET4" dst -j MARK --set-mark "$FWMARK_VALUE"
	# 挂载到 PREROUTING（优先级高于 v2ray 规则）
	iptables -t mangle -I PREROUTING 1 -j CHINADNS_CHN
	iptables -t mangle -I PREROUTING 2 -j CHINADNS_GFW
	# IPv6 同步（按需）
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ] && command -v ip6tables >/dev/null 2>&1; then
		ip6tables -t mangle -D PREROUTING -j CHINADNS_CHN6 2>/dev/null || true
		ip6tables -t mangle -D PREROUTING -j CHINADNS_GFW6 2>/dev/null || true
		ip6tables -t mangle -F CHINADNS_CHN6 2>/dev/null || true
		ip6tables -t mangle -X CHINADNS_CHN6 2>/dev/null || true
		ip6tables -t mangle -F CHINADNS_GFW6 2>/dev/null || true
		ip6tables -t mangle -X CHINADNS_GFW6 2>/dev/null || true
		ip6tables -t mangle -N CHINADNS_CHN6 2>/dev/null || true
		ip6tables -t mangle -F CHINADNS_CHN6
		[ "$LOG_CHINADNS" = "1" ] && ip6tables -t mangle -A CHINADNS_CHN6 -m limit --limit 5/min -j LOG --log-prefix "$LOG_PREFIX_CHN " --log-level 6 2>/dev/null || true
		ip6tables -t mangle -A CHINADNS_CHN6 -m set --match-set "$CHN_IPSET6" dst -j RETURN
		ip6tables -t mangle -N CHINADNS_GFW6 2>/dev/null || true
		ip6tables -t mangle -F CHINADNS_GFW6
		[ "$LOG_CHINADNS" = "1" ] && ip6tables -t mangle -A CHINADNS_GFW6 -m limit --limit 5/min -j LOG --log-prefix "$LOG_PREFIX_GFW " --log-level 6 2>/dev/null || true
		ip6tables -t mangle -A CHINADNS_GFW6 -m set --match-set "$GFW_IPSET6" dst -j MARK --set-mark "$FWMARK_VALUE"
		ip6tables -t mangle -I PREROUTING 1 -j CHINADNS_CHN6
		ip6tables -t mangle -I PREROUTING 2 -j CHINADNS_GFW6
	fi
	log_info "iptables 规则创建完成"
}

save_iptables_rules() {
	log_info "保存 chinadns 相关 iptables 规则..."
	mkdir -p "$IPSET_SAVE_DIR"
	iptables-save -t mangle | grep -E '\bCHINADNS_(CHN|GFW)\b' > "$IPSET_SAVE_DIR/iptables-mangle.rules" 2>/dev/null || true
	log_info "iptables 规则保存完成"
}

show_status() {
	log_info "chinadns-ng ipset/iptables 状态:"
	echo "IPv4 集合:"
	for set in "$CHN_IPSET4" "$GFW_IPSET4" "$CHN_ROUTE4"; do
		if ipset list "$set" >/dev/null 2>&1; then
			count=$(ipset list "$set" | grep -c "^[0-9]" || echo "0")
			echo "  $set: $count 条目"
		else
			echo "  $set: 不存在"
		fi
	done
	if [ "$ENABLE_IPV6_EFFECTIVE" = "1" ]; then
		echo "IPv6 集合:"
		for set in "$CHN_IPSET6" "$GFW_IPSET6" "$CHN_ROUTE6"; do
			if ipset list "$set" >/dev/null 2>&1; then
				count=$(ipset list "$set" | grep -c "^[0-9]" || echo "0")
				echo "  $set: $count 条目"
			else
				echo "  $set: 不存在"
			fi
		done
	fi
	echo "PREROUTING (mangle) 前 10 条:"
	iptables -t mangle -S PREROUTING 2>/dev/null | sed -n '1,10p' || true
	echo "ip rule:"
	ip rule show || true
	if [ -n "$ROUTE_TABLE_VALUE" ]; then
		echo "ip route table $ROUTE_TABLE_VALUE:"
		ip route show table "$ROUTE_TABLE_VALUE" || true
	fi
}

main() {
	case "${1:-}" in
		create)
			check_deps && create_ipsets ;;
		save)
			check_deps && save_ipsets && save_iptables_rules ;;
		restore)
			check_deps && restore_ipsets && create_iptables_rules ;;
		status)
			check_deps && show_status ;;
		setup)
			check_deps && create_ipsets && create_iptables_rules && save_ipsets && save_iptables_rules ;;
		*)
			echo "用法: $0 {create|save|restore|status|setup}"
			echo "  create  - 创建 ipset 集合和 iptables 规则"
			echo "  save    - 保存当前集合与 chinadns 规则"
			echo "  restore - 从保存文件恢复集合并重新应用规则"
			echo "  status  - 显示集合/规则/路由状态"
			echo "  setup   - 一次性完成（create + 规则 + save）"
			exit 1 ;;
	esac
}

main "$@" 