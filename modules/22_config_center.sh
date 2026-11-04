#!/bin/bash
# ============================================================
# 文件：modules/22_config_center.sh
# 功能：配置文件中心 [Config File Center]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 常用配置文件统一入口（Nginx/Apache/MySQL/Redis/SSH/系统）
#   - 查看/编辑/备份（.bak.时间戳）/恢复备份/语法校验
#   - 内置常见配置文件路径自动探测（多发行版兼容）
#   - 编辑前自动备份，修改后可一键回滚
# ============================================================
set -euo pipefail

module_name="配置文件中心"
module_short="config_center"
module_version="1.0.0"

CFG_BACKUP_DIR="${CFG_BACKUP_DIR:-${HOME}/.zetops/config_backup}"

module_description() {
    echo "常用配置文件查看/编辑/备份/恢复/语法校验 [Config File Center]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 常用配置列表（自动探测）"
    echo " 2. 查看配置"
    echo " 3. 编辑配置（自动备份）"
    echo " 4. 手动备份配置"
    echo " 5. 恢复备份"
    echo " 6. 语法校验"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) cfg_list ;;
        2) cfg_view ;;
        3) cfg_edit ;;
        4) cfg_backup_manual ;;
        5) cfg_restore ;;
        6) cfg_check ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 探测常用配置文件（按类型分组）
