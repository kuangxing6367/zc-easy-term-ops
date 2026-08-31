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

# 当前光标所在行号（1 起）。菜单渲染函数打印时同步推进，
# 用于把鼠标点击的行号映射回菜单选项（替代 DSR \e[6n 光标查询，
# 消除远程/慢速终端下查询超时或响应残留导致的映射错位）
_TUI_ROW=0

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
# 清屏（纯 ANSI 转义，零外部依赖，不依赖 ncurses 的 clear 命令）
# 参数：无
# 返回：无
# ------------------------------------------------------------
_tui_clear() {
    printf '\033[2J\033[H\033[3J'
    _TUI_ROW=1
}

# ------------------------------------------------------------
# 打印一行文本并推进 _TUI_ROW（原样输出，适合含 ANSI 颜色的行）
# 参数：$* 该行内容
# 返回：无
# ------------------------------------------------------------
_tui_line() {
    printf '%s\n' "$*"
    _TUI_ROW=$(( _TUI_ROW + 1 ))
}

# ------------------------------------------------------------
# 打印一个空行并推进 _TUI_ROW
# 参数：无
# 返回：无
# ------------------------------------------------------------
_tui_nl() {
    printf '\n'
    _TUI_ROW=$(( _TUI_ROW + 1 ))
}

# ------------------------------------------------------------
# 绘制水平分隔线（蓝色主题）并推进 _TUI_ROW
# 参数：$1 长度（默认 60）
# 返回：无
# ------------------------------------------------------------
_tui_hr() {
    local n="${1:-60}"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=60
    printf "${COLOR_CYAN}%${n}s${COLOR_RESET}\n" "" | tr ' ' '─'
    _TUI_ROW=$(( _TUI_ROW + 1 ))
}

