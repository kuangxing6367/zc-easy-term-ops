#!/bin/bash
# ============================================================
# 文件：core/logger.sh
# 功能：日志/颜色/输出函数库 [Logger & Color Library]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：统一日志输出，格式 [时间] [级别] [模块] 内容，
#       彩色终端输出 + 文件落盘（/var/log/zetops/zetops.log）
# ============================================================
set -euo pipefail

# 日志目录与文件（可通过配置文件覆盖）
LOG_DIR="${LOG_DIR:-/var/log/zetops}"
LOG_FILE="${LOG_DIR}/zetops.log"
LOG_LEVEL="${LOG_LEVEL:-DEBUG}"   # DEBUG < INFO < WARNING < ERROR

# 当前模块短名（由 menu.sh 在调用模块前设置）
CURRENT_MODULE="${CURRENT_MODULE:-core}"

# ---- 颜色定义（tput，不支持时降级为无色） ----
if command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    # 注意：tput setaf 在 TERM=dumb/部分容器环境会失败，
    # 必须在 set -e 下容错（|| true），否则工具箱直接退出
    COLOR_RED=$(tput setaf 1 2>/dev/null || true)
    COLOR_GREEN=$(tput setaf 2 2>/dev/null || true)
    COLOR_YELLOW=$(tput setaf 3 2>/dev/null || true)
    COLOR_BLUE=$(tput setaf 4 2>/dev/null || true)
    COLOR_GRAY=$(tput setaf 8 2>/dev/null || true)
    COLOR_BOLD=$(tput bold 2>/dev/null || true)
    COLOR_RESET=$(tput sgr0 2>/dev/null || true)
else
    COLOR_RED=""; COLOR_GREEN=""; COLOR_YELLOW=""; COLOR_BLUE=""
    COLOR_GRAY=""; COLOR_BOLD=""; COLOR_RESET=""
fi

# ------------------------------------------------------------
# 初始化日志系统：创建日志目录与文件
# 参数：无
# 返回：无
# ------------------------------------------------------------
log_init() {
    if [[ ! -d "${LOG_DIR}" ]]; then
        mkdir -p "${LOG_DIR}" 2>/dev/null || true
    fi
    # 日志目录不可写时降级到 /tmp，保证工具可用
    if [[ ! -w "${LOG_DIR}" ]]; then
        LOG_DIR="/tmp/zetops"
        LOG_FILE="${LOG_DIR}/zetops.log"
        mkdir -p "${LOG_DIR}"
    fi
    : > /dev/null
    touch "${LOG_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 日志级别映射：字符串级别 -> 数字
# 参数：$1 级别字符串
# ------------------------------------------------------------
_log_level_num() {
    case "${1:-INFO}" in
        DEBUG)   echo 10 ;;
        INFO)    echo 20 ;;
        WARNING) echo 30 ;;
        ERROR)   echo 40 ;;
        *)       echo 20 ;;
    esac
}

# ------------------------------------------------------------
# 核心写入函数（内部使用）
# 参数：$1 级别  $2 消息
# 返回：无
# ------------------------------------------------------------
_log_write() {
    local level="$1"
    local message="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${ts}] [${level}] [${CURRENT_MODULE}] ${message}"

    # 级别过滤
    if (( $(_log_level_num "${level}") >= $(_log_level_num "${LOG_LEVEL}") )); then
        case "${level}" in
            INFO)    echo -e "${COLOR_BLUE}${line}${COLOR_RESET}" ;;
            SUCCESS) echo -e "${COLOR_GREEN}${line}${COLOR_RESET}" ;;
            WARNING) echo -e "${COLOR_YELLOW}${line}${COLOR_RESET}" ;;
            ERROR)   echo -e "${COLOR_RED}${line}${COLOR_RESET}" >&2 ;;
            DEBUG)   echo -e "${COLOR_GRAY}${line}${COLOR_RESET}" ;;
            *)       echo -e "${line}" ;;
        esac
    fi
    # 文件落盘（不带颜色）
    if [[ -w "${LOG_FILE}" ]]; then
        echo "${line}" >> "${LOG_FILE}"
    fi
}

# ---- 对外统一接口（只接收 1 个消息参数） ----
log_info()    { _log_write "INFO"    "$1"; }
log_success() { _log_write "SUCCESS" "$1"; }
log_warning() { _log_write "WARNING" "$1"; }
log_error()   { _log_write "ERROR"   "$1"; }
log_debug()   { _log_write "DEBUG"   "$1"; }
