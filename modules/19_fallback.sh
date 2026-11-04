#!/bin/bash
# ============================================================
# 文件：modules/19_fallback.sh
# 功能：容灾回退链 [Disaster Recovery Fallback Chain]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 回退链配置 ~/.zetops/fallback.ini（primary → fallback_N → 兜底）
#   - 链式回退执行（自动重试、逐级降级）
#   - 回退演练（--dry-run 不实际执行）
#   - Watchdog 自动故障切换（后台监控，连续失败 N 次自动降级）
#   - 回退历史记录（~/.zetops/fallback_history.log）
# ============================================================
set -euo pipefail

module_name="容灾回退链"
module_short="fallback"
module_version="1.0.0"

FB_FILE="${FB_FILE:-${HOME}/.zetops/fallback.ini}"
FB_HISTORY="${FB_HISTORY:-${HOME}/.zetops/fallback_history.log}"
FB_WATCH_PID="${FB_WATCH_PID:-/tmp/zetops_fallback_watch.pid}"

module_description() {
    echo "服务回退链配置、链式降级执行、回退演练、Watchdog 自动切换 [Fallback & DR]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看所有回退策略"
    echo " 2. 新建/编辑回退链"
    echo " 3. 删除回退链"
    echo " 4. 链式回退执行"
    echo " 5. 回退演练（不实际执行）"
    echo " 6. Watchdog 自动切换（启动/停止）"
    echo " 7. 回退历史记录"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) fb_list ;;
        2) fb_edit ;;
        3) fb_delete ;;
        4) fb_exec ;;
        5) fb_drill ;;
        6) fb_watchdog_menu ;;
        7) fb_history ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 确保配置文件存在
# ------------------------------------------------------------
fb_ensure_file() {
    mkdir -p "$(dirname "${FB_FILE}")" 2>/dev/null || true
    [[ -f "${FB_FILE}" ]] || touch "${FB_FILE}"
}

# ------------------------------------------------------------
# 列出回退链节名
# ------------------------------------------------------------
fb_sections() {
    grep -E '^\[' "${FB_FILE}" 2>/dev/null | tr -d '[]' || true
}

