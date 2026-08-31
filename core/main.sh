#!/bin/bash
# ============================================================
# 文件：core/main.sh
# 功能：主程序入口（主菜单调度核心）
# 作者：zc 团队
# 版本：1.5.3
# 日期：2026-08-05
# 说明：加载核心库 → 环境检查 → 锁检查 → 扫描模块/插件 → 双协议调度
#   （默认 CLI：--help/--version/--list/--run/--backup；--tui 进入交互界面）
# ============================================================
set -euo pipefail

# ------------------------------------------------------------
# 解析脚本真实路径（兼容软链接执行：
#   /usr/local/bin/zetops -> /opt/zc-easy-term-ops/core/main.sh）
# 参数：无
# 输出：脚本真实路径
# ------------------------------------------------------------
_resolve_script_path() {
    local src="${BASH_SOURCE[0]}"
    local dir=""
    while [[ -L "${src}" ]]; do
        dir="$(cd -P "$(dirname "${src}")" && pwd)"
        src="$(readlink "${src}")"
        [[ "${src}" != /* ]] && src="${dir}/${src}"
    done
    echo "${src}"
}

# 项目根目录（本文件位于 <root>/core/main.sh）
ZETOPS_ROOT="$(cd -P "$(dirname "$(_resolve_script_path)")/.." && pwd)"
LOCK_FILE="/var/run/zetops.lock"
CURRENT_MODULE="core"

# ------------------------------------------------------------
# 安全退出清理（Ctrl+C / 正常退出）
# 参数：无
# 返回：无
# ------------------------------------------------------------
cleanup() {
    echo ""
    log_warning "正在退出 ZETOPS ..."
    stop_spinner 2>/dev/null || true
    # 关闭 TUI 鼠标捕获（若已开启；X10 + SGR 双模式）
    printf '\e[?1000l\e[?1002l\e[?1006l' > /dev/tty 2>/dev/null || true
    # 仅当本进程持有锁时删除锁文件（异常断开时文件残留由 check_lock 的过期检测兜底）
    if [[ "${_LOCK_OWNED:-0}" == "1" ]]; then
        rm -f "${LOCK_FILE}" 2>/dev/null || true
        _LOCK_OWNED=0
    fi
    exit 0
}

# ------------------------------------------------------------
# 依赖检查（必备命令）
# 参数：无
# 返回：0=通过 1=缺失
# ------------------------------------------------------------
check_deps() {
    local deps=(awk sed grep date basename dirname readlink)
    local missing=()
    local d
    for d in "${deps[@]}"; do
        check_command "${d}" || missing+=("${d}")
    done
    # 网络工具至少需要 curl 或 wget 之一
    if ! check_command curl && ! check_command wget; then
        missing+=("curl|wget")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖命令: ${missing[*]}"
        log_info "请先运行 install.sh 自动安装依赖，或手动安装后重试"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# 单实例锁检查（防止并发运行）
# 说明：PID 锁 + 过期检测。锁文件记录启动进程 PID；若 PID 已不存在
#      （例如 SSH 断开导致进程被终止、但锁文件未来得及清理），
#       视为过期锁自动清理并继续，避免"断开后锁文件残留卡死下次启动"。
# 返回：0=获得锁 1=已被其他存活实例占用
# ------------------------------------------------------------
check_lock() {
    local dir
    dir=$(dirname "${LOCK_FILE}" 2>/dev/null || echo /var/run)
    mkdir -p "${dir}" 2>/dev/null || true
    if [[ -f "${LOCK_FILE}" ]]; then
        local old_pid=""
        old_pid=$(cat "${LOCK_FILE}" 2>/dev/null | tr -dc '0-9')
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            log_error "ZETOPS 已在运行（PID ${old_pid}，锁文件 ${LOCK_FILE}），请勿重复启动"
            return 1
        fi
        # 记录 PID 已不在运行（进程退出/被杀）→ 过期锁，清理后继续
        log_warning "检测到过期锁文件（PID ${old_pid:-未知} 已退出），自动清理后继续"
        rm -f "${LOCK_FILE}" 2>/dev/null || true
    fi
    if ! printf '%s\n' "$$" > "${LOCK_FILE}" 2>/dev/null; then
        log_error "无法写入锁文件 ${LOCK_FILE}"
        return 1
    fi
    _LOCK_OWNED=1
    return 0
}

# ------------------------------------------------------------
# 扫描并注册全部模块（modules/*.sh）
# 参数：无
# 返回：无
# ------------------------------------------------------------
load_modules() {
    local f
    for f in "${ZETOPS_ROOT}"/modules/*.sh; do
        [[ -f "${f}" ]] || continue
        # shellcheck source=/dev/null
        source "${f}"
        register_module "${f}"
    done
    log_success "已加载 ${#MODULE_NAMES[@]} 个功能模块"
}

# ------------------------------------------------------------
# 扫描并注册全部插件（plugins/*.sh）
# 参数：无
# 返回：无
# ------------------------------------------------------------
load_plugins() {
    local f
    for f in "${ZETOPS_ROOT}"/plugins/*.sh; do
        [[ -f "${f}" ]] || continue
        # shellcheck source=/dev/null
        source "${f}"
        register_plugin "${f}"
    done
    if [[ ${#PLUGIN_NAMES[@]} -gt 0 ]]; then
        log_success "已加载 ${#PLUGIN_NAMES[@]} 个插件"
    fi
}

# ------------------------------------------------------------
# 用法帮助（默认 CLI 协议）
# 参数：无
# 返回：无
# ------------------------------------------------------------
usage() {
    echo "ZETOPS - 交互式 Linux 运维工具箱  v${ZETOPS_VERSION}"
    echo ""
    echo "用法:"
    echo "  zetops [选项] [模块] [选项号]"
    echo ""
    echo "选项:"
    echo "  -h, --help             显示本帮助"
    echo "  -v, --version          显示版本号"
    echo "  -l, --list             列出全部模块与插件"
    echo "  -t, --tui              进入交互式 TUI（蓝色主题，支持鼠标点击）"
    echo "  -r, --run 模块 选项号   非交互执行模块菜单项（适合脚本/定时任务）"
    echo "  -b, --backup 路径       备份文件，生成 .bak.<时间戳> 副本"
    echo ""
    echo "示例:"
    echo "  zetops                         默认 CLI：显示本帮助与模块列表"
    echo "  zetops --tui                   进入 TUI 交互界面"
    echo "  zetops --run 13 1              非交互执行模块13的第1项"
    echo "  zetops --run ai_assistant 1    按模块短名执行"
    echo "  zetops --backup /etc/nginx/nginx.conf"
}

# ------------------------------------------------------------
# 列出全部模块与插件（--list / 默认 CLI）
# 参数：无
# 返回：无
# ------------------------------------------------------------
list_all() {
    local i
    echo ""
    echo "已加载 ${#MODULE_NAMES[@]} 个功能模块:"
    echo "  ${COLOR_GRAY}序号  短名              名称${COLOR_RESET}"
    for i in "${!MODULE_NAMES[@]}"; do
        printf "  %-4s %-18s %s\n" "$((i + 1))" "${MODULE_SHORTS[$i]}" "${MODULE_NAMES[$i]}"
    done
    if [[ ${#PLUGIN_NAMES[@]} -gt 0 ]]; then
        echo ""
        echo "已加载 ${#PLUGIN_NAMES[@]} 个插件:"
        for i in "${!PLUGIN_NAMES[@]}"; do
            printf "  [插件] %s\n" "${PLUGIN_NAMES[$i]}"
        done
    fi
    echo ""
}

# ------------------------------------------------------------
# 按序号或短名解析模块下标
# 参数：$1 序号（1 起）或短名
# 输出：模块下标（无效时无输出）
# 返回：0=找到 1=未找到
# ------------------------------------------------------------
resolve_module() {
    local ref="$1" i
    if [[ "${ref}" =~ ^[0-9]+$ ]]; then
        i=$(( ref - 1 ))
        if (( i >= 0 && i < ${#MODULE_FILES[@]} )); then
            echo "${i}"
            return 0
        fi
        return 1
    fi
    for i in "${!MODULE_SHORTS[@]}"; do
        if [[ "${MODULE_SHORTS[$i]}" == "${ref}" ]]; then
            echo "${i}"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------
# 非交互执行模块菜单项（--run 模块 选项号）
# 参数：$1 模块下标  $2 选项号  $@ 其余参数透传
# 返回：module_execute 的返回码
# ------------------------------------------------------------
run_module_noninteractive() {
    local idx="$1"
    local opt="$2"
    shift 2
    local file="${MODULE_FILES[$idx]}"
    local short="${MODULE_SHORTS[$idx]}"
    local rc=0
    export ZETOPS_NONINTERACTIVE=1
    exec 0</dev/null
    # shellcheck source=/dev/null
    source "${file}"
    CURRENT_MODULE="${short}"
    module_execute "${opt}" "$@"
    rc=$?
    CURRENT_MODULE="menu"
    return "${rc}"
}

# ------------------------------------------------------------
# 主菜单循环
# 参数：无
# 返回：无
# ------------------------------------------------------------
main_loop() {
    local choice
    while true; do
        show_main_menu
        choice=$(get_user_choice $(( ${#MODULE_NAMES[@]} + ${#PLUGIN_NAMES[@]} )))
        [[ "${choice}" == "q" ]] && break
        if (( choice >= 1 && choice <= ${#MODULE_NAMES[@]} )); then
            show_sub_menu $((choice - 1))
        else
            local pidx=$(( choice - ${#MODULE_NAMES[@]} - 1 ))
            if (( pidx >= 0 && pidx < ${#PLUGIN_NAMES[@]} )); then
                show_plugin_menu "${pidx}"
            fi
        fi
    done
    log_success "感谢使用 ZETOPS，再见！"
}

# ------------------------------------------------------------
# 主入口（默认 CLI 协议，--tui 切换交互界面）
# 参数：见 usage()
# 返回：无
# ------------------------------------------------------------
main() {
    # Ctrl+C 安全退出
    trap 'cleanup' INT TERM

    # 加载核心库
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/logger.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/utils.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/config.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/detect_env.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/menu.sh"

    log_init
    load_config
    load_api_config
    check_deps || exit 1

    # ---- 参数解析（CLI 协议） ----
    local mode="cli"
    local run_ref="" run_opt=""
    local arg="${1:-}"
    case "${arg}" in
        -h|--help) usage; exit 0 ;;
        -v|--version) echo "ZETOPS v${ZETOPS_VERSION}"; exit 0 ;;
        -l|--list) mode="list" ;;
        -t|--tui) mode="tui" ;;
        -r|--run)
            mode="run"
            run_ref="${2:-}"
            run_opt="${3:-}"
            ;;
        -b|--backup)
            if [[ -z "${2:-}" ]]; then
                log_error "--backup 缺少文件路径"
                usage
                exit 1
            fi
            check_lock || exit 1
            backup_file "${2}"
            exit $?
            ;;
        "")
            mode="cli"
            ;;
        *)
            log_error "未知参数: ${arg}"
            usage
            exit 1
            ;;
    esac

    check_lock || exit 1
    load_modules
    load_plugins

    case "${mode}" in
        tui)
            main_loop
            cleanup
            ;;
        list)
            list_all
            exit 0
            ;;
        run)
            if [[ -z "${run_ref}" || -z "${run_opt}" ]]; then
                log_error "--run 需要模块（序号或短名）与选项号"
                usage
                exit 1
            fi
            local idx
            idx=$(resolve_module "${run_ref}") || {
                log_error "未找到模块: ${run_ref}（可用 zetops --list 查看）"
                exit 1
            }
            run_module_noninteractive "${idx}" "${run_opt}"
            exit $?
            ;;
        cli)
            usage
            list_all
            exit 0
            ;;
    esac
}

# 直接执行入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
