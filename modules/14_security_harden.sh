#!/bin/bash
# ============================================================
# 文件：modules/14_security_harden.sh
# 功能：安全基线扫描与一键加固 [Security Baseline & Hardening]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 纯 Shell 实现 CIS 风格基线检查（零外部依赖）
#   - 检查项：空密码账户/uid=0非root/权限/SUID/防火墙/SSH/密码策略/内核参数
#   - 扫描只读，加固逐项交互确认，全程写审计日志
# ============================================================
set -euo pipefail

module_name="安全基线加固"
module_short="security_harden"
module_version="1.0.0"

# 审计日志文件（与 16_audit_log 共用）
AUDIT_FILE="${AUDIT_FILE:-${HOME}/.zetops/audit.log}"

module_description() {
    echo "安全基线扫描(CIS风格)、一键加固、审计记录 [Security Baseline & Hardening]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 安全基线扫描（只读检查）"
    echo " 2. 一键加固（逐项确认执行）"
    echo " 3. 查看最近审计记录"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) security_scan ;;
        2) security_harden ;;
        3) security_audit_view ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ---- 扫描结果容器（全局，供加固复用） ----
SEC_RESULTS=()   # "检查项ID|状态(pass/fail/warn)|描述"
SEC_FAIL_IDS=()  # 失败项 ID 列表