# ------------------------------------------------------------
# 读取回退链配置项
# 参数：$1 节名  $2 键名
# ------------------------------------------------------------
fb_get() {
    local section="$1" key="$2"
    awk -v sec="${section}" -v k="${key}" '
        $0 ~ "^\\[" sec "\\]$" { found=1; next }
        /^\[/ { found=0 }
        found && $1 ~ "^" k "=" { sub(/^[^=]*=/, ""); print; exit }
    ' "${FB_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 读取回退链全部命令（primary + fallback_1..N）
# 参数：$1 节名
# 输出：每行一个 "层级|命令"
# ------------------------------------------------------------
fb_chain_cmds() {
    local section="$1"
    # 输出格式：序号|层级|命令（primary=0，fallback_N=N，再按序号排序保证执行顺序）
    awk -v sec="${section}" '
        $0 ~ "^\\[" sec "\\]$" { found=1; next }
        /^\[/ { found=0 }
        found && $1 ~ /^primary=/ {
            sub(/^[^=]*=/, ""); print "0|primary|" $0; next
        }
        found && $1 ~ /^fallback_[0-9]+=/ {
            key=$1; sub(/=.*/, "", key); n=substr(key, 10); sub(/^[^=]*=/, "")
            print n "|" key "|" $0
        }
    ' "${FB_FILE}" 2>/dev/null | sort -n -t'|' -k1,1 || true
}

# ------------------------------------------------------------
# 记录回退历史
# 参数：$1 节名  $2 事件  $3 结果
# ------------------------------------------------------------
fb_log() {
    mkdir -p "$(dirname "${FB_HISTORY}")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1 | $2 | $3" >> "${FB_HISTORY}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 1. 查看所有回退策略
# ------------------------------------------------------------
fb_list() {
    fb_ensure_file
    local sections
    sections=$(fb_sections)
    echo ""
    log_info "回退策略清单（${FB_FILE}）"
    echo "--------------------------------------------------"
    if [[ -z "${sections}" ]]; then
        echo "  ${COLOR_GRAY}(暂无策略，请先创建: 菜单 2)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local sec primary retries interval
    for sec in ${sections}; do
        primary=$(fb_get "${sec}" "primary")
        retries=$(fb_get "${sec}" "max_retries")
        interval=$(fb_get "${sec}" "retry_interval")
        local chain_count
        chain_count=$(fb_chain_cmds "${sec}" | grep -c '^[0-9]|fallback' || true)
        echo "  ${COLOR_BOLD}[${sec}]${COLOR_RESET} 回退链 ${chain_count} 层 | 重试 ${retries:-3} 次/间隔 ${interval:-5}s"
        echo "      primary: ${primary}"
        local line
        fb_chain_cmds "${sec}" | grep '^[0-9]|fallback' | while IFS='|' read -r _ key cmd; do
            echo "      ${key}: ${cmd}"
        done
    done
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 2. 新建/编辑回退链
# ------------------------------------------------------------
fb_edit() {
    fb_ensure_file
    echo ""
    read_input sec_name "回退链节名（如 service_nginx）" ""
    [[ -z "${sec_name}" ]] && return

    local exists=0
    grep -q "^\[${sec_name}\]$" "${FB_FILE}" 2>/dev/null && exists=1
    [[ "${exists}" == "1" ]] && log_warning "节 [${sec_name}] 已存在，将覆盖其配置"

    echo ""
    echo "  ${COLOR_GRAY}命令示例: systemctl start nginx / docker start nginx-backup${COLOR_RESET}"
    read_input primary "主服务命令 (primary)" ""
    [[ -z "${primary}" ]] && { log_warning "主服务命令不能为空"; return; }

    # 逐层录入 fallback（输入空结束）
    local fbs=() i=1 cmd=""
    while true; do
        echo -n "  回退第 ${i} 层命令 (fallback_${i}, 留空结束): "
        read -r cmd || cmd=""
        [[ -z "${cmd}" ]] && break
        fbs+=("${cmd}")
        i=$((i + 1))
        (( i > 5 )) && { log_warning "最多 5 层回退"; break; }
    done

    read_input max_retries "最大重试次数（默认 3）" "3"
    read_input retry_interval "重试间隔秒数（默认 5）" "5"

    # 写入（先删旧节再写新节）
    if [[ "${exists}" == "1" ]]; then
        awk -v sec="${sec_name}" '
            $0 ~ "^\\[" sec "\\]$" { skip=1; next }
            /^\[/ { skip=0 }
            !skip { print }
        ' "${FB_FILE}" > "${FB_FILE}.tmp" && mv "${FB_FILE}.tmp" "${FB_FILE}"
    fi
    {
        echo ""
        echo "[${sec_name}]"
        echo "primary=${primary}"
        local n=1
        for c in "${fbs[@]}"; do
            echo "fallback_${n}=${c}"
            n=$((n + 1))
        done
        echo "max_retries=${max_retries}"
        echo "retry_interval=${retry_interval}"
    } >> "${FB_FILE}"

    log_success "回退链 [${sec_name}] 已保存"
    audit_log "配置回退链 ${sec_name}" "成功"
}

# ------------------------------------------------------------
# 3. 删除回退链
# ------------------------------------------------------------
fb_delete() {
    fb_ensure_file
    local sections
    sections=$(fb_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无策略"
        return
    fi
    echo ""
    echo "  可选回退链: ${sections}"
    read_input sec_name "输入要删除的节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${FB_FILE}" 2>/dev/null; then
        log_error "节 [${sec_name}] 不存在"
        return
    fi
    if confirm_action "确认删除回退链 [${sec_name}]?"; then
        awk -v sec="${sec_name}" '
            $0 ~ "^\\[" sec "\\]$" { skip=1; next }
            /^\[/ { skip=0 }
            !skip { print }
        ' "${FB_FILE}" > "${FB_FILE}.tmp" && mv "${FB_FILE}.tmp" "${FB_FILE}"
        sed -i '/^$/N;/^\n$/D' "${FB_FILE}" 2>/dev/null || true
        log_success "回退链 [${sec_name}] 已删除"
        audit_log "删除回退链 ${sec_name}" "成功"
    fi
}

# ------------------------------------------------------------
# 执行回退链（核心引擎）
# 参数：$1 节名  $2 dry-run(0/1)
# 返回：0=有层成功 1=全部失败
# ------------------------------------------------------------
fb_execute_chain() {
    local sec="$1"
    local dry="${2:-0}"
    local max_retries interval
    max_retries=$(fb_get "${sec}" "max_retries")
    interval=$(fb_get "${sec}" "retry_interval")
    max_retries="${max_retries:-3}"
    interval="${interval:-5}"

    local line key cmd attempt=0
    while read -r line; do
        [[ -z "${line}" ]] && continue
        key=$(echo "${line}" | cut -d'|' -f2)
        cmd=$(echo "${line}" | cut -d'|' -f3-)
        attempt=0
        while (( attempt < max_retries )); do
            attempt=$((attempt + 1))
            if [[ "${dry}" == "1" ]]; then
                echo "  ${COLOR_GRAY}[演练] ${key}: ${cmd}${COLOR_RESET}"
                echo "  ${COLOR_GREEN}✅ [演练] ${key} 假设成功${COLOR_RESET}"
                fb_log "${sec}" "演练 ${key}" "假设成功"
                return 0
            fi
            echo "  ${COLOR_BLUE}尝试 ${key} (第 ${attempt}/${max_retries} 次): ${cmd}${COLOR_RESET}"
            if bash -c "${cmd}" >/dev/null 2>&1; then
                echo "  ${COLOR_GREEN}✅ ${key} 执行成功${COLOR_RESET}"
                fb_log "${sec}" "切换至 ${key}" "成功: ${cmd}"
                return 0
            fi
            echo "  ${COLOR_YELLOW}⚠️  ${key} 失败${COLOR_RESET}"
            (( attempt < max_retries )) && sleep "${interval}"
        done
    done <<< "$(fb_chain_cmds "${sec}")"

    # 全部失败
    if [[ "${dry}" != "1" ]]; then
        echo "  ${COLOR_RED}❌ 回退链全部失败，服务不可用${COLOR_RESET}"
        fb_log "${sec}" "回退链" "全部失败"
    fi
    return 1
}

# ------------------------------------------------------------
# 4. 链式回退执行
# ------------------------------------------------------------
fb_exec() {
    fb_ensure_file
    local sections
    sections=$(fb_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无回退链，请先创建（菜单 2）"
        return
    fi
    echo ""
    echo "  可选回退链: ${sections}"
    read_input sec_name "输入要执行的节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${FB_FILE}" 2>/dev/null; then
        log_error "节 [${sec_name}] 不存在"
        return
    fi
    echo ""
    echo "  ${COLOR_BOLD}--- 开始执行回退链 [${sec_name}] ---${COLOR_RESET}"
    fb_execute_chain "${sec_name}" 0
    echo "  ${COLOR_GRAY}查看历史: 菜单 7${COLOR_RESET}"
    audit_log "执行回退链 ${sec_name}" "完成"
}

# ------------------------------------------------------------
# 5. 回退演练（不实际执行）
# ------------------------------------------------------------
fb_drill() {
    fb_ensure_file
    local sections
    sections=$(fb_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无回退链"
        return
    fi
    echo ""
    echo "  可选回退链: ${sections}"
    read_input sec_name "输入要演练的节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${FB_FILE}" 2>/dev/null; then
        log_error "节 [${sec_name}] 不存在"
        return
    fi
    echo ""
    echo "  ${COLOR_BOLD}--- 回退演练 [${sec_name}]（--dry-run 不实际执行）---${COLOR_RESET}"
    fb_execute_chain "${sec_name}" 1
    log_success "演练完成（未执行任何命令）"
    audit_log "回退演练 ${sec_name}" "完成"
}

# ------------------------------------------------------------
# 6a. Watchdog 监控循环（后台运行）
# 参数：$1 节名  $2 检测命令  $3 间隔秒  $4 连续失败阈值
# ------------------------------------------------------------
fb_watchdog_loop() {
    local sec="$1" check_cmd="$2" interval="${3:-10}" threshold="${4:-3}"
    local fails=0 recovered=0
    while true; do
        if bash -c "${check_cmd}" >/dev/null 2>&1; then
            if (( recovered == 1 )); then
                fb_log "${sec}" "主服务恢复" "检测通过"
                recovered=0
            fi
            fails=0
        else
            fails=$((fails + 1))
            echo "  ${COLOR_YELLOW}[watchdog] ${sec} 检测失败 ${fails}/${threshold} 次${COLOR_RESET}"
            if (( fails >= threshold )); then
                fb_log "${sec}" "watchdog 触发" "连续 ${fails} 次失败，开始回退"
                fb_execute_chain "${sec}" 0
                fails=0
                recovered=1
            fi
        fi
        sleep "${interval}"
    done
}

# ------------------------------------------------------------
# 6. Watchdog 菜单（启动/停止/状态）
# ------------------------------------------------------------
fb_watchdog_menu() {
    fb_ensure_file
    echo ""
    echo "  Watchdog 自动切换"
    echo "  ----------------------------------"
    if [[ -f "${FB_WATCH_PID}" ]] && kill -0 "$(cat "${FB_WATCH_PID}")" 2>/dev/null; then
        echo "  状态: ${COLOR_GREEN}运行中 (PID $(cat "${FB_WATCH_PID}"))${COLOR_RESET}"
    else
        echo "  状态: ${COLOR_GRAY}未运行${COLOR_RESET}"
    fi
    echo "  ----------------------------------"
    echo "  1. 启动 Watchdog"
    echo "  2. 停止 Watchdog"
    read_input wd_choice "选择 (1/2，回车返回)" ""
    case "${wd_choice}" in
        1)
            local sections
            sections=$(fb_sections)
            if [[ -z "${sections}" ]]; then
                log_warning "暂无回退链，请先创建（菜单 2）"
                return
            fi
            echo ""
            echo "  可选回退链: ${sections}"
            read_input sec_name "监控哪个回退链" ""
            [[ -z "${sec_name}" ]] && return
            read_input check_cmd "健康检测命令（如: systemctl is-active nginx）" ""
            if [[ -z "${check_cmd}" ]]; then
                log_warning "检测命令不能为空"
                return
            fi
            read_input interval "检测间隔秒（默认 10）" "10"
            read_input threshold "连续失败阈值（默认 3）" "3"
            if [[ -f "${FB_WATCH_PID}" ]] && kill -0 "$(cat "${FB_WATCH_PID}")" 2>/dev/null; then
                log_warning "Watchdog 已在运行，请先停止"
                return
            fi
            nohup bash -c "
                source '${BASH_SOURCE[0]}' >/dev/null 2>&1
                fb_watchdog_loop '${sec_name}' '${check_cmd}' '${interval}' '${threshold}'
            " > /dev/null 2>&1 &
            echo $! > "${FB_WATCH_PID}"
            echo "  ${COLOR_GREEN}✅ Watchdog 已启动 (PID $!)，监控 [${sec_name}]${COLOR_RESET}"
            echo "  ${COLOR_GRAY}日志: ${FB_HISTORY}${COLOR_RESET}"
            audit_log "启动 Watchdog 监控 ${sec_name}" "成功"
            ;;
        2)
            if [[ -f "${FB_WATCH_PID}" ]] && kill -0 "$(cat "${FB_WATCH_PID}")" 2>/dev/null; then
                local wpid
                wpid=$(cat "${FB_WATCH_PID}")
                kill "${wpid}" 2>/dev/null
                rm -f "${FB_WATCH_PID}"
                echo "  ${COLOR_GREEN}✅ Watchdog 已停止${COLOR_RESET}"
                audit_log "停止 Watchdog" "成功"
            else
                log_warning "Watchdog 未在运行"
            fi
            ;;
        *)
            return
            ;;
    esac
}

# ------------------------------------------------------------
# 7. 回退历史记录
# ------------------------------------------------------------
fb_history() {
    echo ""
    log_info "回退历史（${FB_HISTORY}）"
    echo "--------------------------------------------------"
    if [[ ! -f "${FB_HISTORY}" ]]; then
        echo "  ${COLOR_GRAY}(暂无历史记录)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    # 着色：成功绿 / 失败红 / 触发黄
    awk -F'|' '
        {
            line = "  " $1 " [" $2 "] " $3 " " $4
            if ($4 ~ /失败/) { print line "\033[1;31m ❌\033[0m" }
            else if ($3 ~ /触发/) { print line "\033[1;33m ⚠️\033[0m" }
            else { print line "\033[1;32m ✅\033[0m" }
        }
    ' "${FB_HISTORY}" 2>/dev/null | tail -30
    echo "--------------------------------------------------"
    echo "  ${COLOR_GRAY}历史总数: $(wc -l < "${FB_HISTORY}" | tr -d ' ') 条${COLOR_RESET}"
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
    fb_list
fi
