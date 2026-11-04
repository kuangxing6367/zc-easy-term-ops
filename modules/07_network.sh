#!/bin/bash
# ============================================================
# 文件：modules/07_network.sh
# 功能：网络配置与诊断 [Network Configuration & Diagnosis]
# 作者：zc 团队
# 版本：1.1.0
# 日期：2026-08-06
# 说明：单网卡操作（禁用全局重启 network 服务）、DNS/路由管理、
#       网络诊断、VPN(WireGuard/OpenVPN)、代理服务
#       v1.1.0: 补齐查看功能（DNS/hosts/路由备份列表/VPN状态/代理状态），
#               修改类操作执行前自动展示当前值，实现"先看后改"
# ============================================================
set -euo pipefail

module_name="网络配置与诊断"
module_short="network"
module_version="1.1.0"

# 重要约束：本模块只允许操作单网卡，禁止 systemctl restart network
# （避免全局重启导致 SSH 断连/配置丢失）

module_description() {
    echo "网卡配置(静态IP/DHCP/MTU/VLAN/Bond)、DNS、路由(含备份回滚)、网络诊断、VPN、代理"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 网卡配置（静态IP/DHCP/MTU/VLAN/Bond）"
    echo " 2. DNS 管理（查看/修改/hosts）"
    echo " 3. 路由管理（查看/备份/回滚）"
    echo " 4. 网络诊断（ping/traceroute/mtr/带宽测速）"
    echo " 5. VPN 管理（查看状态/配置）"
    echo " 6. 代理服务（查看状态/配置）"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) nic_manager ;;
        2) dns_manager ;;
        3) route_manager ;;
        4) net_diag ;;
        5) vpn_manager ;;
        6) proxy_manager ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ============================================================
# 网卡二级菜单
# ============================================================
nic_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [网卡配置] 子菜单"
        echo "======================================"
        echo " 1. 列出所有网卡"
        echo " 2. 配置静态 IP/DHCP（单网卡，安全切换）"
        echo " 3. 修改 MTU"
        echo " 4. VLAN 绑定"
        echo " 5. Bonding 配置"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-5) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) nic_list ;;
            2) nic_config ;;
            3) nic_mtu ;;
            4) nic_vlan ;;
            5) nic_bond ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [网卡] 列出所有网卡
# 参数：无
# 返回：无
# ------------------------------------------------------------
nic_list() {
    log_info "网卡列表:"
    ip -br link show
    echo ""
    echo "IP 地址信息:"
    ip -br addr show
}

