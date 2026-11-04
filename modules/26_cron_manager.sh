#!/bin/bash
# ============================================================
# 文件：modules/26_cron_manager.sh
# 功能：计划任务管理（crontab 可视化） [Cron Manager]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 基于系统 crontab，可视化增删改查计划任务
#   - 时间表达式自动翻译为中文说明（每天 08:00 / 每5分钟 ...）
#   - 支持暂停/恢复（注释标记）、手动执行一次、快捷模板
#   - 通过临时文件编辑后统一写入 crontab，保留用户原有环境变量与注释
# ============================================================
set -euo pipefail

module_name="计划任务管理"
module_short="cron_manager"
module_version="1.0.0"

CRON_TMP="${CRON_TMP:-${HOME}/.zetops/crontab.tmp}"
CRON_PAUSE_MARK="ZETOPS-PAUSED"

module_description() {
    echo "crontab 可视化管理：计划任务增删改查/暂停恢复/手动执行/中文时间解释 [Cron Manager]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看全部计划任务"
    echo " 2. 添加计划任务"
    echo " 3. 编辑计划任务"
    echo " 4. 暂停/恢复任务"
    echo " 5. 删除计划任务"
    echo " 6. 手动执行一次"
    echo " 7. 清空全部任务"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) cron_list ;;
        2) cron_add ;;
        3) cron_edit ;;
        4) cron_toggle ;;
        5) cron_delete ;;
        6) cron_run_now ;;
        7) cron_clear_all ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 刷新临时 crontab 文件（无 crontab 时生成空文件）
# ------------------------------------------------------------
cron_refresh() {
    mkdir -p "$(dirname "${CRON_TMP}")" 2>/dev/null || true
    crontab -l > "${CRON_TMP}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 将临时文件写回系统 crontab
# 返回：0 成功
# ------------------------------------------------------------
cron_commit() {
    crontab "${CRON_TMP}" || { log_error "写入 crontab 失败"; return 1; }
    log_success "计划任务已更新"
    audit_log "更新计划任务" "成功"
}

# ------------------------------------------------------------
# 判断一行是否为计划任务行（时间 5 字段 或 @ 关键字）
# 参数：$1 行内容
# 返回：0=是任务行
# ------------------------------------------------------------
cron_is_task() {
    local line="$1"
    [[ -z "${line}" ]] && return 1
    [[ "${line}" =~ ^@[a-z]+[[:space:]] ]] && return 0
    local f1
    f1=$(echo "${line}" | awk '{print $1}')
    [[ "${f1}" =~ ^[0-9*] ]] && return 0
    return 1
}

# ------------------------------------------------------------
# 时间字段 → 中文时刻（HH:MM）
# 参数：$1 时  $2 分
# 输出：如 08:30
# ------------------------------------------------------------
cron_tm() {
    local h="$1" m="$2"
    if [[ "${h}" =~ ^[0-9]+$ && "${m}" =~ ^[0-9]+$ ]]; then
        printf "%02d:%02d" "$((10#$h))" "$((10#$m))"
    else
        echo "${h}时${m}分"
    fi
}

# ------------------------------------------------------------
# crontab 时间表达式 → 中文说明
# 参数：$1 5字段时间表达式（或 @daily 等）
# 输出：中文描述
# ------------------------------------------------------------
cron_explain() {
    local spec="$1"
    # @ 关键字
    case "${spec}" in
        @reboot)  echo "开机启动"; return ;;
        @daily|@midnight) echo "每天 00:00"; return ;;
        @hourly)  echo "每小时整点"; return ;;
        @weekly)  echo "每周日 00:00"; return ;;
        @monthly) echo "每月1日 00:00"; return ;;
        @yearly|@annually) echo "每年1月1日 00:00"; return ;;
    esac
    local min hour dom mon dow
    read -r min hour dom mon dow <<< "${spec}"
    local res=""
    if [[ "${dow}" != "*" ]]; then
        local day
        case "${dow}" in
            0|7) day="周日" ;; 1) day="周一" ;; 2) day="周二" ;; 3) day="周三" ;;
            4) day="周四" ;; 5) day="周五" ;; 6) day="周六" ;;
            *) day="周${dow}" ;;
        esac
        res="每${day} $(cron_tm "${hour}" "${min}")"
    elif [[ "${dom}" != "*" ]]; then
        res="每月${dom}日 $(cron_tm "${hour}" "${min}")"
    elif [[ "${mon}" != "*" ]]; then
        res="每年${mon}月 $(cron_tm "${hour}" "${min}")"
    elif [[ "${hour}" == "*" ]]; then
        if [[ "${min}" == "*" ]]; then
            res="每分钟"
        elif [[ "${min}" =~ ^\*/([0-9]+)$ ]]; then
            res="每${BASH_REMATCH[1]}分钟"
        elif [[ "${min}" == "0" ]]; then
            res="每小时整点"
        else
            res="每小时 ${min}分"
        fi
    elif [[ "${hour}" =~ ^\*/([0-9]+)$ ]]; then
        res="每${BASH_REMATCH[1]}小时 ${min}分"
    else
        res="每天 $(cron_tm "${hour}" "${min}")"
    fi
    echo "${res}"
}

