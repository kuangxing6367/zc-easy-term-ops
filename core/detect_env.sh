#!/bin/bash
# ============================================================
# 文件：core/detect_env.sh
# 功能：环境检测函数库 [Environment Detection Library]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：容器/LXC/WSL/虚拟化/架构/安全环境检测，
#       部分命令在容器或 WSL 下行为不同，模块可据此适配
# ============================================================
set -euo pipefail

# ------------------------------------------------------------
# 检测是否运行在容器内（Docker/LXC/containerd...）
# 参数：无
# 返回：0=容器内 1=物理机/虚拟机
# ------------------------------------------------------------
is_container() {
    [[ -f /.dockerenv ]] && return 0
    [[ -f /run/.containerenv ]] && return 0
    # cgroup 第一层路径含 docker/kubepods/containerd/lxc
    if [[ -r /proc/1/cgroup ]]; then
        if grep -qE '/(docker|kubepods|containerd|lxc|libpod)/' /proc/1/cgroup 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------
# 检测是否运行在 WSL（Windows Subsystem for Linux）
# 参数：无
# 返回：0=WSL 1=非WSL
# ------------------------------------------------------------
is_wsl() {
    [[ -r /proc/version ]] && grep -qi "microsoft" /proc/version
}

# ------------------------------------------------------------
# 检测虚拟化平台
# 参数：无
# 输出：kvm/xen/vmware/virtualbox/none/unknown
# ------------------------------------------------------------
detect_virt() {
    if check_command systemd-detect-virt; then
        systemd-detect-virt 2>/dev/null || echo "none"
        return
    fi
    # 回退：检查 /proc/cpuinfo hypervisor 标志
    if grep -qi "hypervisor" /proc/cpuinfo 2>/dev/null; then
        echo "vm"
    else
        echo "none"
    fi
}

# ------------------------------------------------------------
# 检测运行环境类型
# 参数：无
# 输出：container/wsl/vm/baremetal
# ------------------------------------------------------------
detect_env_type() {
    is_container && { echo "container"; return; }
    is_wsl && { echo "wsl"; return; }
    local virt
    virt=$(detect_virt)
    [[ "${virt}" != "none" && "${virt}" != "unknown" ]] && { echo "vm"; return; }
    echo "baremetal"
}

# ------------------------------------------------------------
# 汇总展示环境信息（供 health/诊断模块使用）
# 参数：无
# 输出：多行环境信息
# ------------------------------------------------------------
show_env_info() {
    echo "环境类型: $(detect_env_type)"
    echo "发行版:   $(get_distro)"
    echo "内核:     $(uname -r)"
    echo "架构:     $(get_arch)"
    echo "虚拟化:   $(detect_virt)"
    echo "包管理:   $(detect_pkg_manager)"
    if is_container; then
        echo "容器:     是"
    else
        echo "容器:     否"
    fi
    if is_wsl; then
        echo "WSL:      是（部分命令行为与原生 Linux 不同）"
    fi
}

# 仅在独立执行时输出（被 main.sh source 时不输出）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # shellcheck source=/dev/null
    source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/logger.sh"
    # shellcheck source=/dev/null
    source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/utils.sh"
    show_env_info
fi
