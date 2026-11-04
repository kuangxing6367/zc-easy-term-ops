#!/bin/bash
# ============================================================
# 文件：modules/25_report_daily.sh
# 功能：每日巡检报告 [Daily Inspection Report]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 一键采集：系统负载/磁盘/内存/CPU/失败服务/SSL证书到期/监听端口
#   - 报告保存 ~/.zetops/reports/daily-YYYY-MM-DD.txt（只追加不覆盖历史）
#   - 支持 crontab 定时巡检（默认每日 08:00），可直接命令行触发 cron_run
#   - 危险项自动标记：磁盘>80% / 负载>核数 / 内存<10% / 证书<30天 / 失败服务
# ============================================================
set -euo pipefail

module_name="每日巡检报告"
module_short="report_daily"
module_version="1.0.0"

REPORT_DIR="${REPORT_DIR:-${HOME}/.zetops/reports}"
REPORT_CRON_MARK="# ZETOPS-REPORT-DAILY"

module_description() {
    echo "每日自动巡检：负载/磁盘/内存/服务/证书，一键生成健康报告，支持定时任务 [Daily Report]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 立即生成巡检报告"
    echo " 2. 查看最近报告"
    echo " 3. 历史报告列表"
    echo " 4. 安装定时巡检（crontab）"
    echo " 5. 移除定时巡检"
    echo " 6. 查看定时状态"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) report_menu_generate ;;
        2) report_view ;;
        3) report_list ;;
        4) report_install_cron ;;
        5) report_remove_cron ;;
        6) report_cron_status ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 采集一段内容并追加到报告文件（bash -c 隔离，失败不中断）
# 参数：$1 要执行的命令字符串
# ------------------------------------------------------------
report_capture() {
    bash -c "$1" >> "${REPORT_FILE}" 2>&1 || \
        echo "  (采集失败: $1)" >> "${REPORT_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 计算 SSL 证书剩余天数（兼容 site_manager 逻辑，独立实现）
# 参数：$1 证书路径
# 输出：剩余天数（数字）或空
# ------------------------------------------------------------
report_cert_days() {
    local cert="$1"
    [[ -f "${cert}" ]] || { echo ""; return; }
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2 || true)
    [[ -z "${expiry}" ]] && { echo ""; return; }
    local exp_epoch now_epoch
    exp_epoch=$(date -d "${expiry}" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "${expiry}" +%s 2>/dev/null || echo "")
    [[ -z "${exp_epoch}" ]] && { echo ""; return; }
    now_epoch=$(date +%s)
    echo $(( (exp_epoch - now_epoch) / 86400 ))
}

