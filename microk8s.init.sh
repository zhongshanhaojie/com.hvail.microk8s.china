#!/bin/bash

# MicroK8s 自动安装和配置脚本
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_warn "正在以root用户运行"
    else
        log_error "请使用sudo运行此脚本"
        exit 1
    fi
}

# 安装 MicroK8s
install_microk8s() {
    log_step "1. 安装 MicroK8s..."
    snap install microk8s --classic
    
    microk8s status --wait-ready
}

# 镜像恢复功能
download_images() {
    local mapping_file=$1
    
    log_step "2. 下载镜像..."
    
    # Check if the restore script exists
    if [ ! -f "restore-images-microk8s-aliyun.sh" ]; then
        log_error "镜像恢复脚本 restore-images-microk8s-aliyun.sh 不存在"
        return 1
    fi
    
    # If no mapping file provided, try to find the most recent one
    if [ -z "$mapping_file" ]; then
        mapping_file=$(ls image-mapping-*.txt 2>/dev/null | sort | tail -1)
        
        if [ -z "$mapping_file" ]; then
            log_warn "未找到镜像映射文件，跳过镜像下载"
            return 0
        fi
        
        log_info "自动选择映射文件: $mapping_file"
    else
        # Check if the provided mapping file exists
        if [ ! -f "$mapping_file" ]; then
            log_error "镜像映射文件不存在: $mapping_file"
            return 1
        fi
        log_info "使用指定映射文件: $mapping_file"
    fi
    
    # Execute the image download script with mapping file
    log_info "执行镜像下载脚本..."
    sh ./restore-images-microk8s-aliyun.sh "$mapping_file"
    
    # Check if the script executed successfully
    if [ $? -ne 0 ]; then
        log_error "镜像下载脚本执行失败"
        return 1
    fi
    
    # Check MicroK8s status after image download
    log_info "检查 MicroK8s 状态..."
    microk8s status --wait-ready
    
    # List downloaded images
    log_info "已下载的镜像列表:"
    microk8s ctr images ls
}

# 设置网段
set_network_cidr() {
    local setting_cidr=$1
    log_step "3. 设置网段..."

    # Check if the set script exists
    if [ ! -f "set-microk8s-clusterip.sh" ]; then
        log_error "CIDR设置 set-microk8s-clusterip.sh 不存在"
        return 1
    fi

    # If no mapping file provided, try to find the most recent one
    if [ -z "$setting_cidr" ]; then
        log_warn "未找到CIDR设置, 跳过CIDR"
        return 0
    else
        # Check if the provided mapping file exists
        if [ ! -f "$setting_cidr" ]; then
            log_error "cidr不存在: $setting_cidr"
            return 1
        fi
        log_info "使用指定 CIDR : $setting_cidr"
    fi
    
    log_info "执行CIDR设置..."
    sh ./set-microk8s-clusterip.sh "$setting_cidr"
    
    # Check if the script executed successfully
    if [ $? -ne 0 ]; then
        log_error "CIDR设置执行失败"
        return 1
    fi
}

# 基础状态检查
basic_checks() {
    log_step "4. 执行基础状态检查..."
    
    log_info "检查 MicroK8s 状态..."
    microk8s status
    
    log_info "检查节点状态..."
    microk8s kubectl get nodes -o wide
    
    log_info "检查所有命名空间的 Pod..."
    microk8s kubectl get pods --all-namespaces
    
    log_info "检查服务..."
    microk8s services
}

# 启用必要插件
enable_addons() {
    log_step "5. 启用必要插件..."
    
    log_info "启用 DNS..."
    microk8s enable dns
    
    log_info "启用 Dashboard..."
    microk8s enable dashboard
    
    log_info "等待插件就绪..."
    sleep 30
}

# 重启核心部署
restart_core_deployments() {
    log_step "6. 重启核心部署..."
    
    log_info "重启 CoreDNS..."
    microk8s kubectl rollout restart deployment/coredns -n kube-system
    
    log_info "重启 Calico 控制器..."
    microk8s kubectl rollout restart deployment/calico-kube-controllers -n kube-system
    
    log_info "重启 Dashboard 指标收集器..."
    microk8s kubectl rollout restart deployment/dashboard-metrics-scraper -n kube-system
}

# 检查部署状态
check_deployments() {
    log_step "7. 检查部署状态..."
    
    log_info "所有命名空间的部署:"
    microk8s kubectl get deployments --all-namespaces
    
    log_info "所有命名空间的 Pod:"
    microk8s kubectl get pods --all-namespaces
    
    log_info "检查事件:"
    microk8s kubectl get events --all-namespaces --sort-by='.lastTimestamp' | head -20
}

# 故障排查函数
troubleshoot() {
    log_step "故障排查..."
    
    log_info "检查 CoreDNS Pod..."
    microk8s kubectl get pods -n kube-system | grep coredns
    
    log_info "检查 Calico Pod..."
    microk8s kubectl get pods -n kube-system | grep calico
    
    log_info "检查 Dashboard 服务..."
    microk8s kubectl get svc -n kube-system kubernetes-dashboard
    
    log_info "检查节点详情..."
    microk8s kubectl describe nodes
}

# 主函数
main() {
    log_step "开始 MicroK8s 安装和配置..."
    
    check_root
    
    # 安装和基础配置
    install_microk8s

    download_images "$1"

    set_network_cidr "$2"

    basic_checks
    
    # 启用插件
    enable_addons
    
    # 如果有镜像映射文件，恢复镜像
    if [ $# -eq 1 ]; then
        restore_images "$1"
    fi
    
    # 重启部署
    restart_core_deployments
    
    # 最终检查
    check_deployments
    troubleshoot
    
    log_step "安装完成!"
    log_info "可以使用以下命令访问 Dashboard:"
    echo "microk8s kubectl get svc -n kube-system kubernetes-dashboard"
    echo "microk8s dashboard-proxy"
}

# 使用说明
usage() {
    echo "用法: $0 [镜像映射文件]"
    echo "示例:"
    echo "  $0                          # 仅安装和配置"
    echo "  $0 image-mapping-xxx.txt    # 安装配置并恢复镜像"
}

# 脚本入口
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

main "$@"