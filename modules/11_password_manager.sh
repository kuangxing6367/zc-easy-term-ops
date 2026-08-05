#!/bin/bash
# ============================================================
# 文件：modules/11_password_manager.sh
# 功能：密码与权限管理 [Password & Permission Management]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：MySQL/PostgreSQL/Redis 密码重置、Linux 用户密码修改、
#       sudo 权限恢复、SSH 密钥生成与分发、密码策略检查
# 注意：函数统一使用 pm_ 前缀，避免与 database 模块的
#       mysql_*/pg_*/redis_* 函数冲突
# ============================================================
set -euo pipefail

module_name="密码与权限管理"
module_short="password_manager"
module_version="1.0.0"

module_description() {
    echo "MySQL/PostgreSQL/Redis 密码重置、Linux 用户密码、sudo 恢复、SSH 密钥分发、密码策略"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. MySQL root 密码重置"
    echo " 2. MySQL 用户密码修改"
    echo " 3. PostgreSQL 密码重置"
    echo " 4. Redis 密码设置/修改"
    echo " 5. Linux 用户密码修改"
    echo " 6. sudo 权限恢复"
    echo " 7. SSH 密钥生成与分发"
    echo " 8. 密码策略检查"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) pm_mysql_root_reset ;;
        2) pm_mysql_user_passwd ;;
        3) pm_pg_reset ;;
        4) pm_redis_passwd ;;
        5) pm_linux_passwd ;;
        6) pm_sudo_recover ;;
        7) pm_ssh_keygen ;;
        8) pm_policy_check ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [MySQL] root 密码重置（--skip-grant-tables 安全模式）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_mysql_root_reset() {
    check_root || return 1
    check_command mysqld || check_command mariadbd || { log_error "MySQL/MariaDB 未安装"; return 1; }
    confirm_action "重置 MySQL root 密码（服务将临时重启）" || return 1
    local new_pw confirm_pw
    read -s -p "输入新密码: " new_pw || new_pw=""; echo
    read -s -p "再次确认密码: " confirm_pw || confirm_pw=""; echo
    [[ -n "${new_pw}" && "${new_pw}" == "${confirm_pw}" ]] || { log_error "两次输入不一致或为空"; return 1; }

    # 停止数据库，以 --skip-grant-tables 启动
    systemctl stop mysql 2>/dev/null || systemctl stop mysqld 2>/dev/null || systemctl stop mariadb 2>/dev/null || true
    mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld 2>/dev/null || true
    log_warning "以安全模式(skip-grant-tables)启动..."
    mysqld_safe --skip-grant-tables --skip-networking &>/dev/null &
    sleep 5
    # 重置密码
    mysql -uroot <<SQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_pw}';
FLUSH PRIVILEGES;
SQL
    # 关闭安全模式实例
    mysqladmin -uroot shutdown 2>/dev/null || pkill -f skip-grant-tables 2>/dev/null || true
    sleep 2
    # 正常启动
    systemctl start mysql 2>/dev/null || systemctl start mysqld 2>/dev/null || systemctl start mariadb 2>/dev/null || true
    log_success "MySQL root 密码已重置"
}

# ------------------------------------------------------------
# [MySQL] 修改指定用户的密码
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_mysql_user_passwd() {
    check_root || return 1
    check_command mysql || { log_error "MySQL 客户端未安装"; return 1; }
    local user host pw rootpw
    read_input user "用户名:" ""
    read_input host "主机(host):" "localhost"
    read_input pw "新密码:" ""
    read_input rootpw "MySQL root 密码:" ""
    [[ -n "${user}" && -n "${pw}" ]] || { log_error "用户名/密码不能为空"; return 1; }
    mysql -uroot -p"${rootpw}" -e "ALTER USER '${user}'@'${host}' IDENTIFIED BY '${pw}'; FLUSH PRIVILEGES;" 2>/dev/null \
        && log_success "用户 ${user}@${host} 密码已修改" \
        || log_error "修改失败（请检查 root 密码与用户是否存在）"
}

