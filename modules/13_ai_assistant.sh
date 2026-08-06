#!/bin/bash
# ============================================================
# 文件：modules/13_ai_assistant.sh
# 功能：ZETOPS AI 智能运维助手 [AI Ops Assistant]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 纯 Bash 规则引擎，零外部依赖（无 Python/Node/AI API）
#   - 自然语言输入 → 意图识别 → 自动诊断 → 交互确认 → 执行修复 → 验证
#   - 支持 9 大运维场景：Web 502/503、服务宕机、磁盘满、CPU 高负载、
#     内存 OOM、网络不通、Docker 容器、MySQL 连接、端口不通
#   - 多轮对话上下文，支持跟进诊断与验证
# ============================================================
set -euo pipefail

module_name="AI 智能运维助手"
module_short="ai_assistant"
module_version="1.0.0"

# ---- 多轮上下文（全局） ----
AI_CTX_INTENT=""       # 上次意图
AI_CTX_TARGET=""       # 上次目标（服务名/端口/IP/容器名）
AI_CTX_LAST_CMD=""     # 上次执行的修复命令
AI_CTX_HISTORY=()      # 对话历史摘要

# ============================================================
# 模块统一接口
# ============================================================
module_description() {
    echo "ZETOPS AI - 自然语言运维助手，自动诊断+交互修复 [Natural Language Ops Assistant]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. AI 对话模式（自然语言描述问题）"
    echo " 2. 查看支持的诊断场景"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) ai_chat_loop ;;
        2) ai_show_scenarios ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ============================================================
# AI 对话主循环
# ============================================================

# ------------------------------------------------------------
# AI 对话主循环（自然语言输入 → 意图解析 → 诊断 → 修复 → 验证）
# 参数：无
# 返回：无
# ------------------------------------------------------------
ai_chat_loop() {
    clear
    echo "${COLOR_BOLD}${COLOR_BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          ZETOPS AI - 智能运维助手 v${module_version}            ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  用自然语言描述你的问题，AI 会自动诊断并建议修复方案       ║"
    echo "║  输入 'help' 查看示例 | 'exit' 或 '退出' 返回              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "${COLOR_RESET}"

    local input=""
    while true; do
        # 读取自然语言输入
        echo -n "${COLOR_BOLD}${COLOR_GREEN}AI>${COLOR_RESET} "
        read -r input || { echo ""; break; }
        input="${input#"${input%%[![:space:]]*}"}"  # 去除前导空格
        input="${input%"${input##*[![:space:]]}"}"   # 去除尾部空格

        # 空输入跳过
        [[ -z "${input}" ]] && continue

        # 退出指令
        case "${input}" in
            exit|quit|退出|q|Q)
                echo "${COLOR_BLUE}ZETOPS AI 已退出，再见！${COLOR_RESET}"
                break
                ;;
            help|帮助|?|？)
                ai_show_help
                continue
                ;;
            clear|cls|清屏)
                clear
                continue
                ;;
            history|历史)
                ai_show_history
                continue
                ;;
        esac

        # 解析意图并执行
        ai_process_input "${input}"
    done
}

# ------------------------------------------------------------
# 处理用户输入：解析意图 → 分发到对应处理器
# 参数：$1 用户输入
# 返回：无
# ------------------------------------------------------------
ai_process_input() {
    local input="$1"
    local intent

    # 解析意图
    intent=$(ai_parse_intent "${input}")

    # 记录对话历史
    AI_CTX_HISTORY+=("[用户] ${input}")
    AI_CTX_HISTORY+=("[AI] 意图: ${intent}")

    if [[ "${intent}" == "unknown" ]]; then
        echo ""
        echo "${COLOR_YELLOW}  抱歉，我暂时无法理解这个问题。${COLOR_RESET}"
        echo "${COLOR_GRAY}  支持的场景：502/503错误、服务宕机、磁盘满、CPU高、内存OOM、网络不通、Docker容器、MySQL连接、端口不通${COLOR_RESET}"
        echo "${COLOR_GRAY}  输入 'help' 查看示例${COLOR_RESET}"
        echo ""
        return
    fi

    echo ""
    echo "${COLOR_BLUE}  正在分析...${COLOR_RESET}"

    # 分发到对应处理器
    case "${intent}" in
        web_error)      ai_handle_web_error "${input}" ;;
        service_down)   ai_handle_service_down "${input}" ;;
        disk_full)      ai_handle_disk_full "${input}" ;;
        high_cpu)       ai_handle_high_cpu "${input}" ;;
        high_memory)    ai_handle_high_memory "${input}" ;;
        network_issue)  ai_handle_network_issue "${input}" ;;
        docker_issue)   ai_handle_docker_issue "${input}" ;;
        mysql_issue)    ai_handle_mysql_issue "${input}" ;;
        port_blocked)   ai_handle_port_blocked "${input}" ;;
        *)              ai_handle_unknown "${input}" ;;
    esac

    AI_CTX_INTENT="${intent}"
    echo ""
}

# ============================================================
# 意图解析引擎（纯 Bash 正则模式匹配）
# ============================================================

