#!/bin/bash

# mirror-images-single-repo.sh - 单仓库镜像下载和推送脚本
# 用法: ./mirror-images-single-repo.sh <镜像列表文件> <目标仓库地址>

set -e

# 参数检查
if [ $# -ne 2 ]; then
    echo "用法: $0 <镜像列表文件> <目标仓库地址>"
    echo "示例: $0 images.txt myregistry.com/mirror"
    exit 1
fi

IMAGE_LIST_FILE="$1"
TARGET_REGISTRY="$2"
MAPPING_FILE="image-mapping-$(date +%Y%m%d-%H%M).txt"

# 检查依赖命令
command -v docker >/dev/null 2>&1 || { echo "错误: 需要安装 docker"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "错误: 需要安装 jq"; exit 1; }

# 检查镜像列表文件
if [ ! -f "$IMAGE_LIST_FILE" ]; then
    echo "错误: 镜像列表文件 $IMAGE_LIST_FILE 不存在"
    exit 1
fi

echo "开始处理镜像到单仓库..."
echo "目标仓库: $TARGET_REGISTRY"
echo "映射文件: $MAPPING_FILE"
echo "=========================================="

# 创建映射文件头
echo "# 单仓库镜像映射文件 - 生成时间: $(date)" > "$MAPPING_FILE"
echo "# 格式: 原镜像名,目标tag名,原标签,目标仓库,摘要" >> "$MAPPING_FILE"

# 计数器
success_count=0
fail_count=0

# 处理每个镜像
while IFS= read -r source_image; do
    # 跳过空行和注释行（以#开头的行）
    if [ -z "$source_image" ]; then
        continue
    fi
    if [ "$(echo "$source_image" | cut -c1)" = "#" ]; then
        continue
    fi
    
    echo "处理镜像: $source_image"
    
    # 解析镜像名和标签
    if echo "$source_image" | grep -q ":"; then
        image_name=$(echo "$source_image" | cut -d: -f1)
        image_tag=$(echo "$source_image" | cut -d: -f2)
    else
        image_name="$source_image"
        image_tag="latest"
    fi
    
    # 生成唯一的目标 tag 名称（使用编码后的镜像路径）
    # 替换 / 为 -，: 为 _，避免特殊字符
    encoded_name=$(echo "$image_name" | sed 's|/|--|g' | sed 's|:|__|g' | tr '[:upper:]' '[:lower:]')
    target_tag_name="${encoded_name}--${image_tag}"
    
    # 完整的源和目标镜像名
    source_full="$image_name:$image_tag"
    target_full="$TARGET_REGISTRY:$target_tag_name"
    
    echo "源镜像: $source_full"
    echo "目标镜像: $target_full"
    
    # 下载镜像
    if docker pull "$source_full"; then
        # 获取镜像摘要
        image_digest=$(docker inspect "$source_full" | jq -r '.[0].RepoDigests[0]' | cut -d'@' -f2)
        
        # 重新打标签
        if docker tag "$source_full" "$target_full"; then
            # 推送到目标仓库
            if docker push "$target_full"; then
                # 记录到映射文件
                echo "$source_full,$target_tag_name,$image_tag,$TARGET_REGISTRY,$image_digest" >> "$MAPPING_FILE"
                echo "✓ 成功推送: $target_full"
                success_count=$((success_count + 1))
                
                # 清理本地镜像
                docker rmi "$source_full" "$target_full" 2>/dev/null || true
            else
                echo "✗ 推送失败: $target_full"
                fail_count=$((fail_count + 1))
            fi
        else
            echo "✗ 打标签失败: $target_full"
            fail_count=$((fail_count + 1))
        fi
    else
        echo "✗ 下载失败: $source_full"
        fail_count=$((fail_count + 1))
    fi
    
    echo "------------------------------------------"
done < "$IMAGE_LIST_FILE"

echo "=========================================="
echo "处理完成!"
echo "成功: $success_count, 失败: $fail_count"
echo "映射文件: $MAPPING_FILE"

# 显示生成的 tag 命名规则
echo ""
echo "Tag 命名规则示例:"
echo "原镜像: docker.io/calico/node:v3.28.1"
echo "目标Tag: docker.io--calico--node--v3.28.1"
echo "完整目标: $TARGET_REGISTRY:docker.io--calico--node--v3.28.1"
