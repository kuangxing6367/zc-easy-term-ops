#!/bin/bash
# ============================================================
# 文件：core/main.sh
# 功能：主程序入口（主菜单调度核心）
# 作者：zc 团队
# 版本：1.6.0
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
    cat <<EOF
ZETOPS - Linux 运维工具箱  v${ZETOPS_VERSION}

用法:
  zetops                              直接进入交互界面（TUI）
  zetops <模块>                       查看该模块菜单（与 TUI 同内容）
  zetops <模块> <动作> [下级...]       非交互执行，动作与 TUI 菜单逐项对应

选项:
  -h, --help              显示本帮助
  -v, --version           显示版本号
  -l, --list              列出全部模块
  -l, --list <模块>       列出该模块的全部动作（含编号）
  -t, --tui               进入交互界面（等同裸执行）
  -r, --run <模块> <编号>  兼容旧语法：按模块编号 + 菜单编号执行
  -b, --backup <路径>      备份文件，生成 .bak.<时间戳> 副本
  -y, --yes               非交互模式下放行危险操作（默认拒绝）

模块与动作既可用编号，也可用菜单文字关键字（唯一命中才执行）:
  zetops firewall                     查看防火墙模块菜单
  zetops firewall 1                   执行菜单第 1 项
  zetops firewall iptables            按关键字执行「iptables 规则管理」
  zetops firewall iptables 1 1        逐级下钻：等同在 TUI 里依次按 1 → 1
  zetops --list firewall              列出防火墙模块全部动作

安全说明:
  非交互执行时，所有「危险操作二次确认」默认一律拒绝，
  必须显式追加 --yes 才会放行；不会因为缺少交互而静默执行危险操作。
EOF
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
# 读取指定模块的菜单项（CLI 命令树的唯一来源）
# 说明：直接在 TUI 里渲染的那份 module_menu 输出上做解析，因此
#      CLI 的动作清单与 TUI 菜单天然保持一致，不存在两套定义。
# 参数：$1 模块下标
# 输出：每行 "序号<TAB>名称"（已剔除 0=返回）
# 返回：0=解析出至少一项 1=无
# ------------------------------------------------------------
module_menu_items() {
    local idx="$1"
    local raw=""
    # 子 shell 内 source，避免覆盖其他模块已注册的同名函数
    raw="$(
        # shellcheck source=/dev/null
        source "${MODULE_FILES[$idx]}" >/dev/null 2>&1
        module_menu 2>/dev/null
    )" || true
    [[ -z "${raw}" ]] && return 1
    local out
    out="$(printf '%s\n' "${raw}" \
        | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)\.[[:space:]]\+\(.*[^[:space:]]\)[[:space:]]*$/\1\t\2/p' \
        | awk -F'\t' '$1 != "0"')"
    [[ -z "${out}" ]] && return 1
    printf '%s\n' "${out}"
    return 0
}

