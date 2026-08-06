#!/bin/bash
# ============================================================
# 文件：modules/15_hardware_info.sh
# 功能：硬件信息汇总 [Hardware Info Collector]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：CPU/内存/磁盘/网卡/PCI/系统 一键汇总，纯命令组合零依赖，
#       所有子命令带 || true 容错，缺工具自动降级提示
# ============================================================
set -euo pipefail

module_name="硬件信息查看"
module_short="hardware_info"
module_version="1.0.0"

module_description() {
    echo "CPU/内存/磁盘/网卡/PCI 硬件信息一键汇总 [Hardware Info]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 一键汇总（全部硬件信息）"
    echo " 2. CPU 信息"
    echo " 3. 内存信息"
    echo " 4. 磁盘信息"
    echo " 5. 网卡信息"
    echo " 6. PCI 设备"
    echo " 7. 系统信息"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) hw_show_all ;;
        2) hw_show_cpu ;;
        3) hw_show_memory ;;
        4) hw_show_disk ;;
        5) hw_show_net ;;
        6) hw_show_pci ;;
        7) hw_show_system ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 分区渲染工具（打印标题与内容）
# 参数：$1 标题  $2 内容
# ------------------------------------------------------------
hw_section() {
    local title="$1"
    local content="$2"
    echo ""
    echo "${COLOR_BOLD}${COLOR_BLUE}===== ${title} =====${COLOR_RESET}"
    if [[ -n "${content}" ]]; then
        echo -e "${content}" | sed 's/^/  /'
    else
        echo "  ${COLOR_GRAY}(无数据或缺少工具)${COLOR_RESET}"
    fi
}

# ------------------------------------------------------------
# 一键汇总
# ------------------------------------------------------------
hw_show_all() {
    hw_show_system
    hw_show_cpu
    hw_show_memory
    hw_show_disk
    hw_show_net
    hw_show_pci
}

# ------------------------------------------------------------
# CPU 信息
# ------------------------------------------------------------
hw_show_cpu() {
    local info=""
    if check_command lscpu; then
        info=$(lscpu 2>/dev/null | grep -E '^CPU\(s\)|^Model name|^Architecture|^CPU MHz|^CPU max MHz|^Socket|^Core|^Thread|^Vendor|^Flags:' | head -12 || true)
    else
        info="型号: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo '未知')"
        info+="\n核心数: $(nproc 2>/dev/null || echo '?')"
    fi
    hw_section "CPU 信息" "${info}"
}

# ------------------------------------------------------------
# 内存信息
# ------------------------------------------------------------
hw_show_memory() {
    local info=""
    if check_command free; then
        info=$(free -h 2>/dev/null | head -3 || true)
    fi
    if check_command dmidecode && [[ -r /dev/mem ]]; then
        local mem_type mem_size
        mem_type=$(dmidecode -t memory 2>/dev/null | grep -m1 'Type:' | awk '{print $2}' || true)
        mem_size=$(dmidecode -t memory 2>/dev/null | grep -m1 'Maximum Capacity' | awk -F: '{print $2}' | xargs || true)
        info+="\n内存类型: ${mem_type:-未知}  最大容量: ${mem_size:-未知}"
    fi
    hw_section "内存信息" "${info}"
}

# ------------------------------------------------------------
# 磁盘信息
# ------------------------------------------------------------
hw_show_disk() {
    local info=""
    if check_command lsblk; then
        info=$(lsblk -d -o NAME,SIZE,MODEL,TYPE 2>/dev/null | grep -v loop || true)
    fi
    hw_section "磁盘信息 (lsblk)" "${info}"

    local smart=""
    if check_command smartctl; then
        local disk
        for disk in $(lsblk -d -n -o NAME 2>/dev/null | grep -v loop | head -3 || true); do
            local health
            health=$(smartctl -H "/dev/${disk}" 2>/dev/null | grep -E 'SMART overall|PASSED|FAILED' | head -1 || true)
            [[ -n "${health}" ]] && smart+="${disk}: ${health}\n"
        done
        hw_section "磁盘健康度 (smartctl)" "${smart}"
    else
        echo ""
        echo "  ${COLOR_GRAY}(未安装 smartctl，跳过健康度检查)${COLOR_RESET}"
    fi
}

# ------------------------------------------------------------
# 网卡信息
# ------------------------------------------------------------
hw_show_net() {
    local info=""
    if check_command ethtool; then
        local iface
        for iface in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -5 || true); do
            local speed link
            speed=$(ethtool "${iface}" 2>/dev/null | grep -E 'Speed:' | awk '{print $2}' || true)
            link=$(ethtool "${iface}" 2>/dev/null | grep -E 'Link detected' | awk '{print $3}' || true)
            local driver
            driver=$(readlink -f "/sys/class/net/${iface}/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "?")
            info+="${iface}: 速率=${speed:-未知} 链路=${link:-未知} 驱动=${driver}\n"
        done
    else
        info=$(ip -brief link 2>/dev/null || ip link 2>/dev/null || true)
        [[ -z "${info}" ]] && info="(未安装 ethtool 且无 ip 命令)"
    fi
    hw_section "网卡信息" "${info}"
}

# ------------------------------------------------------------
# PCI 设备
# ------------------------------------------------------------
hw_show_pci() {
    local info=""
    if check_command lspci; then
        info=$(lspci 2>/dev/null | head -15 || true)
    else
        info="(未安装 pciutils/lspci)"
    fi
    hw_section "PCI 设备" "${info}"
}

# ------------------------------------------------------------
# 系统信息
# ------------------------------------------------------------
hw_show_system() {
    local info=""
    info+="发行版:  $(get_distro)\n"
    info+="内核:    $(uname -r)\n"
    info+="架构:    $(get_arch)\n"
    info+="主机名:  $(hostname 2>/dev/null || echo '?')"
    if check_command uptime; then
        info+="\n运行时长: $(uptime -p 2>/dev/null || echo '?')"
    fi
    info+="\n环境类型: $(detect_env_type 2>/dev/null || echo 'unknown')"
    hw_section "系统信息" "${info}"
}

# ============================================================
# 独立执行保护
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ZETOPS_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/logger.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/utils.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/detect_env.sh"
    hw_show_all
fi