# ------------------------------------------------------------
# [PostgreSQL] 密码重置（pg_hba.conf 临时 trust 模式）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_pg_reset() {
    check_root || return 1
    local hba="/etc/postgresql/$(ls /etc/postgresql 2>/dev/null | tail -n1)/main/pg_hba.conf"
    [[ -f "${hba}" ]] || hba="/var/lib/pgsql/data/pg_hba.conf"
    [[ -f "${hba}" ]] || { log_error "未找到 pg_hba.conf"; return 1; }
    confirm_action "重置 PostgreSQL 密码（临时切换 trust 认证）" || return 1
    local new_pw confirm_pw
    read -s -p "输入新密码: " new_pw || new_pw=""; echo
    read -s -p "再次确认密码: " confirm_pw || confirm_pw=""; echo
    [[ -n "${new_pw}" && "${new_pw}" == "${confirm_pw}" ]] || { log_error "两次输入不一致或为空"; return 1; }

    # 备份并临时改为 trust
    cp "${hba}" "${hba}.bak.$(date +%s)"
    sed -i 's/^\(local\s\+all\s\+all\s\+\)scram-sha-256/\1trust/; s/^\(local\s\+all\s\+all\s\+\)md5/\1trust/; s/^\(local\s\+all\s\+all\s\+\)peer/\1trust/' "${hba}"
    systemctl reload postgresql 2>/dev/null || true
    # 修改密码
    su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${new_pw}';\" " 2>/dev/null \
        || runuser -u postgres -- psql -c "ALTER USER postgres PASSWORD '${new_pw}';"
    # 恢复原认证配置
    local bak
    bak=$(ls -t "${hba}".bak.* | head -n1)
    cp "${bak}" "${hba}"
    systemctl reload postgresql 2>/dev/null || true
    log_success "PostgreSQL postgres 密码已重置（认证配置已恢复）"
}

# ------------------------------------------------------------
# [Redis] 设置/修改密码（redis.conf requirepass）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_redis_passwd() {
    check_root || return 1
    check_command redis-cli || { log_error "Redis 客户端未安装"; return 1; }
    local conf="/etc/redis/redis.conf"
    [[ -f "${conf}" ]] || conf="/etc/redis.conf"
    [[ -f "${conf}" ]] || { log_error "未找到 redis.conf"; return 1; }
    local pw confirm_pw
    read -s -p "输入新密码: " pw || pw=""; echo
    read -s -p "再次确认密码: " confirm_pw || confirm_pw=""; echo
    [[ -n "${pw}" && "${pw}" == "${confirm_pw}" ]] || { log_error "两次输入不一致或为空"; return 1; }
    cp "${conf}" "${conf}.bak.$(date +%s)"
    # 修改 requirepass（去注释/替换/追加）
    sed -i 's/^#\?requirepass .*/requirepass '"${pw}"'/' "${conf}"
    grep -q "^requirepass" "${conf}" || echo "requirepass ${pw}" >> "${conf}"
    systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null || true
    redis-cli -a "${pw}" ping 2>/dev/null && log_success "Redis 密码已设置" || log_warning "已修改配置，请确认服务已重启"
}

# ------------------------------------------------------------
# [Linux] 修改用户密码（passwd）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_linux_passwd() {
    check_root || return 1
    local user
    read_input user "用户名:" ""
    id "${user}" >/dev/null 2>&1 || { log_error "用户不存在: ${user}"; return 1; }
    log_info "交互式修改用户 ${user} 密码（passwd 工具）..."
    passwd "${user}"
    log_success "用户 ${user} 密码修改完成"
}

# ------------------------------------------------------------
# [sudo] sudo 权限恢复（加入 sudo 组 + visudo -c 检查修复）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_sudo_recover() {
    check_root || return 1
    local user
    read_input user "需要恢复 sudo 权限的用户名:" ""
    id "${user}" >/dev/null 2>&1 || { log_error "用户不存在: ${user}"; return 1; }
    confirm_action "将用户 ${user} 加入 sudo/wheel 组并修复 sudoers" || return 1
    # 加入 sudo 组（Debian/Ubuntu）与 wheel 组（RHEL 系）
    local group=""
    getent group sudo >/dev/null && group="sudo"
    getent group wheel >/dev/null && group="wheel"
    if [[ -n "${group}" ]]; then
        usermod -aG "${group}" "${user}"
        log_success "已加入 ${group} 组"
    else
        # 无 sudo/wheel 组时直接写入 sudoers
        echo "${user} ALL=(ALL) ALL" >> /etc/sudoers
        log_success "已写入 /etc/sudoers"
    fi
    # visudo -c 检查语法
    if check_command visudo; then
        if visudo -c 2>&1 | grep -q "parsed OK"; then
            log_success "sudoers 语法检查通过 (visudo -c)"
        else
            log_warning "sudoers 存在语法问题，正在修复备份..."
            visudo -c 2>&1 | head -n 5 || true
        fi
    fi
    # 确保 /etc/sudoers 权限正确
    chmod 440 /etc/sudoers 2>/dev/null || true
    log_success "sudo 权限恢复完成"
}

# ------------------------------------------------------------
# [SSH密钥] 生成密钥对（RSA/ED25519）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_ssh_keygen() {
    local type email
    read_input type "密钥类型 [1=ED25519 2=RSA]:" "1"
    read_input email "邮箱/注释(用于标识):" ""
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    if [[ "${type}" == "2" ]]; then
        ssh-keygen -t rsa -b 4096 -C "${email}" -f ~/.ssh/id_rsa
        log_success "RSA 密钥对已生成: ~/.ssh/id_rsa(.pub)"
    else
        ssh-keygen -t ed25519 -C "${email}" -f ~/.ssh/id_ed25519
        log_success "ED25519 密钥对已生成: ~/.ssh/id_ed25519(.pub)"
    fi
    log_info "公钥内容（可复制到目标服务器 authorized_keys）:"
    cat ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null || true
}

