#!/bin/bash
# ============================================================
# 文件：modules/21_ftp_manager.sh
# 功能：FTP 服务管理 [FTP Server Manager]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 基于 vsftpd（最主流 FTP 服务器）
#   - 安装/卸载、启动停止重启、开机自启
#   - FTP 用户管理（创建/删除/锁定/目录绑定）
#   - 匿名访问开关、常见配置项修改（端口/根目录/限速）
#   - 配置语法校验、连接测试（本地 21 端口探测）
# ============================================================
set -euo pipefail

module_name="FTP 服务管理"
module_short="ftp_manager"
module_version="1.0.0"

FTP_CONF="/etc/vsftpd/vsftpd.conf"
FTP_CONF_ALT="/etc/vsftpd.conf"

module_description() {
    echo "vsftpd 安装/启停/用户/匿名/配置/连接测试 [FTP Server Manager]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 服务状态总览"
    echo " 2. 安装 vsftpd"
    echo " 3. 启动/停止/重启"
    echo " 4. FTP 用户管理"
    echo " 5. 匿名访问开关"
    echo " 6. 修改配置项"
    echo " 7. 配置校验与连接测试"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) ftp_status ;;
        2) ftp_install ;;
        3) ftp_control_menu ;;
        4) ftp_user_menu ;;
        5) ftp_anon_toggle ;;
        6) ftp_config_menu ;;
        7) ftp_verify ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 获取配置文件路径
# 输出：配置文件完整路径
# ------------------------------------------------------------
ftp_conf_path() {
    [[ -f "${FTP_CONF}" ]] && { echo "${FTP_CONF}"; return; }
    [[ -f "${FTP_CONF_ALT}" ]] && { echo "${FTP_CONF_ALT}"; return; }
    echo ""
}

# ------------------------------------------------------------
# 读取配置项
# 参数：$1 键名
# 输出：值（无则空）
# ------------------------------------------------------------
ftp_get_conf() {
    local key="$1" conf
    conf=$(ftp_conf_path)
    [[ -z "${conf}" ]] && return
    grep -E "^${key}=" "${conf}" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# ------------------------------------------------------------
# 1. 服务状态总览
# ------------------------------------------------------------
ftp_status() {
    local conf svc
    conf=$(ftp_conf_path)
    echo ""
    log_info "FTP 服务状态"
    echo "--------------------------------------------------"
    if ! check_command vsftpd; then
        echo "  ${COLOR_RED}❌ vsftpd 未安装${COLOR_RESET}"
        echo "  使用菜单 2 安装"
        echo "--------------------------------------------------"
        return
    fi
    # 服务状态（多回退）
    local status
    status=$(ai_get_svc_status vsftpd 2>/dev/null || systemctl is-active vsftpd 2>/dev/null || echo "unknown")
    echo "  ${COLOR_BOLD}服务状态:${COLOR_RESET} $([ "${status}" == "active" ] && echo "${COLOR_GREEN}运行中${COLOR_RESET}" || echo "${COLOR_RED}${status}${COLOR_RESET}")"

    # 端口监听
    local listen
    listen=$(ss -tlnp 2>/dev/null | grep -E ':(21|20) ' || true)
    if [[ -n "${listen}" ]]; then
        echo "  ${COLOR_BOLD}端口监听:${COLOR_RESET} ${COLOR_GREEN}✅${COLOR_RESET}"
        echo "${listen}" | sed 's/^/      /'
    else
        echo "  ${COLOR_BOLD}端口监听:${COLOR_RESET} ${COLOR_RED}❌ 21 端口未监听${COLOR_RESET}"
    fi

    # 配置关键项
    echo ""
    echo "  ${COLOR_BOLD}当前配置关键项:${COLOR_RESET}"
    echo "    配置文件: ${conf}"
    echo "    匿名访问: $(ftp_get_conf anonymous_enable)"
    echo "    本地用户: $(ftp_get_conf local_enable)"
    echo "    写入权限: $(ftp_get_conf write_enable)"
    echo "    被动端口: $(ftp_get_conf pasv_min_port)-$(ftp_get_conf pasv_max_port)"
    echo "    监听端口: $(ftp_get_conf listen_port)"
    echo "    根目录限制: $(ftp_get_conf chroot_local_user)"
    echo "    最大上传速率: $(ftp_get_conf local_max_rate)"
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 2. 安装 vsftpd
# ------------------------------------------------------------
ftp_install() {
    if check_command vsftpd; then
        log_success "vsftpd 已安装: $(vsftpd -v 2>&1 | head -1)"
        return
    fi
    echo ""
    if ! confirm_action "安装 vsftpd（使用系统包管理器）?"; then
        return
    fi
    case "$(detect_pkg_manager)" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y vsftpd ;;
        yum)    sudo yum install -y vsftpd ;;
        dnf)    sudo dnf install -y vsftpd ;;
        zypper) sudo zypper install -y vsftpd ;;
        *)
            log_error "不支持的包管理器: $(detect_pkg_manager)"
            return
            ;;
    esac
    # 启动并设置开机自启（debian 系默认不启动）
    sudo systemctl enable --now vsftpd 2>/dev/null || sudo service vsftpd start 2>/dev/null || true
    log_success "vsftpd 安装完成并已启动"
    audit_log "安装 vsftpd" "成功"
}

