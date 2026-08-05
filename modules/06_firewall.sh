#!/bin/bash
# ============================================================
# 文件：modules/06_firewall.sh
# 功能：防火墙与网络安全 [Firewall & Network Security]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：iptables/ufw/firewalld 规则管理、Fail2ban 防暴力破解、
#       SSH 安全加固、本机端口扫描
# ============================================================
set -euo pipefail

module_name="防火墙与网络安全"
module_short="firewall"
module_version="1.0.0"

module_description() {
    echo "iptables/ufw/firewalld 规则管理、NAT转发、Fail2ban防护、SSH安全加固"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. iptables 规则管理"
    echo " 2. ufw 防火墙管理"
    echo " 3. firewalld 管理"
    echo " 4. Fail2ban 防暴力破解"
    echo " 5. SSH 安全加固"
    echo " 6. 本机端口扫描"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) iptables_manager ;;
        2) ufw_manager ;;
        3) firewalld_manager ;;
        4) fail2ban_manager ;;
        5) ssh_harden ;;
        6) port_scan ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ============================================================
# iptables 二级菜单
# ============================================================
iptables_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [iptables管理] 子菜单"
        echo "======================================"
        echo " 1. 查看规则"
        echo " 2. 添加规则"
        echo " 3. 删除规则"
        echo " 4. NAT 转发配置"
        echo " 5. 保存规则 (持久化)"
        echo " 6. 导入/导出规则"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-6) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) iptables_view ;;
            2) iptables_add ;;
            3) iptables_delete ;;
            4) iptables_nat ;;
            5) iptables_save ;;
            6) iptables_transfer ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [iptables] 查看规则
# 参数：无
# 返回：无
# ------------------------------------------------------------
iptables_view() {
    check_root || return 1
    iptables -L -n -v --line-numbers 2>/dev/null || log_error "iptables 不可用"
}

# ------------------------------------------------------------
# [iptables] 添加规则（协议/端口/IP/网段）
# 参数：无
# 返回：无
# ------------------------------------------------------------
iptables_add() {
    check_root || return 1
    local chain proto port source action
    read_input chain "链(Chain):" "INPUT"
    read_input proto "协议(Protocol) [tcp/udp/icmp]:" "tcp"
    read_input port "端口(留空跳过):" ""
    read_input source "来源(IP/网段，留空=any):" ""
    read_input action "动作(Action) [ACCEPT/DROP/REJECT]:" "ACCEPT"
    local rule="-A ${chain} -p ${proto}"
    [[ -n "${port}" ]] && { validate_port "${port}" || { log_error "端口无效"; return 1; }; rule+=" --dport ${port}"; }
    [[ -n "${source}" ]] && rule+=" -s ${source}"
    rule+=" -j ${action}"
    log_info "执行: iptables ${rule}"
    iptables ${rule}
    log_success "规则已添加"
}

# ------------------------------------------------------------
# [iptables] 删除规则
# 参数：无
# 返回：无
# ------------------------------------------------------------
iptables_delete() {
    check_root || return 1
    local chain num
    read_input chain "链(Chain):" "INPUT"
    read_input num "规则行号(--line-numbers 中查看):" ""
    [[ "${num}" =~ ^[0-9]+$ ]] || { log_error "无效行号"; return 1; }
    iptables -D "${chain}" "${num}"
    log_success "已删除 ${chain} 第 ${num} 条规则"
}

# ------------------------------------------------------------
# [iptables] NAT 转发配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
iptables_nat() {
    check_root || return 1
    local iface
    read_input iface "外网网卡(如 eth0):" "eth0"
    echo "开启 IP 转发(IP Forwarding)..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    iptables -t nat -A POSTROUTING -o "${iface}" -j MASQUERADE
    log_success "NAT 转发已开启（外网网卡 ${iface}）"
    log_info "提示: 内网机器需添加默认路由指向本机"
}

# ------------------------------------------------------------
# [iptables] 保存规则（持久化 save）
# 参数：无
# 返回：无
# ------------------------------------------------------------
iptables_save() {
    check_root || return 1
    case "$(detect_pkg_manager)" in
        apt)  install_pkg iptables-persistent
              netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4
              log_success "规则已保存（重启后自动恢复）"
              ;;
        dnf|yum)
              install_pkg iptables-services
              systemctl enable --now iptables 2>/dev/null || true
              service iptables save 2>/dev/null || iptables-save > /etc/sysconfig/iptables
              log_success "规则已保存（/etc/sysconfig/iptables）"
              ;;
    esac
}

