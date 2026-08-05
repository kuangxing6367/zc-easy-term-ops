#!/bin/bash
# ============================================================
# 文件：modules/01_system_init.sh
# 功能：系统初始化与优化 [System Init & Optimization]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：系统更新、时间同步(chrony)、主机名、Swap、
#       ulimit限制、SELinux/AppArmor、内核参数调优
# ============================================================
set -euo pipefail

module_name="系统初始化与优化"
module_short="system_init"
module_version="1.0.0"

# ------------------------------------------------------------
# 模块描述（进入模块时显示）
# 参数：无
# 返回：无
# ------------------------------------------------------------
module_description() {
    echo "系统初始化、时间同步(chrony)、主机名(hostname)、Swap虚拟内存、"
    echo "系统限制(ulimit)、SELinux/AppArmor、内核参数调优(sysctl)"
}

# ------------------------------------------------------------
# 子菜单
# 参数：无
# 返回：无
# ------------------------------------------------------------
module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 系统更新与升级"
    echo " 2. 时间同步配置 (NTP/Chrony)"
    echo " 3. 主机名修改"
    echo " 4. Swap 虚拟内存管理"
    echo " 5. 系统限制优化 (ulimit/文件描述符)"
    echo " 6. SELinux/AppArmor 管理"
    echo " 7. 内核参数调优 (sysctl)"
    echo " 0. 返回主菜单"
    echo "======================================"
}

# ------------------------------------------------------------
# 执行入口（参数为子菜单选项）
# 参数：$1 选项数字
# 返回：无
# ------------------------------------------------------------
module_execute() {
    local choice="$1"
    case "${choice}" in
        1) system_update ;;
        2) time_sync ;;
        3) hostname_change ;;
        4) swap_manager ;;
        5) limits_tune ;;
        6) selinux_manager ;;
        7) kernel_tune ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [系统更新] 更新与升级软件包（Package Update）
# 参数：无
# 返回：无
# ------------------------------------------------------------
system_update() {
    check_root || return 1
    local pm
    pm=$(detect_pkg_manager)
    log_info "使用 ${pm} 更新系统 ..."
    case "${pm}" in
        apt)
            show_spinner "apt-get update 刷新软件源..."
            apt-get update -qq || { stop_spinner; log_error "更新索引失败"; return 1; }
            stop_spinner
            show_spinner "apt-get upgrade 升级软件包..."
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || { stop_spinner; log_error "升级失败"; return 1; }
            stop_spinner
            ;;
        dnf|yum)
            "${pm}" check-update || true
            "${pm}" upgrade -y || { log_error "升级失败"; return 1; }
            ;;
        zypper)
            zypper --non-interactive update || { log_error "升级失败"; return 1; }
            ;;
        *)
            log_error "不支持的包管理器: ${pm}"
            return 1
            ;;
    esac
    log_success "系统更新完成"
    if [[ -f /var/run/reboot-required ]]; then
        read_input reboot_ans "检测到需要重启，是否立即重启?" "n"
        case "${reboot_ans}" in
            y|Y|yes) systemctl reboot ;;
            *) log_warning "已跳过重启，请稍后手动重启" ;;
        esac
    fi
}

# ------------------------------------------------------------
# [时间同步] 配置 NTP 时间同步（统一使用 chrony）
# 参数：无
# 返回：无
# ------------------------------------------------------------
time_sync() {
    check_root || return 1
    log_info "安装 chrony（统一时间同步服务）..."
    install_pkg chrony || return 1

    # 从 API 节点获取 NTP 服务器列表，失败时使用默认公共 NTP
    local ntps
    ntps=$(api_fetch "ntp/servers" || true)
    if [[ -z "${ntps}" ]]; then
        log_warning "API 未配置或获取失败，使用默认 NTP 服务器"
        ntps="ntp.aliyun.com
ntp.tencent.com
cn.pool.ntp.org"
    fi
    local conf="/etc/chrony/chrony.conf"
    [[ -d /etc/chrony ]] || conf="/etc/chrony.conf"

    # 备份原配置
    cp "${conf}" "${conf}.bak.$(date +%s)" 2>/dev/null || true
    cat > "${conf}" <<EOF
# 由 ZETOPS 生成
server ntp.aliyun.com iburst
server ntp.tencent.com iburst
server cn.pool.ntp.org iburst
pool 2.centos.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

    # 禁用其他时间同步服务，避免冲突
    systemctl disable --now ntpd 2>/dev/null || true
    systemctl disable --now systemd-timesyncd 2>/dev/null || true

    systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null
    log_info "手动校时（强制同步一次）..."
    chronyc makestep 2>/dev/null || true
    log_success "时间同步配置完成：$(date)"
}