# ------------------------------------------------------------
# 3. 启动/停止/重启
# ------------------------------------------------------------
ftp_control_menu() {
    if ! check_command vsftpd; then
        log_warning "vsftpd 未安装，请先安装（菜单 2）"
        return
    fi
    echo ""
    echo "  1. 启动   2. 停止   3. 重启"
    read_input act "选择" ""
    case "${act}" in
        1)
            sudo systemctl start vsftpd 2>/dev/null || sudo service vsftpd start 2>/dev/null || true
            log_success "FTP 服务已启动"
            ;;
        2)
            sudo systemctl stop vsftpd 2>/dev/null || sudo service vsftpd stop 2>/dev/null || true
            log_success "FTP 服务已停止"
            ;;
        3)
            sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
            log_success "FTP 服务已重启"
            ;;
        *) return ;;
    esac
    audit_log "FTP 服务操作" "${act}"
}

# ------------------------------------------------------------
# 4. FTP 用户管理
# ------------------------------------------------------------
ftp_user_menu() {
    echo ""
    echo "  ${COLOR_BOLD}FTP 用户管理${COLOR_RESET}"
    echo "  ${COLOR_GRAY}------------------------------------------------${COLOR_RESET}"
    # 列出已配置的 FTP 用户（vsftpd 虚拟用户列表或系统用户）
    local users
    users=$(getent passwd | awk -F: '$7 ~ /nologin|false/ && $3 >= 1000 {print $1}' | head -20 || true)
    echo "  ${COLOR_BOLD}当前系统受限用户（可用于 FTP）:${COLOR_RESET}"
    if [[ -n "${users}" ]]; then
        echo "  ${users}" | sed 's/^/    /'
    else
        echo "    ${COLOR_GRAY}(无)${COLOR_RESET}"
    fi
    echo "  ${COLOR_GRAY}------------------------------------------------${COLOR_RESET}"
    echo "  1. 创建 FTP 用户"
    echo "  2. 删除 FTP 用户"
    echo "  3. 修改用户密码"
    echo "  4. 锁定/解锁用户"
    read_input act "选择" ""
    case "${act}" in
        1)
            read_input ftp_user "用户名（仅字母数字）" ""
            [[ "${ftp_user}" =~ ^[a-zA-Z0-9_]+$ ]] || { log_error "用户名格式非法"; return; }
            if id "${ftp_user}" >/dev/null 2>&1; then
                log_warning "用户 ${ftp_user} 已存在"
                return
            fi
            read_input home_dir "家目录（默认 /home/${ftp_user}）" "/home/${ftp_user}"
            read_input is_shell "是否允许 SSH 登录？[y/N]" "n"
            local shell="/usr/sbin/nologin"
            [[ "${is_shell}" == "y" || "${is_shell}" == "Y" ]] && shell="/bin/bash"
            if confirm_action "创建用户 ${ftp_user}（家目录 ${home_dir}）?"; then
                sudo useradd -m -d "${home_dir}" -s "${shell}" "${ftp_user}" && {
                    sudo passwd "${ftp_user}"
                    log_success "FTP 用户 ${ftp_user} 创建完成"
                    audit_log "创建 FTP 用户 ${ftp_user}" "成功"
                }
            fi
            ;;
        2)
            read_input ftp_user "要删除的用户名" ""
            id "${ftp_user}" >/dev/null 2>&1 || { log_error "用户不存在"; return; }
            if confirm_action "删除用户 ${ftp_user}（含家目录）？不可恢复"; then
                sudo userdel -r "${ftp_user}" && {
                    log_success "用户 ${ftp_user} 已删除"
                    audit_log "删除 FTP 用户 ${ftp_user}" "成功"
                }
            fi
            ;;
        3)
            read_input ftp_user "用户名" ""
            id "${ftp_user}" >/dev/null 2>&1 || { log_error "用户不存在"; return; }
            sudo passwd "${ftp_user}"
            log_success "密码已修改"
            audit_log "修改 FTP 用户 ${ftp_user} 密码" "成功"
            ;;
        4)
            read_input ftp_user "用户名" ""
            id "${ftp_user}" >/dev/null 2>&1 || { log_error "用户不存在"; return; }
            echo "  1. 锁定（禁止登录）  2. 解锁"
            read_input lock_act "选择" ""
            case "${lock_act}" in
                1) sudo passwd -l "${ftp_user}" && log_success "用户 ${ftp_user} 已锁定" ;;
                2) sudo passwd -u "${ftp_user}" && log_success "用户 ${ftp_user} 已解锁" ;;
            esac
            audit_log "锁定状态操作 ${ftp_user}" "完成"
            ;;
        *) return ;;
    esac
}