# ------------------------------------------------------------
# 写入审计日志
# 参数：$1 操作描述  $2 结果
# ------------------------------------------------------------
security_audit() {
    mkdir -p "$(dirname "${AUDIT_FILE}")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $(whoami) | ${CURRENT_MODULE} | $1 | $2" >> "${AUDIT_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 记录一条扫描结果
# 参数：$1 ID  $2 状态  $3 描述
# ------------------------------------------------------------
sec_record() {
    SEC_RESULTS+=("$1|$2|$3")
    if [[ "$2" == "fail" ]]; then
        SEC_FAIL_IDS+=("$1")
    fi
}

# ------------------------------------------------------------
# 安全基线扫描（只读，不修改任何配置）
# 参数：无
# 返回：无
# ------------------------------------------------------------
security_scan() {
    SEC_RESULTS=()
    SEC_FAIL_IDS=()
    echo ""
    log_info "开始安全基线扫描（只读检查）..."

    # ---- 1. 空密码账户 ----
    local empty_pwd
    empty_pwd=$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null || true)
    if [[ -n "${empty_pwd}" ]]; then
        sec_record "empty_pwd" "fail" "存在空密码账户: $(echo "${empty_pwd}" | tr '\n' ' ')"
    else
        sec_record "empty_pwd" "pass" "无空密码账户"
    fi

    # ---- 2. UID=0 的非 root 账户 ----
    local uid0
    uid0=$(awk -F: '($3==0 && $1!="root"){print $1}' /etc/passwd 2>/dev/null || true)
    if [[ -n "${uid0}" ]]; then
        sec_record "uid0" "fail" "存在 UID=0 非 root 账户: ${uid0}"
    else
        sec_record "uid0" "pass" "仅 root 拥有 UID=0"
    fi

    # ---- 3. 关键文件权限 ----
    local passwd_perm shadow_perm
    passwd_perm=$(stat -c '%a' /etc/passwd 2>/dev/null || echo "?")
    shadow_perm=$(stat -c '%a' /etc/shadow 2>/dev/null || echo "?")
    if [[ "${passwd_perm}" == "644" ]] && [[ "${shadow_perm}" == "600" || "${shadow_perm}" == "640" ]]; then
        sec_record "file_perm" "pass" "/etc/passwd(${passwd_perm}) /etc/shadow(${shadow_perm}) 权限正常"
    else
        sec_record "file_perm" "fail" "/etc/passwd(${passwd_perm}) /etc/shadow(${shadow_perm}) 权限异常"
    fi

    # ---- 4. 世界可写文件（/etc 下） ----
    local world_writable
    world_writable=$(find /etc -maxdepth 2 -type f -perm -0002 2>/dev/null | head -5 || true)
    if [[ -n "${world_writable}" ]]; then
        sec_record "world_writable" "warn" "发现世界可写文件: $(echo "${world_writable}" | tr '\n' ' ')"
    else
        sec_record "world_writable" "pass" "/etc 下无世界可写文件"
    fi

    # ---- 5. SUID/SGID 文件 ----
    local suid_count
    suid_count=$(find /usr -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l)
    if (( suid_count > 50 )); then
        sec_record "suid" "warn" "SUID/SGID 文件数量较多: ${suid_count} 个"
    else
        sec_record "suid" "pass" "SUID/SGID 文件: ${suid_count} 个"
    fi

    # ---- 6. 防火墙状态 ----
    local fw_status="未启用"
    if check_command ufw; then
        fw_status=$(ufw status 2>/dev/null | head -1 || echo "未启用")
    elif check_command firewall-cmd; then
        if firewall-cmd --state 2>/dev/null | grep -q running; then fw_status="运行中"; fi
    elif check_command iptables; then
        if iptables -L -n 2>/dev/null | grep -qE 'policy|ACCEPT'; then fw_status="存在规则"; fi
    fi
    if [[ "${fw_status}" == "未启用" || "${fw_status}" == "inactive" ]]; then
        sec_record "firewall" "fail" "防火墙未启用"
    else
        sec_record "firewall" "pass" "防火墙: ${fw_status}"
    fi

    # ---- 7. SSH 配置风险 ----
    local sshd_conf="/etc/ssh/sshd_config"
    if [[ -f "${sshd_conf}" ]]; then
        local root_login pwd_auth
        root_login=$(grep -E '^PermitRootLogin' "${sshd_conf}" 2>/dev/null | awk '{print $2}' || true)
        pwd_auth=$(grep -E '^PasswordAuthentication' "${sshd_conf}" 2>/dev/null | awk '{print $2}' || true)
        if [[ "${root_login}" == "yes" ]]; then
            sec_record "ssh_root" "fail" "SSH 允许 root 登录 (PermitRootLogin yes)"
        else
            sec_record "ssh_root" "pass" "SSH root 登录: ${root_login:-未显式配置}"
        fi
        if [[ "${pwd_auth}" == "yes" ]]; then
            sec_record "ssh_pwd" "warn" "SSH 允许密码登录，建议改用密钥"
        else
            sec_record "ssh_pwd" "pass" "SSH 密码登录: ${pwd_auth:-未显式配置}"
        fi
    else
        sec_record "ssh" "warn" "未找到 sshd_config，跳过 SSH 检查"
    fi

    # ---- 8. 密码策略 ----
    if [[ -f /etc/login.defs ]]; then
        local max_days
        max_days=$(grep -E '^PASS_MAX_DAYS' /etc/login.defs 2>/dev/null | awk '{print $2}' || true)
        if (( max_days > 90 )); then
            sec_record "pwd_max" "fail" "密码最大有效期 ${max_days} 天（建议 ≤90）"
        else
            sec_record "pwd_max" "pass" "密码有效期: ${max_days:-未配置} 天"
        fi
    fi

    # ---- 9. 内核转发与 ICMP 重定向 ----
    local ip_forward
    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [[ "${ip_forward}" == "1" ]]; then
        sec_record "ip_forward" "warn" "IP 转发已开启（非路由器建议关闭）"
    else
        sec_record "ip_forward" "pass" "IP 转发已关闭"
    fi

    # ---- 10. 开放端口 ----
    local open_ports
    open_ports=$(ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ' || true)
    sec_record "open_ports" "info" "当前监听端口: ${open_ports:-无}"

    # ---- 输出报告 ----
    echo ""
    log_info "扫描报告（共 ${#SEC_RESULTS[@]} 项）"
    echo "--------------------------------------------------"
    local line status desc
    for line in "${SEC_RESULTS[@]}"; do
        status="${line#*|}"
        desc="${status#*|}"
        status="${status%%|*}"
        case "${status}" in
            pass) echo "  ${COLOR_GREEN}[PASS]${COLOR_RESET} ${desc}" ;;
            fail) echo "  ${COLOR_RED}[FAIL]${COLOR_RESET} ${desc}" ;;
            warn) echo "  ${COLOR_YELLOW}[WARN]${COLOR_RESET} ${desc}" ;;
            info) echo "  ${COLOR_BLUE}[INFO]${COLOR_RESET} ${desc}" ;;
        esac
    done
    echo "--------------------------------------------------"
    echo "  通过 ${#SEC_RESULTS[@]} 项，失败 ${#SEC_FAIL_IDS[@]} 项"
    security_audit "安全基线扫描" "完成，${#SEC_RESULTS[@]}项检查，${#SEC_FAIL_IDS[@]}项失败"
}