# ------------------------------------------------------------
# [网卡] 配置静态 IP / DHCP（单网卡操作）
# 参数：无
# 返回：无
# 注意：使用 nmcli（NetworkManager）或 ifup/ifdown 单网卡切换，
#       禁止 systemctl restart network 全局重启
# ------------------------------------------------------------
nic_config() {
    check_root || return 1
    local iface
    read_input iface "网卡名称(Interface):" "eth0"
    ip link show "${iface}" >/dev/null 2>&1 || { log_error "网卡不存在: ${iface}"; return 1; }
    log_info "== 网卡 ${iface} 当前配置 =="
    ip -br addr show "${iface}"
    local mode
    read_input mode "模式 [1=静态IP 2=DHCP]:" "1"
    if check_command nmcli; then
        # 优先使用 NetworkManager
        if [[ "${mode}" == "2" ]]; then
            nmcli con mod "${iface}" ipv4.method auto 2>/dev/null || \
            nmcli con add type ethernet con-name "${iface}" ifname "${iface}" ipv4.method auto
            log_warning "即将应用新配置（可能短暂断网）..."
            nmcli con up "${iface}"
            log_success "网卡 ${iface} 已切换为 DHCP"
            return 0
        fi
        local ip gw dns
        read_input ip "IP 地址(如 192.168.1.100/24):" ""
        read_input gw "网关(Gateway):" ""
        read_input dns "DNS(逗号分隔):" "223.5.5.5"
        nmcli con mod "${iface}" ipv4.method manual ipv4.addresses "${ip}" ipv4.gateway "${gw}" ipv4.dns "${dns}" 2>/dev/null || \
        nmcli con add type ethernet con-name "${iface}" ifname "${iface}" ipv4.method manual ipv4.addresses "${ip}" ipv4.gateway "${gw}" ipv4.dns "${dns}"
        log_warning "即将应用新配置（可能短暂断网）..."
        nmcli con up "${iface}"
        log_success "网卡 ${iface} 静态IP配置完成"
    else
        # 无 NetworkManager：直接操作单网卡（ip addr，不重启全局网络）
        if [[ "${mode}" == "2" ]]; then
            log_warning "无 NetworkManager，需配置 dhclient:"
            read_input conf_mgmt "使用 dhclient 获取IP? [y/n]:" "y"
            [[ "${conf_mgmt}" == "y" ]] && { dhclient "${iface}"; log_success "DHCP 获取完成"; }
            return 0
        fi
        local ip gw dns
        read_input ip "IP 地址(如 192.168.1.100/24):" ""
        read_input gw "网关(Gateway):" ""
        read_input dns "DNS(空格分隔):" "223.5.5.5"
        confirm_action "修改网卡 ${iface} IP 为 ${ip}（当前会话可能断网）" || return 1
        ip addr flush dev "${iface}"
        ip addr add "${ip}" dev "${iface}"
        ip link set "${iface}" up
        [[ -n "${gw}" ]] && ip route replace default via "${gw}"
        log_warning "配置未写入开机持久化文件，如需持久化请使用 nmcli 或编辑 /etc/network/interfaces"
        log_success "网卡 ${iface} 已配置 ${ip}"
    fi
}

# ------------------------------------------------------------
# [网卡] 修改 MTU
# 参数：无
# 返回：无
# ------------------------------------------------------------
nic_mtu() {
    check_root || return 1
    local iface mtu
    read_input iface "网卡名称:" "eth0"
    log_info "== 网卡 ${iface} 当前 MTU =="
    ip link show "${iface}" | grep -o 'mtu [0-9]*' || true
    read_input mtu "MTU 值(如 1500/1400):" "1500"
    [[ "${mtu}" =~ ^[0-9]+$ ]] || { log_error "MTU 无效"; return 1; }
    ip link set dev "${iface}" mtu "${mtu}"
    log_success "网卡 ${iface} MTU 已设置为 ${mtu}"
    log_warning "注意：MTU 过大可能导致丢包，建议 1400 起步测试"
}

# ------------------------------------------------------------
# [网卡] VLAN 绑定
# 参数：无
# 返回：无
# ------------------------------------------------------------
nic_vlan() {
    check_root || return 1
    check_command ip || return 1
    local iface vlan_id
    read_input iface "物理网卡:" "eth0"
    read_input vlan_id "VLAN ID(1-4094):" ""
    [[ "${vlan_id}" =~ ^[0-9]+$ ]] && (( vlan_id >= 1 && vlan_id <= 4094 )) || { log_error "VLAN ID 无效"; return 1; }
    ip link add link "${iface}" name "${iface}.${vlan_id}" type vlan id "${vlan_id}"
    ip link set "${iface}.${vlan_id}" up
    log_success "VLAN 接口 ${iface}.${vlan_id} 已创建"
}

# ------------------------------------------------------------
# [网卡] Bonding 配置（主备/负载均衡）
# 参数：无
# 返回：无
# ------------------------------------------------------------
nic_bond() {
    check_root || return 1
    local bond_name mode slave1 slave2
    read_input bond_name "Bond 接口名:" "bond0"
    read_input mode "模式 [1=active-backup主备 4=802.3ad链路聚合]:" "1"
    read_input slave1 "成员网卡1:" ""
    read_input slave2 "成员网卡2:" ""
    ip link add "${bond_name}" type bond mode "${mode}" miimon 100 2>/dev/null || {
        # 部分系统需要先卸载再建
        ip link del "${bond_name}" 2>/dev/null || true
        ip link add "${bond_name}" type bond mode "${mode}" miimon 100
    }
    ip link set "${slave1}" master "${bond_name}"
    ip link set "${slave2}" master "${bond_name}"
    ip link set "${bond_name}" up
    log_success "Bond 接口 ${bond_name} 创建完成（成员: ${slave1}+${slave2}）"
    log_warning "请为 bond0 配置 IP（参考菜单: 网卡配置）"
}

