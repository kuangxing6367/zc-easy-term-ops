#!/bin/bash
# ============================================================
# 文件：modules/23_task_pipeline.sh
# 功能：运维任务编排 [Ops Task Pipeline]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 多步骤任务定义（~/.zetops/tasks/*.ztask），纯文本可手编
#   - 格式：task_desc=描述 / step:名称 命令（逐行执行，支持 # 注释）
#   - 执行：逐步骤执行（bash -c 隔离），失败默认中止可选手动继续
#   - 进度显示、执行历史记录、模板创建/编辑
# ============================================================
set -euo pipefail

module_name="运维任务编排"
module_short="task_pipeline"
module_version="1.0.0"

TASKS_DIR="${TASKS_DIR:-${HOME}/.zetops/tasks}"
TASKS_HISTORY="${TASKS_HISTORY:-${HOME}/.zetops/tasks_history.log}"

module_description() {
    echo "多步骤运维任务定义/编排/执行/历史（发布=git pull→构建→重启→健康检查） [Task Pipeline]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看已有任务列表"
    echo " 2. 创建任务（模板）"
    echo " 3. 编辑任务"
    echo " 4. 执行任务"
    echo " 5. 查看任务执行历史"
    echo " 6. 删除任务"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) task_list ;;
        2) task_create ;;
        3) task_edit ;;
        4) task_run_menu ;;
        5) task_history ;;
        6) task_delete ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 确保任务目录存在