# ------------------------------------------------------------
# 校验时间字段
# 参数：$1 字段值  $2 最大值
# 返回：0=合法
# ------------------------------------------------------------
cron_validate_field() {
    local field="$1" max="$2"
    [[ "${field}" == "*" ]] && return 0
    if [[ "${field}" =~ ^\*/([0-9]+)$ ]]; then
        (( BASH_REMATCH[1] >= 1 && BASH_REMATCH[1] <= max )) && return 0 || return 1
    fi
    local p
    IFS=',' read -ra parts <<< "${field}"
    for p in "${parts[@]}"; do
        [[ "${p}" =~ ^[0-9]+$ ]] || return 1
        (( 10#$p <= max )) || return 1
    done
    return 0
}

# ------------------------------------------------------------
# 校验完整 crontab 时间表达式
# 参数：$1 时间表达式
# 返回：0=合法
# ------------------------------------------------------------
cron_validate() {
    local spec="$1"
    [[ "${spec}" =~ ^@[a-z]+ ]] && return 0
    local m h d mo w
    read -r m h d mo w <<< "${spec}"
    [[ -n "${w}" ]] || return 1
    cron_validate_field "${m}" 59 || return 1
    cron_validate_field "${h}" 23 || return 1
    cron_validate_field "${d}" 31 || return 1
    cron_validate_field "${mo}" 12 || return 1
    cron_validate_field "${w}" 7 || return 1
    return 0
}

# ------------------------------------------------------------
# 列出任务行（带真实行号），仅任务行（含暂停标记行）
# 输出：行号|内容
# ------------------------------------------------------------
cron_entries() {
    cron_refresh
    local line_no=0 line
    while IFS= read -r line; do
        line_no=$((line_no + 1))
        [[ -z "${line}" ]] && continue
        # 跳过环境变量行（整行 KEY=value）
        if [[ ! "${line}" =~ ^[[:space:]]*# ]] && [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            continue
        fi
        if [[ "${line}" =~ ^[[:space:]]*# ]]; then
            # 普通注释跳过；暂停标记行保留
            [[ "${line}" =~ ${CRON_PAUSE_MARK} ]] || continue
        fi
        echo "${line_no}|${line}"
    done < "${CRON_TMP}"
}

# ------------------------------------------------------------
# 1. 查看全部计划任务
# ------------------------------------------------------------
cron_list() {
    echo ""
    log_info "计划任务列表（当前用户 crontab）"
    echo "--------------------------------------------------"
    local entries n=0
    entries=$(cron_entries)
    if [[ -z "${entries}" ]]; then
        echo "  ${COLOR_GRAY}(暂无计划任务，请先添加: 菜单 2)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local line rec spec cmd status mark
    while IFS= read -r rec; do
        n=$((n + 1))
        line=${rec%%|*}
        local body="${rec#*|}"
        if [[ "${body}" =~ ^[[:space:]]*#[[:space:]]*ZETOPS-PAUSED[[:space:]]*(.*)$ ]]; then
            body="${BASH_REMATCH[1]}"
            status="已暂停"
        else
            status="运行中"
        fi
        spec=$(echo "${body}" | awk '{print $1" "$2" "$3" "$4" "$5}')
        cmd=$(echo "${body}" | cut -d' ' -f6-)
        local st_color="${COLOR_GREEN}"
        [[ "${status}" == "已暂停" ]] && st_color="${COLOR_YELLOW}"
        printf "  %2d. ${COLOR_BOLD}%-14s${COLOR_RESET} %-4s %s\n" "${n}" "$(cron_explain "${spec}")" "${st_color}[${status}]${COLOR_RESET}" "${cmd}"
    done <<< "${entries}"
    echo "--------------------------------------------------"
    echo "  ${COLOR_GRAY}共 ${n} 条计划任务${COLOR_RESET}"
}

# ------------------------------------------------------------
# 交互选择一条任务
# 参数：$1 操作名
# 输出：行号|原内容（空=取消）
# ------------------------------------------------------------
cron_pick() {
    local action="$1"
    local entries n=0
    entries=$(cron_entries)
    if [[ -z "${entries}" ]]; then
        log_warning "暂无计划任务"
        return 1
    fi
    local rec body spec cmd
    echo ""
    while IFS= read -r rec; do
        n=$((n + 1))
        body="${rec#*|}"
        [[ "${body}" =~ ^[[:space:]]*#[[:space:]]*ZETOPS-PAUSED[[:space:]]*(.*)$ ]] && body="${BASH_REMATCH[1]}"
        spec=$(echo "${body}" | awk '{print $1" "$2" "$3" "$4" "$5}')
        cmd=$(echo "${body}" | cut -d' ' -f6-)
        printf "  %2d. %-14s %s\n" "${n}" "$(cron_explain "${spec}")" "${cmd}"
    done <<< "${entries}"
    read_input num "选择要${action}的编号" ""
    [[ -z "${num}" ]] && return 1
    [[ "${num}" =~ ^[0-9]+$ ]] || { log_error "编号无效"; return 1; }
    echo "${entries}" | sed -n "${num}p"
}

# ------------------------------------------------------------
# 2. 添加计划任务
# ------------------------------------------------------------
cron_add() {
    check_command crontab || { log_error "系统未安装 crontab（请先安装 cron）"; return; }
    echo ""
    echo "  ${COLOR_BOLD}添加方式:${COLOR_RESET}"
    echo "  1. 快捷模板"
    echo "  2. 交互式填时间"
    echo "  3. 粘贴完整 crontab 行"
    read_input mode "选择" "1"

    local spec="" cmd=""
    case "${mode}" in
        1)
            echo ""
            echo "  模板:"
            echo "   1. 每分钟执行          * * * * *"
            echo "   2. 每5分钟执行         */5 * * * *"
            echo "   3. 每小时执行          0 * * * *"
            echo "   4. 每天 08:00          0 8 * * *"
            echo "   5. 每周一 09:00        0 9 * * 1"
            echo "   6. 每月1日 00:00       0 0 1 * *"
            echo "   7. 开机启动            @reboot"
            read_input tpl "选择模板" "4"
            case "${tpl}" in
                1) spec="* * * * *" ;; 2) spec="*/5 * * * *" ;; 3) spec="0 * * * *" ;;
                5) spec="0 9 * * 1" ;; 6) spec="0 0 1 * *" ;; 7) spec="@reboot" ;;
                *) spec="0 8 * * *" ;;
            esac
            ;;
        2)
            read_input c_min  "分钟(0-59, */n 表示每n分钟, * 任意)" "*"
            read_input c_hour "小时(0-23, * 任意)" "*"
            read_input c_dom  "日(1-31, * 任意)" "*"
            read_input c_mon  "月(1-12, * 任意)" "*"
            read_input c_dow  "周(0-7, * 任意)" "*"
            spec="${c_min} ${c_hour} ${c_dom} ${c_mon} ${c_dow}"
            ;;
        3)
            read_input full_line "粘贴整行（时间 命令）" ""
            spec=$(echo "${full_line}" | awk '{print $1" "$2" "$3" "$4" "$5}')
            cmd=$(echo "${full_line}" | cut -d' ' -f6-)
            ;;
        *) log_error "无效选择"; return ;;
    esac

    if ! cron_validate "${spec}"; then
        log_error "时间表达式非法: ${spec}"
        return
    fi
    if [[ "${mode}" != "3" ]]; then
        read_input cmd "要执行的命令" ""
    fi
    [[ -z "${cmd}" ]] && { log_warning "命令为空，取消添加"; return; }

    # 写入临时文件并提交
    cron_refresh
    echo "${spec} ${cmd}" >> "${CRON_TMP}"
    cron_commit && {
        echo "  ${COLOR_GRAY}时间: ${spec} → $(cron_explain "${spec}")${COLOR_RESET}"
        log_success "任务已添加"
    }
}