# 输出：每行 "组|名称|路径|校验命令"
# ------------------------------------------------------------
cfg_discover() {
    local entries=()
    local p
    # Nginx
    p=""
    for f in /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf /usr/local/etc/nginx/nginx.conf; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("Web|Nginx 主配置|${p}|nginx -t")
    # Apache
    p=""
    for f in /etc/apache2/apache2.conf /etc/httpd/conf/httpd.conf; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("Web|Apache 主配置|${p}|apachectl -t")
    # MySQL
    p=""
    for f in /etc/mysql/my.cnf /etc/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("数据库|MySQL 配置|${p}|mysqld --validate-config")
    # MariaDB
    p=""
    for f in /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/my.cnf; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("数据库|MariaDB 配置|${p}|mariadbd --validate-config")
    # Redis
    p=""
    for f in /etc/redis/redis.conf /etc/redis.conf; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("数据库|Redis 配置|${p}|redis-server --test-memory 1")
    # SSH
    p=""
    for f in /etc/ssh/sshd_config; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("安全|SSH 服务端配置|${p}|sshd -t")
    # 系统
    p=""
    [[ -f /etc/hosts ]] && entries+=("系统|hosts 映射|/etc/hosts|")
    [[ -f /etc/fstab ]] && entries+=("系统|fstab 挂载|/etc/fstab|mount -a --fake")
    [[ -f /etc/rsyslog.conf ]] && entries+=("系统|rsyslog 日志|/etc/rsyslog.conf|rsyslogd -N1")
    [[ -f /etc/resolv.conf ]] && entries+=("网络|DNS 配置|/etc/resolv.conf|")
    [[ -f /etc/sysctl.conf ]] && entries+=("内核|sysctl 参数|/etc/sysctl.conf|sysctl -p --dry-run")
    [[ -f /etc/vsftpd/vsftpd.conf ]] && entries+=("FTP|vsftpd 配置|/etc/vsftpd/vsftpd.conf|")
    [[ -f /etc/vsftpd.conf ]] && entries+=("FTP|vsftpd 配置|/etc/vsftpd.conf|")
    [[ -f /etc/samba/smb.conf ]] && entries+=("共享|Samba 配置|/etc/samba/smb.conf|testparm -s")
    # PHP
    p=""
    for f in /etc/php/*/cli/php.ini /etc/php.ini; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("Web|PHP 配置|${p}|php -l")
    # Docker
    p=""
    for f in /etc/docker/daemon.json; do
        [[ -f "${f}" ]] && { p="${f}"; break; }
    done
    [[ -n "${p}" ]] && entries+=("容器|Docker daemon|${p}|docker info")

    printf '%s\n' "${entries[@]}"
}

# ------------------------------------------------------------
# 1. 常用配置列表
# ------------------------------------------------------------
cfg_list() {
    local entries
    entries=$(cfg_discover)
    echo ""
    log_info "常用配置文件（自动探测）"
    echo "--------------------------------------------------"
    if [[ -z "${entries}" ]]; then
        echo "  ${COLOR_GRAY}(未探测到任何配置文件)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local i=0 line group name path chk
    while IFS='|' read -r group name path chk; do
        i=$((i + 1))
        printf "  [%2d] %-4s %-16s %s\n" "${i}" "${group}" "${name}" "${COLOR_GRAY}${path}${COLOR_RESET}"
    done <<< "${entries}"
    echo "--------------------------------------------------"
    echo "  共 ${i} 个配置文件"
    echo ""
    echo "  ${COLOR_GRAY}提示: 直接输入上面的序号即可对文件操作（查看/编辑/备份/校验）${COLOR_RESET}"
}

# ------------------------------------------------------------
# 解析序号/路径 → 配置路径
# 参数：$1 用户输入（序号或路径）
# 输出：文件完整路径（空=失败）
# ------------------------------------------------------------
cfg_resolve() {
    local input="$1"
    if [[ -z "${input}" ]]; then
        return 1
    fi
    # 直接路径
    if [[ "${input}" == /* ]]; then
        [[ -f "${input}" ]] && { echo "${input}"; return 0; }
        log_error "文件不存在: ${input}"
        return 1
    fi
    # 序号
    if [[ "${input}" =~ ^[0-9]+$ ]]; then
        local entries
        entries=$(cfg_discover)
        local line
        line=$(echo "${entries}" | sed -n "${input}p")
        if [[ -n "${line}" ]]; then
            echo "${line}" | cut -d'|' -f3
            return 0
        fi
    fi
    log_error "无效序号或路径: ${input}"
    return 1
}

# ------------------------------------------------------------
# 显示配置文件信息（用于选择）
# ------------------------------------------------------------
cfg_show_select() {
    local entries
    entries=$(cfg_discover)
    local i=0 line
    while IFS='|' read -r group name path chk; do
        i=$((i + 1))
        echo "  [$((i + 1))] ${name} (${path})"
    done <<< "${entries}"
}

# ------------------------------------------------------------
# 2. 查看配置
# ------------------------------------------------------------
cfg_view() {
    local entries
    entries=$(cfg_discover)
    if [[ -z "${entries}" ]]; then
        log_warning "未探测到配置文件"
        return
    fi
    echo ""
    cfg_show_select
    echo ""
    read_input sel "输入序号或路径" ""
    local full
    full=$(cfg_resolve "${sel}") || return
    echo ""
    local lines
    lines=$(wc -l < "${full}" | tr -d ' ')
    echo "  ${COLOR_BOLD}--- ${full} (${lines} 行) ---${COLOR_RESET}"
    # 去掉空行后显示（配置文件空行多）
    grep -v '^[[:space:]]*\(#\|;\)' "${full}" 2>/dev/null | grep -v '^[[:space:]]*$' | head -60 | sed 's/^/  /'
    if (( lines > 60 )); then
        echo ""
        echo "  ${COLOR_GRAY}文件共 ${lines} 行，显示有效配置前 60 行${COLOR_RESET}"
    fi
    echo ""
}

# ------------------------------------------------------------
# 3. 编辑配置（编辑前自动备份）
# ------------------------------------------------------------
cfg_edit() {
    echo ""
    cfg_show_select
    echo ""
    read_input sel "输入要编辑的序号或路径" ""
    local full
    full=$(cfg_resolve "${sel}") || return

    # 自动备份
    mkdir -p "${CFG_BACKUP_DIR}" 2>/dev/null || true
    local bak_name
    bak_name=$(echo "${full}" | tr '/' '_' | sed 's/^_//')
    local bak_path="${CFG_BACKUP_DIR}/${bak_name}.$(date +%Y%m%d_%H%M%S)"
    cp "${full}" "${bak_path}" 2>/dev/null && {
        log_info "已自动备份: ${bak_path}"
    }

    echo ""
    echo "  1. nano   2. vi   3. 不编辑返回"
    read_input editor "选择编辑器" "1"
    case "${editor}" in
        1)
            check_command nano || { log_error "未安装 nano"; return; }
            sudo nano "${full}"
            ;;
        2)
            check_command vi || { log_error "未安装 vi"; return; }
            sudo vi "${full}"
            ;;
        *) return ;;
    esac
    log_success "编辑完成: ${full}"
    echo ""
    echo "  ${COLOR_GRAY}如需回滚请用菜单 5 恢复备份${COLOR_RESET}"
    audit_log "编辑配置 ${full}" "成功"
}

# ------------------------------------------------------------
# 4. 手动备份配置
# ------------------------------------------------------------
cfg_backup_manual() {
    echo ""
    read_input full "输入配置文件路径" ""
    [[ -z "${full}" ]] && return
    [[ -f "${full}" ]] || { log_error "文件不存在"; return; }
    mkdir -p "${CFG_BACKUP_DIR}" 2>/dev/null || true
    local bak_name
    bak_name=$(echo "${full}" | tr '/' '_' | sed 's/^_//')
    local bak_path="${CFG_BACKUP_DIR}/${bak_name}.$(date +%Y%m%d_%H%M%S)"
    cp "${full}" "${bak_path}" 2>/dev/null && {
        log_success "备份完成: ${bak_path}"
        audit_log "备份配置 ${full}" "成功"
    } || log_error "备份失败（权限不足）"
}

# ------------------------------------------------------------
# 5. 恢复备份
# ------------------------------------------------------------
cfg_restore() {
    if [[ ! -d "${CFG_BACKUP_DIR}" ]] || [[ -z "$(ls -A "${CFG_BACKUP_DIR}" 2>/dev/null)" ]]; then
        log_warning "暂无备份（${CFG_BACKUP_DIR}）"
        return
    fi
    echo ""
    log_info "可用备份（${CFG_BACKUP_DIR}）"
    echo "--------------------------------------------------"
    local i=0 f
    local backups=()
    for f in "${CFG_BACKUP_DIR}"/*; do
        [[ -f "${f}" ]] || continue
        i=$((i + 1))
        backups+=("${f}")
        echo "  [$((i + 1))] $(basename "${f}")"
    done
    echo "--------------------------------------------------"
    read_input sel "输入备份序号" ""
    [[ -z "${sel}" ]] && return
    if ! [[ "${sel}" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#backups[@]} )); then
        log_error "无效序号"
        return
    fi
    local bk="${backups[$((sel - 1))]}"
    # 从备份名反推原路径：/etc_nginx_nginx.conf.20260806_120000 → /etc/nginx/nginx.conf
    local orig
    orig=$(basename "${bk}" | sed 's/\.\(2026\|20[0-9][0-9]\)[0-9_]*$//' | tr '_' '/')
    orig="/${orig#/}"
    echo ""
    echo "  ${COLOR_YELLOW}备份: $(basename "${bk}")${COLOR_RESET}"
    echo "  将恢复到: ${orig}"
    if confirm_action "确认恢复？当前文件会先备份"; then
        if [[ -f "${orig}" ]]; then
            cp "${orig}" "${bk}.pre_restore" 2>/dev/null || true
        fi
        if sudo cp "${bk}" "${orig}" 2>/dev/null; then
            log_success "已恢复: ${orig}"
            audit_log "恢复配置 ${orig}" "成功"
        else
            log_error "恢复失败（权限不足）"
        fi
    fi
}

# ------------------------------------------------------------
# 6. 语法校验
# ------------------------------------------------------------
cfg_check() {
    local entries
    entries=$(cfg_discover)
    echo ""
    log_info "配置文件语法校验"
    echo "--------------------------------------------------"
    if [[ -z "${entries}" ]]; then
        echo "  ${COLOR_GRAY}(未探测到配置文件)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local line group name path chk ok=0 fail=0
    while IFS='|' read -r group name path chk; do
        if [[ -z "${chk}" ]]; then
            echo "  ${COLOR_GRAY}- ${name}: 无校验命令，跳过${COLOR_RESET}"
            continue
        fi
        echo -n "  ${name}: "
        if sudo bash -c "${chk}" >/dev/null 2>&1; then
            echo "${COLOR_GREEN}✅ 校验通过${COLOR_RESET}"
            ok=$((ok + 1))
        else
            echo "${COLOR_RED}❌ 校验失败${COLOR_RESET}"
            fail=$((fail + 1))
        fi
    done <<< "${entries}"
    echo "--------------------------------------------------"
    echo "  通过 ${ok} / 失败 ${fail}"
    if (( fail > 0 )); then
        echo ""
        echo "  ${COLOR_YELLOW}校验失败的配置建议立即检查，可用菜单 5 恢复备份${COLOR_RESET}"
    fi
    audit_log "配置语法校验" "通过${ok} 失败${fail}"
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
    cfg_list
fi