# ============================================================
# DNS 二级菜单
# ============================================================
dns_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [DNS管理] 子菜单"
        echo "======================================"
        echo " 1. 查看当前 DNS 配置"
        echo " 2. 修改 /etc/resolv.conf"
        echo " 3. 测试域名解析"
        echo " 4. 查看当前 hosts 映射"
        echo " 5. 添加 hosts 映射"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-5) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) dns_view ;;
            2) dns_config ;;
            3) dns_test ;;
            4) hosts_view ;;
            5) hosts_manage ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [DNS] 查看当前 DNS 配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
dns_view() {
    log_info "== 当前 DNS 配置 (/etc/resolv.conf) =="
    cat /etc/resolv.conf 2>/dev/null || log_error "无法读取 /etc/resolv.conf"
}

# ------------------------------------------------------------
# [DNS] 修改 resolv.conf（修改前先展示当前内容）
# 参数：无
# 返回：无
# ------------------------------------------------------------
dns_config() {
    check_root || return 1
    log_info "== 修改前 /etc/resolv.conf 内容 =="
    cat /etc/resolv.conf 2>/dev/null || true
    local dns
    read_input dns "DNS 服务器(空格分隔):" "223.5.5.5 119.29.29.29"
    cp /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)"
    : > /etc/resolv.conf
    local d
    for d in ${dns}; do
        echo "nameserver ${d}" >> /etc/resolv.conf
    done
    log_success "DNS 已更新: ${dns}"
}

# ------------------------------------------------------------
# [DNS] 测试解析
# 参数：无
# 返回：无
# ------------------------------------------------------------
dns_test() {
    local domain
    read_input domain "要测试的域名:" "www.baidu.com"
    nslookup "${domain}" 2>/dev/null || dig "${domain}" +short 2>/dev/null || host "${domain}" 2>/dev/null || log_error "请安装 dnsutils/bind-utils"
}

# ------------------------------------------------------------
# [DNS] 查看当前 hosts 映射
# 参数：无
# 返回：无
# ------------------------------------------------------------
hosts_view() {
    log_info "== 当前 hosts 映射 (/etc/hosts) =="
    cat /etc/hosts 2>/dev/null || log_error "无法读取 /etc/hosts"
}

# ------------------------------------------------------------
# [DNS] hosts 映射管理（添加前先展示当前 hosts）
# 参数：无
# 返回：无
# ------------------------------------------------------------
hosts_manage() {
    check_root || return 1
    log_info "== 当前 hosts 文件 =="
    cat /etc/hosts 2>/dev/null || true
    local ip domain
    read_input ip "IP:" ""
    validate_ip "${ip}" || { log_error "IP 无效"; return 1; }
    read_input domain "域名:" ""
    grep -q "${domain}" /etc/hosts || echo -e "${ip}\t${domain}" >> /etc/hosts
    log_success "hosts 映射已添加: ${ip} ${domain}"
}

# ============================================================
# 路由二级菜单
# ============================================================
route_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [路由管理] 子菜单"
        echo "======================================"
        echo " 1. 查看路由表"
        echo " 2. 查看路由备份列表"
        echo " 3. 添加静态路由"
        echo " 4. 删除静态路由"
        echo " 5. 路由表备份"
        echo " 6. 一键回滚路由"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-6) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) route_view ;;
            2) route_backup_list ;;
            3) route_add ;;
            4) route_delete ;;
            5) route_backup ;;
            6) route_rollback ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [路由] 查看路由表
