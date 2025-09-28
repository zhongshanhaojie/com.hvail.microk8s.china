#!/bin/bash

# restore-images-microk8s-aliyun.sh - 阿里云镜像还原脚本

set -e

if [ $# -lt 1 ]; then
    echo "用法: $0 <映射文件> [用户名] [密码]"
    echo "示例: $0 image-mapping-20231201-120000.txt"
    echo "示例: $0 image-mapping-20231201-120000.txt username password"
    exit 1
fi

MAPPING_FILE="$1"
USERNAME="$2"
PASSWORD="$3"

command -v microk8s >/dev/null 2>&1 || { echo "错误: 需要安装 microk8s"; exit 1; }

if [ ! -f "$MAPPING_FILE" ]; then
    echo "错误: 映射文件 $MAPPING_FILE 不存在"
    exit 1
fi

echo "开始从阿里云仓库还原镜像..."
echo "映射文件: $MAPPING_FILE"

# 从映射文件获取仓库地址
SOURCE_REGISTRY=$(grep -v "^#" "$MAPPING_FILE" | head -1 | cut -d',' -f4)
REGISTRY_HOST=$(echo "$SOURCE_REGISTRY" | cut -d'/' -f1)

echo "源仓库: $SOURCE_REGISTRY"
echo "仓库主机: $REGISTRY_HOST"

# 配置认证（如果提供了用户名密码）
if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
    echo "配置阿里云认证..."
    
    # 创建临时认证脚本
    cat > /tmp/configure_auth.sh << 'EOF'
#!/bin/bash
REGISTRY_HOST="$1"
USERNAME="$2"
PASSWORD="$3"

sudo mkdir -p /var/snap/microk8s/current/args/certs.d/$REGISTRY_HOST

sudo tee /var/snap/microk8s/current/args/certs.d/$REGISTRY_HOST/hosts.toml > /dev/null <<CONF
server = "https://$REGISTRY_HOST"

[host."https://$REGISTRY_HOST"]
  capabilities = ["pull", "resolve"]
  skip_verify = false
  timeout = 30
  
  [host."https://$REGISTRY_HOST".auth]
    username = "$USERNAME"
    password = "$PASSWORD"
CONF

sudo systemctl restart snap.microk8s.daemon-containerd
sleep 10
EOF

    chmod +x /tmp/configure_auth.sh
    /tmp/configure_auth.sh "$REGISTRY_HOST" "$USERNAME" "$PASSWORD"
    rm -f /tmp/configure_auth.sh
    echo "认证配置完成"
else
    echo "未提供认证信息，尝试匿名拉取"
fi

echo "=========================================="

success_count=0
fail_count=0

while IFS=, read -r source_image target_tag_name original_tag registry digest; do
    if [ -z "$source_image" ] || [ "$(echo "$source_image" | cut -c1)" = "#" ]; then
        continue
    fi

    full_target_image="$registry:$target_tag_name"
    
    echo "还原: $full_target_image -> $source_image"
    
    # 尝试拉取镜像
    if sudo microk8s ctr image pull "$full_target_image" --platform linux/amd64; then
        if sudo microk8s ctr image tag "$full_target_image" "$source_image"; then
            echo "✓ 成功还原: $source_image"
            success_count=$((success_count + 1))
            
            # 清理中间镜像
            sudo microk8s ctr image remove "$full_target_image" 2>/dev/null || true
        else
            echo "✗ 打标签失败: $source_image"
            fail_count=$((fail_count + 1))
        fi
    else
        echo "✗ 拉取失败: $full_target_image"
        
        # 显示详细的错误信息
        echo "调试信息:"
        sudo microk8s ctr image pull "$full_target_image" --platform linux/amd64 2>&1 | tail -5
        fail_count=$((fail_count + 1))
    fi
    
    echo "------------------------------------------"
done < "$MAPPING_FILE"

echo "=========================================="
echo "还原完成!"
echo "成功: $success_count, 失败: $fail_count"

# 显示镜像列表
echo ""
echo "MicroK8s 中的镜像列表:"
sudo microk8s ctr images list | grep -v "sha256:" | head -20