# ------------------------------------------------------------
# [iptables] 导入/导出规则
# 参数：无
# 返回：无
# ------------------------------------------------------------
iptables_transfer() {
    check_root || return 1
    local act file
    read_input act "操作 [1=导出 2=导入]:" "1"
    read_input file "规则文件路径:" "/root/iptables.rules"
    case "${act}" in
        1) iptables-save > "${file}" && log_success "已导出到 ${file}" ;;
        2) [[ -f "${file}" ]] || { log_error "文件不存在"; return 1; }
           confirm_action "导入规则（将覆盖当前规则）" || return 1
           iptables-restore < "${file}" && log_success "规则已导入" ;;
    esac
}

# ============================================================
# ufw 二级菜单
# ============================================================
ufw_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [ufw管理] 子菜单"
        echo "======================================"
        echo " 1. 启用 ufw"
        echo " 2. 禁用 ufw"
        echo " 3. 添加/删除端口规则"
        echo " 4. IP 黑白名单"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-4) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) ufw enable && log_success "ufw 已启用" ;;
            2) ufw disable && log_success "ufw 已禁用" ;;
            3) ufw_port_rule ;;
            4) ufw_ip_rule ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [ufw] 添加/删除端口规则
# 参数：无
# 返回：无
# ------------------------------------------------------------
ufw_port_rule() {
    check_root || return 1
    check_command ufw || { install_pkg ufw; ufw --force enable; }
    local port proto act
    read_input port "端口:" ""
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    read_input proto "协议 [tcp/udp]:" "tcp"
    read_input act "操作 [1=允许allow 2=拒绝deny]:" "1"
    if [[ "${act}" == "1" ]]; then ufw allow "${port}/${proto}"; else ufw deny "${port}/${proto}"; fi
    log_success "ufw 规则已更新"
}

# ------------------------------------------------------------
# [ufw] IP 黑白名单
# 参数：无
# 返回：无
# ------------------------------------------------------------
ufw_ip_rule() {
    check_root || return 1
    local ip act
    read_input ip "IP 地址:" ""
    validate_ip "${ip}" || { log_error "IP 无效"; return 1; }
    read_input act "操作 [1=允许allow 2=拒绝deny]:" "1"
    if [[ "${act}" == "1" ]]; then ufw allow from "${ip}"; else ufw deny from "${ip}"; fi
    log_success "IP 规则已更新"
}

# ============================================================
# firewalld 二级菜单
# ============================================================
firewalld_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [firewalld管理] 子菜单"
        echo "======================================"
        echo " 1. 切换后端（nftables/iptables）"
        echo " 2. 查看状态/区域"
        echo " 3. 添加/删除服务"
        echo " 4. 添加/删除端口"
        echo " 5. 富规则配置 (Rich Rule)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-5) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) firewalld_backend ;;
            2) firewall-cmd --state; firewall-cmd --get-active-zones ;;
            3) firewalld_service ;;
            4) firewalld_port ;;
            5) firewalld_rich_rule ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [firewalld] 切换后端（Backend）
# 参数：无
# 返回：无
# ------------------------------------------------------------
firewalld_backend() {
    check_root || return 1
    local backend
    read_input backend "后端 [nftables/iptables]:" "nftables"
    sed -i "s/^FirewallBackend=.*/FirewallBackend=${backend}/" /etc/firewalld/firewalld.conf 2>/dev/null || \
        echo "FirewallBackend=${backend}" >> /etc/firewalld/firewalld.conf
    systemctl restart firewalld
    log_success "firewalld 后端已切换为 ${backend}"
}

# ------------------------------------------------------------
# [firewalld] 服务规则
# 参数：无
# 返回：无
# ------------------------------------------------------------
firewalld_service() {
    check_root || return 1
    local svc act
    read_input svc "服务名(如 http/ssh/nginx):" ""
    read_input act "操作 [1=添加 2=删除]:" "1"
    if [[ "${act}" == "1" ]]; then firewall-cmd --permanent --add-service="${svc}"; else firewall-cmd --permanent --remove-service="${svc}"; fi
    firewall-cmd --reload
    log_success "服务规则已更新: ${svc}"
}

# ------------------------------------------------------------
# [firewalld] 端口规则
# 参数：无
# 返回：无
# ------------------------------------------------------------
firewalld_port() {
    check_root || return 1
    local port proto act
    read_input port "端口:" ""
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    read_input proto "协议 [tcp/udp]:" "tcp"
    read_input act "操作 [1=添加 2=删除]:" "1"
    if [[ "${act}" == "1" ]]; then firewall-cmd --permanent --add-port="${port}/${proto}"; else firewall-cmd --permanent --remove-port="${port}/${proto}"; fi
    firewall-cmd --reload
    log_success "端口规则已更新: ${port}/${proto}"
}

