#!/bin/bash
# ============================================================
# 文件：core/menu.sh
# 功能：菜单渲染引擎（生成主/子菜单，处理用户输入）
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：主菜单列出全部模块与插件，子菜单调用模块接口函数
# ============================================================
set -euo pipefail

# ---- 模块/插件注册表（由 main.sh 扫描后填充） ----
MODULE_FILES=()     # 模块文件路径
MODULE_SHORTS=()    # 模块短名
MODULE_NAMES=()     # 模块显示名
PLUGIN_FILES=()     # 插件文件路径
PLUGIN_NAMES=()     # 插件显示名

# ---- TUI 鼠标支持：屏幕行号 → 该行菜单选项号映射 ----
# （_tui_capture 渲染菜单时自动构建；值为空格分隔的选项号，双列网格一行可能两个）
declare -A _TUI_OPT_ROW_OPT=()

# ------------------------------------------------------------
# 注册一个模块（由 main.sh 扫描时调用）
# 参数：$1 文件路径
# 返回：无
# ------------------------------------------------------------
register_module() {
    local file="$1"
    local short="" name=""
    # 从模块文件内提取元信息（不执行文件）
    short=$(grep -E '^module_short=' "${file}" | head -n1 | cut -d= -f2- | tr -d '"' | xargs)
    name=$(grep -E '^module_name=' "${file}" | head -n1 | cut -d= -f2- | tr -d '"' | xargs)
    [[ -z "${short}" ]] && short=$(basename "${file}" .sh)
    [[ -z "${name}" ]] && name="${short}"
    MODULE_FILES+=("${file}")
    MODULE_SHORTS+=("${short}")
    MODULE_NAMES+=("${name}")
}

# ------------------------------------------------------------
# 注册一个插件
# 参数：$1 文件路径
# 返回：无
# ------------------------------------------------------------
register_plugin() {
    local file="$1"
    local name=""
    name=$(grep -E '^plugin_name=' "${file}" | head -n1 | cut -d= -f2- | tr -d '"' | xargs)
    [[ -z "${name}" ]] && name=$(basename "${file}" .sh)
    PLUGIN_FILES+=("${file}")
    PLUGIN_NAMES+=("${name}")
}

# ------------------------------------------------------------
# 查询当前光标所在行号（ANSI DSR \e[6n）
# 参数：无
# 输出：行号（非终端环境输出 0）
# ------------------------------------------------------------
_ui_cursor_row() {
    local row="0"
    if [[ -t 1 ]] && [[ -e /dev/tty ]]; then
        printf '\e[6n' > /dev/tty
        IFS='[;' read -r -s -d 'R' -t 0.3 _ row _ < /dev/tty || row="0"
    fi
    echo "${row}"
}