# ------------------------------------------------------------
# 解析用户输入的意图
# 参数：$1 用户输入文本
# 输出：意图标识符（web_error/service_down/disk_full/...）
# ------------------------------------------------------------
ai_parse_intent() {
    local input="$1"
    local lower
    lower=$(echo "${input}" | tr '[:upper:]' '[:lower:]')

    # ---- Web 502/503/500 错误 ----
    if [[ "${lower}" =~ (502|503|500|bad gateway|网关) ]] || \
       [[ "${lower}" =~ (nginx|apache).*(错误|error|故障|fail|502|503|500) ]] || \
       [[ "${lower}" =~ (错误|error|故障).*(nginx|apache|web|网关) ]]; then
        echo "web_error"
        return
    fi

    # ---- 服务宕机/启动失败 ----
    if [[ "${lower}" =~ (服务|service|进程|process).*(挂|down|停|stop|死|kill|崩|crash|失败|fail) ]] || \
       [[ "${lower}" =~ (挂了|down了|停止了|起不来|启动失败|无法启动|crash) ]]; then
        echo "service_down"
        return
    fi

    # ---- 磁盘满 ----
    if [[ "${lower}" =~ (磁盘|disk|空间|space|存储|storage).*(满|full|不够|不足|告警|alert) ]] || \
       [[ "${lower}" =~ (no space|磁盘占满|写不进去|空间不足) ]]; then
        echo "disk_full"
        return
    fi

    # ---- CPU 高负载 ----
    if [[ "${lower}" =~ (cpu|处理器|负载|load).*(高|high|满|100|告警|飙升|占用) ]] || \
       [[ "${lower}" =~ (卡顿|卡死|load high|cpu 100) ]]; then
        echo "high_cpu"
        return
    fi

    # ---- 内存/OOM ----
    if [[ "${lower}" =~ (内存|memory|内存|oom|out of memory).*(高|满|不足|泄漏|leak|告警|kill) ]] || \
       [[ "${lower}" =~ (oom|out of memory|内存溢出|内存不够|内存泄漏) ]]; then
        echo "high_memory"
        return
    fi

    # ---- 网络不通 ----
    if [[ "${lower}" =~ (网络|network|连接|connect|ping|不通|无法访问|超时|timeout) ]] || \
       [[ "${lower}" =~ (上不了网|连不上|网络故障|network unreachable) ]]; then
        echo "network_issue"
        return
    fi

    # ---- Docker 容器问题 ----
    if [[ "${lower}" =~ (docker|容器|container).*(挂|down|停|起不来|失败|fail|重启|restart|异常|error) ]] || \
       [[ "${lower}" =~ (容器.*退出|exited|container.*fail) ]]; then
        echo "docker_issue"
        return
    fi

    # ---- MySQL 连接问题 ----
    if [[ "${lower}" =~ (mysql|mariadb|数据库|database|sql).*(连接|connect|拒绝|refused|超时|timeout|挂|down|失败|fail) ]] || \
       [[ "${lower}" =~ (数据库.*连不上|mysql.*down|连接被拒绝) ]]; then
        echo "mysql_issue"
        return
    fi

    # ---- 端口不通 ----
    if [[ "${lower}" =~ (端口|port).*(不通| blocked|关闭|close|防火墙|firewall|拒绝|refused|无法访问) ]] || \
       [[ "${lower}" =~ (telnet.*不通|端口.*不通|防火墙.*拦截|port.*blocked) ]]; then
        echo "port_blocked"
        return
    fi

    echo "unknown"
}

# ------------------------------------------------------------
# 从输入中提取服务名
# 参数：$1 用户输入
# 输出：服务名（如 nginx/mysql/docker/redis...）
# ------------------------------------------------------------
ai_extract_service() {
    local input="$1"
    local lower
    lower=$(echo "${input}" | tr '[:upper:]' '[:lower:]')

    # 按优先级匹配常见服务
    local services=(nginx apache httpd tomcat mysql mariadb mysqld postgresql pgsql redis mongodb docker php-fpm php7.4 php8.0 php8.1 php8.2 uwsgi gunicorn node pm2 nginx-ingress)
    local s
    for s in "${services[@]}"; do
        if [[ "${lower}" =~ ${s} ]]; then
            echo "${s}"
            return
        fi
    done
    echo ""
}

# ------------------------------------------------------------
# 从输入中提取端口号
# 参数：$1 用户输入
# 输出：端口号（如 8080/3306...）
# ------------------------------------------------------------
ai_extract_port() {
    local input="$1"
    if [[ "${input}" =~ ([0-9]{2,5}) ]] && [[ "${input}" =~ (端口|port|:|服务) ]]; then
        local port="${BASH_REMATCH[1]}"
        if (( port >= 1 && port <= 65535 )); then
            echo "${port}"
            return
        fi
    fi
    # 常见服务默认端口
    local lower
    lower=$(echo "${input}" | tr '[:upper:]' '[:lower:]')
    case "${lower}" in
        *nginx*|*apache*|*httpd*)   echo "80" ;;
        *mysql*|*mariadb*)          echo "3306" ;;
        *redis*)                    echo "6379" ;;
        *postgresql*|*pgsql*)       echo "5432" ;;
        *tomcat*)                   echo "8080" ;;
        *mongodb*)                  echo "27017" ;;
        *)                          echo "" ;;
    esac
}

# ============================================================
# 核心交互工具函数
# ============================================================

# ------------------------------------------------------------
# 打印带编号的步骤
# 参数：$1 步骤编号  $2 内容
# ------------------------------------------------------------
ai_print_step() {
    local num="$1"
    local msg="$2"
    echo "  ${COLOR_BOLD}${COLOR_BLUE}${num}.${COLOR_RESET} ${msg}"
}

# ------------------------------------------------------------
# 打印分析结果标记
# 参数：$1 类型(ok/warn/error/info)  $2 消息
# ------------------------------------------------------------
ai_print_finding() {
    local type="$1"
    local msg="$2"
    case "${type}" in
        ok)    echo "  ${COLOR_GREEN}✅ ${msg}${COLOR_RESET}" ;;
        warn)  echo "  ${COLOR_YELLOW}⚠️  ${msg}${COLOR_RESET}" ;;
        error) echo "  ${COLOR_RED}❌ ${msg}${COLOR_RESET}" ;;
        info)  echo "  ${COLOR_BLUE}ℹ️  ${msg}${COLOR_RESET}" ;;
        *)     echo "  ${msg}" ;;
    esac
}

# ------------------------------------------------------------
# y/N 确认提示（默认 N）
# 参数：$1 提示语
# 返回：0=确认(y) 1=取消(n)
# ------------------------------------------------------------
ai_confirm() {
    local prompt="$1"
    local ans=""
    echo ""
    echo -n "  ${COLOR_BOLD}${prompt} [y/N]: ${COLOR_RESET}"
    read -r ans || ans="n"
    ans=$(echo "${ans}" | tr '[:upper:]' '[:lower:]')
    [[ "${ans}" == "y" || "${ans}" == "yes" ]]
}