# ------------------------------------------------------------
# [firewalld] 富规则配置（Rich Rule，如 IP 限流）
# 参数：无
# 返回：无
# ------------------------------------------------------------
firewalld_rich_rule() {
    check_root || return 1
    local source act
    read_input source "来源 IP/网段:" ""
    read_input act "操作 [1=允许 2=拒绝]:" "1"
    local rule="rule family=ipv4 source address=${source}"
    if [[ "${act}" == "1" ]]; then rule+=" accept"; else rule+=" drop"; fi
    firewall-cmd --permanent --add-rich-rule="${rule}"
    firewall-cmd --reload
    log_success "富规则已添加: ${rule}"
}

# ============================================================
# Fail2ban 二级菜单
# ============================================================
fail2ban_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [Fail2ban管理] 子菜单"
        echo "======================================"
        echo " 1. 安装 Fail2ban"
        echo " 2. 配置防护规则 (SSH/Nginx/MySQL)"
        echo " 3. 查看被封 IP"
        echo " 4. 解封 IP"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-4) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) fail2ban_install ;;
            2) fail2ban_config ;;
            3) fail2ban status ;;
            4) fail2ban_unban ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Fail2ban] 安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
fail2ban_install() {
    check_root || return 1
    case "$(detect_pkg_manager)" in
        apt)  install_pkg fail2ban ;;
        dnf|yum) install_pkg fail2ban fail2ban-firewalld ;;
    esac
    systemctl enable --now fail2ban 2>/dev/null || true
    log_success "Fail2ban 已安装并启动"
}

# ------------------------------------------------------------
# [Fail2ban] 配置防护规则（SSH/Nginx/MySQL）
# 参数：无
# 返回：无
# ------------------------------------------------------------
fail2ban_config() {
    check_root || return 1
    cat > /etc/fail2ban/jail.local <<EOF
# 由 ZETOPS 生成
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = %(sshd_backend)s

[nginx-http-auth]
enabled = true
logpath = /var/log/nginx/error.log

[mysqld-auth]
enabled = true
logpath = /var/log/mysql/error.log
EOF
    systemctl restart fail2ban 2>/dev/null || true
    log_success "Fail2ban 防护规则已配置（SSH/Nginx/MySQL）"
}

# ------------------------------------------------------------
# [Fail2ban] 解封 IP
# 参数：无
# 返回：无
# ------------------------------------------------------------
fail2ban_unban() {
    check_root || return 1
    local ip
    read_input ip "要解封的 IP:" ""
    validate_ip "${ip}" || { log_error "IP 无效"; return 1; }
    fail2ban-client unban "${ip}" 2>/dev/null || true
    log_success "IP 已解封: ${ip}"
}

# ------------------------------------------------------------
# [SSH加固] SSH 安全加固（端口/禁止root/禁用密码认证）
# 参数：无
# 返回：无
# ------------------------------------------------------------
ssh_harden() {
    check_root || return 1
    local port root_pw pw_auth
    read_input port "SSH 新端口(1-65535):" "22"
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    read_input root_pw "禁止 root 登录? [y/n]:" "y"
    read_input pw_auth "禁用密码认证(仅密钥登录)? [y/n]:" "n"
    local conf="/etc/ssh/sshd_config"
    cp "${conf}" "${conf}.bak.$(date +%s)"
    sed -i "s/^#*Port .*/Port ${port}/" "${conf}"
    if [[ "${root_pw}" == "y" ]]; then
        sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" "${conf}"
    fi
    if [[ "${pw_auth}" == "y" ]]; then
        sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication no/" "${conf}"
        sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" "${conf}"
    fi
    if check_command semanage; then
        semanage port -a -t ssh_port_t -p tcp "${port}" 2>/dev/null || true
    fi
    log_warning "即将重启 sshd（若使用 SSH 连接，请确保新端口已放行防火墙）"
    confirm_action "重启 sshd 服务" || return 1
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_success "SSH 加固完成：端口 ${port}，root登录=${root_pw}，密码认证=${pw_auth}"
}

# ------------------------------------------------------------
# [端口扫描] 扫描本机开放端口
# 参数：无
# 返回：无
# ------------------------------------------------------------
port_scan() {
    check_root || return 1
    if check_command ss; then
        log_info "本机正在监听的端口(TCP):"
        ss -tlnp | sort -u
    else
        netstat -tlnp 2>/dev/null || log_error "缺少 ss/netstat"
    fi
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