# ------------------------------------------------------------
# [主机名] 修改主机名（Hostname）
# 参数：无
# 返回：无
# ------------------------------------------------------------
hostname_change() {
    check_root || return 1
    local new_hostname
    read_input new_hostname "请输入新主机名" ""
    if [[ -z "${new_hostname}" || ! "${new_hostname}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log_error "主机名不合法（只能包含字母/数字/._-）"
        return 1
    fi
    echo "${new_hostname}" > /etc/hostname
    hostname "${new_hostname}"
    # 同步更新 /etc/hosts 中旧主机名映射
    if [[ -f /etc/hosts ]]; then
        sed -i "s/$(hostname)/${new_hostname}/g" /etc/hosts 2>/dev/null || true
    fi
    log_success "主机名已修改为: ${new_hostname}"
}

# ------------------------------------------------------------
# [Swap] 虚拟内存管理（创建/删除/调整 swap 文件）
# 参数：无
# 返回：无
# ------------------------------------------------------------
swap_manager() {
    check_root || return 1
    local act
    read_input act "选择操作 [1=查看 2=创建 3=删除]:" "1"
    case "${act}" in
        1) swapon --show; free -h ;;
        2) swap_create ;;
        3) swap_remove ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Swap] 创建 swap 文件
# 参数：无
# 返回：无
# ------------------------------------------------------------
swap_create() {
    local size file
    read_input size "Swap 大小（G）:" "2"
    read_input file "Swap 文件路径:" "/swapfile"
    [[ "${size}" =~ ^[0-9]+$ ]] || { log_error "大小必须为数字(GB)"; return 1; }
    if [[ -e "${file}" ]]; then
        log_error "文件已存在: ${file}"
        return 1
    fi
    show_spinner "创建 ${size}G swap 文件（fallocate）..."
    fallocate -l "${size}G" "${file}" || dd if=/dev/zero of="${file}" bs=1M count=$((size * 1024))
    chmod 600 "${file}"
    mkswap "${file}" >/dev/null
    swapon "${file}"
    stop_spinner
    # 写入 /etc/fstab 实现开机自动挂载
    grep -q "${file}" /etc/fstab || echo "${file} none swap sw 0 0" >> /etc/fstab
    log_success "Swap 创建完成: ${file} ${size}G"
    swapon --show
}

# ------------------------------------------------------------
# [Swap] 删除 swap 文件
# 参数：无
# 返回：无
# ------------------------------------------------------------
swap_remove() {
    local file
    read_input file "要删除的 Swap 文件路径:" "/swapfile"
    if [[ ! -e "${file}" ]]; then
        log_error "文件不存在: ${file}"
        return 1
    fi
    confirm_action "删除 swap 文件 ${file}" || return 1
    swapoff "${file}" 2>/dev/null || true
    sed -i "\|${file}|d" /etc/fstab
    rm -f "${file}"
    log_success "Swap 文件已删除: ${file}"
}

# ------------------------------------------------------------
# [系统限制] 优化 ulimit/文件描述符/最大进程数
# 参数：无
# 返回：无
# ------------------------------------------------------------
limits_tune() {
    check_root || return 1
    local fds procs
    read_input fds "最大文件描述符数(File Descriptors):" "65535"
    read_input procs "最大进程数(Processes):" "65535"
    [[ "${fds}" =~ ^[0-9]+$ ]] || { log_error "无效数字"; return 1; }
    [[ "${procs}" =~ ^[0-9]+$ ]] || { log_error "无效数字"; return 1; }
    cp /etc/security/limits.conf "/etc/security/limits.conf.bak.$(date +%s)" 2>/dev/null || true
    cat >> /etc/security/limits.conf <<EOF
# 由 ZETOPS 添加
* soft nofile ${fds}
* hard nofile ${fds}
* soft nproc ${procs}
* hard nproc ${procs}
EOF
    log_success "limits.conf 已更新（需重新登录生效）"
    log_info "当前会话软限制: ulimit -n $(ulimit -n)"
}