# ------------------------------------------------------------
# 一键加固（逐项确认执行，危险项二次确认）
# 参数：无
# 返回：无
# ------------------------------------------------------------
security_harden() {
    [[ "$(id -u)" -ne 0 ]] && { log_error "加固操作需要 root 权限"; return 1; }

    # 若未扫描过则先扫描
    if [[ ${#SEC_RESULTS[@]} -eq 0 ]]; then
        log_info "先执行一次基线扫描..."
        security_scan
    fi

    echo ""
    log_warning "开始一键加固（每项都会询问确认，可随时跳过）"

    local item
    for item in "${SEC_FAIL_IDS[@]}"; do
        case "${item}" in
            empty_pwd)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 锁定空密码账户${COLOR_RESET}"
                local users
                users=$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null || true)
                echo "  ${COLOR_GRAY}命令: passwd -l <空密码账户>${COLOR_RESET}"
                if confirm_action "锁定空密码账户: ${users}"; then
                    local u
                    for u in ${users}; do
                        passwd -l "${u}" >/dev/null 2>&1 && echo "  ${COLOR_GREEN}✅ 已锁定 ${u}${COLOR_RESET}"
                    done
                    security_audit "锁定空密码账户" "成功"
                fi
                ;;
            uid0)
                echo ""
                echo "  ${COLOR_BOLD}[加固] UID=0 非 root 账户${COLOR_RESET}"
                echo "  ${COLOR_YELLOW}⚠️  此操作需人工判断：建议检查 /etc/passwd 中 UID=0 账户是否必要${COLOR_RESET}"
                local uid0_users
                uid0_users=$(awk -F: '($3==0 && $1!="root"){print $1}' /etc/passwd 2>/dev/null || true)
                if confirm_action "删除 UID=0 非 root 账户: ${uid0_users}（不可恢复，请谨慎）"; then
                    local u
                    for u in ${uid0_users}; do
                        userdel -r "${u}" 2>/dev/null && echo "  ${COLOR_GREEN}✅ 已删除 ${u}${COLOR_RESET}"
                    done
                    security_audit "删除 UID=0 非root账户" "成功"
                fi
                ;;
            file_perm)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 修复关键文件权限${COLOR_RESET}"
                if confirm_action "修复 /etc/passwd=644 /etc/shadow=600"; then
                    chmod 644 /etc/passwd
                    chmod 600 /etc/shadow
                    echo "  ${COLOR_GREEN}✅ 权限已修复${COLOR_RESET}"
                    security_audit "修复关键文件权限" "成功"
                fi
                ;;
            world_writable)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 修复世界可写文件${COLOR_RESET}"
                if confirm_action "去除 /etc 下世界可写位（chmod o-w）"; then
                    find /etc -maxdepth 2 -type f -perm -0002 -exec chmod o-w {} \; 2>/dev/null
                    echo "  ${COLOR_GREEN}✅ 已去除世界可写位${COLOR_RESET}"
                    security_audit "去除世界可写文件权限" "成功"
                fi
                ;;
            firewall)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 启用防火墙${COLOR_RESET}"
                if check_command ufw; then
                    if confirm_action "启用 UFW 防火墙（将拒绝外部未放行连接）"; then
                        ufw --force enable >/dev/null 2>&1
                        echo "  ${COLOR_GREEN}✅ UFW 已启用${COLOR_RESET}"
                        security_audit "启用 UFW 防火墙" "成功"
                    fi
                elif check_command firewall-cmd; then
                    if confirm_action "启动 firewalld"; then
                        systemctl enable --now firewalld >/dev/null 2>&1
                        echo "  ${COLOR_GREEN}✅ firewalld 已启用${COLOR_RESET}"
                        security_audit "启用 firewalld" "成功"
                    fi
                else
                    log_warning "未检测到 ufw/firewalld，跳过"
                fi
                ;;
            ssh_root)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 禁用 SSH root 登录${COLOR_RESET}"
                if confirm_action "设置 PermitRootLogin no（需已有其他可登录账户，否则可能锁死）"; then
                    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
                    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
                    echo "  ${COLOR_GREEN}✅ SSH root 登录已禁用${COLOR_RESET}"
                    security_audit "禁用 SSH root 登录" "成功"
                fi
                ;;
            ssh_pwd)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 禁用 SSH 密码登录${COLOR_RESET}"
                if confirm_action "设置 PasswordAuthentication no（请确认已配置密钥登录）"; then
                    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
                    echo "  ${COLOR_GREEN}✅ SSH 密码登录已禁用${COLOR_RESET}"
                    security_audit "禁用 SSH 密码登录" "成功"
                fi
                ;;
            pwd_max)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 设置密码有效期${COLOR_RESET}"
                if confirm_action "设置 PASS_MAX_DAYS 90"; then
                    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 90/' /etc/login.defs
                    echo "  ${COLOR_GREEN}✅ 密码有效期已设为 90 天${COLOR_RESET}"
                    security_audit "设置密码有效期90天" "成功"
                fi
                ;;
            ip_forward)
                echo ""
                echo "  ${COLOR_BOLD}[加固] 关闭 IP 转发${COLOR_RESET}"
                if confirm_action "关闭 net.ipv4.ip_forward（如作为路由器请跳过）"; then
                    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1
                    echo "  ${COLOR_GREEN}✅ IP 转发已关闭${COLOR_RESET}"
                    security_audit "关闭 IP 转发" "成功"
                fi
                ;;
        esac
    done

    echo ""
    log_success "加固流程结束"
    security_audit "一键加固" "流程结束"
    echo ""
    log_info "建议重新扫描验证: 选择菜单 1"
}

# ------------------------------------------------------------
# 查看最近审计记录
# 参数：无
# 返回：无
# ------------------------------------------------------------
security_audit_view() {
    echo ""
    log_info "最近 20 条审计记录 (${AUDIT_FILE})"
    echo "--------------------------------------------------"
    if [[ -f "${AUDIT_FILE}" ]]; then
        tail -20 "${AUDIT_FILE}" | sed 's/^/  /'
    else
        echo "  ${COLOR_GRAY}(暂无审计记录)${COLOR_RESET}"
    fi
    echo "--------------------------------------------------"
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
    security_scan
fi