# ------------------------------------------------------------
# 3. 编辑计划任务（修改整行内容）
# ------------------------------------------------------------
cron_edit() {
    local pick
    pick=$(cron_pick "编辑") || return
    local line_no body
    line_no="${pick%%|*}"
    body="${pick#*|}"
    [[ "${body}" =~ ^[[:space:]]*#[[:space:]]*ZETOPS-PAUSED[[:space:]]*(.*)$ ]] && body="${BASH_REMATCH[1]}"

    local new_body
    read_input new_body "新内容（时间 命令，默认保留原文）" "${body}"
    [[ -z "${new_body}" ]] && { log_info "未修改，取消"; return; }
    local spec
    spec=$(echo "${new_body}" | awk '{print $1" "$2" "$3" "$4" "$5}')
    if ! cron_validate "${spec}"; then
        log_error "时间表达式非法: ${spec}"
        return
    fi
    cron_refresh
    # 用 awk 替换指定行号（保留原暂停标记状态）
    local paused=0
    [[ "${pick#*|}" =~ ${CRON_PAUSE_MARK} ]] && paused=1
    if (( paused == 1 )); then
        new_body="# ${CRON_PAUSE_MARK}: ${new_body}"
    fi
    awk -v ln="${line_no}" -v val="${new_body}" 'NR==ln {print val; next} {print}' "${CRON_TMP}" > "${CRON_TMP}.new" && mv "${CRON_TMP}.new" "${CRON_TMP}"
    cron_commit && log_success "任务已更新"
}

# ------------------------------------------------------------
# 4. 暂停/恢复任务
# ------------------------------------------------------------
cron_toggle() {
    local pick
    pick=$(cron_pick "暂停/恢复") || return
    local line_no body paused
    line_no="${pick%%|*}"
    body="${pick#*|}"
    if [[ "${body}" =~ ${CRON_PAUSE_MARK} ]]; then
        paused=1
        body="${body#*: }"
    else
        paused=0
    fi
    cron_refresh
    local new_body
    if (( paused == 1 )); then
        new_body="${body}"
        local action="恢复"
    else
        new_body="# ${CRON_PAUSE_MARK}: ${body}"
        local action="暂停"
    fi
    awk -v ln="${line_no}" -v val="${new_body}" 'NR==ln {print val; next} {print}' "${CRON_TMP}" > "${CRON_TMP}.new" && mv "${CRON_TMP}.new" "${CRON_TMP}"
    cron_commit && log_success "任务已${action}"
}

# ------------------------------------------------------------
# 5. 删除计划任务
# ------------------------------------------------------------
cron_delete() {
    local pick
    pick=$(cron_pick "删除") || return
    local line_no body
    line_no="${pick%%|*}"
    body="${pick#*|}"
    if confirm_action "确认删除该任务？\n  ${body}"; then
        cron_refresh
        awk -v ln="${line_no}" 'NR!=ln' "${CRON_TMP}" > "${CRON_TMP}.new" && mv "${CRON_TMP}.new" "${CRON_TMP}"
        cron_commit && log_success "任务已删除"
    fi
}

# ------------------------------------------------------------
# 6. 手动执行一次
# ------------------------------------------------------------
cron_run_now() {
    local pick
    pick=$(cron_pick "手动执行") || return
    local body cmd
    body="${pick#*|}"
    [[ "${body}" =~ ^[[:space:]]*#[[:space:]]*ZETOPS-PAUSED[[:space:]]*(.*)$ ]] && body="${BASH_REMATCH[1]}"
    cmd=$(echo "${body}" | cut -d' ' -f6-)
    [[ -z "${cmd}" ]] && { log_error "无法解析命令"; return; }
    if confirm_action "立即执行一次: ${cmd}"; then
        echo ""
        echo "  ${COLOR_BOLD}▶ 执行输出:${COLOR_RESET}"
        echo "  --------------------------------------------------"
        bash -c "${cmd}" 2>&1 | sed 's/^/    /'
        local rc=${PIPESTATUS[0]}
        echo "  --------------------------------------------------"
        if (( rc == 0 )); then
            log_success "执行成功"
        else
            log_error "执行失败（退出码 ${rc}）"
        fi
        audit_log "手动执行计划任务" "$([ ${rc} -eq 0 ] && echo 成功 || echo 失败)"
    fi
}

# ------------------------------------------------------------
# 7. 清空全部任务
# ------------------------------------------------------------
cron_clear_all() {
    check_command crontab || { log_error "系统未安装 crontab"; return; }
    if ! crontab -l >/dev/null 2>&1; then
        log_warning "当前无 crontab"
        return
    fi
    if confirm_action "清空当前用户全部计划任务？"; then
        crontab -r 2>/dev/null || true
        log_success "已清空全部计划任务"
        audit_log "清空计划任务" "成功"
    fi
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
    cron_list
fi