# ------------------------------------------------------------
# 生成巡检报告
# 参数：$1 输出文件（空=默认 daily-日期.txt）
# 返回：0 成功
# ------------------------------------------------------------
report_generate() {
    local out_file="${1:-}"
    mkdir -p "${REPORT_DIR}" 2>/dev/null || true
    [[ -z "${out_file}" ]] && out_file="${REPORT_DIR}/daily-$(date +%Y-%m-%d).txt"
    REPORT_FILE="${out_file}"

    # 运行时长（uptime -p 兼容，缺失则跳过；cron 模式保持干净输出）
    local up_str
    up_str=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "")
    [[ -z "${up_str}" ]] && up_str="未知"

    echo ""
    echo "  ${COLOR_BLUE}▶ 正在生成巡检报告...${COLOR_RESET}"

    {
        echo "================================================================"
        echo "  ZETOPS 每日巡检报告 | Daily Inspection Report"
        echo "================================================================"
        echo "生成时间 : $(date '+%Y-%m-%d %H:%M:%S %A')"
        echo "主机名   : $(hostname 2>/dev/null || echo '?')"
        echo "系统     : $(uname -srm 2>/dev/null || echo '?')"
        echo "内核     : $(uname -r 2>/dev/null || echo '?')"
        echo "运行时长 : ${up_str}"
        echo "--------------------------------------------------------------"
    } > "${out_file}"

    report_capture 'echo ">>> 系统负载 (uptime)"; uptime; echo ">>> CPU 核数: $(nproc 2>/dev/null || echo 1)"'
    report_capture 'echo ""; echo ">>> 内存使用 (free -h)"; free -h'
    report_capture 'echo ""; echo ">>> 内存 TOP5 进程 (ps)"; ps -eo pid,user,%mem,%cpu,comm --sort=-%mem 2>/dev/null | head -6'
    report_capture 'echo ""; echo ">>> 磁盘使用 (df -h)"; df -h 2>/dev/null | grep -vE "^(tmpfs|devtmpfs|overlay)"'
    report_capture 'echo ""; echo ">>> 失败服务 (systemctl --failed)"; systemctl --failed --no-legend 2>/dev/null || echo "  (systemd 不可用)"'
    report_capture 'echo ""; echo ">>> 监听端口 (ss/netstat)"; (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | head -30'

    # ---- SSL 证书到期检测 ----
    echo "" >> "${out_file}"
    echo ">>> SSL 证书到期检测" >> "${out_file}"
    local cert_found=0
    local sites_file="${HOME}/.zetops/sites.ini"
    if [[ -f "${sites_file}" ]]; then
        local sec="" line cert days
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
            if [[ "${line}" =~ ^\[(.*)\] ]]; then
                sec="${BASH_REMATCH[1]}"
                continue
            fi
            if [[ "${line}" =~ ^ssl_cert[[:space:]]*=[[:space:]]*(.+)$ ]]; then
                cert=$(echo "${BASH_REMATCH[1]}" | xargs)
                days=$(report_cert_days "${cert}")
                cert_found=1
                if [[ -z "${days}" ]]; then
                    echo "  [${sec}] ${cert}  (无法读取证书)" >> "${out_file}"
                elif (( days < 0 )); then
                    echo "  [${sec}] ${cert}  ⛔ 已过期 ${days#-} 天" >> "${out_file}"
                elif (( days <= 30 )); then
                    echo "  [${sec}] ${cert}  ⚠️ 剩余 ${days} 天（<30 请尽快续期）" >> "${out_file}"
                else
                    echo "  [${sec}] ${cert}  ✅ 剩余 ${days} 天" >> "${out_file}"
                fi
            fi
        done < "${sites_file}"
    fi
    # 扫描 Let's Encrypt 常见目录
    local lc
    for lc in /etc/letsencrypt/live/*/fullchain.pem; do
        [[ -f "${lc}" ]] || continue
        days=$(report_cert_days "${lc}")
        cert_found=1
        if [[ -z "${days}" ]]; then
            echo "  ${lc}  (无法读取证书)" >> "${out_file}"
        elif (( days <= 30 )); then
            echo "  ${lc}  ⚠️ 剩余 ${days:-0} 天（<30 请尽快续期）" >> "${out_file}"
        else
            echo "  ${lc}  ✅ 剩余 ${days} 天" >> "${out_file}"
        fi
    done
    if (( cert_found == 0 )); then
        echo "  (未发现站点证书配置，跳过)" >> "${out_file}"
    fi

    echo "--------------------------------------------------------------" >> "${out_file}"

    # ---- 危险项汇总 ----
    echo "" >> "${out_file}"
    echo ">>> 危险项检查" >> "${out_file}"
    local warn_file="${out_file}.warn"
    : > "${warn_file}"
    # 磁盘使用率（子 shell 管道，用临时文件汇总保证计数正确；use 须以 % 结尾防止字段错位）
    df -P 2>/dev/null | awk 'NR>1 && $1!="tmpfs" {print $5, $6}' | while read -r use mount; do
        [[ "${use}" =~ %$ ]] || continue
        local num=${use%\%}
        if [[ "${num}" =~ ^[0-9]+$ ]] && (( num >= 80 )); then
            echo "  ⚠️ 磁盘 ${mount} 使用率 ${use}（>80%）" >> "${warn_file}"
        fi
    done
    # 负载 vs 核数（pipefail 下外部命令缺失会返回非零，均加 || true 兜底）
    local load1 cores_num
    load1=$(uptime 2>/dev/null | sed -n 's/.*load average: *\([0-9.]*\).*/\1/p' || true)
    cores_num=$(nproc 2>/dev/null || echo 1)
    if [[ -n "${load1}" ]] && awk "BEGIN {exit !(${load1} > ${cores_num})}" 2>/dev/null; then
        echo "  ⚠️ 负载 ${load1} 高于 CPU 核数 ${cores_num}" >> "${warn_file}"
    fi
    # 内存可用率
    local mem_avail mem_total
    mem_avail=$(free -m 2>/dev/null | awk '/Mem:/{print $7}' || true)
    mem_total=$(free -m 2>/dev/null | awk '/Mem:/{print $2}' || true)
    if [[ -n "${mem_avail}" && -n "${mem_total}" ]] && (( mem_total > 0 )) && awk "BEGIN {exit !((${mem_avail} * 100 / ${mem_total}) < 10)}"; then
        echo "  ⚠️ 可用内存仅 ${mem_avail}MB / ${mem_total}MB（<10%）" >> "${warn_file}"
    fi
    # 失败服务
    if command -v systemctl >/dev/null 2>&1; then
        local fail_n
        fail_n=$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ' || true)
        if [[ "${fail_n}" =~ ^[0-9]+$ ]] && (( fail_n > 0 )); then
            echo "  ⚠️ 存在 ${fail_n} 个失败服务" >> "${warn_file}"
        fi
    fi
    if [[ -s "${warn_file}" ]]; then
        cat "${warn_file}" >> "${out_file}"
    else
        echo "  (未发现明显危险项)" >> "${out_file}"
    fi
    rm -f "${warn_file}"

    echo "================================================================" >> "${out_file}"

    echo ""
    log_success "报告已生成: ${out_file}"
    if command -v audit_log >/dev/null 2>&1; then
        audit_log "生成巡检报告" "成功"
    fi
}