# ------------------------------------------------------------
# 解析动作引用（与 TUI 菜单编号同源）
# 参数：$1 模块下标  $2 动作引用（编号 / 菜单文字关键字）
# 输出：动作编号
# 返回：0=唯一命中 1=未命中或存在歧义
# ------------------------------------------------------------
resolve_action() {
    local idx="$1" ref="$2"
    local items
    items="$(module_menu_items "${idx}")" || return 1

    local num name
    # 纯数字：与 TUI 菜单编号完全一致
    if [[ "${ref}" =~ ^[0-9]+$ ]]; then
        while IFS=$'\t' read -r num name; do
            if [[ "${num}" == "${ref}" ]]; then
                echo "${num}"
                return 0
            fi
        done <<< "${items}"
        return 1
    fi

    # 文字：大小写不敏感的子串匹配，必须唯一命中，避免选错功能
    local -a hits=()
    while IFS=$'\t' read -r num name; do
        if [[ "${name,,}" == *"${ref,,}"* ]]; then
            hits+=("${num}")
        fi
    done <<< "${items}"

    if (( ${#hits[@]} == 1 )); then
        echo "${hits[0]}"
        return 0
    fi
    if (( ${#hits[@]} > 1 )); then
        log_error "动作 '${ref}' 匹配到多个菜单项（${hits[*]}），请改用编号或更具体的关键字"
        return 1
    fi
    return 1
}

# ------------------------------------------------------------
# 打印指定模块的动作清单（zetops --list <模块> / 动作未命中时提示）
# 参数：$1 模块下标
# 返回：无
# ------------------------------------------------------------
list_module_actions() {
    local idx="$1"
    echo ""
    echo "${MODULE_NAMES[$idx]}  ${COLOR_GRAY}(${MODULE_SHORTS[$idx]})${COLOR_RESET}"
    echo "${COLOR_GRAY}  编号  动作${COLOR_RESET}"
    local items num name
    if ! items="$(module_menu_items "${idx}")"; then
        echo "  (该模块没有可解析的菜单项)"
        echo ""
        return 0
    fi
    while IFS=$'\t' read -r num name; do
        printf "  %-4s  %s\n" "${num}" "${name}"
    done <<< "${items}"
    echo ""
    echo "${COLOR_GRAY}执行: zetops ${MODULE_SHORTS[$idx]} <编号> [下级编号...]${COLOR_RESET}"
    echo ""
}

# ------------------------------------------------------------
# 非交互执行模块菜单项（CLI 子命令）
# 说明：把 CLI 传入的下级编号按顺序写入 stdin 应答队列，
#      模块内原有的 read 选择会依次消费它们——等同于在 TUI 里
#      依次按键，但不再有人工交互，也不会因误触执行别的功能。
# 参数：$1 模块下标  $2 动作编号  $@ 下级应答序列
# 返回：module_execute 的返回码
# ------------------------------------------------------------
run_module_noninteractive() {
    local idx="$1"
    local opt="$2"
    shift 2
    local -a answers=("$@")
    local file="${MODULE_FILES[$idx]}"
    local short="${MODULE_SHORTS[$idx]}"
    local rc=0
    export ZETOPS_NONINTERACTIVE=1
    if (( ${#answers[@]} > 0 )); then
        exec 0< <(printf '%s\n' "${answers[@]}")
    else
        exec 0</dev/null
    fi
    # shellcheck source=/dev/null
    source "${file}"
    CURRENT_MODULE="${short}"
    module_execute "${opt}" || rc=$?
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
    _TUI_PAGE=0
    while true; do
        show_main_menu
        choice=$(get_user_choice $(( ${#MODULE_NAMES[@]} + ${#PLUGIN_NAMES[@]} )))
        [[ "${choice}" == "q" ]] && break
        # 主页分页：滚轮/PageUp/PageDown 翻页（重新渲染当前页）
        if [[ "${choice}" == "PGDN" ]]; then
            local tot=$(( ${#MODULE_NAMES[@]} + ${#PLUGIN_NAMES[@]} ))
            local psz="${_TUI_PAGE_SIZE:-12}"
            local pg=$(( (tot + psz - 1) / psz ))
            (( pg < 1 )) && pg=1
            (( _TUI_PAGE < pg - 1 )) && _TUI_PAGE=$(( _TUI_PAGE + 1 ))
            continue
        fi
        if [[ "${choice}" == "PGUP" ]]; then
            (( _TUI_PAGE > 0 )) && _TUI_PAGE=$(( _TUI_PAGE - 1 ))
            continue
        fi
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
    # 内置纯 Bash TUI 文本编辑器（依赖 utils.sh 的宽字符函数；不注册为独立模块）
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/editor.sh"
    # shellcheck source=/dev/null
    source "${ZETOPS_ROOT}/core/menu.sh"

    log_init
    load_config
    load_api_config
    check_deps || exit 1

    # ---- 剥离全局开关：-y / --yes（可出现在任意位置） ----
    local assume_yes=0
    local -a argv=()
    local a
    for a in "$@"; do
        case "${a}" in
            -y|--yes) assume_yes=1 ;;
            *) argv+=("${a}") ;;
        esac
    done
    export ZETOPS_ASSUME_YES="${assume_yes}"
    if (( ${#argv[@]} > 0 )); then
        set -- "${argv[@]}"
    else
        set --
    fi

    # ---- 参数解析（CLI 协议） ----
    local mode="cli"
    local run_ref="" run_opt=""
    local sub_ref=""
    local -a sub_rest=()
    local idx=""
    local arg="${1:-}"
    case "${arg}" in
        -h|--help) usage; exit 0 ;;
        -v|--version) echo "ZETOPS v${ZETOPS_VERSION}"; exit 0 ;;
        -t|--tui) mode="tui" ;;
        -l|--list)
            if [[ -n "${2:-}" ]]; then
                mode="list_module"
                sub_ref="${2}"
            else
                mode="list"
            fi
            ;;
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
            # 裸执行直接进入交互界面（交互式工具箱的默认行为）
            mode="tui"
            ;;
        -*)
            log_error "未知参数: ${arg}"
            usage
            exit 1
            ;;
        *)
            # 子命令形式：zetops <模块> [动作] [下级...]
            mode="subcmd"
            sub_ref="$1"
            shift
            if (( $# > 0 )); then
                sub_rest=("$@")
            else
                sub_rest=()
            fi
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
        list_module)
            idx=$(resolve_module "${sub_ref}") || {
                log_error "未找到模块: ${sub_ref}"
                list_all
                exit 1
            }
            list_module_actions "${idx}"
            exit 0
            ;;
        subcmd)
            idx=$(resolve_module "${sub_ref}") || {
                log_error "未找到模块: ${sub_ref}"
                list_all
                exit 1
            }
            # 只给模块名：展示与 TUI 完全一致的模块菜单，不执行任何动作
            if (( ${#sub_rest[@]} == 0 )); then
                (
                    # shellcheck source=/dev/null
                    source "${MODULE_FILES[$idx]}"
                    module_description
                    echo ""
                    module_menu
                )
                exit 0
            fi
            local act_ref="${sub_rest[0]}"
            local act_num=""
            act_num="$(resolve_action "${idx}" "${act_ref}")" || {
                log_error "模块 ${MODULE_SHORTS[$idx]} 中没有动作: ${act_ref}"
                list_module_actions "${idx}"
                exit 1
            }
            run_module_noninteractive "${idx}" "${act_num}" "${sub_rest[@]:1}"
            exit $?
            ;;
        run)
            if [[ -z "${run_ref}" || -z "${run_opt}" ]]; then
                log_error "--run 需要模块（序号或短名）与选项号"
                usage
                exit 1
            fi
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