# ------------------------------------------------------------
# 危险命令检测（检测破坏性操作模式）
# 参数：$1 命令字符串
# 返回：0=危险 1=安全
# ------------------------------------------------------------
ai_is_dangerous() {
    local cmd="$1"
    # 高风险命令模式：递归删除根目录、磁盘格式化、清空防火墙、递归权限修改等
    if echo "${cmd}" | grep -qiE 'rm -rf /|dd if=.*of=|mkfs|fdisk|chmod -R 777 /|chown -R [^ ]+ /[^ ]|iptables -F|systemctl (stop|disable) firewalld'; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------
# 安全超时执行（timeout 不存在时直接执行，避免卡死）
# 参数：$1 超时秒数  $@ 命令及参数
# 输出：命令输出
# ------------------------------------------------------------
ai_timeout() {
    local secs="$1"
    shift
    if check_command timeout; then
        timeout "${secs}" "$@"
    else
        "$@"
    fi
}

# ------------------------------------------------------------
# 多回退命令执行（依次尝试命令列表，首个成功即返回）
# 参数：$@ 命令字符串列表（每个参数为一条完整命令）
# 输出：首个成功命令的输出
# 返回：0=某个成功 1=全部失败
# ------------------------------------------------------------
ai_run_with_fallback() {
    local cmd output
    for cmd in "$@"; do
        output=$(bash -c "${cmd}" 2>&1) && {
            echo "${output}"
            return 0
        }
    done
    return 1
}

# ------------------------------------------------------------
# 获取服务状态（systemctl → service 回退，兼容无 systemd 环境）
# 参数：$1 服务名
# 输出：active/inactive/unknown
# ------------------------------------------------------------
ai_get_svc_status() {
    local svc="$1"
    if check_command systemctl; then
        systemctl is-active "${svc}" 2>/dev/null || echo "unknown"
    elif check_command service; then
        service "${svc}" status >/dev/null 2>&1 && echo "active" || echo "inactive"
    else
        # 最后回退：检查进程是否存在
        pgrep -x "${svc}" >/dev/null 2>&1 && echo "active" || echo "unknown"
    fi
}

# ------------------------------------------------------------
# 安全执行只读诊断命令（不修改系统，无需确认）
# 参数：$1 命令描述  $2 命令
# 输出：命令输出
# ------------------------------------------------------------
ai_run_safe() {
    local desc="$1"
    shift
    show_spinner "  诊断: ${desc}"
    local output
    output=$("$@" 2>&1) || output="${output}"
    stop_spinner
    echo "${output}"
}

# ------------------------------------------------------------
# 执行修复命令（需用户确认）
# 参数：$1 命令描述  $2 命令字符串
# 返回：0=执行成功 1=用户取消或执行失败
# ------------------------------------------------------------
ai_run_fix() {
    local desc="$1"
    local cmd="$2"

    # 危险命令额外警告
    if ai_is_dangerous "${cmd}"; then
        echo ""
        echo "  ${COLOR_RED}${COLOR_BOLD}⚠️  警告：此命令具有破坏性，请仔细确认！${COLOR_RESET}"
    fi

    echo ""
    echo "  ${COLOR_BOLD}建议执行:${COLOR_RESET} ${COLOR_YELLOW}${cmd}${COLOR_RESET}"

    if ai_confirm "是否执行?"; then
        echo "  ${COLOR_BLUE}执行中...${COLOR_RESET}"
        # 使用 bash -c 在子 shell 中执行，隔离对当前 shell 环境的影响
        if bash -c "${cmd}" 2>&1; then
            echo "  ${COLOR_GREEN}✅ 已执行：${desc}${COLOR_RESET}"
            AI_CTX_LAST_CMD="${cmd}"
            AI_CTX_HISTORY+=("[执行] ${cmd}")
            return 0
        else
            echo "  ${COLOR_RED}❌ 执行失败，请检查错误信息${COLOR_RESET}"
            return 1
        fi
    else
        echo "  ${COLOR_GRAY}已跳过${COLOR_RESET}"
        return 1
    fi
}

# ------------------------------------------------------------
# 执行验证命令（需用户确认）
# 参数：$1 验证描述  $2 验证命令
# ------------------------------------------------------------
ai_run_verify() {
    local desc="$1"
    local cmd="$2"

    echo ""
    echo "  ${COLOR_BLUE}验证建议: ${desc}${COLOR_RESET}"
    echo "  ${COLOR_GRAY}命令: ${cmd}${COLOR_RESET}"

    if ai_confirm "是否执行验证?"; then
        echo "  ${COLOR_BLUE}验证中...${COLOR_RESET}"
        local output
        output=$(bash -c "${cmd}" 2>&1) || output="${output}"
        echo "  ${COLOR_GRAY}--- 输出 ---${COLOR_RESET}"
        echo "${output}" | head -20 | sed 's/^/  /'
        echo "  ${COLOR_GRAY}------------${COLOR_RESET}"
        if [[ -n "${output}" ]]; then
            echo "  ${COLOR_GREEN}✅ 验证完成${COLOR_RESET}"
        else
            echo "  ${COLOR_YELLOW}⚠️  验证无输出，请手动检查${COLOR_RESET}"
        fi
    else
        echo "  ${COLOR_GRAY}已跳过验证${COLOR_RESET}"
    fi
}

# ============================================================
# 诊断场景处理器
# ============================================================

# ------------------------------------------------------------
# 场景1：Web 502/503/500 错误诊断
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_web_error() {
    local input="$1"
    local service
    service=$(ai_extract_service "${input}")
    [[ -z "${service}" ]] && service="nginx"
    AI_CTX_TARGET="${service}"

    local step=1

    # 步骤1：检查 Web 服务器是否运行
    local svc_status
    svc_status=$(ai_get_svc_status "${service}")
    if [[ "${svc_status}" == "active" ]]; then
        ai_print_step $((step++)) "Web 服务 ${service} 正在运行"
    else
        ai_print_step $((step++)) "${COLOR_RED}Web 服务 ${service} 未运行 (状态: ${svc_status})${COLOR_RESET}"
        ai_run_fix "启动 ${service} 服务" "sudo systemctl start ${service}"
        ai_run_verify "检查服务状态" "systemctl status ${service}"
        return
    fi

    # 步骤2：检查后端 upstream 配置
    local upstream_info=""
    if [[ -d /etc/nginx ]]; then
        upstream_info=$(grep -rh "proxy_pass\|upstream" /etc/nginx/ 2>/dev/null | head -10 || true)
    fi
    if [[ -n "${upstream_info}" ]]; then
        ai_print_step $((step++)) "检测到反向代理配置:"
        echo "${upstream_info}" | sed 's/^/      /'
    fi

    # 步骤3：检查后端端口监听
    local backend_ports
    backend_ports=$(ss -tlnp 2>/dev/null | grep -E ':(80|443|8080|8000|9000|3000|5000)' || true)
    if [[ -n "${backend_ports}" ]]; then
        ai_print_step $((step++)) "检测到以下端口监听:"
        echo "${backend_ports}" | sed 's/^/      /'
    else
        ai_print_step $((step++)) "${COLOR_RED}未检测到常见 Web 后端端口监听${COLOR_RESET}"
        ai_print_finding error "后端服务可能未启动"
    fi

    # 步骤4：检查错误日志
    local error_log=""
    for log in /var/log/nginx/error.log /var/log/apache2/error.log /var/log/httpd/error_log; do
        if [[ -f "${log}" ]]; then
            error_log=$(tail -10 "${log}" 2>/dev/null || true)
            break
        fi
    done
    if [[ -n "${error_log}" ]]; then
        ai_print_step $((step++)) "最近的错误日志:"
        echo "${error_log}" | sed 's/^/      /'
    fi

    # 分析与建议
    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"
    if [[ "${svc_status}" != "active" ]]; then
        ai_print_finding error "${service} 服务未运行，这是 502 的直接原因"
        ai_run_fix "启动 ${service}" "sudo systemctl start ${service}"
    else
        ai_print_finding warn "Web 服务运行中，502 可能由后端 upstream 引起"
        echo "  ${COLOR_GRAY}请检查后端服务（php-fpm/uwsgi/gunicorn/node）是否正常${COLOR_RESET}"
        ai_run_fix "重载 ${service} 配置" "sudo systemctl reload ${service}"
    fi

    ai_run_verify "测试 Web 访问" "curl -sI --max-time 5 http://localhost"
}

# ------------------------------------------------------------
# 场景2：服务宕机/启动失败
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_service_down() {
    local input="$1"
    local service
    service=$(ai_extract_service "${input}")
    AI_CTX_TARGET="${service:-unknown}"

    local step=1

    if [[ -n "${service}" ]]; then
        # 检查指定服务
        local svc_status
        svc_status=$(ai_get_svc_status "${service}")
        ai_print_step $((step++)) "服务 ${service} 状态: ${svc_status}"

        # 检查进程是否存在
        local proc
        proc=$(pgrep -a "${service}" 2>/dev/null | head -3 || true)
        if [[ -n "${proc}" ]]; then
            ai_print_step $((step++)) "进程信息:"
            echo "${proc}" | sed 's/^/      /'
        else
            ai_print_step $((step++)) "${COLOR_RED}未找到 ${service} 进程${COLOR_RESET}"
        fi

        # 检查最近日志
        local logs
        logs=$(journalctl -u "${service}" --no-pager -n 15 2>/dev/null || true)
        if [[ -n "${logs}" ]]; then
            ai_print_step $((step++)) "最近日志 (journalctl -u ${service}):"
            echo "${logs}" | tail -10 | sed 's/^/      /'
        fi
    else
        # 未指定服务，列出异常服务
        ai_print_step $((step++)) "未指定服务名，检查所有异常的服务:"
        local failed
        failed=$(systemctl --failed --no-legend 2>/dev/null || true)
        if [[ -n "${failed}" ]]; then
            echo "${failed}" | sed 's/^/      /'
        else
            echo "      (无异常服务)"
        fi
        echo ""
        echo "  ${COLOR_GRAY}请指定服务名，如: 'nginx 挂了' / 'mysql 起不来'${COLOR_RESET}"
        return
    fi

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"
    if [[ "${svc_status}" != "active" ]]; then
        ai_print_finding error "${service} 当前状态: ${svc_status}"
        ai_run_fix "启动 ${service}" "sudo systemctl start ${service}"
        ai_run_verify "检查服务状态" "systemctl status ${service}"
    else
        ai_print_finding ok "${service} 正在运行"
        ai_run_fix "重启 ${service}" "sudo systemctl restart ${service}"
    fi
}

# ------------------------------------------------------------
# 场景3：磁盘空间满
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_disk_full() {
    local input="$1"
    local step=1

    # 步骤1：磁盘使用率
    local df_output
    df_output=$(df -h 2>/dev/null || true)
    ai_print_step $((step++)) "磁盘使用情况 (df -h):"
    echo "${df_output}" | sed 's/^/      /'

    # 分析高使用率分区
    local high_usage
    high_usage=$(df -h 2>/dev/null | awk 'NR>1 && $(NF-1)+0 > 80 {print $0}' || true)

    # 步骤2：inode 使用率
    local inode_output
    inode_output=$(df -i 2>/dev/null | awk 'NR>1 && $5+0 > 80 {print $0}' || true)
    if [[ -n "${inode_output}" ]]; then
        ai_print_step $((step++)) "${COLOR_YELLOW}inode 使用率过高:${COLOR_RESET}"
        echo "${inode_output}" | sed 's/^/      /'
    fi

    # 步骤3：查找大目录
    local big_dirs
    big_dirs=$(du -sh /var/log /tmp /home /root /data /opt 2>/dev/null | sort -rh | head -10 || true)
    if [[ -n "${big_dirs}" ]]; then
        ai_print_step $((step++)) "主要目录占用:"
        echo "${big_dirs}" | sed 's/^/      /'
    fi

    # 步骤4：查找大文件
    local big_files
    big_files=$(find /var/log /tmp -type f -size +100M 2>/dev/null | head -10 || true)
    if [[ -n "${big_files}" ]]; then
        ai_print_step $((step++)) "大文件 (>100M):"
        echo "${big_files}" | sed 's/^/      /'
    fi

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"
    if [[ -n "${high_usage}" ]]; then
        ai_print_finding error "以下分区使用率超过 80%:"
        echo "${high_usage}" | sed 's/^/      /'
        echo ""
        echo "  ${COLOR_BOLD}建议修复方案:${COLOR_RESET}"
        ai_run_fix "清理系统日志 (保留最近100M)" "sudo journalctl --vacuum-size=100M"

        # 按包管理器生成对应清理命令（apt/yum/dnf/zypper/apk）
        local pkg_clean=""
        case "$(detect_pkg_manager)" in
            apt)    pkg_clean="apt-get clean" ;;
            dnf)    pkg_clean="dnf clean all" ;;
            yum)    pkg_clean="yum clean all" ;;
            zypper) pkg_clean="zypper clean --all" ;;
            apk)    pkg_clean="apk cache clean" ;;
        esac
        [[ -n "${pkg_clean}" ]] && ai_run_fix "清理包管理器缓存" "sudo ${pkg_clean}"

        ai_run_fix "清理 /tmp 旧文件 (>7天)" "sudo find /tmp -type f -mtime +7 -delete"
        ai_run_verify "检查磁盘空间" "df -h"
    else
        ai_print_finding ok "所有分区使用率正常 (<80%)"
    fi
}