# ------------------------------------------------------------
# [SELinux] SELinux/AppArmor 管理（查看/临时禁用/永久禁用）
# 参数：无
# 返回：无
# ------------------------------------------------------------
selinux_manager() {
    local act
    echo "当前安全模块状态:"
    if check_command getenforce; then
        echo "  SELinux: $(getenforce 2>/dev/null || echo '不可用')"
    elif check_command aa-status; then
        aa-status 2>/dev/null | head -n 5 || echo "  AppArmor: 不可用"
    else
        echo "  未检测到 SELinux / AppArmor"
    fi
    read_input act "选择操作 [1=临时禁用 2=永久禁用 3=恢复启用]:" ""
    case "${act}" in
        1)
            if check_command setenforce; then
                setenforce 0 && log_success "SELinux 已临时禁用（Enforcing→Permissive）"
            elif [[ -f /sys/module/apparmor/parameters/enabled ]]; then
                log_warning "AppArmor 无法热禁用，建议使用 aa-complain 或重启后修改内核参数"
            fi
            ;;
        2)
            confirm_action "永久禁用 SELinux/AppArmor（修改内核启动参数）" || return 1
            if [[ -f /etc/selinux/config ]]; then
                sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
                log_success "SELinux 永久禁用（/etc/selinux/config），重启后生效"
            fi
            if [[ -f /etc/default/grub ]]; then
                sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="apparmor=0 security=apparmor"/' /etc/default/grub
                grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || update-grub 2>/dev/null || true
                log_success "AppArmor 启动参数已禁用，重启后生效"
            fi
            ;;
        3)
            if [[ -f /etc/selinux/config ]]; then
                sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
                setenforce 1 2>/dev/null || true
                log_success "SELinux 已恢复 Enforcing"
            fi
            ;;
    esac
}

# ------------------------------------------------------------
# [内核调优] 内核参数调优（sysctl，含备份）
# 参数：无
# 返回：无
# ------------------------------------------------------------
kernel_tune() {
    check_root || return 1
    local swappiness tcp_reuse tcp_syncookies
    read_input swappiness "swappiness（0-100，越小越少用Swap）:" "10"
    read_input tcp_reuse "启用 tcp_tw_reuse（TIME_WAIT复用）? [1=是 0=否]:" "1"
    read_input tcp_syncookies "启用 tcp_syncookies（防SYN洪水）? [1=是 0=否]:" "1"
    [[ "${swappiness}" =~ ^[0-9]+$ ]] && (( swappiness <= 100 )) || { log_error "swappiness 无效"; return 1; }

    # 备份 sysctl.conf
    cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
    cat > /etc/sysctl.d/99-zetops.conf <<EOF
# 由 ZETOPS 生成
vm.swappiness = ${swappiness}
net.ipv4.tcp_tw_reuse = ${tcp_reuse}
net.ipv4.tcp_syncookies = ${tcp_syncookies}
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_fin_timeout = 30
EOF
    sysctl -p /etc/sysctl.d/99-zetops.conf >/dev/null 2>&1 || true
    log_success "内核参数已应用（原配置已备份为 /etc/sysctl.conf.bak.*）"
    sysctl vm.swappiness
}

# ---- 独立执行入口 ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../core/logger.sh"
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../core/utils.sh"
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../core/config.sh"
    log_init; load_config; load_api_config
    CURRENT_MODULE="${module_short}"
    while true; do
        module_description; module_menu
        read -r -p "请选择 (0-9) [q=退出]: " _c || break
        [[ "${_c}" == "q" ]] && break
        module_execute "${_c}" || true
        [[ "${_c}" == "0" ]] && break
    done
fi