# ------------------------------------------------------------
# 5. 匿名访问开关
# ------------------------------------------------------------
ftp_anon_toggle() {
    local conf
    conf=$(ftp_conf_path)
    [[ -z "${conf}" ]] && { log_warning "vsftpd 未安装或配置不存在"; return; }
    local current
    current=$(ftp_get_conf anonymous_enable)
    echo ""
    echo "  当前匿名访问: $([ "${current}" == "YES" ] && echo "${COLOR_GREEN}开启${COLOR_RESET}" || echo "${COLOR_YELLOW}关闭${COLOR_RESET}")"
    if [[ "${current}" == "YES" ]]; then
        if confirm_action "关闭匿名访问？"; then
            sudo sed -i 's/^anonymous_enable=YES/anonymous_enable=NO/' "${conf}"
            sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
            log_success "匿名访问已关闭"
            audit_log "关闭 FTP 匿名访问" "成功"
        fi
    else
        if confirm_action "开启匿名访问？"; then
            sudo sed -i 's/^anonymous_enable=NO/anonymous_enable=YES/' "${conf}" 2>/dev/null
            # 无该行则追加
            grep -q '^anonymous_enable=' "${conf}" || echo "anonymous_enable=YES" | sudo tee -a "${conf}" >/dev/null
            sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
            log_success "匿名访问已开启（默认目录 /srv/ftp 或 /var/ftp）"
            audit_log "开启 FTP 匿名访问" "成功"
        fi
    fi
}

