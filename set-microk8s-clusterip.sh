#!/bin/bash

# 设置 MicroK8s ClusterIP 子网脚本
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 sudo 运行此脚本"
        exit 1
    fi
}

# 显示当前配置
show_current_config() {
    log_step "当前 ClusterIP 子网配置:"
    
    local api_server_config="/var/snap/microk8s/current/args/kube-apiserver"
    if [ -f "$api_server_config" ]; then
        local current_cidr=$(grep "service-cluster-ip-range" "$api_server_config" | awk -F'=' '{print $2}')
        if [ -n "$current_cidr" ]; then
            log_info "当前 Service ClusterIP 子网: $current_cidr"
        else
            log_warn "未找到当前的 service-cluster-ip-range 配置"
        fi
    fi
    
    log_info "当前服务列表:"
    microk8s kubectl get svc --all-namespaces | head -10
}

# 验证 CIDR 格式
validate_cidr() {
    local cidr=$1
    if [[ ! "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        log_error "CIDR 格式错误: $cidr"
        log_info "正确格式示例: 10.96.0.0/16, 172.16.0.0/16, 192.168.0.0/16"
        return 1
    fi
    return 0
}

# 设置 ClusterIP 子网
set_clusterip_subnet() {
    local new_cidr=$1
    
    if [ -z "$new_cidr" ]; then
        log_error "请提供新的 ClusterIP 子网"
        echo "用法: $0 <clusterip-cidr>"
        echo "示例: $0 10.96.0.0/16"
        exit 1
    fi
    
    # 验证 CIDR 格式
    if ! validate_cidr "$new_cidr"; then
        exit 1
    fi
    
    log_step "开始设置 ClusterIP 子网为: $new_cidr"
    
    # 显示当前配置
    show_current_config
    
    log_info "停止 MicroK8s..."
    microk8s stop
    
    # 备份配置文件
    local api_server_config="/var/snap/microk8s/current/args/kube-apiserver"
    local backup_file="${api_server_config}.backup.$(date +%Y%m%d%H%M%S)"
    
    log_info "备份配置文件: $backup_file"
    cp "$api_server_config" "$backup_file"
    
    # 修改配置
    log_info "修改 kube-apiserver 配置..."
    
    if grep -q "service-cluster-ip-range" "$api_server_config"; then
        # 替换现有的配置
        sed -i "s|--service-cluster-ip-range=.*|--service-cluster-ip-range=$new_cidr|" "$api_server_config"
    else
        # 添加新的配置
        echo "--service-cluster-ip-range=$new_cidr" >> "$api_server_config"
    fi
    
    # 验证修改
    log_info "验证配置修改..."
    local updated_cidr=$(grep "service-cluster-ip-range" "$api_server_config" | awk -F'=' '{print $2}')
    if [ "$updated_cidr" = "$new_cidr" ]; then
        log_info "✓ 配置修改成功"
    else
        log_error "✗ 配置修改失败"
        exit 1
    fi
    
    # 清理旧的 etcd 数据（可选，如果需要彻底重置）
    if [ "${2:-}" = "reset" ]; then
        log_warn "重置模式：清理旧的网络数据..."
        rm -rf /var/snap/microk8s/common/var/lib/etcd/*
    fi
    
    log_info "启动 MicroK8s..."
    microk8s start
    
    log_info "等待 MicroK8s 就绪..."
    microk8s status --wait-ready
    
    # 重启 CoreDNS 以确保使用新的网络配置
    log_info "重启 CoreDNS..."
    microk8s kubectl rollout restart deployment/coredns -n kube-system
    microk8s kubectl rollout status deployment/coredns -n kube-system --timeout=60s
}

# 验证新配置
verify_new_config() {
    log_step "验证新的 ClusterIP 配置..."
    
    # 检查配置文件中设置的值
    local api_server_config="/var/snap/microk8s/current/args/kube-apiserver"
    local configured_cidr=$(grep "service-cluster-ip-range" "$api_server_config" | awk -F'=' '{print $2}')
    log_info "配置文件中设置的 ClusterIP 子网: $configured_cidr"
    
    # 创建测试服务来验证
    log_info "创建测试服务验证新配置..."
    
    microk8s kubectl create namespace test-clusterip --dry-run=client -o yaml | microk8s kubectl apply -f -
    
    cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-clusterip-service
  namespace: test-clusterip
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: test
EOF
    
    # 获取测试服务的 ClusterIP
    local test_ip=$(microk8s kubectl get svc test-clusterip-service -n test-clusterip -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    
    if [ -n "$test_ip" ]; then
        log_info "测试服务 ClusterIP: $test_ip"
        log_info "✓ 新的 ClusterIP 子网工作正常"
    else
        log_warn "无法获取测试服务的 ClusterIP"
    fi
    
    # 清理测试资源
    microk8s kubectl delete namespace test-clusterip --ignore-not-found=true
    
    log_info "当前所有服务的 ClusterIP:"
    microk8s kubectl get svc --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLUSTER-IP:.spec.clusterIP | head -15
}

# 重置为默认配置
reset_to_default() {
    log_step "重置为默认 ClusterIP 子网..."
    
    local default_cidr="10.152.183.0/24"
    
    log_info "停止 MicroK8s..."
    microk8s stop
    
    local api_server_config="/var/snap/microk8s/current/args/kube-apiserver"
    
    if grep -q "service-cluster-ip-range" "$api_server_config"; then
        sed -i "s|--service-cluster-ip-range=.*|--service-cluster-ip-range=$default_cidr|" "$api_server_config"
    else
        echo "--service-cluster-ip-range=$default_cidr" >> "$api_server_config"
    fi
    
    log_info "启动 MicroK8s..."
    microk8s start
    microk8s status --wait-ready
    
    log_info "重置完成，当前 ClusterIP 子网: $default_cidr"
}

# 主函数
main() {
    check_root
    
    case "${1:-}" in
        "show")
            show_current_config
            ;;
        "reset")
            reset_to_default
            verify_new_config
            ;;
        "verify")
            verify_new_config
            ;;
        *)
            if [ $# -eq 1 ]; then
                show_current_config
                echo
                set_clusterip_subnet "$1"
                verify_new_config
            else
                echo "用法: $0 <clusterip-cidr>"
                echo "示例: $0 10.96.0.0/16"
                echo ""
                echo "其他命令:"
                echo "  $0 show     # 显示当前配置"
                echo "  $0 reset    # 重置为默认配置"
                echo "  $0 verify   # 验证配置"
                echo ""
                echo "常用的 ClusterIP 子网:"
                echo "  10.96.0.0/16     # 常见选择"
                echo "  172.16.0.0/16    # 私有网络"
                echo "  192.168.0.0/16   # 家庭网络"
                echo "  10.152.183.0/24  # MicroK8s 默认"
                exit 1
            fi
            ;;
    esac
}

# 脚本入口
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    main
    exit 0
fi

main "$@"