#!/bin/bash
# ============================================================
# 文件：core/config.sh
# 功能：配置文件加载与读取接口 + API 节点接口
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：
#   - 用户配置：~/.zetops/zetops.conf
#   - API 配置：~/.zetops/api.conf（外部数据统一从 API 获取）
# ============================================================
set -euo pipefail

# 配置目录与文件
CONFIG_DIR="${CONFIG_DIR:-${HOME}/.zetops}"
CONFIG_FILE="${CONFIG_DIR}/zetops.conf"
API_CONF_FILE="${CONFIG_DIR}/api.conf"

# 默认配置值（config 模板字段，未配置时生效）
LOG_DIR="${LOG_DIR:-/var/log/zetops}"
BACKUP_DIR="${BACKUP_DIR:-/data/backup}"
DATA_DIR="${DATA_DIR:-/data}"
MYSQL_VERSION="${MYSQL_VERSION:-8.0}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/data/mysql}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-docker.io}"

# ---- 工具箱版本与更新源配置（自我更新模块使用） ----
# 工具箱整体版本号（升级时由自我更新模块自动更新）
ZETOPS_VERSION="${ZETOPS_VERSION:-1.2.0}"
# GitHub 仓库地址（自我更新拉取来源）
ZETOPS_REPO_URL="${ZETOPS_REPO_URL:-https://github.com/kuangxing6367/zc-easy-term-ops.git}"
# 更新分支
ZETOPS_UPDATE_BRANCH="${ZETOPS_UPDATE_BRANCH:-main}"
# GitHub 加速镜像前缀（国内加速，如 https://ghfast.top/ ；留空=直连 GitHub）
ZETOPS_GITHUB_MIRROR="${ZETOPS_GITHUB_MIRROR:-}"

# API 节点配置
API_BASE_URL=""
API_TIMEOUT=10

# ------------------------------------------------------------
# 加载用户配置文件（存在则 source，不存在使用默认值）
# 参数：无
# 返回：无
# ------------------------------------------------------------
load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
        log_debug "已加载配置 ${CONFIG_FILE}"
    else
        log_debug "未找到配置文件，使用默认值（首次运行请执行 install.sh 初始化）"
    fi
}

# ------------------------------------------------------------
# 从配置文件读取键值
# 参数：$1 键名  $2 默认值
# 输出：值
# 返回：无
# ------------------------------------------------------------
get_config_value() {
    local key="$1"
    local default="${2:-}"
    local val=""
    if [[ -f "${CONFIG_FILE}" ]] && grep -qE "^[[:space:]]*${key}=" "${CONFIG_FILE}"; then
        val=$(grep -E "^[[:space:]]*${key}=" "${CONFIG_FILE}" | head -n1 | cut -d= -f2- | tr -d '"' | xargs)
    fi
    echo "${val:-${default}}"
}

# ------------------------------------------------------------
# 加载 API 节点配置（~/.zetops/api.conf）
# 内容示例：
#   API_BASE_URL="https://your.api.node/v1"
#   API_TIMEOUT=10
# 参数：无
# 返回：无
# ------------------------------------------------------------
load_api_config() {
    if [[ -f "${API_CONF_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${API_CONF_FILE}"
        API_TIMEOUT="${API_TIMEOUT:-10}"
        log_debug "已加载 API 配置 ${API_CONF_FILE}"
    else
        API_BASE_URL=""
        API_TIMEOUT=10
        log_warning "未配置 API 节点（~/.zetops/api.conf），将使用内置默认源"
    fi
}

# ------------------------------------------------------------
# 从 API 节点获取外部数据（镜像源/NTP/安装脚本/配置模板）
# 参数：$1 路径（相对 API_BASE_URL）
# 输出：响应正文（失败时为空）
# 返回：无
# ------------------------------------------------------------
api_fetch() {
    local path="$1"
    if [[ -z "${API_BASE_URL}" ]]; then
        return 0
    fi
    if ! check_command curl; then
        log_warning "缺少 curl，无法请求 API 节点"
        return 0
    fi
    curl -s --max-time "${API_TIMEOUT}" "${API_BASE_URL%/}/${path}" 2>/dev/null || true
}