# ------------------------------------------------------------
# 1. 生成报告（交互入口）
# ------------------------------------------------------------
report_menu_generate() {
    local today="${REPORT_DIR}/daily-$(date +%Y-%m-%d).txt"
    if [[ -f "${today}" ]]; then
        read_input over "今日报告已存在，是否覆盖？[y/N]" "n"
        if [[ "${over}" != "y" && "${over}" != "Y" ]]; then
            log_info "保留今日已有报告，直接查看"
            report_view_file "${today}"
            return
        fi
    fi
    report_generate
    report_view_file "${REPORT_FILE}"
}

# ------------------------------------------------------------
# 查看指定报告文件
# 参数：$1 文件路径
# ------------------------------------------------------------
report_view_file() {
    local file="$1"
    echo ""
    if [[ ! -f "${file}" ]]; then
        log_warning "报告不存在: ${file}"
        return
    fi
    log_info "报告内容（${file}）"
    echo "--------------------------------------------------"
    cat "${file}"
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 2. 查看最近报告
# ------------------------------------------------------------
report_view() {
    local latest
    latest=$(ls -t "${REPORT_DIR}"/daily-*.txt 2>/dev/null | head -1 || true)
    if [[ -z "${latest}" ]]; then
        log_warning "暂无报告，请先执行: 菜单 1"
        return
    fi
    report_view_file "${latest}"
}

# ------------------------------------------------------------
# 3. 历史报告列表
# ------------------------------------------------------------
report_list() {
    echo ""
    log_info "历史报告（${REPORT_DIR}）"
    echo "--------------------------------------------------"
    local list
    list=$(ls -lt "${REPORT_DIR}"/daily-*.txt 2>/dev/null || true)
    if [[ -z "${list}" ]]; then
        echo "  ${COLOR_GRAY}(暂无报告)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    echo "${list}" | while IFS= read -r f; do
        printf "  %s  (%s 行, %s)\n" "$(basename "${f}")" "$(wc -l < "${f}" | tr -d ' ')" "$(du -h "${f}" 2>/dev/null | cut -f1)"
    done
    echo "--------------------------------------------------"
    read_input pick "输入报告日期查看（YYYY-MM-DD，回车跳过）" ""
    if [[ -n "${pick}" ]]; then
        report_view_file "${REPORT_DIR}/daily-${pick}.txt"
    fi
}

# ------------------------------------------------------------
# 4. 安装定时巡检（crontab 每日）
# ------------------------------------------------------------
report_install_cron() {
    check_command crontab || { log_error "系统未安装 crontab（请先安装 cron）"; return; }
    local script_path
    script_path="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/25_report_daily.sh"
    [[ -f "${script_path}" ]] || { log_error "找不到模块文件: ${script_path}"; return; }

    if crontab -l 2>/dev/null | grep -qF "${REPORT_CRON_MARK}"; then
        log_warning "定时巡检已安装，无需重复添加"
        report_cron_status
        return
    fi

    read_input rp_hour "每天执行时间(时 0-23)" "8"
    read_input rp_min "每天执行时间(分 0-59)" "0"
    [[ "${rp_hour}" =~ ^[0-9]+$ ]] && (( rp_hour >= 0 && rp_hour <= 23 )) || rp_hour=8
    [[ "${rp_min}" =~ ^[0-9]+$ ]] && (( rp_min >= 0 && rp_min <= 59 )) || rp_min=0

    ( crontab -l 2>/dev/null; echo "${REPORT_CRON_MARK}"; echo "${rp_min} ${rp_hour} * * * /bin/bash ${script_path} cron_run >/dev/null 2>&1" ) | crontab - || {
        log_error "写入 crontab 失败"; return 1; }
    log_success "已安装每日巡检（${rp_hour}:${rp_min}），报告保存至 ${REPORT_DIR}"
    audit_log "安装定时巡检" "成功"
}

# ------------------------------------------------------------
# 5. 移除定时巡检
# ------------------------------------------------------------
report_remove_cron() {
    check_command crontab || { log_error "系统未安装 crontab"; return; }
    if ! crontab -l 2>/dev/null | grep -qF "${REPORT_CRON_MARK}"; then
        log_warning "当前未安装定时巡检"
        return
    fi
    if confirm_action "确认移除每日巡检定时任务？"; then
        crontab -l 2>/dev/null | grep -vF "${REPORT_CRON_MARK}" | grep -vF "25_report_daily.sh cron_run" | crontab - || {
            log_error "移除 crontab 失败"; return 1; }
        log_success "已移除定时巡检"
        audit_log "移除定时巡检" "成功"
    fi
}

# ------------------------------------------------------------
# 6. 查看定时状态
# ------------------------------------------------------------
report_cron_status() {
    echo ""
    log_info "定时巡检状态"
    echo "--------------------------------------------------"
    if ! check_command crontab; then
        echo "  ${COLOR_RED}未安装 crontab${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local line
    line=$(crontab -l 2>/dev/null | grep -F "25_report_daily.sh cron_run" || true)
    if [[ -z "${line}" ]]; then
        echo "  ${COLOR_YELLOW}未安装定时巡检（菜单 4 可安装）${COLOR_RESET}"
    else
        echo "  ✅ 已安装: ${line}"
    fi
    echo "  ${COLOR_GRAY}报告目录: ${REPORT_DIR}${COLOR_RESET}"
    echo "--------------------------------------------------"
}

# ============================================================
# 独立执行保护（crontab 调用: bash 25_report_daily.sh cron_run）
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
    if [[ "${1:-}" == "cron_run" ]]; then
        report_generate >/dev/null 2>&1 || exit 1
        echo "$(date '+%Y-%m-%d %H:%M:%S') 每日巡检完成: ${REPORT_FILE}" >> "${HOME}/.zetops/reports.log" 2>/dev/null || true
    else
        report_list
    fi
fi
