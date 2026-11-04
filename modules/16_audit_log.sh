#!/bin/bash
# ============================================================
# 文件：modules/16_audit_log.sh
# 功能：运维操作审计 [Operation Audit Log]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 记录 时间|用户|模块|操作|结果 到 ~/.zetops/audit.log（只追加）
#   - 提供全局函数 audit_log()，任何模块可调用
#   - 支持按时间/用户/模块筛选查看与统计
# ============================================================
set -euo pipefail

module_name="操作审计日志"
module_short="audit_log"
module_version="1.0.0"

# 审计日志文件（14 安全模块共用同一文件）
AUDIT_FILE="${AUDIT_FILE:-${HOME}/.zetops/audit.log}"

module_description() {
    echo "运维操作审计：记录谁在什么时候做了什么 [Operation Audit]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看审计日志（最近 30 条）"
    echo " 2. 按用户筛选"
    echo " 3. 按模块筛选"
    echo " 4. 统计概览"
    echo " 5. 手动记录一条操作"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) audit_view "" "" ;;
        2) audit_filter_user ;;
        3) audit_filter_module ;;
        4) audit_stats ;;
        5) audit_manual ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 写入一条审计记录（全局函数，其他模块可调用）
# 参数：$1 操作描述  $2 结果（可选，默认"成功"）
# 返回：无
# ------------------------------------------------------------
audit_log() {
    local action="$1"
    local result="${2:-成功}"
    mkdir -p "$(dirname "${AUDIT_FILE}")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $(whoami 2>/dev/null || echo '?') | ${CURRENT_MODULE:-core} | ${action} | ${result}" >> "${AUDIT_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 渲染审计记录
# 参数：$1 用户过滤(空=全部)  $2 模块过滤(空=全部)
# 返回：无
# ------------------------------------------------------------
audit_view() {
    local user_f="${1:-}"
    local mod_f="${2:-}"
    echo ""
    log_info "审计日志（${AUDIT_FILE}）"
    echo "--------------------------------------------------"
    if [[ ! -f "${AUDIT_FILE}" ]]; then
        echo "  ${COLOR_GRAY}(暂无审计记录)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi

    # 输出：时间 | 用户 | 模块 | 操作 | 结果（着色：成功绿/失败红）
    awk -F'|' -v uf="${user_f}" -v mf="${mod_f}" '
        (uf == "" || $3 == uf) && (mf == "" || $4 == mf) {
            time=$1; user=$2; mod=$3; act=$4; res=$5
            printf "  %s %-10s [%s] %s", time, user, mod, act
            if (res ~ /成功/) { printf " %s%s%s\n", "\033[1;32m", res, "\033[0m" }
            else if (res ~ /失败/) { printf " %s%s%s\n", "\033[1;31m", res, "\033[0m" }
            else { printf " %s\n", res }
        }
    ' "${AUDIT_FILE}" 2>/dev/null | tail -30
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 按用户筛选（列出出现过的人员供选择）
# ------------------------------------------------------------
audit_filter_user() {
    echo ""
    log_info "历史操作用户:"
    local users
    users=$(cut -d'|' -f3 "${AUDIT_FILE}" 2>/dev/null | sort -u | tr '\n' ' ')
    if [[ -z "${users}" ]]; then
        echo "  ${COLOR_GRAY}(无记录)${COLOR_RESET}"
        return
    fi
    echo "  ${users}"
    echo ""
    read_input target "输入要筛选的用户名" ""
    [[ -z "${target}" ]] && return
    audit_view "${target}" ""
}

# ------------------------------------------------------------
# 按模块筛选（列出出现过的模块供选择）
# ------------------------------------------------------------
audit_filter_module() {
    echo ""
    log_info "历史操作模块:"
    local mods
    mods=$(cut -d'|' -f4 "${AUDIT_FILE}" 2>/dev/null | sort -u | tr '\n' ' ')
    if [[ -z "${mods}" ]]; then
        echo "  ${COLOR_GRAY}(无记录)${COLOR_RESET}"
        return
    fi
    echo "  ${mods}"
    echo ""
    read_input target "输入要筛选的模块名" ""
    [[ -z "${target}" ]] && return
    audit_view "" "${target}"
}

# ------------------------------------------------------------
# 统计概览
# ------------------------------------------------------------
audit_stats() {
    echo ""
    log_info "审计统计概览"
    echo "--------------------------------------------------"
    if [[ ! -f "${AUDIT_FILE}" ]]; then
        echo "  ${COLOR_GRAY}(暂无记录)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    echo "  总记录数:  $(wc -l < "${AUDIT_FILE}" 2>/dev/null | tr -d ' ')"
    echo "  操作用户:  $(cut -d'|' -f3 "${AUDIT_FILE}" 2>/dev/null | sort -u | wc -l | tr -d ' ') 人"
    echo "  涉及模块:  $(cut -d'|' -f4 "${AUDIT_FILE}" 2>/dev/null | sort -u | wc -l | tr -d ' ') 个"
    echo ""
    echo "  ${COLOR_BOLD}各模块操作次数:${COLOR_RESET}"
    cut -d'|' -f4 "${AUDIT_FILE}" 2>/dev/null | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
    echo ""
    echo "  ${COLOR_BOLD}最近 5 条记录:${COLOR_RESET}"
    tail -5 "${AUDIT_FILE}" 2>/dev/null | cut -d'|' -f1,3,4,5 | sed 's/^/    /'
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 手动记录一条操作
# ------------------------------------------------------------
audit_manual() {
    echo ""
    read_input action "输入操作描述" ""
    [[ -z "${action}" ]] && { log_warning "操作描述不能为空"; return; }
    read_input result "输入结果（默认: 成功）" "成功"
    audit_log "${action}" "${result}"
    log_success "已写入审计日志: ${action} | ${result}"
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
    # 独立运行时默认展示最近记录
    audit_view "" ""
fi