# 参数：无
# 返回：无
# ------------------------------------------------------------
route_view() {
    log_info "== 当前路由表 =="
    ip route show
}

# ------------------------------------------------------------
# [路由] 查看路由备份列表
# 参数：无
# 返回：无
# ------------------------------------------------------------
route_backup_list() {
    log_info "== 路由备份列表 (${BACKUP_DIR}/route-*.bak) =="
    if compgen -G "${BACKUP_DIR}/route-*.bak" >/dev/null; then
        ls -lht ${BACKUP_DIR}/route-*.bak
    else
        log_info "暂无路由备份，可先执行『路由表备份』"
    fi
}

# ------------------------------------------------------------
# [路由] 添加静态路由
# 参数：无
# 返回：无
# ------------------------------------------------------------
route_add() {
    check_root || return 1
    local network gw
    read_input network "目标网段(如 10.10.0.0/16):" ""
    read_input gw "下一跳网关:" ""
    ip route add "${network}" via "${gw}"
    log_success "路由已添加: ${network} via ${gw}"
}

# ------------------------------------------------------------
# [路由] 删除静态路由
# 参数：无
# 返回：无
# ------------------------------------------------------------
route_delete() {
    check_root || return 1
    local network
    read_input network "目标网段(如 10.10.0.0/16):" ""
    ip route del "${network}"
    log_success "路由已删除: ${network}"
}

# ------------------------------------------------------------
# [路由] 备份路由表
# 参数：无
# 返回：无
# ------------------------------------------------------------
route_backup() {
    check_root || return 1
    local file="${BACKUP_DIR}/route-$(date +%Y%m%d_%H%M%S).bak"
    mkdir -p "${BACKUP_DIR}"
    ip route show > "${file}"
    log_success "路由表已备份: ${file}"
}

# ------------------------------------------------------------
# [路由] 一键回滚路由
# 参数：无
# 返回：无
# ------------------------------------------------------------
route_rollback() {
    check_root || return 1
    local file
    read_input file "备份文件路径:" "${BACKUP_DIR}/route-*.bak"
    [[ -f "${file}" ]] || { log_error "备份文件不存在: ${file}"; return 1; }
    confirm_action "回滚路由表（将清空现有路由并恢复备份）" || return 1
    # 删除当前全部路由，再由备份逐条恢复
    while IFS= read -r line; do
        [[ -n "${line}" ]] && ip route del ${line} 2>/dev/null || true
    done < <(ip route show)
    # 逐条恢复备份
    while IFS= read -r line; do
        [[ -n "${line}" ]] && ip route add ${line} 2>/dev/null || true
    done < "${file}"
    log_success "路由表已回滚"
}
# ============================================================
# 网络诊断
# ============================================================
# ------------------------------------------------------------
# [诊断] 网络诊断工具安装与使用
# 参数：无
# 返回：无
# ------------------------------------------------------------
net_diag() {
    check_root || return 1
    local tools=(ping traceroute mtr telnet nc iperf3)
    local need=()
    local t
    for t in "${tools[@]}"; do
        check_command "${t}" || need+=("${t}")
    done
    if [[ ${#need[@]} -gt 0 ]]; then
        log_info "安装诊断工具: ${need[*]}"
        case "$(detect_pkg_manager)" in
            apt)  install_pkg iputils-ping traceroute mtr-tiny netcat-openbsd iperf3 telnet ;;
            dnf|yum) install_pkg iputils traceroute mtr nmap-ncat iperf3 telnet ;;
        esac
    fi
    local act target
    read_input act "诊断类型 [1=延迟ping 2=路由traceroute 3=连通mtr 4=端口telnet 5=带宽iperf3]:" "1"
    case "${act}" in
        1) read_input target "目标:" "www.baidu.com"; ping -c 5 "${target}" ;;
        2) read_input target "目标:" "www.baidu.com"; traceroute "${target}" ;;
        3) read_input target "目标:" "www.baidu.com"; mtr -r -c 10 "${target}" ;;
        4) read_input target "IP:端口(如 1.2.3.4 22):" ""; timeout 5 bash -c "echo | nc -zv ${target} 2>&1" || true ;;
        5) log_warning "iperf3 测速需要服务端配合: 服务端运行 iperf3 -s，客户端选本项输入服务器IP"
           local server
           read_input server "iperf3 服务器 IP:" ""
           iperf3 -c "${server}" ;;
        *) log_error "无效选择" ;;
    esac
}