# ------------------------------------------------------------
# [SSH分发] 密钥分发到远程服务器（ssh-copy-id）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_ssh_distribute() {
    local ip user port
    read_input ip "远程服务器 IP:" ""
    validate_ip "${ip}" || { log_error "IP 无效"; return 1; }
    read_input user "远程用户名:" "root"
    read_input port "SSH 端口:" "22"
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    # 确保本地有密钥
    local key=""
    [[ -f ~/.ssh/id_ed25519.pub ]] && key=~/.ssh/id_ed25519.pub
    [[ -f ~/.ssh/id_rsa.pub ]] && key=~/.ssh/id_rsa.pub
    if [[ -z "${key}" ]]; then
        log_warning "本地无密钥，先生成 ED25519..."
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
        key=~/.ssh/id_ed25519.pub
    fi
    ssh-copy-id -p "${port}" -i "${key}" "${user}@${ip}" || { log_error "密钥分发失败"; return 1; }
    log_success "密钥已分发到 ${user}@${ip}:${port}"
    log_info "验证: ssh -p ${port} ${user}@${ip}"
}

# ------------------------------------------------------------
# [密码策略] 检查密码复杂度/有效期/失败锁定策略
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_policy_check() {
    check_root || return 1
    echo "===== 密码策略检查 (Password Policy) ====="
    echo ""
    echo "== 1. 密码复杂度 (pam_pwquality / pwquality) =="
    local pq="/etc/security/pwquality.conf"
    if [[ -f "${pq}" ]]; then
        grep -vE '^\s*#|^\s*$' "${pq}" || echo "  （未自定义，使用系统默认）"
    fi
    echo ""
    echo "== 2. 密码有效期 (/etc/login.defs) =="
    grep -E 'PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE' /etc/login.defs | grep -v '^#'
    echo ""
    echo "== 3. 失败锁定策略 (pam_faillock / pam_tally2) =="
    if check_command faillock; then
        faillock 2>/dev/null | head -n 10 || true
    else
        grep -rE 'pam_faillock|pam_tally' /etc/pam.d/ 2>/dev/null | head -n 5 || echo "  未启用失败锁定"
    fi
    echo ""
    read_input do_set "是否交互修改策略? [y/n]:" "n"
    if [[ "${do_set}" == "y" ]]; then
        pm_policy_set
    fi
}

# ------------------------------------------------------------
# [密码策略] 交互修改策略
# 参数：无
# 返回：无
# ------------------------------------------------------------
pm_policy_set() {
    check_root || return 1
    local min_len max_days min_days warn fail_attempts
    read_input min_len "最小密码长度(复杂度):" "12"
    read_input max_days "密码最长有效期(天):" "90"
    read_input min_days "最短修改间隔(天):" "7"
    read_input warn "过期提醒天数:" "14"
    read_input fail_attempts "连续失败锁定次数:" "5"
    # 复杂度
    if [[ -f /etc/security/pwquality.conf ]]; then
        cp /etc/security/pwquality.conf "/etc/security/pwquality.conf.bak.$(date +%s)"
        echo -e "minlen = ${min_len}\ndcredit = -1\nucredit = -1\ndifok = 3" > /etc/security/pwquality.conf
    fi
    # 有效期
    cp /etc/login.defs "/etc/login.defs.bak.$(date +%s)"
    sed -i "s/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   ${max_days}/; s/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   ${min_days}/; s/^PASS_WARN_AGE.*/PASS_WARN_AGE   ${warn}/" /etc/login.defs
    # 失败锁定（pam_faillock 通用配置）
    local pam_common="/etc/pam.d/common-auth"
    local pam_system="/etc/pam.d/system-auth"
    if [[ -f "${pam_common}" ]] || [[ -f "${pam_system}" ]]; then
        local target=""
        [[ -f "${pam_common}" ]] && target="${pam_common}"
        [[ -f "${pam_system}" ]] && target="${pam_system}"
        if ! grep -q pam_faillock "${target}"; then
            cp "${target}" "${target}.bak.$(date +%s)"
            sed -i "1i auth required pam_faillock.so preauth audit silent deny=${fail_attempts} unlock_time=600" "${target}"
            sed -i "1i auth [default=die] pam_faillock.so authfail audit deny=${fail_attempts} unlock_time=600" "${target}"
        fi
        log_warning "已启用 pam_faillock（失败 ${fail_attempts} 次锁定10分钟）"
    fi
    log_success "密码策略已更新（请在新会话中验证生效）"
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