# ------------------------------------------------------------
# 执行一个只输出文本的命令：按实际输出行数推进 _TUI_ROW
# （用于 module_description 等不参与行映射但占屏幕行的内容）
# 参数：$@ 命令及参数
# 返回：无
# ------------------------------------------------------------
_tui_run() {
    local out=""
    out=$("$@") || true
    if [[ -n "${out}" ]]; then
        printf '%s\n' "${out}"
        local nlc="${out//[^$'\n']/}"
        _TUI_ROW=$(( _TUI_ROW + ${#nlc} + 1 ))
    fi
}

# ------------------------------------------------------------
# 清空 /dev/tty 输入缓冲（丢弃残留的控制序列/按键，
# 防止 DSR 响应残留、上次按键等污染后续鼠标/键盘解析）
# 参数：无
# 返回：无
# ------------------------------------------------------------
_tty_flush() {
    [[ -e /dev/tty ]] || return 0
    local b="" n=0
    while (( n < 200 )); do
        IFS= LC_ALL=C read -r -s -n 1 -t 0.02 b < /dev/tty 2>/dev/null || break
        n=$(( n + 1 ))
    done
    return 0
}

# ------------------------------------------------------------
# 开启终端鼠标捕获（X10 + SGR 双模式）
# 参数：无
# 返回：0=成功 1=失败
# ------------------------------------------------------------
_tui_mouse_on() {
    [[ -e /dev/tty ]] || return 1
    _tty_flush
    printf '\033[?1000h\033[?1002h\033[?1006h' > /dev/tty 2>/dev/null
}

# ------------------------------------------------------------
# 关闭终端鼠标捕获并清空残留输入
# 参数：$1 是否已开启（1=开）
# 返回：无
# ------------------------------------------------------------
_tui_mouse_off() {
    local on="${1:-0}"
    [[ "${on}" == "1" ]] || return 0
    [[ -e /dev/tty ]] || return 0
    printf '\033[?1000l\033[?1002l\033[?1006l' > /dev/tty 2>/dev/null || true
    _tty_flush
}

# ------------------------------------------------------------
# 单字节字符 → ASCII 码（纯 Bash，兼容任意字节）
# 参数：$1 单字节字符
# 输出：ASCII 值
# ------------------------------------------------------------
_ord() {
    LC_ALL=C printf '%d' "'${1}"
}

# ------------------------------------------------------------
# 渲染完成后校准鼠标行映射。
# 菜单内容在短终端（如 24 行）上会发生滚动，鼠标上报的 y 是
# "当前可见区"行号，而 _TUI_ROW 记录的是"内容"行号；两者存在
# 一个滚动偏移。这里用 DSR \e[6n 查询最终光标行号，算出偏移并
# 平移 _TUI_OPT_ROW_OPT 的键，使点击坐标精确命中对应选项。
# 参数：无
# 返回：无
# ------------------------------------------------------------
_tui_finalize_rows() {
    [[ -e /dev/tty ]] || return 0
    local n=$(( _TUI_ROW - 1 ))   # 已渲染内容总行数
    local r=0 tries=0
    _tty_flush
    for (( tries = 0; tries < 2; tries++ )); do
        printf '\033[6n' > /dev/tty
        IFS='[;' read -r -s -d 'R' -t 0.5 _ r _ < /dev/tty 2>/dev/null || r=0
        [[ "${r}" =~ ^[0-9]+$ ]] || r=0
        (( r > 0 )) && break
    done
    # 查询失败时按"未滚动"处理（r=n → 偏移 0），不中断
    (( r > 0 )) || r="${n}"
    local off=$(( r - n ))
    if (( off != 0 )); then
        local k v
        for k in "${!_TUI_OPT_ROW_OPT[@]}"; do
            v="${_TUI_OPT_ROW_OPT[$k]}"
            unset "_TUI_OPT_ROW_OPT[$k]"
            _TUI_OPT_ROW_OPT[$(( k + off ))]="${v}"
        done
    fi
}

# ------------------------------------------------------------
# 运行一个输出菜单行的命令：记录每行首部 "N." 选项与行号映射，再原样输出
# （主菜单双列网格一行含两个选项号，同时记录第二个）
# 参数：$@ 命令及参数
# ------------------------------------------------------------
_tui_capture() {
    local start="${_TUI_ROW}"
    local out=""
    out=$("$@") || true
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
    local nlc="${out//[^$'\n']/}"
    _TUI_ROW=$(( start + ${#nlc} + 1 ))
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
# 参数：$1 src（tty=从 /dev/tty 读；stdin=从标准输入读）
# 输出："line:<内容>" / "mouse:<按钮>,<x>,<y>" / "none"
# 说明：
#   - 兼容 X10（ESC [ M b x y）与 SGR（ESC [ < b ; x ; y M|m）两种鼠标协议
#   - 所有读取均带超时，绝不因残留控制序列而无限阻塞
#   - 高位字节按 LC_ALL=C 逐字节读取，避免 UTF-8 下坐标解析卡死
# ------------------------------------------------------------
_tui_read_event() {
    local src="${1:-tty}" ch="" nxt="" m=""
    if [[ "${src}" == "tty" ]]; then
        IFS= read -r -s -n 1 -t 3 ch < /dev/tty || ch=""
    else
        IFS= read -r -s -n 1 -t 3 ch || ch=""
    fi
    [[ -z "${ch}" ]] && { echo "none"; return 1; }

    if [[ "${ch}" == $'\e' ]]; then
        # ---- ESC 起始的控制序列 ----
        if [[ "${src}" == "tty" ]]; then
            IFS= read -r -s -n 1 -t 1 nxt < /dev/tty || nxt=""
        else
            IFS= read -r -s -n 1 -t 1 nxt || nxt=""
        fi
        [[ -z "${nxt}" ]] && { echo "none"; return 1; }

        if [[ "${nxt}" == "[" ]]; then
            if [[ "${src}" == "tty" ]]; then
                IFS= read -r -s -n 1 -t 1 m < /dev/tty || m=""
            else
                IFS= read -r -s -n 1 -t 1 m || m=""
            fi
            # X10 鼠标：ESC [ M <b><x><y>（b/x/y 各为 值+32 的单字节）
            if [[ "${m}" == "M" ]]; then
                local b1="" b2="" b3="" btn="" x="" y=""
                if [[ "${src}" == "tty" ]]; then
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 b1 < /dev/tty || b1=""
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 b2 < /dev/tty || b2=""
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 b3 < /dev/tty || b3=""
                else
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 b1 || b1=""
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 b2 || b2=""
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 b3 || b3=""
                fi
                if [[ -n "${b1}" && -n "${b2}" && -n "${b3}" ]]; then
                    btn=$(( $(_ord "${b1}") - 32 ))
                    x=$(( $(_ord "${b2}") - 32 ))
                    y=$(( $(_ord "${b3}") - 32 ))
                    printf 'mouse:%d,%d,%d' "${btn}" "${x}" "${y}"
                    return 0
                fi
                echo "none"
                return 1
            # SGR 鼠标：ESC [ < b ; x ; y M|m
            elif [[ "${m}" == "<" ]]; then
                local seq="" c="" btn="" x="" y=""
                while (( ${#seq} < 32 )); do
                    if [[ "${src}" == "tty" ]]; then
                        IFS= read -r -s -n 1 -t 1 c < /dev/tty || c=""
                    else
                        IFS= read -r -s -n 1 -t 1 c || c=""
                    fi
                    [[ -z "${c}" ]] && break
                    seq+="${c}"
                    [[ "${c}" == "M" || "${c}" == "m" ]] && break
                done
                local body="${seq%[Mm]}"
                IFS=';' read -r btn x y <<< "${body}"
                if [[ "${btn}" =~ ^[0-9]+$ ]] && [[ "${x}" =~ ^[0-9]+$ ]] && [[ "${y}" =~ ^[0-9]+$ ]]; then
                    printf 'mouse:%d,%d,%d' "${btn}" "${x}" "${y}"
                    return 0
                fi
                echo "none"
                return 1
            fi
        fi
        # 其他控制序列（方向键 / 功能键等）：忽略
        echo "none"
        return 1
    fi

    if [[ "${ch}" == $'\n' || "${ch}" == $'\r' ]]; then
        echo "line:"
        return 0
    fi
    # 普通输入：回显首个字符，再读取行剩余部分（带超时，避免残留字节无限等待）
    printf '%s' "${ch}" >&2
    local rest=""
    if [[ "${src}" == "tty" ]]; then
        IFS= read -r -t 3 rest < /dev/tty || rest=""
    else
        IFS= read -r -t 3 rest || rest=""
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
    local prompt=""
    # TUI 鼠标模式：真实终端 + 非 dumb + 未显式关闭
    if [[ -t 0 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ "${ZETOPS_TUI_MOUSE:-on}" == "on" ]] && _tui_mouse_on; then
        mouse=1
        src="tty"
    fi
    # 注意：本函数通过命令替换调用（choice=$(get_user_choice ...)），
    # 因此提示/告警必须输出到 stderr，stdout 只返回最终选择数字
    prompt="  ${COLOR_BOLD}${COLOR_GREEN}请输入操作编号 (0-${max}) [q=退出${COLOR_RESET}${COLOR_GRAY}，鼠标可点击菜单${COLOR_RESET}${COLOR_BOLD}${COLOR_GREEN}]: ${COLOR_RESET}"
    # 提示只打印一次：空闲等待（超时）时不重复刷新，避免"自动刷新"现象
    echo -n "${prompt}" >&2
    while true; do
        local ev=""
        ev=$(_tui_read_event "${src}") || true
        case "${ev}" in
            line:q|line:Q)
                _tui_mouse_off "${mouse}"
                echo "q"
                return 0
                ;;
            line:*)
                ans="${ev#line:}"
                if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 0 && ans <= max )); then
                    _tui_mouse_off "${mouse}"
                    echo "${ans}"
                    return 0
                fi
                echo "${COLOR_YELLOW}  ⚠ 输入无效，请输入 0-${max} 的数字${COLOR_RESET}" >&2
                echo -n "${prompt}" >&2
                ;;
            mouse:*)
                local btn x y opt=""
                IFS=',' read -r btn x y <<< "${ev#mouse:}"
                # 仅响应左键按下（btn==0；释放/滚轮/拖拽忽略）
                if (( btn == 0 )); then
                    opt=$(_tui_row_to_opt "${y}" "${x}")
                    if [[ -n "${opt}" ]] && (( opt >= 0 && opt <= max )); then
                        _tui_mouse_off "${mouse}"
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
# ASCII Logo Banner（同时推进 _TUI_ROW）
# 参数：无
# ------------------------------------------------------------
_ui_banner() {
    _tui_line "${COLOR_BOLD}${COLOR_BLUE}"
    cat <<'EOF'
 ███████╗███████╗████████╗ ██████╗ ██████╗ ███████╗
 ╚══███╔╝██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
   ███╔╝ █████╗     ██║   ██║   ██║██████╔╝███████╗
  ███╔╝  ██╔══╝     ██║   ██║   ██║██╔══██╗╚════██║
 ███████╗███████╗   ██║   ╚██████╔╝██║  ██║███████║
 ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝
EOF
    _TUI_ROW=$(( _TUI_ROW + 7 ))
    _tui_line "${COLOR_RESET}"
    _tui_line "  ${COLOR_BOLD}${COLOR_CYAN}交互式 Linux 运维全能工具箱${COLOR_RESET}   ${COLOR_GRAY}v${ZETOPS_VERSION:-1.4.0} | Interactive Linux Ops Toolkit${COLOR_RESET}"
    _tui_nl
}

# ------------------------------------------------------------
# 系统概览（只读快速探测，全部容错；同时推进 _TUI_ROW）
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
    _tui_line "  ${COLOR_BOLD}${COLOR_CYAN}OS${COLOR_RESET}: ${os:-?}   ${COLOR_BOLD}${COLOR_CYAN}Kernel${COLOR_RESET}: ${krn:-?}   ${COLOR_BOLD}${COLOR_CYAN}CPU${COLOR_RESET}: ${cores:-?}核"
    _tui_line "  ${COLOR_BOLD}${COLOR_CYAN}内存${COLOR_RESET}: ${mem:-N/A}   ${COLOR_BOLD}${COLOR_CYAN}磁盘/${COLOR_RESET}: ${disk:-N/A}   ${COLOR_BOLD}${COLOR_CYAN}主机${COLOR_RESET}: ${host:-?} (${ip})"
    _tui_line "  ${COLOR_BOLD}${COLOR_CYAN}时间${COLOR_RESET}: $(date '+%Y-%m-%d %H:%M:%S')"
    _tui_nl
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
    _tui_clear
    _TUI_OPT_ROW_OPT=()
    _ui_banner
    _ui_sysinfo
    _tui_hr
    _tui_nl
    _tui_capture _ui_module_list
    _tui_capture _ui_plugins
    _tui_nl
    _tui_hr
    _tui_line "  ${COLOR_BOLD}${COLOR_CYAN}q${COLOR_RESET}. 退出    ${COLOR_GRAY}输入模块编号${COLOR_RESET}${COLOR_CYAN}或鼠标点击${COLOR_RESET}${COLOR_GRAY}进入对应功能${COLOR_RESET}"
    _tui_nl
    _tui_finalize_rows
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
        _tui_clear
        _TUI_OPT_ROW_OPT=()
        _tui_line "${COLOR_BOLD}${COLOR_CYAN}"
        _tui_line "  ┌────────────────────────────────────────────────────┐"
        _tui_line "  │  ${module_name}  ▸  输入 0 返回主菜单（鼠标可点击）"
        _tui_line "  └────────────────────────────────────────────────────┘"
        _tui_line "${COLOR_RESET}"
        _tui_run module_description
        _tui_capture module_menu
        _tui_finalize_rows
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
        _tui_clear
        _TUI_OPT_ROW_OPT=()
        _tui_line "${COLOR_BOLD}${COLOR_CYAN}"
        _tui_line "  ┌────────────────────────────────────────────────────┐"
        _tui_line "  │  [插件] ${name}  ▸  输入 0 返回主菜单（鼠标可点击）"
        _tui_line "  └────────────────────────────────────────────────────┘"
        _tui_line "${COLOR_RESET}"
        _tui_capture plugin_menu
        _tui_finalize_rows
        choice=$(get_user_choice 99)
        [[ "${choice}" == "q" ]] && break
        case "${choice}" in
            0) break ;;
            *) plugin_execute "${choice}" || true ;;
        esac
    done
    CURRENT_MODULE="menu"
}