# ------------------------------------------------------------
# 场景4：CPU 高负载
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_high_cpu() {
    local input="$1"
    local step=1

    # 步骤1：系统负载
    local load
    load=$(uptime 2>/dev/null || true)
    ai_print_step $((step++)) "系统负载:"
    echo "      ${load}"

    # 步骤2：CPU Top 进程
    local top_cpu
    top_cpu=$(ps aux --sort=-%cpu 2>/dev/null | head -11 || true)
    ai_print_step $((step++)) "CPU 占用 Top 10 进程:"
    echo "${top_cpu}" | sed 's/^/      /'

    # 步骤3：检查僵尸进程
    local zombies
    zombies=$(ps aux 2>/dev/null | awk '$8 ~ /Z/ {print}' || true)
    if [[ -n "${zombies}" ]]; then
        ai_print_step $((step++)) "${COLOR_YELLOW}检测到僵尸进程:${COLOR_RESET}"
        echo "${zombies}" | sed 's/^/      /'
    fi

    # 步骤4：CPU 核心数
    local cores
    cores=$(nproc 2>/dev/null || echo "?")
    ai_print_step $((step++)) "CPU 核心数: ${cores}"

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"

    # 提取负载均值
    local load1
    load1=$(echo "${load}" | sed -n 's/.*load average: *\([0-9.]*\).*/\1/p' || echo "0")
    load1="${load1:-0}"
    local cores_num=${cores//[^0-9]/}
    cores_num=${cores_num:-1}

    if awk "BEGIN {exit !(${load1} > ${cores_num})}" 2>/dev/null; then
        ai_print_finding warn "1分钟负载 ${load1} 超过 CPU 核心数 ${cores}，系统过载"

        # 提取 CPU 最高的进程
        local top_proc
        top_proc=$(ps aux --sort=-%cpu 2>/dev/null | sed -n '2p' || true)
        local top_pid
        top_pid=$(echo "${top_proc}" | awk '{print $2}')
        local top_cmd
        top_cmd=$(echo "${top_proc}" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}')

        if [[ -n "${top_pid}" ]]; then
            ai_print_finding info "CPU 最高进程: PID=${top_pid} (${top_cmd})"
            ai_run_fix "终止高 CPU 进程 (PID=${top_pid})" "sudo kill ${top_pid}"
        fi
    else
        ai_print_finding ok "CPU 负载正常 (负载 ${load1} / 核心数 ${cores})"
    fi

    ai_run_verify "检查系统负载" "uptime"
}

# ------------------------------------------------------------
# 场景5：内存 OOM
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_high_memory() {
    local input="$1"
    local step=1

    # 步骤1：内存使用
    local mem
    mem=$(free -h 2>/dev/null || true)
    ai_print_step $((step++)) "内存使用情况:"
    echo "${mem}" | sed 's/^/      /'

    # 步骤2：内存 Top 进程
    local top_mem
    top_mem=$(ps aux --sort=-%mem 2>/dev/null | head -11 || true)
    ai_print_step $((step++)) "内存占用 Top 10 进程:"
    echo "${top_mem}" | sed 's/^/      /'

    # 步骤3：Swap 使用
    local swap_line
    swap_line=$(echo "${mem}" | grep -i swap || true)
    ai_print_step $((step++)) "Swap: ${swap_line}"

    # 步骤4：OOM Killer 日志
    local oom_log
    oom_log=$(dmesg 2>/dev/null | grep -i "oom\|killed process\|out of memory" | tail -10 || true)
    if [[ -n "${oom_log}" ]]; then
        ai_print_step $((step++)) "${COLOR_RED}检测到 OOM Killer 记录:${COLOR_RESET}"
        echo "${oom_log}" | sed 's/^/      /'
    else
        ai_print_step $((step++)) "未检测到 OOM Killer 记录"
    fi

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"

    # 检查可用内存
    local avail_mem
    avail_mem=$(free -m 2>/dev/null | awk '/Mem:/ {print $7}' || echo "0")
    if (( avail_mem < 200 )); then
        ai_print_finding error "可用内存仅 ${avail_mem}MB，内存严重不足"
    else
        ai_print_finding warn "可用内存 ${avail_mem}MB"
    fi

    # 提取内存最高进程
    local top_proc
    top_proc=$(ps aux --sort=-%mem 2>/dev/null | sed -n '2p' || true)
    local top_pid
    top_pid=$(echo "${top_proc}" | awk '{print $2}')
    local top_cmd
    top_cmd=$(echo "${top_proc}" | awk '{for(i=11;i<=NF;i++) printf "%s ", $i; print ""}')

    if [[ -n "${top_pid}" ]]; then
        ai_print_finding info "内存最高进程: PID=${top_pid} (${top_cmd})"
        ai_run_fix "终止高内存进程 (PID=${top_pid})" "sudo kill ${top_pid}"
    fi

    # 如果没有 swap，建议添加
    local swap_total
    swap_total=$(free -m 2>/dev/null | awk '/Swap:/ {print $2}' || echo "0")
    if (( swap_total == 0 )); then
        ai_print_finding warn "系统未配置 Swap，建议添加 Swap 文件"
        ai_run_fix "创建 2GB Swap 文件" "sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
    fi

    ai_run_verify "检查内存状态" "free -h"
}

# ------------------------------------------------------------
# 场景6：网络不通
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_network_issue() {
    local input="$1"
    local step=1

    # 步骤1：网卡状态
    local interfaces
    interfaces=$(ip -brief addr 2>/dev/null || ip addr 2>/dev/null || ifconfig 2>/dev/null || true)
    ai_print_step $((step++)) "网卡状态:"
    echo "${interfaces}" | sed 's/^/      /'

    # 步骤2：路由表
    local routes
    routes=$(ip route 2>/dev/null || route -n 2>/dev/null || true)
    ai_print_step $((step++)) "路由表:"
    echo "${routes}" | head -10 | sed 's/^/      /'

    # 步骤3：DNS 配置
    local dns
    dns=$(cat /etc/resolv.conf 2>/dev/null || true)
    ai_print_step $((step++)) "DNS 配置:"
    echo "${dns}" | sed 's/^/      /'

    # 步骤4：测试外网连通性
    local ping_result
    ping_result=$(ping -c 3 -W 3 8.8.8.8 2>&1 || true)
    ai_print_step $((step++)) "Ping 8.8.8.8:"
    echo "${ping_result}" | sed 's/^/      /'

    # 步骤5：测试 DNS 解析
    local dns_result
    dns_result=$(ai_timeout 5 nslookup baidu.com 2>&1 || ai_timeout 5 dig baidu.com 2>&1 || ai_timeout 5 host baidu.com 2>&1 || true)
    ai_print_step $((step++)) "DNS 解析测试 (baidu.com):"
    echo "${dns_result}" | head -10 | sed 's/^/      /'

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"

    # 判断问题
    if echo "${ping_result}" | grep -q "100% packet loss"; then
        ai_print_finding error "外网完全不通"
        ai_print_finding info "可能原因: 网卡 down / 路由缺失 / 防火墙拦截"

        # 检查默认路由
        if ! ip route 2>/dev/null | grep -q "default"; then
            ai_print_finding warn "无默认路由，网络无法对外通信"
            ai_run_fix "通过 DHCP 获取网络配置" "sudo timeout 10 dhclient"
        fi
    elif echo "${dns_result}" | grep -qi "server can't find\|connection timed out\|no servers"; then
        ai_print_finding error "DNS 解析失败"
        ai_run_fix "设置公共 DNS" "sudo sh -c 'echo \"nameserver 8.8.8.8\" > /etc/resolv.conf && echo \"nameserver 114.114.114.114\" >> /etc/resolv.conf'"
        ai_run_verify "测试 DNS 解析" "timeout 5 nslookup baidu.com"
    else
        ai_print_finding ok "网络基本正常"
        ai_print_finding info "如果特定服务不通，请检查端口/防火墙"
    fi

    ai_run_verify "测试网络连通" "ping -c 3 baidu.com"
}

# ------------------------------------------------------------
# 场景7：Docker 容器问题
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_docker_issue() {
    local input="$1"
    local step=1
    local container_cmd=""

    # 检测容器运行时（docker 优先，podman 兼容）
    if check_command docker; then
        container_cmd="docker"
    elif check_command podman; then
        container_cmd="podman"
        ai_print_step $((step++)) "${COLOR_BLUE}检测到 Podman（Docker 兼容模式）${COLOR_RESET}"
    else
        ai_print_step $((step++)) "${COLOR_RED}Docker/Podman 均未安装${COLOR_RESET}"
        ai_run_fix "安装 Docker" "curl -fsSL https://get.docker.com | sh"
        return
    fi

    # 步骤1：容器服务状态（Podman 无 system 服务，跳过）
    local docker_status="active"
    if [[ "${container_cmd}" == "docker" ]]; then
        docker_status=$(ai_get_svc_status docker)
    fi
    ai_print_step $((step++)) "${container_cmd} 服务状态: ${docker_status}"

    # 步骤2：所有容器状态
    local containers
    containers=$(${container_cmd} ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)
    ai_print_step $((step++)) "所有容器:"
    echo "${containers}" | sed 's/^/      /'

    # 步骤3：异常容器
    local exited
    exited=$(${container_cmd} ps -a --filter "status=exited" --filter "status=dead" --filter "status=restarting" --format "{{.Names}} ({{.Status}})" 2>/dev/null || true)
    if [[ -n "${exited}" ]]; then
        ai_print_step $((step++)) "${COLOR_YELLOW}异常容器:${COLOR_RESET}"
        echo "${exited}" | sed 's/^/      /'

        # 获取第一个异常容器的日志
        local first_exited
        first_exited=$(echo "${exited}" | head -1 | awk '{print $1}')
        if [[ -n "${first_exited}" ]]; then
            local logs
            logs=$(${container_cmd} logs --tail 15 "${first_exited}" 2>&1 || true)
            ai_print_step $((step++)) "容器 ${first_exited} 最近日志:"
            echo "${logs}" | sed 's/^/      /'
            AI_CTX_TARGET="${first_exited}"
        fi
    fi

    # 步骤4：容器磁盘占用
    local disk_usage
    disk_usage=$(${container_cmd} system df 2>/dev/null || true)
    if [[ -n "${disk_usage}" ]]; then
        ai_print_step $((step++)) "${container_cmd} 磁盘占用:"
        echo "${disk_usage}" | sed 's/^/      /'
    fi

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"

    if [[ "${docker_status}" != "active" ]]; then
        ai_print_finding error "${container_cmd} 服务未运行"
        ai_run_fix "启动 ${container_cmd}" "sudo systemctl start ${container_cmd}"
        ai_run_verify "检查 ${container_cmd} 状态" "systemctl status ${container_cmd}"
    elif [[ -n "${exited}" ]]; then
        ai_print_finding warn "存在异常容器"
        if [[ -n "${first_exited}" ]]; then
            ai_run_fix "重启容器 ${first_exited}" "${container_cmd} restart ${first_exited}"
            ai_run_verify "检查容器状态" "${container_cmd} ps -a --filter name=${first_exited}"
        fi
        ai_run_fix "清理已退出的容器" "${container_cmd} container prune -f"
    else
        ai_print_finding ok "所有容器运行正常"
    fi
}

# ------------------------------------------------------------
# 场景8：MySQL 连接问题
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_mysql_issue() {
    local input="$1"
    local step=1
    local svc_name="mysql"
    local db_client="mysql"
    local db_admin="mysqladmin"

    # 自动判断服务名 + 客户端命令（mysql → mariadb 多回退策略）
    if check_command mariadb; then
        db_client="mariadb"
        db_admin="mariadb-admin"
        svc_name="mariadb"
    elif check_command mysql; then
        db_client="mysql"
        db_admin="mysqladmin"
    fi
    # 服务名修正（mysqld vs mysql）
    if check_command systemctl && systemctl list-unit-files 2>/dev/null | grep -q "mysqld"; then
        svc_name="mysqld"
    fi
    AI_CTX_TARGET="${svc_name}"

    # 步骤1：服务状态（systemctl → service → pgrep 多回退）
    local svc_status
    svc_status=$(ai_get_svc_status "${svc_name}")
    ai_print_step $((step++)) "${svc_name} 服务状态: ${svc_status}"

    # 步骤2：端口监听
    local port_listen
    port_listen=$(ss -tlnp 2>/dev/null | grep ':3306' || true)
    ai_print_step $((step++)) "端口 3306 监听状态:"
    if [[ -n "${port_listen}" ]]; then
        echo "${port_listen}" | sed 's/^/      /'
    else
        echo "      ${COLOR_RED}3306 端口未监听${COLOR_RESET}"
    fi

    # 步骤3：MySQL 进程
    local mysql_proc
    mysql_proc=$(pgrep -a mysqld 2>/dev/null | head -3 || true)
    ai_print_step $((step++)) "MySQL 进程:"
    if [[ -n "${mysql_proc}" ]]; then
        echo "${mysql_proc}" | sed 's/^/      /'
    else
        echo "      ${COLOR_RED}未找到 mysqld 进程${COLOR_RESET}"
    fi

    # 步骤4：最近日志
    local logs
    logs=$(journalctl -u "${svc_name}" --no-pager -n 15 2>/dev/null || tail -15 /var/log/mysql/error.log 2>/dev/null || true)
    if [[ -n "${logs}" ]]; then
        ai_print_step $((step++)) "最近日志:"
        echo "${logs}" | tail -10 | sed 's/^/      /'
    fi

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"

    if [[ "${svc_status}" != "active" ]]; then
        ai_print_finding error "${svc_name} 服务未运行"
        ai_run_fix "启动 ${svc_name}" "sudo systemctl start ${svc_name}"
        ai_run_verify "检查服务状态" "systemctl status ${svc_name}"
    elif [[ -z "${port_listen}" ]]; then
        ai_print_finding error "MySQL 运行但 3306 端口未监听"
        ai_print_finding info "可能原因: bind-address 限制 / 配置错误"
        ai_run_fix "重启 ${svc_name}" "sudo systemctl restart ${svc_name}"
    else
        ai_print_finding ok "MySQL 服务运行正常，端口 3306 已监听"
        # 数据库连接测试（mysql/mysqladmin → mariadb/mariadb-admin 自动回退）
        ai_run_fix "测试数据库连接" "timeout 5 ${db_admin} ping 2>/dev/null || timeout 5 ${db_client} -u root -e 'SELECT 1' 2>&1"
    fi
}

# ------------------------------------------------------------
# 场景9：端口不通/防火墙拦截
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_port_blocked() {
    local input="$1"
    local port
    port=$(ai_extract_port "${input}")
    AI_CTX_TARGET="${port:-unknown}"

    local step=1

    if [[ -z "${port}" ]]; then
        ai_print_step 1 "未检测到端口号，请指定，如: '8080端口不通'"
        return
    fi

    # 步骤1：检查端口是否监听
    local listen
    listen=$(ss -tlnp 2>/dev/null | grep ":${port} " || true)
    ai_print_step $((step++)) "端口 ${port} 监听状态:"
    if [[ -n "${listen}" ]]; then
        echo "${listen}" | sed 's/^/      /'
    else
        echo "      ${COLOR_RED}端口 ${port} 未监听${COLOR_RESET}"
    fi

    # 步骤2：防火墙规则
    local fw_rules=""
    if check_command ufw; then
        fw_rules=$(ufw status 2>/dev/null || true)
        ai_print_step $((step++)) "UFW 防火墙状态:"
    elif check_command firewall-cmd; then
        fw_rules=$(firewall-cmd --list-all 2>/dev/null || true)
        ai_print_step $((step++)) "Firewalld 状态:"
    elif check_command iptables; then
        fw_rules=$(iptables -L -n 2>/dev/null | head -20 || true)
        ai_print_step $((step++)) "iptables 规则:"
    else
        ai_print_step $((step++)) "未检测到防火墙工具"
    fi
    [[ -n "${fw_rules}" ]] && echo "${fw_rules}" | sed 's/^/      /'

    # 步骤3：SELinux 状态
    if check_command getenforce; then
        local selinux
        selinux=$(getenforce 2>/dev/null || true)
        ai_print_step $((step++)) "SELinux 状态: ${selinux}"
    fi

    echo ""
    echo "  ${COLOR_BOLD}--- 分析结论 ---${COLOR_RESET}"

    if [[ -z "${listen}" ]]; then
        ai_print_finding error "端口 ${port} 没有服务监听"
        ai_print_finding info "请先启动监听该端口的服务"
    else
        ai_print_finding ok "端口 ${port} 有服务监听"

        # 检查防火墙是否放行
        if check_command ufw; then
            if ! ufw status 2>/dev/null | grep -q "${port}"; then
                ai_print_finding warn "UFW 防火墙可能未放行端口 ${port}"
                ai_run_fix "UFW 放行端口 ${port}" "sudo ufw allow ${port}/tcp"
            fi
        elif check_command firewall-cmd; then
            if ! firewall-cmd --list-ports 2>/dev/null | grep -qw "${port}"; then
                ai_print_finding warn "Firewalld 可能未放行端口 ${port}"
                ai_run_fix "Firewalld 放行端口 ${port}" "sudo firewall-cmd --permanent --add-port=${port}/tcp && sudo firewall-cmd --reload"
            fi
        fi
    fi

    ai_run_verify "测试端口连通" "ss -tlnp | grep ':${port} '"
}

# ------------------------------------------------------------
# 未知意图处理
# 参数：$1 用户输入
# ------------------------------------------------------------
ai_handle_unknown() {
    local input="$1"
    echo "  ${COLOR_YELLOW}未能识别具体问题类型${COLOR_RESET}"
    echo ""
    echo "  ${COLOR_BOLD}支持的诊断场景:${COLOR_RESET}"
    ai_show_scenarios_brief
    echo ""
    echo "  ${COLOR_GRAY}请用关键词描述问题，例如:${COLOR_RESET}"
    echo "  ${COLOR_GRAY}  'nginx 502' / '磁盘满了' / 'cpu 100%' / 'docker 容器起不来'${COLOR_RESET}"
}

# ============================================================
# 辅助展示函数
# ============================================================

# ------------------------------------------------------------
# 显示支持的诊断场景（完整）
# ------------------------------------------------------------
ai_show_scenarios() {
    clear
    echo "${COLOR_BOLD}${COLOR_BLUE}"
    echo "======================================"
    echo "  ZETOPS AI 支持的诊断场景"
    echo "======================================"
    echo "${COLOR_RESET}"
    ai_show_scenarios_brief
    echo ""
    press_enter
}

# ------------------------------------------------------------
# 显示支持的诊断场景（简要列表）
# ------------------------------------------------------------
ai_show_scenarios_brief() {
    echo "  ${COLOR_BOLD}1. Web 502/503/500${COLOR_RESET}  - Nginx/Apache 网关错误诊断"
    echo "  ${COLOR_BOLD}2. 服务宕机${COLOR_RESET}        - 服务停止/启动失败/崩溃"
    echo "  ${COLOR_BOLD}3. 磁盘满${COLOR_RESET}          - 空间不足/inode耗尽"
    echo "  ${COLOR_BOLD}4. CPU 高负载${COLOR_RESET}      - CPU 飙高/卡顿/僵尸进程"
    echo "  ${COLOR_BOLD}5. 内存 OOM${COLOR_RESET}        - 内存不足/OOM Killer/内存泄漏"
    echo "  ${COLOR_BOLD}6. 网络不通${COLOR_RESET}        - 连接超时/DNS故障/路由问题"
    echo "  ${COLOR_BOLD}7. Docker 容器${COLOR_RESET}     - 容器退出/启动失败/日志分析"
    echo "  ${COLOR_BOLD}8. MySQL 连接${COLOR_RESET}      - 连接拒绝/服务异常/端口不通"
    echo "  ${COLOR_BOLD}9. 端口不通${COLOR_RESET}        - 端口未监听/防火墙拦截"
}

# ------------------------------------------------------------
# 显示帮助信息
# ------------------------------------------------------------
ai_show_help() {
    echo ""
    echo "${COLOR_BOLD}  ZETOPS AI 使用帮助${COLOR_RESET}"
    echo "  ${COLOR_GRAY}----------------------------------------${COLOR_RESET}"
    echo "  直接用自然语言描述问题，例如:"
    echo ""
    echo "  ${COLOR_GREEN}AI>${COLOR_RESET} nginx 502 了"
    echo "  ${COLOR_GREEN}AI>${COLOR_RESET} 磁盘满了写不进去"
    echo "  ${COLOR_GREEN}AI>${COLOR_RESET} mysql 连不上"
    echo "  ${COLOR_GREEN}AI>${COLOR_RESET} docker 容器一直重启"
    echo "  ${COLOR_GREEN}AI>${COLOR_RESET} cpu 100% 了"
    echo "  ${COLOR_GREEN}AI>${COLOR_RESET} 8080 端口不通"
    echo ""
    echo "  ${COLOR_BOLD}命令:${COLOR_RESET}"
    echo "    help    - 显示帮助"
    echo "    history - 显示对话历史"
    echo "    clear   - 清屏"
    echo "    exit    - 退出 AI 模式"
    echo ""
}

# ------------------------------------------------------------
# 显示对话历史
# ------------------------------------------------------------
ai_show_history() {
    echo ""
    echo "${COLOR_BOLD}  对话历史 (最近 20 条):${COLOR_RESET}"
    echo "  ${COLOR_GRAY}----------------------------------------${COLOR_RESET}"
    local total=${#AI_CTX_HISTORY[@]}
    local start=0
    if (( total > 20 )); then
        start=$((total - 20))
    fi
    local i
    for ((i = start; i < total; i++)); do
        echo "  ${AI_CTX_HISTORY[$i]}"
    done
    if (( total == 0 )); then
        echo "  ${COLOR_GRAY}(暂无历史记录)${COLOR_RESET}"
    fi
    echo ""
}

# ============================================================
# 独立执行保护
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 独立运行时加载核心库
    ZETOPS_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/logger.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/utils.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/config.sh"
    log_init
    load_config
    load_api_config
    ai_chat_loop
fi