# ------------------------------------------------------------
# 运行一个输出菜单行的命令：记录每行首部 "N." 选项与行号映射，再原样输出
# （主菜单双列网格一行含两个选项号，同时记录第二个）
# 参数：$@ 命令及参数
# ------------------------------------------------------------
_tui_capture() {
    local start
    start=$(_ui_cursor_row)
    local out
    out=$("$@")
    local lineno=0 line="" plain="" first="" second=""
    while IFS= read -r line; do
        # 去除 ANSI 颜色/样式转义序列后再匹配选项号
        plain=$(printf '%s' "${line}" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b[()][A-Za-z]//g' -e 's/\x1b.//g')
        if [[ "${plain}" =~ ^[[:space:]]*([0-9]+)\. ]]; then
            first="${BASH_REMATCH[1]}"
            second=""
            if [[ "${plain}" =~ ^[[:space:]]*[0-9]+\.[^0-9]+[[:space:]]+([0-9]+)\. ]]; then
                second="${BASH_REMATCH[1]}"
            fi
            if [[ -n "${second}" ]]; then
                _TUI_OPT_ROW_OPT[$((start + lineno))]="${first} ${second}"
            else
                _TUI_OPT_ROW_OPT[$((start + lineno))]="${first}"
            fi
        fi
        lineno=$((lineno + 1))
    done <<< "${out}"
    printf '%s\n' "${out}"
}

# ------------------------------------------------------------
# 按屏幕行列解析鼠标点击对应的菜单选项号
# 参数：$1 行  $2 列
# 输出：选项号（无效时无输出）
# ------------------------------------------------------------
_tui_row_to_opt() {
    local row="$1" col="$2"
    local val="${_TUI_OPT_ROW_OPT[${row}]:-}"
    [[ -z "${val}" ]] && return 1
    local -a opts=(${val})
    if (( ${#opts[@]} >= 2 )); then
        # 双列网格：左列 x<40，右列 x>=40
        if (( col < 40 )); then
            echo "${opts[0]}"
        else
            echo "${opts[1]}"
        fi
    else
        echo "${opts[0]}"
    fi
    return 0
}

# ------------------------------------------------------------
# 读取一个交互事件（TUI 鼠标模式专用）
# 输出："line:<内容>" / "mouse:<按钮>,<x>,<y>" / "none"
# 说明：鼠标模式从 /dev/tty 读取（兼容命令替换调用环境）
# ------------------------------------------------------------
_tui_read_key() {
    local src="${1:-tty}" ch=""
    if [[ "${src}" == "tty" ]]; then
        IFS= read -r -s -n 1 -t 3 ch < /dev/tty || ch=""
    else
        IFS= read -r -s -n 1 -t 3 ch || ch=""
    fi
    [[ -z "${ch}" ]] && { echo "none"; return 1; }
    if [[ "${ch}" == $'\e' ]]; then
        local seq="" b1="" b2="" b3=""
        if [[ "${src}" == "tty" ]]; then
            IFS= read -r -s -n 2 -t 1 seq < /dev/tty || seq=""
            if [[ "${seq}" == "[M" ]]; then
                IFS= read -r -s -n 1 b1 < /dev/tty || b1=""
                IFS= read -r -s -n 1 b2 < /dev/tty || b2=""
                IFS= read -r -s -n 1 b3 < /dev/tty || b3=""
                if [[ -n "${b1}" && -n "${b2}" && -n "${b3}" ]]; then
                    printf 'mouse:%d,%d,%d' \
                        "$(( $(printf '%d' "'${b1}") - 32 ))" \
                        "$(( $(printf '%d' "'${b2}") - 32 ))" \
                        "$(( $(printf '%d' "'${b3}") - 32 ))"
                    return 0
                fi
            fi
        fi
        echo "none"
        return 1
    fi
    if [[ "${ch}" == $'\n' || "${ch}" == $'\r' ]]; then
        echo "line:"
        return 0
    fi
    # 普通输入：回显首个字符，再读取行剩余部分
    printf '%s' "${ch}" >&2
    local rest=""
    if [[ "${src}" == "tty" ]]; then
        IFS= read -r rest < /dev/tty || rest=""
    else
        IFS= read -r rest || rest=""
    fi
    printf 'line:%s%s' "${ch}" "${rest}"
    return 0
}

# ------------------------------------------------------------
# 读取用户选择（1..max，0 退出，q 返回；TUI 下支持鼠标点击）
# 参数：$1 最大选项数
# 输出：用户选择数字
# ------------------------------------------------------------
get_user_choice() {
    local max="$1"
    local ans=""
    local mouse=0 src="stdin"
    # TUI 鼠标模式：真实终端 + 非 dumb + 未显式关闭
    if [[ -t 0 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ "${ZETOPS_TUI_MOUSE:-on}" == "on" ]] && [[ -e /dev/tty ]]; then
        mouse=1
        src="tty"
        printf '\e[?1000h\e[?1002h' > /dev/tty 2>/dev/null || mouse=0
    fi
    # 注意：本函数通过命令替换调用（choice=$(get_user_choice ...)），
    # 因此提示/告警必须输出到 stderr，stdout 只返回最终选择数字
    while true; do
        echo -n "  ${COLOR_BOLD}${COLOR_GREEN}请输入操作编号 (0-${max}) [q=退出${COLOR_RESET}${COLOR_GRAY}，鼠标可点击菜单${COLOR_RESET}${COLOR_BOLD}${COLOR_GREEN}]: ${COLOR_RESET}" >&2
        local ev=""
        ev=$(_tui_read_key "${src}") || true
        case "${ev}" in
            line:q|line:Q)
                (( mouse == 1 )) && printf '\e[?1000l\e[?1002l' > /dev/tty 2>/dev/null
                echo "q"
                return 0
                ;;
            line:*)
                ans="${ev#line:}"
                if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 0 && ans <= max )); then
                    (( mouse == 1 )) && printf '\e[?1000l\e[?1002l' > /dev/tty 2>/dev/null
                    echo "${ans}"
                    return 0
                fi
                echo "${COLOR_YELLOW}  ⚠ 输入无效，请输入 0-${max} 的数字${COLOR_RESET}" >&2
                ;;
            mouse:*)
                local btn x y opt=""
                IFS=',' read -r btn x y <<< "${ev#mouse:}"
                # 仅响应左键按下（btn==0；释放/滚轮/拖拽忽略）
                if (( btn == 0 )); then
                    opt=$(_tui_row_to_opt "${y}" "${x}")
                    if [[ -n "${opt}" ]] && (( opt >= 0 && opt <= max )); then
                        (( mouse == 1 )) && printf '\e[?1000l\e[?1002l' > /dev/tty 2>/dev/null
                        echo "${opt}"
                        return 0
                    fi
                fi
                ;;
            *) : ;;
        esac
    done
}