# ============================================================
# VPN / 代理
# ============================================================
vpn_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [VPN管理] 子菜单"
        echo "======================================"
        echo " 1. 查看 VPN 状态"
        echo " 2. 配置 VPN (WireGuard/OpenVPN)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) vpn_status ;;
            2) vpn_config ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [VPN] 查看 VPN 状态（WireGuard / OpenVPN）
# 参数：无
# 返回：无
# ------------------------------------------------------------
vpn_status() {
    log_info "== VPN 状态 =="
    local found=0
    # WireGuard：wg 命令直接查看接口
    if check_command wg && wg show 2>/dev/null | grep -q .; then
        found=1
        log_info "-- WireGuard 接口 (wg show) --"
        wg show
    fi
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        found=1
        log_info "-- wg-quick@wg0 服务 --"
        systemctl status wg-quick@wg0 --no-pager 2>/dev/null | head -n 15 || true
    fi
    # OpenVPN：systemd 服务或状态日志
    if systemctl is-active --quiet openvpn 2>/dev/null || systemctl is-active --quiet openvpn-server@server 2>/dev/null; then
        found=1
        log_info "-- OpenVPN 服务 --"
        systemctl status openvpn --no-pager 2>/dev/null | head -n 15 || systemctl status openvpn-server@server --no-pager 2>/dev/null | head -n 15 || true
    fi
    if [[ -f /var/log/openvpn/openvpn-status.log ]]; then
        found=1
        log_info "-- OpenVPN 客户端状态 (/var/log/openvpn/openvpn-status.log) --"
        tail -n 20 /var/log/openvpn/openvpn-status.log
    fi
    if [[ ${found} == 0 ]]; then
        log_info "未检测到已配置/运行的 VPN 服务，可先执行『配置 VPN』"
    fi
}

# ------------------------------------------------------------
# [VPN] WireGuard / OpenVPN 配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
vpn_config() {
    check_root || return 1
    local vpn_type
    read_input vpn_type "VPN 类型 [1=WireGuard 2=OpenVPN]:" "1"
    case "${vpn_type}" in
        1)
            case "$(detect_pkg_manager)" in
                apt)  install_pkg wireguard wireguard-tools ;;
                dnf|yum) install_pkg wireguard-tools ;;
            esac
            local wg_dir="/etc/wireguard"
            mkdir -p "${wg_dir}"
            cd "${wg_dir}"
            wg genkey | tee privatekey | wg pubkey > publickey
            chmod 600 privatekey
            local priv pub
            priv=$(cat privatekey); pub=$(cat publickey)
            local server_ip net ip
            read_input server_ip "本机公网IP/域名:" ""
            read_input net "内网网段(如 10.0.0.0/24):" "10.0.0.0/24"
            read_input ip "本机 WireGuard IP:" "10.0.0.1/24"
            cat > wg0.conf <<EOF