# ------------------------------------------------------------
task_ensure_dir() {
    mkdir -p "${TASKS_DIR}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 列出任务文件（不含扩展名）
# 输出：每行一个任务名
# ------------------------------------------------------------
task_list_names() {
    task_ensure_dir
    for f in "${TASKS_DIR}"/*.ztask; do
        [[ -f "${f}" ]] && basename "${f}" .ztask
    done | sort || true
}

# ------------------------------------------------------------
# 1. 查看任务列表
# ------------------------------------------------------------
task_list() {
    task_ensure_dir
    local names
    names=$(task_list_names)
    echo ""
    log_info "任务列表（${TASKS_DIR}）"
    echo "--------------------------------------------------"
    if [[ -z "${names}" ]]; then
        echo "  ${COLOR_GRAY}(暂无任务，请先创建: 菜单 2)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local name desc step_count
    for name in ${names}; do
        desc=$(grep -E '^task_desc=' "${TASKS_DIR}/${name}.ztask" 2>/dev/null | head -1 | cut -d= -f2- || true)
        step_count=$(grep -cE '^step:' "${TASKS_DIR}/${name}.ztask" 2>/dev/null || true)
        echo "  ${COLOR_BOLD}${name}${COLOR_RESET}  (${step_count} 步)"
        [[ -n "${desc}" ]] && echo "       ${COLOR_GRAY}${desc}${COLOR_RESET}"
    done
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 2. 创建任务（模板）
# ------------------------------------------------------------
task_create() {
    task_ensure_dir
    echo ""
    read_input task_name "任务名（字母数字下划线）" ""
    [[ "${task_name}" =~ ^[a-zA-Z0-9_]+$ ]] || { log_error "任务名格式非法（仅字母数字下划线）"; return; }
    local task_file="${TASKS_DIR}/${task_name}.ztask"
    [[ -f "${task_file}" ]] && { log_error "任务 ${task_name} 已存在"; return; }

    read_input desc "任务描述" ""
    echo ""
    echo "  ${COLOR_BOLD}创建方式:${COLOR_RESET}"
    echo "  1. 交互式添加步骤"
    echo "  2. 使用模板 + 手动编辑"
    read_input mode "选择" "1"

    if [[ "${mode}" == "2" ]]; then
        {
            echo "# ${task_name} - ${desc}"
            echo "task_desc=\"${desc}\""
            echo "task_version=\"1.0\""
            echo ""
            echo "# 步骤格式: step:名称 命令"
            echo "step:git_pull   cd /opt/app && git pull origin main"
            echo "step:build      cd /opt/app && mvn package -DskipTests"
            echo "step:restart    systemctl restart app"
            echo "step:health     curl -s --max-time 5 http://localhost:8080/health | grep -q ok"
        } > "${task_file}"
        log_success "模板已创建: ${task_file}"
        echo "  ${COLOR_GRAY}请编辑: ${task_file}${COLOR_RESET}"
        read_input edit_now "立即编辑？[y/N]" "n"
        if [[ "${edit_now}" == "y" || "${edit_now}" == "Y" ]]; then
            task_edit_editor "${task_file}"
        fi
        return
    fi

    # 交互式添加步骤
    {
        echo "# ${task_name} - ${desc}"
        echo "task_desc=\"${desc}\""
        echo "task_version=\"1.0\""
    } > "${task_file}"
    local i=1 cmd=""
    echo ""
    echo "  ${COLOR_GRAY}逐条输入命令（输入空行结束）${COLOR_RESET}"
    while true; do
        echo -n "  第 ${i} 步命令: "
        read -r cmd || cmd=""
        [[ -z "${cmd}" ]] && break
        echo "step:step_${i}   ${cmd}" >> "${task_file}"
        i=$((i + 1))
        (( i > 20 )) && { log_warning "最多 20 步"; break; }
    done
    if (( i == 1 )); then
        log_warning "未添加任何步骤，任务已删除"
        rm -f "${task_file}"
        return
    fi
    log_success "任务 ${task_name} 创建完成（$((i - 1)) 步）"
    audit_log "创建任务 ${task_name}" "成功"
}

# ------------------------------------------------------------
# 交互选择任务
# 参数：$1 提示语
# 输出：任务名（空=取消）
# ------------------------------------------------------------
task_pick() {
    local names
    names=$(task_list_names)
    if [[ -z "${names}" ]]; then
        log_warning "暂无任务"
        return 1
    fi
    echo ""
    echo "  可选任务: ${names}"
    read_input picked "输入任务名" ""
    [[ -z "${picked}" ]] && return 1
    if [[ ! -f "${TASKS_DIR}/${picked}.ztask" ]]; then
        log_error "任务 ${picked} 不存在"
        return 1
    fi
    echo "${picked}"
    return 0
}

# ------------------------------------------------------------
# 编辑器选择打开文件
# 参数：$1 文件路径
# ------------------------------------------------------------
task_edit_editor() {
    local file="$1"
    if check_command nano; then
        nano "${file}"
    elif check_command vi; then
        vi "${file}"
    else
        log_error "未找到 nano/vi 编辑器"
        return 1
    fi
}

# ------------------------------------------------------------
# 3. 编辑任务
# ------------------------------------------------------------
task_edit() {
    local picked
    picked=$(task_pick "编辑哪个任务") || return
    task_edit_editor "${TASKS_DIR}/${picked}.ztask" && {
        log_success "任务 ${picked} 已保存"
        audit_log "编辑任务 ${picked}" "成功"
    }
}

# ------------------------------------------------------------
# 4. 执行任务
# ------------------------------------------------------------
task_run_menu() {
    local picked
    picked=$(task_pick "执行哪个任务") || return
    echo ""
    echo "  ${COLOR_BOLD}任务 [${picked}] 执行方式:${COLOR_RESET}"
    echo "  1. 失败即中止（默认）"
    echo "  2. 失败后询问是否继续"
    echo "  3. 忽略失败全部执行"
    read_input mode "选择" "1"

    task_run "${picked}" "${mode}"
    echo ""
    echo "  ${COLOR_GRAY}查看详细历史: 菜单 5${COLOR_RESET}"
}

# ------------------------------------------------------------
# 执行任务（核心引擎）
# 参数：$1 任务名  $2 失败策略(1=中止 2=询问 3=忽略)
# 返回：0=全部成功 1=有失败
# ------------------------------------------------------------
task_run() {
    local name="$1" policy="${2:-1}"
    local file="${TASKS_DIR}/${name}.ztask"
    [[ -f "${file}" ]] || { log_error "任务文件不存在"; return 1; }

    local desc
    desc=$(grep -E '^task_desc=' "${file}" | head -1 | cut -d= -f2- || true)
    echo ""
    echo "  ${COLOR_BOLD}▶ 开始执行任务 [${name}]${COLOR_RESET} ${desc:+- ${desc}}"
    echo "  ${COLOR_GRAY}策略: $([ "${policy}" == "1" ] && echo "失败即中止" || ([ "${policy}" == "2" ] && echo "失败询问" || echo "忽略失败"))${COLOR_RESET}"
    echo "  --------------------------------------------------"

    local line step=0 ok=0 fail=0
    local total
    total=$(grep -cE '^step:' "${file}" || true)
    while IFS= read -r line; do
        # 跳过空行/注释/配置行
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ ^step: ]] || continue
        step=$((step + 1))
        local step_name step_cmd
        step_name=$(echo "${line#step:}" | awk '{print $1}')
        step_cmd=$(echo "${line#step:}" | cut -d' ' -f2-)

        echo ""
        echo "  ${COLOR_BOLD}${COLOR_BLUE}[${step}/${total}] ${step_name}${COLOR_RESET}"
        echo "  ${COLOR_GRAY}命令: ${step_cmd}${COLOR_RESET}"
        show_spinner "  执行中..."
        if bash -c "${step_cmd}" 2>&1 | sed 's/^/      /'; then
            stop_spinner
            echo "  ${COLOR_GREEN}✅ ${step_name} 成功${COLOR_RESET}"
            ok=$((ok + 1))
        else
            stop_spinner
            echo "  ${COLOR_RED}❌ ${step_name} 失败${COLOR_RESET}"
            fail=$((fail + 1))
            if [[ "${policy}" == "1" ]]; then
                echo "  ${COLOR_YELLOW}任务中止（失败即中止策略）${COLOR_RESET}"
                break
            elif [[ "${policy}" == "2" ]]; then
                if ! confirm_action "此步骤失败，是否继续执行后续步骤？"; then
                    echo "  ${COLOR_YELLOW}任务中止${COLOR_RESET}"
                    break
                fi
            fi
        fi
    done < "${file}"

    echo ""
    echo "  --------------------------------------------------"
    if (( fail == 0 )); then
        echo "  ${COLOR_GREEN}✅ 任务 [${name}] 全部完成（${ok}/${total} 步成功）${COLOR_RESET}"
    else
        echo "  ${COLOR_YELLOW}⚠️  任务 [${name}] 结束（成功 ${ok} / 失败 ${fail} / 共 ${total} 步）${COLOR_RESET}"
    fi
    # 记录历史
    mkdir -p "$(dirname "${TASKS_HISTORY}")" 2>/dev/null || true
    local result="成功"
    (( fail > 0 )) && result="失败(${ok}成功/${fail}失败)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${name} | ${result} | 共${total}步" >> "${TASKS_HISTORY}" 2>/dev/null || true
    audit_log "执行任务 ${name}" "${result}"
    (( fail == 0 ))
}

# ------------------------------------------------------------
# 5. 查看任务执行历史
# ------------------------------------------------------------
task_history() {
    echo ""
    log_info "任务执行历史（${TASKS_HISTORY}）"
    echo "--------------------------------------------------"
    if [[ ! -f "${TASKS_HISTORY}" ]]; then
        echo "  ${COLOR_GRAY}(暂无执行记录)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    awk -F'|' '
        {
            if ($3 ~ /失败/) { mark="\033[1;31m ❌\033[0m" }
            else { mark="\033[1;32m ✅\033[0m" }
            print "  " $1 " [" $2 "] " $3 " " $4 mark
        }
    ' "${TASKS_HISTORY}" 2>/dev/null | tail -20
    echo "--------------------------------------------------"
    echo "  ${COLOR_GRAY}总执行次数: $(wc -l < "${TASKS_HISTORY}" | tr -d ' ')${COLOR_RESET}"
}

# ------------------------------------------------------------
# 6. 删除任务
# ------------------------------------------------------------
task_delete() {
    local picked
    picked=$(task_pick "删除哪个任务") || return
    if confirm_action "确认删除任务 [${picked}]？"; then
        rm -f "${TASKS_DIR}/${picked}.ztask"
        log_success "任务 ${picked} 已删除"
        audit_log "删除任务 ${picked}" "成功"
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
    task_list
fi
