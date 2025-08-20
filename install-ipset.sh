#!/bin/sh

# chinadns-ng ipset 持久化系统安装脚本
# 用于在 IstoreOS/OpenWrt 系统上安装 ipset 持久化功能

# 配置
INSTALL_DIR="/etc/chinadns-ng/ipset"
INIT_SCRIPT="/etc/init.d/ipset-restore"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "需要 root 权限运行此脚本"
        exit 1
    fi
}

# 检查依赖
check_deps() {
    log_info "检查系统依赖..."
    
    for cmd in ipset iptables; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_err "缺少命令: $cmd"
            exit 1
        fi
    done
    
    log_ok "依赖检查完成"
}

# 安装文件
install_files() {
    log_info "安装 ipset 持久化文件..."
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    
    # 复制 ipset-persist.sh
    if [ -f "./ipset-persist.sh" ]; then
        cp -f "./ipset-persist.sh" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/ipset-persist.sh"
        log_ok "安装 ipset-persist.sh"
    else
        log_err "未找到 ipset-persist.sh"
        exit 1
    fi
    
    # 安装 init 脚本
    if [ -f "./ipset-restore.init" ]; then
        cp -f "./ipset-restore.init" "$INIT_SCRIPT"
        chmod +x "$INIT_SCRIPT"
        log_ok "安装 init 脚本"
    else
        log_warn "未找到 init 脚本，跳过"
    fi
    
    # 创建持久化目录
    mkdir -p "$INSTALL_DIR"
    log_ok "创建持久化目录"
}

# 启用服务
enable_service() {
    log_info "启用 ipset 恢复服务..."
    
    if [ -f "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" enable
        log_ok "启用 ipset-restore 服务"
    else
        log_warn "init 脚本不存在，无法启用服务"
    fi
}

# 测试功能
test_function() {
    log_info "测试 ipset 功能..."
    
    # 创建测试集合
    if ipset create -exist test_set hash:ip family inet hashsize 1024 maxelem 100 2>/dev/null; then
        ipset add test_set 1.1.1.1 2>/dev/null
        ipset destroy test_set 2>/dev/null
        log_ok "ipset 功能正常"
    else
        log_err "ipset 功能异常"
        return 1
    fi
}

# 显示使用说明
show_usage() {
    echo
    log_info "安装完成！使用说明："
    echo
    echo "1. 手动操作："
    echo "   $INSTALL_DIR/ipset-persist.sh create  # 创建 ipset 集合和规则"
    echo "   $INSTALL_DIR/ipset-persist.sh save    # 保存当前配置"
    echo "   $INSTALL_DIR/ipset-persist.sh restore # 恢复保存的配置"
    echo "   $INSTALL_DIR/ipset-persist.sh status  # 显示当前状态"
    echo "   $INSTALL_DIR/ipset-persist.sh setup   # 完整设置"
    echo
    echo "2. 自动恢复："
    echo "   系统重启后会自动恢复 ipset 集合"
    echo
    echo "3. 与 chinadns-ng 集成："
    echo "   确保 chinadns-ng 启动后运行："
    echo "   $INSTALL_DIR/ipset-persist.sh setup"
    echo
    echo "4. 与 v2ray-tproxy 集成："
    echo "   在 chinadns-ng 启动后，运行 v2ray-tproxy 安装脚本"
    echo
}

# 主函数
main() {
    log_info "开始安装 chinadns-ng ipset 持久化系统..."
    
    check_root
    check_deps
    install_files
    enable_service
    test_function
    
    if [ $? -eq 0 ]; then
        log_ok "安装成功！"
        show_usage
    else
        log_err "安装过程中出现问题，请检查日志"
        exit 1
    fi
}

# 运行主函数
main "$@" 