# 由 ZETOPS 生成
[Interface]
Address = ${ip}
PrivateKey = ${priv}
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF
            systemctl enable --now wg-quick@wg0 2>/dev/null || wg-quick up wg0 || true
            log_success "WireGuard 服务端配置完成（公钥: ${pub}）"
            log_info "== 当前 WireGuard 状态 =="
            wg show 2>/dev/null || true
            log_info "客户端配置示例: [Interface] Address=10.0.0.2/24 PrivateKey=<client_private> [Peer] PublicKey=${pub} Endpoint=${server_ip}:51820 AllowedIPs=${net}"
            ;;
        2)
            install_pkg openvpn easy-rsa
            log_info "生成 OpenVPN 服务端配置（Easy-RSA）..."
            local ecdir="/etc/openvpn/easy-rsa"
            mkdir -p "${ecdir}"
            cd "${ecdir}"
            if [[ -f /usr/share/easy-rsa/easyrsa ]]; then
                cp -r /usr/share/easy-rsa/* .
                ./easyrsa init-pki 2>/dev/null || true
                log_warning "请依次执行: ./easyrsa build-ca nopass; ./easyrsa gen-req server nopass; ./easyrsa sign-req server server"
            fi
            log_success "OpenVPN 已安装，证书签发按上方提示操作"
            log_info "启动后可执行『查看 VPN 状态』确认运行情况"
            ;;
        *) log_error "无效选择" ;;
    esac
}

proxy_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [代理服务] 子菜单"
        echo "======================================"
        echo " 1. 查看代理服务状态"
        echo " 2. 配置代理服务 (Squid/SS/V2Ray)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) proxy_status ;;
            2) proxy_server ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [代理] 查看代理服务状态（探测常见代理服务/端口监听）
# 参数：无
# 返回：无
# ------------------------------------------------------------
proxy_status() {
    log_info "== 代理服务状态 =="
    local found=0 svc
    for svc in squid shadowsocks-libev ss-server v2ray xray; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            found=1
            log_info "-- ${svc} --"
            systemctl status "${svc}" --no-pager 2>/dev/null | head -n 12 || true
        fi
    done
    if [[ ${found} == 0 ]]; then
        log_info "未检测到运行中的代理服务，检查常用代理端口监听:"
        if check_command ss; then
            ss -tlnp 2>/dev/null | grep -E ':(3128|8388|1080|10808|8080)\b' || log_info "3128(Squid)/8388(SS)/1080(通用代理) 均无监听"
        else
            netstat -tlnp 2>/dev/null | grep -E ':(3128|8388|1080|10808|8080)\b' || log_info "3128(Squid)/8388(SS)/1080(通用代理) 均无监听"
        fi
    fi
}

# ------------------------------------------------------------
# [代理] 代理服务（Squid/SS/V2Ray，配置模板从 API 获取）
# 参数：无
# 返回：无
# ------------------------------------------------------------
proxy_server() {
    check_root || return 1
    local ptype
    read_input ptype "代理类型 [1=Squid 2=Shadowsocks 3=V2Ray]:" "1"
    case "${ptype}" in
        1)
            install_pkg squid
            local template port
            template=$(api_fetch "proxy/squid.conf" || true)
            read_input port "监听端口:" "3128"
            if [[ -n "${template}" ]]; then
                echo "${template}" > /etc/squid/squid.conf
                log_success "已从 API 获取 Squid 配置模板"
            else
                cat > /etc/squid/squid.conf <<EOF
# 由 ZETOPS 生成
http_port ${port}
acl localnet src 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
acl SSL_ports port 443
acl Safe_ports port 80 443 8080
http_access allow localnet
http_access deny all
EOF
            fi
            systemctl enable --now squid 2>/dev/null || true
            log_success "Squid 代理已启动（端口 ${port}）"
            ;;
        2)
            local ss_url
            ss_url=$(api_fetch "proxy/shadowsocks-install" || true)
            if [[ -n "${ss_url}" ]]; then
                curl -fsSL "${ss_url}" | bash || true
            else
                install_pkg shadowsocks-libev
                log_info "请配置 /etc/shadowsocks-libev/config.json 后执行: systemctl restart shadowsocks-libev"
            fi
            log_success "Shadowsocks 代理就绪"
            ;;
        3)
            local v2_url
            v2_url=$(api_fetch "proxy/v2ray-install" || true)
            if [[ -n "${v2_url}" ]]; then
                curl -fsSL "${v2_url}" | bash || true
            else
                log_warning "未配置 API，手动安装参考: https://github.com/v2fly/v2ray-core"
                log_info "建议: bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)"
            fi
            ;;
        *) log_error "无效选择" ;;
    esac
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