# ------------------------------------------------------------
# 绘制水平分隔线（蓝色主题）
# 参数：$1 长度（默认 60）
# ------------------------------------------------------------
_ui_hr() {
    local n="${1:-60}"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=60
    printf "${COLOR_CYAN}%${n}s${COLOR_RESET}\n" "" | tr ' ' '─'
}

# ------------------------------------------------------------
# ASCII Logo Banner
# 参数：无
# ------------------------------------------------------------
_ui_banner() {
    echo "${COLOR_BOLD}${COLOR_BLUE}"
    cat <<'EOF'
 ███████╗███████╗████████╗ ██████╗ ██████╗ ███████╗
 ╚══███╔╝██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
   ███╔╝ █████╗     ██║   ██║   ██║██████╔╝███████╗
  ███╔╝  ██╔══╝     ██║   ██║   ██║██╔══██╗╚════██║
 ███████╗███████╗   ██║   ╚██████╔╝██║  ██║███████║
 ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝
EOF
    echo "${COLOR_RESET}"
    echo "  ${COLOR_BOLD}${COLOR_CYAN}交互式 Linux 运维全能工具箱${COLOR_RESET}   ${COLOR_GRAY}v${ZETOPS_VERSION:-1.4.0} | Interactive Linux Ops Toolkit${COLOR_RESET}"
    echo ""
}

# ------------------------------------------------------------
# 系统概览（只读快速探测，全部容错）
# 参数：无
# ------------------------------------------------------------
_ui_sysinfo() {
    local os="" krn="" cores="" mem="" disk="" host="" ip=""
    os=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    [[ -z "${os}" ]] && os=$(head -1 /etc/redhat-release 2>/dev/null || true)
    [[ -z "${os}" ]] && os="Linux"
    krn=$(uname -r 2>/dev/null || true)
    cores=$(nproc 2>/dev/null || true)
    mem=$(free -h 2>/dev/null | awk '/Mem:/{print $3"/"$2}' || true)
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $5" ("$3"/"$2")"}' || true)
    host=$(hostname 2>/dev/null || true)
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -z "${ip}" ]] && ip="N/A"
    echo "  ${COLOR_BOLD}${COLOR_CYAN}OS${COLOR_RESET}: ${os:-?}   ${COLOR_BOLD}${COLOR_CYAN}Kernel${COLOR_RESET}: ${krn:-?}   ${COLOR_BOLD}${COLOR_CYAN}CPU${COLOR_RESET}: ${cores:-?}核"
    echo "  ${COLOR_BOLD}${COLOR_CYAN}内存${COLOR_RESET}: ${mem:-N/A}   ${COLOR_BOLD}${COLOR_CYAN}磁盘/${COLOR_RESET}: ${disk:-N/A}   ${COLOR_BOLD}${COLOR_CYAN}主机${COLOR_RESET}: ${host:-?} (${ip})"
    echo "  ${COLOR_BOLD}${COLOR_CYAN}时间${COLOR_RESET}: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# ------------------------------------------------------------