# ------------------------------------------------------------
# 6. 修改配置项（常用项交互修改）
# ------------------------------------------------------------
ftp_config_menu() {
    local conf
    conf=$(ftp_conf_path)
    [[ -z "${conf}" ]] && { log_warning "vsftpd 未安装或配置不存在"; return; }

    echo ""
    echo "  ${COLOR_BOLD}可修改配置项:${COLOR_RESET}"
    echo "  1. 监听端口 (listen_port，默认 21)"
    echo "  2. 根目录限制 (chroot_local_user)"
    echo "  3. 最大上传速率 KB/s (local_max_rate)"
    echo "  4. 被动端口范围 (pasv_min_port/pasv_max_port)"
    echo "  5. 欢迎语 (ftpd_banner)"
    read_input act "选择" ""
    case "${act}" in
        1)
            read_input port "端口号 (默认 21)" "21"
            if confirm_action "将 FTP 端口改为 ${port}？"; then
                grep -q '^listen_port=' "${conf}" && sudo sed -i "s/^listen_port=.*/listen_port=${port}/" "${conf}" || echo "listen_port=${port}" | sudo tee -a "${conf}" >/dev/null
                sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
                log_success "监听端口已改为 ${port}"
                audit_log "修改 FTP 端口为 ${port}" "成功"
            fi
            ;;
        2)
            echo "  当前: chroot_local_user=$(ftp_get_conf chroot_local_user)"
            echo "  ${COLOR_GRAY}开启后用户只能访问自己的家目录，更安全${COLOR_RESET}"
            if confirm_action "开启根目录限制？"; then
                grep -q '^chroot_local_user=' "${conf}" && sudo sed -i 's/^chroot_local_user=.*/chroot_local_user=YES/' "${conf}" || echo "chroot_local_user=YES" | sudo tee -a "${conf}" >/dev/null
                # 同时放行可写根目录
                grep -q '^allow_writeable_chroot=' "${conf}" || echo "allow_writeable_chroot=YES" | sudo tee -a "${conf}" >/dev/null
                sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
                log_success "根目录限制已开启"
                audit_log "开启 FTP chroot" "成功"
            fi
            ;;
        3)
            read_input rate "速率上限 KB/s (0=不限，如 1024=1MB/s)" "1024"
            if confirm_action "设置最大上传速率 ${rate} KB/s？"; then
                grep -q '^local_max_rate=' "${conf}" && sudo sed -i "s/^local_max_rate=.*/local_max_rate=${rate}/" "${conf}" || echo "local_max_rate=${rate}" | sudo tee -a "${conf}" >/dev/null
                sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
                log_success "速率限制已设置: ${rate} KB/s"
                audit_log "设置 FTP 限速 ${rate}" "成功"
            fi
            ;;
        4)
            read_input pmin "被动端口下限（如 30000）" "30000"
            read_input pmax "被动端口上限（如 31000）" "31000"
            if confirm_action "设置被动端口范围 ${pmin}-${pmax}？"; then
                grep -q '^pasv_min_port=' "${conf}" && sudo sed -i "s/^pasv_min_port=.*/pasv_min_port=${pmin}/" "${conf}" || echo "pasv_min_port=${pmin}" | sudo tee -a "${conf}" >/dev/null
                grep -q '^pasv_max_port=' "${conf}" && sudo sed -i "s/^pasv_max_port=.*/pasv_max_port=${pmax}/" "${conf}" || echo "pasv_max_port=${pmax}" | sudo tee -a "${conf}" >/dev/null
                sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
                log_success "被动端口范围已设置 ${pmin}-${pmax}"
                audit_log "设置 FTP 被动端口" "成功"
            fi
            ;;
        5)
            read_input banner "欢迎语" ""
            if confirm_action "设置欢迎语？"; then
                grep -q '^ftpd_banner=' "${conf}" && sudo sed -i "s|^ftpd_banner=.*|ftpd_banner=${banner}|" "${conf}" || echo "ftpd_banner=${banner}" | sudo tee -a "${conf}" >/dev/null
                sudo systemctl restart vsftpd 2>/dev/null || sudo service vsftpd restart 2>/dev/null || true
                log_success "欢迎语已设置"
                audit_log "设置 FTP 欢迎语" "成功"
            fi
            ;;
        *) return ;;
    esac
}

# ------------------------------------------------------------
# 7. 配置校验与连接测试
# ------------------------------------------------------------
ftp_verify() {
    local conf
    conf=$(ftp_conf_path)
    echo ""
    log_info "FTP 配置校验与连接测试"
    echo "--------------------------------------------------"
    if ! check_command vsftpd; then
        echo "  ${COLOR_RED}vsftpd 未安装${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    # 语法校验（-olisten=NO 防止占端口）
    if sudo vsftpd -olisten=NO -opasv_enable=NO -c "${conf}" 2>&1 | grep -v '^$' | grep -qiE 'error|warning'; then
        echo "  ${COLOR_RED}❌ 配置存在错误:${COLOR_RESET}"
        sudo vsftpd -olisten=NO -opasv_enable=NO -c "${conf}" 2>&1 | sed 's/^/      /'
    else
        echo "  ${COLOR_GREEN}✅ 配置语法校验通过${COLOR_RESET}"
    fi
    # 21 端口连接测试
    if (exec 3<>/dev/tcp/127.0.0.1/21) 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        echo "  ${COLOR_GREEN}✅ 端口 21 可连接（本机测试）${COLOR_RESET}"
    else
        echo "  ${COLOR_RED}❌ 端口 21 无法连接，服务可能未运行${COLOR_RESET}"
    fi
    # FTP 命令实测
    if check_command curl; then
        local banner
        banner=$(curl -s --max-time 5 ftp://127.0.0.1/ 2>&1 | head -1 || true)
        if [[ -n "${banner}" ]]; then
            echo "  ${COLOR_GREEN}✅ FTP 服务响应: ${banner}${COLOR_RESET}"
        else
            echo "  ${COLOR_YELLOW}⚠️  FTP 无 banner 响应（可能匿名已关闭）${COLOR_RESET}"
        fi
    fi
    echo "--------------------------------------------------"
    audit_log "FTP 配置校验" "完成"
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
    source "${ZETOPS_ROOT}/core/config.sh"
    log_init
    load_config
    ftp_status
fi
