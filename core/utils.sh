#!/bin/bash
# ============================================================
# 文件：core/utils.sh
# 功能：通用工具函数库（命令检查、输入校验、进度动画、系统探测）
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：被 core/main.sh 加载，供所有模块调用
# ============================================================
set -euo pipefail

# ------------------------------------------------------------
# 检查命令是否存在
# 参数：$1 命令名
# 返回：0=存在 1=不存在
# ------------------------------------------------------------
check_command() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1
}

# ------------------------------------------------------------
# 检查是否 root 权限（多数运维操作需要）
# 参数：无
# 返回：0=root 1=非root
# ------------------------------------------------------------
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "需要 root 权限运行，请使用 sudo"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# 探测发行版（Distro）名称（小写）
# 参数：无
# 输出：debian/ubuntu/centos/rhel/rocky/almalinux/fedora/...
# ------------------------------------------------------------
get_distro() {
    if [[ -f /etc/os-release ]]; then
        local id
        id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        echo "${id}"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------
# 探测系统架构（Architecture）
# 参数：无
# 输出：x86_64/aarch64/armv7l/...
# ------------------------------------------------------------
get_arch() {
    uname -m
}

# ------------------------------------------------------------
# 探测包管理器（Package Manager）
# 参数：无
# 输出：apt/dnf/yum/zypper/apk
# ------------------------------------------------------------
detect_pkg_manager() {
    if check_command apt-get; then echo "apt"
    elif check_command dnf; then echo "dnf"
    elif check_command yum; then echo "yum"
    elif check_command zypper; then echo "zypper"
    elif check_command apk; then echo "apk"
    else echo "unknown"; fi
}

# ------------------------------------------------------------
# 安装软件包（按包管理器自动适配）
# 参数：$@ 包名列表
# 返回：无
# ------------------------------------------------------------
install_pkg() {
    local pm
    pm=$(detect_pkg_manager)
    local pkgs=("$@")
    log_info "使用包管理器 ${pm} 安装: ${pkgs[*]}"
    case "${pm}" in
        apt)  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" ;;
        dnf)  dnf install -y "${pkgs[@]}" ;;
        yum)  yum install -y "${pkgs[@]}" ;;
        zypper) zypper --non-interactive install "${pkgs[@]}" ;;
        apk)  apk add --no-cache "${pkgs[@]}" ;;
        *)    log_error "不支持的包管理器: ${pm}" ;;
    esac
}

# ------------------------------------------------------------
# 判断软件包是否已安装
# 参数：$1 包名
# 返回：0=已安装 1=未安装
# ------------------------------------------------------------
is_installed() {
    local pkg="$1"
    case "$(detect_pkg_manager)" in
        apt)  dpkg -s "${pkg}" >/dev/null 2>&1 ;;
        dnf|yum) rpm -q "${pkg}" >/dev/null 2>&1 ;;
        zypper) rpm -q "${pkg}" >/dev/null 2>&1 ;;
        apk)  apk info -e "${pkg}" >/dev/null 2>&1 ;;
        *)    return 1 ;;
    esac
}

# ------------------------------------------------------------
# 校验 IPv4 地址
# 参数：$1 IP 字符串
# 返回：0=合法 1=非法
# ------------------------------------------------------------
validate_ip() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local octet
    for octet in ${ip//./ }; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

# ------------------------------------------------------------
# 校验端口号（1-65535）
# 参数：$1 端口字符串
# 返回：0=合法 1=非法
# ------------------------------------------------------------
validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

# ------------------------------------------------------------
# 校验路径（非空且以 / 开头）
# 参数：$1 路径字符串
# 返回：0=合法 1=非法
# ------------------------------------------------------------
validate_path() {
    local path="$1"
    [[ -n "${path}" && "${path}" == /* ]] || return 1
    return 0
}

# ------------------------------------------------------------
# 危险操作二次确认（输入 yes 或 CONFIRM）
# 参数：$1 危险操作描述
# 返回：0=确认 1=取消
# ------------------------------------------------------------
confirm_action() {
    local desc="$1"
    local ans
    log_warning "危险操作确认: ${desc}"
    echo -n "输入 yes 或 CONFIRM 以继续（其他输入取消）: "
    read -r ans || return 1
    if [[ "${ans}" == "yes" || "${ans}" == "CONFIRM" ]]; then
        return 0
    fi
    log_info "已取消操作"
    return 1
}

# ---- 旋转动画（Spinner）变量 ----
_SPIN_PID=""

# ------------------------------------------------------------
# 启动旋转动画（后台）
# 参数：$1 任务描述
# 返回：无（PID 存于全局 _SPIN_PID）
# ------------------------------------------------------------
show_spinner() {
    local desc="$1"
    local spin='|/-\'
    local i=0
    printf "%s " "${desc}"
    (
        while true; do
            printf "\b%s" "${spin:$((i % 4)):1}"
            i=$((i + 1))
            sleep 0.15
        done
    ) &
    _SPIN_PID=$!
}

# ------------------------------------------------------------
# 停止旋转动画
# 参数：无
# 返回：无
# ------------------------------------------------------------
stop_spinner() {
    if [[ -n "${_SPIN_PID}" ]]; then
        kill "${_SPIN_PID}" 2>/dev/null || true
        wait "${_SPIN_PID}" 2>/dev/null || true
        _SPIN_PID=""
        printf "\b \n"
    fi
}

# ------------------------------------------------------------
# 按下回车继续
# 参数：无
# 返回：无
# ------------------------------------------------------------
press_enter() {
    echo -n "按回车键继续... "
    read -r _ || true
}

# ------------------------------------------------------------
# 读取用户输入（带提示与默认值；非交互时直接用默认值）
# 参数：$1 变量名(引用)  $2 提示语  $3 默认值
# 返回：无（结果写入 $1）
# ------------------------------------------------------------
read_input() {
    local -n _var="$1"
    local prompt="$2"
    local default="${3:-}"
    if [[ ! -t 0 ]]; then
        _var="${default}"
        return 0
    fi
    if [[ -n "${default}" ]]; then
        echo -n "${prompt} [${default}]: "
    else
        echo -n "${prompt}: "
    fi
    local ans
    read -r ans || ans="${default}"
    _var="${ans:-${default}}"
}