# 模块双列网格
# 参数：无
# ------------------------------------------------------------
_ui_module_list() {
    local n=${#MODULE_NAMES[@]}
    local half=$(( (n + 1) / 2 ))
    local i
    for ((i = 0; i < half; i++)); do
        local j=$((i + half))
        if (( j < n )); then
            printf "  ${COLOR_BOLD}%2d.${COLOR_RESET} %-20s   ${COLOR_BOLD}%2d.${COLOR_RESET} %s\n" \
                "$((i + 1))" "${MODULE_NAMES[$i]}" "$((j + 1))" "${MODULE_NAMES[$j]}"
        else
            printf "  ${COLOR_BOLD}%2d.${COLOR_RESET} %s\n" "$((i + 1))" "${MODULE_NAMES[$i]}"
        fi
    done
    if (( n == 0 )); then
        echo "  ${COLOR_YELLOW}（未加载任何模块）${COLOR_RESET}"
    fi
}

# ------------------------------------------------------------
# 插件列表
# 参数：无
# ------------------------------------------------------------
_ui_plugins() {
    local i base=$(( ${#MODULE_NAMES[@]} + 1 ))
    if [[ ${#PLUGIN_NAMES[@]} -gt 0 ]]; then
        echo ""
        echo "  ${COLOR_BOLD}── 插件 ──${COLOR_RESET}"
        for i in "${!PLUGIN_NAMES[@]}"; do
            printf "  ${COLOR_BOLD}%2d.${COLOR_RESET} ${COLOR_GRAY}[插件]${COLOR_RESET} %s\n" "$((base + i))" "${PLUGIN_NAMES[$i]}"
        done
    fi
}

# ------------------------------------------------------------
# 渲染主菜单
# 参数：无
# 返回：无
# ------------------------------------------------------------
show_main_menu() {
    clear
    _TUI_OPT_ROW_OPT=()
    _ui_banner
    _ui_sysinfo
    _ui_hr
    echo ""
    _tui_capture _ui_module_list
    _tui_capture _ui_plugins
    echo ""
    _ui_hr
    echo "  ${COLOR_BOLD}${COLOR_CYAN}q${COLOR_RESET}. 退出    ${COLOR_GRAY}输入模块编号${COLOR_RESET}${COLOR_CYAN}或鼠标点击${COLOR_RESET}${COLOR_GRAY}进入对应功能${COLOR_RESET}"
    echo ""
}

# ------------------------------------------------------------
# 渲染子菜单并循环执行模块选项
# 参数：$1 模块数组下标
# 返回：无
# ------------------------------------------------------------
show_sub_menu() {
    local idx="$1"
    local file="${MODULE_FILES[$idx]}"
    local short="${MODULE_SHORTS[$idx]}"
    local choice

    # shellcheck source=/dev/null
    source "${file}"
    CURRENT_MODULE="${short}"

    while true; do
        clear
        _TUI_OPT_ROW_OPT=()
        echo "${COLOR_BOLD}${COLOR_CYAN}"
        echo "  ┌────────────────────────────────────────────────────┐"
        echo "  │  ${module_name}  ▸  输入 0 返回主菜单（鼠标可点击）"
        echo "  └────────────────────────────────────────────────────┘"
        echo "${COLOR_RESET}"
        module_description
        _tui_capture module_menu
        choice=$(get_user_choice 99)
        [[ "${choice}" == "q" ]] && break
        case "${choice}" in
            0) break ;;
            # || true：置于忽略 errexit 上下文，防止模块内子功能失败时
            # set -e 直接终止整个工具箱（模块自身可捕获错误继续执行）
            *) module_execute "${choice}" || true ;;
        esac
    done
    CURRENT_MODULE="menu"
}

# ------------------------------------------------------------
# 渲染插件子菜单并循环执行
# 参数：$1 插件数组下标
# 返回：无
# ------------------------------------------------------------
show_plugin_menu() {
    local idx="$1"
    local file="${PLUGIN_FILES[$idx]}"
    local name="${PLUGIN_NAMES[$idx]}"
    local choice

    # shellcheck source=/dev/null
    source "${file}"
    CURRENT_MODULE="plugin"

    while true; do
        clear
        _TUI_OPT_ROW_OPT=()
        echo "${COLOR_BOLD}${COLOR_CYAN}"
        echo "  ┌────────────────────────────────────────────────────┐"
        echo "  │  [插件] ${name}  ▸  输入 0 返回主菜单（鼠标可点击）"
        echo "  └────────────────────────────────────────────────────┘"
        echo "${COLOR_RESET}"
        _tui_capture plugin_menu
        choice=$(get_user_choice 99)
        [[ "${choice}" == "q" ]] && break
        case "${choice}" in
            0) break ;;
            *) plugin_execute "${choice}" || true ;;
        esac
    done
    CURRENT_MODULE="menu"
}
