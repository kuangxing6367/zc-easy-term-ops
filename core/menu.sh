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

# 两段式点击：当前高亮选中的选项号（空=未选中）。
# 鼠标点击 = 选中并高亮，再次点击同一项 = 确认进入。
_TUI_SELECTED=""
# 当前菜单上下文："main" / "sub:<idx>" / "plugin:<idx>"，供重绘定位当前菜单
_TUI_CTX="main"

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
# 说明：_TUI_BUF_ON=1 时改为追加到渲染缓冲 _TUI_RENDER_BUF，
#       由 _tui_flush_render 一次性输出——把整屏渲染拼成一个大字符串
#       只做一次 printf，大幅缩短输出窗口，避免渲染期间鼠标事件在
#       tty 输入缓冲堆积（表现为"某排点不动/悬停残留被当文本"）。
# ------------------------------------------------------------
_tui_line() {
    if (( ${_TUI_BUF_ON:-0} == 1 )); then
        _TUI_RENDER_BUF+="$*"$'\n'
    else
        printf '%s\n' "$*"
    fi
    _TUI_ROW=$(( _TUI_ROW + 1 ))
}

# ------------------------------------------------------------
# 一次性输出渲染缓冲并清空（缓冲模式下由渲染函数末尾调用）
# 参数：无
# 返回：无
# ------------------------------------------------------------
_tui_flush_render() {
    if [[ -n "${_TUI_RENDER_BUF:-}" ]]; then
        printf '%s' "${_TUI_RENDER_BUF}"
    fi
    _TUI_RENDER_BUF=""
}

# ------------------------------------------------------------
# 打印一个空行并推进 _TUI_ROW
# 参数：无
# 返回：无
# ------------------------------------------------------------
_tui_nl() {
    if (( ${_TUI_BUF_ON:-0} == 1 )); then
        _TUI_RENDER_BUF+=$'\n'
    else
        printf '\n'
    fi
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
    local line
    line=$(printf "${COLOR_CYAN}%${n}s${COLOR_RESET}" "" | tr ' ' '─')
    if (( ${_TUI_BUF_ON:-0} == 1 )); then
        _TUI_RENDER_BUF+="${line}"$'\n'
    else
        printf '%s\n' "${line}"
    fi
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
    local rows=0 r=0
    _tty_flush
    # 用终端屏幕高度估算光标行，替代 DSR(\e[6n) 查询：
    # DSR 依赖终端响应，XShell/部分终端响应慢或格式异常会导致校准错误（"某排点不动"）。
    # 主菜单渲染后光标停在最后一行：内容未滚动时在内容末行 n，
    # 内容滚动后停在屏幕最后可见行 rows → r = min(n, rows)。
    # 仅在真实终端读取 stty，避免重定向/子 shell 下 < /dev/tty 阻塞
    rows=0
    if [[ -t 1 ]]; then
        rows=$(stty size < /dev/tty 2>/dev/null | awk '{print $1}')
    fi
    rows=${rows:-0}
    [[ "${rows}" =~ ^[0-9]+$ ]] || rows=0
    if (( rows > 0 && n > rows )); then
        r="${rows}"
    else
        r="${n}"
    fi
    # 清空可能残留的字节（含 DSR 响应），防止其被后续当普通文本回显
    _tty_flush
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
# 将一行输出为「选中高亮」样式（整行反色 + ▸ 标记，htop/网页选中感）
# 参数：$1 原始行（可含 ANSI 颜色）
# 返回：无
# ------------------------------------------------------------
_tui_hl() {
    local line="$1" lead="" body=""
    lead="${line%%[![:space:]]*}"          # 保留前导空白，保持列对齐
    body="${line#"${lead}"}"
    printf '%s\e[7m▸ %s\e[0m' "${lead}" "${body}"
}

# ------------------------------------------------------------
# 运行一个输出菜单行的命令：记录每行首部 "N." 选项与行号映射，再原样输出
# （主菜单双列网格一行含两个选项号，同时记录第二个）
# 若行映射到 _TUI_SELECTED 选中项，则整行反色高亮（两段式点击的视觉反馈）
# 参数：$@ 命令及参数
# ------------------------------------------------------------
_tui_capture() {
    local start="${_TUI_ROW}"
    local out=""
    out=$("$@") || true
    # 1) 先构建「行号 → 选项号」映射（不输出）
    local -A rowmap=()
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
                rowmap[$((start + lineno))]="${first} ${second}"
            else
                rowmap[$((start + lineno))]="${first}"
            fi
        fi
        lineno=$((lineno + 1))
    done <<< "${out}"
    # 同步到全局映射（供鼠标行号反查）
    local k
    for k in "${!rowmap[@]}"; do
        _TUI_OPT_ROW_OPT[${k}]="${rowmap[$k]}"
    done
    # 2) 逐行拼装（命中选中项的行整行高亮），经 _tui_line 输出——
    #    缓冲模式下全部进 _TUI_RENDER_BUF，由渲染函数末尾一次性 printf，
    #    缩短渲染输出窗口，防止鼠标事件堆积
    local sel="${_TUI_SELECTED:-}"
    lineno=0
    while IFS= read -r line; do
        local r=$((start + lineno))
        if [[ -n "${sel}" ]] && [[ " ${rowmap[${r}]:-} " == *" ${sel} "* ]]; then
            _tui_line "$(_tui_hl "${line}")"
        else
            _tui_line "${line}"
        fi
        lineno=$((lineno + 1))
    done <<< "${out}"
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
        # 双列网格：左列 col < 右列起始列，右列从 _TUI_RIGHT_COL 开始
        # （渲染时按显示宽度固定左列宽度，保证右列起始列与点击分界一致）
        if (( col < ${_TUI_RIGHT_COL:-30} )); then
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
        [[ -z "${nxt}" ]] && {
            # ESC 单独到达（如悬停事件被拆分）：丢弃并清空残留，
            # 防止剩余序列字节被后续当普通文本回显
            [[ "${src}" == "tty" ]] && _tty_flush
            echo "none"; return 1
        }

        if [[ "${nxt}" == "[" ]]; then
            if [[ "${src}" == "tty" ]]; then
                IFS= read -r -s -n 1 -t 1 m < /dev/tty || m=""
            else
                IFS= read -r -s -n 1 -t 1 m || m=""
            fi
            # 方向键：ESC [ A/B/C/D → key:up/down/left/right（全菜单统一导航）
            case "${m}" in
                A) echo "key:up"; return 0 ;;
                B) echo "key:down"; return 0 ;;
                C) echo "key:right"; return 0 ;;
                D) echo "key:left"; return 0 ;;
            esac
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
                    # 丢弃鼠标指针信息：移动/悬停/拖拽/滚轮（btn>=32）不产生输入
                    if (( btn >= 32 )); then
                        echo "none"
                        return 1
                    fi
                    printf 'mouse:%d,%d,%d' "${btn}" "${x}" "${y}"
                    return 0
                fi
                echo "none"
                return 1
            # SGR 鼠标：ESC [ < b ; x ; y M|m （M=按下，m=释放）
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
                # 关键：区分按下(M)与释放(m)。二者按钮号相同(0)，
                # 若不区分，一次点击的"按下+释放"会被误判成两次点击 → 点一次就进入
                local body="${seq%[Mm]}" term="${seq: -1}"
                IFS=';' read -r btn x y <<< "${body}"
                if [[ "${btn}" =~ ^[0-9]+$ ]] && [[ "${x}" =~ ^[0-9]+$ ]] && [[ "${y}" =~ ^[0-9]+$ ]]; then
                    # 丢弃鼠标指针信息：移动/悬停/拖拽等（btn>=32）不产生输入，
                    # 防止其转义序列被当普通文本回显；滚轮(64/65)保留用于主页翻页
                    if (( btn >= 32 )); then
                        if (( btn == 64 || btn == 65 )); then
                            printf 'mouse:%d,%d,%d' "${btn}" "${x}" "${y}"
                            return 0
                        fi
                        echo "none"
                        return 1
                    fi
                    if [[ "${term}" == "M" ]]; then
                        printf 'mouse:%d,%d,%d' "${btn}" "${x}" "${y}"
                    else
                        # 释放事件：按钮号置 3（与 X10 释放一致），调用方按 btn==0 判断时自动忽略
                        printf 'mouse:%d,%d,%d' "$(( btn + 3 ))" "${x}" "${y}"
                    fi
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
    # 丢弃控制字符（鼠标序列残留/功能键等），不回显，防止乱码污染屏幕
    if (( ${#ch} == 1 )); then
        local _och
        LC_ALL=C printf -v _och '%d' "'${ch}"
        if (( _och < 32 || _och == 127 )); then
            echo "none"
            return 1
        fi
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
# 重绘当前菜单（两段式点击选中高亮后调用）。
# 本函数在命令替换子 shell（choice=$(get_user_choice...)）中执行，
# stdout 会被捕获，故重绘输出显式写入 /dev/tty。
# 参数：无
# 返回：无
# ------------------------------------------------------------
_tui_redraw_menu() {
    [[ -e /dev/tty ]] || return 0
    local typ="${_TUI_CTX:-main}" arg="${_TUI_CTX#*:}"
    {
        case "${typ}" in
            main)   show_main_menu_render ;;
            sub)    show_sub_menu_render "${arg}" ;;
            plugin) show_plugin_menu_render "${arg}" ;;
            *)      : ;;
        esac
    } > /dev/tty 2>&1 || true
}

# ------------------------------------------------------------
# 读取用户选择（1..max，0 退出，q 返回；TUI 下支持鼠标两段式点击）
# 参数：$1 最大选项数
# 输出：用户选择数字
# ------------------------------------------------------------
get_user_choice() {
    local max="$1"
    local ans=""
    local mouse=0 src="stdin"
    local prompt=""
    local sel="" ev="" btn="" x="" y="" opt=""
    # TUI 鼠标模式：真实终端 + 非 dumb + 未显式关闭
    if [[ -t 0 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ "${ZETOPS_TUI_MOUSE:-on}" == "on" ]] && _tui_mouse_on; then
        mouse=1
        src="tty"
    fi
    # 注意：本函数通过命令替换调用（choice=$(get_user_choice ...)），
    # 因此提示/告警必须输出到 stderr，stdout 只返回最终选择数字
    _TUI_SELECTED=""
    prompt="  ${COLOR_BOLD}${COLOR_GREEN}请输入操作编号 (0-${max}) [q=退出${COLOR_RESET}${COLOR_GRAY}，方向键/鼠标选中，回车或再点确认${COLOR_RESET}${COLOR_BOLD}${COLOR_GREEN}]: ${COLOR_RESET}"
    # 提示只打印一次：空闲等待（超时）时不重复刷新，避免"自动刷新"现象
    echo -n "${prompt}" >&2
    while true; do
        ev=$(_tui_read_event "${src}") || true
        case "${ev}" in
            line:q|line:Q)
                _tui_mouse_off "${mouse}"
                _TUI_SELECTED=""
                echo "q"
                return 0
                ;;
            line:)
                # 回车：确认当前高亮选中项（若有）
                if [[ -n "${sel}" ]]; then
                    _tui_mouse_off "${mouse}"
                    _TUI_SELECTED=""
                    echo "${sel}"
                    return 0
                fi
                ;;
            line:*)
                ans="${ev#line:}"
                if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 0 && ans <= max )); then
                    _tui_mouse_off "${mouse}"
                    _TUI_SELECTED=""
                    echo "${ans}"
                    return 0
                fi
                echo "${COLOR_YELLOW}  ⚠ 输入无效，请输入 0-${max} 的数字${COLOR_RESET}" >&2
                echo -n "${prompt}" >&2
                ;;
            key:up|key:down|key:left|key:right)
                # 方向键导航：在当前渲染的选项集合中上下移动选中项
                # （主菜单当前页 / 子菜单全部选项；复用 _TUI_OPT_ROW_OPT 行映射）
                local -a _ol=()
                local _k _v
                for _k in "${!_TUI_OPT_ROW_OPT[@]}"; do
                    _v="${_TUI_OPT_ROW_OPT[$_k]}"
                    [[ -n "${_v}" ]] && _ol+=("${_v}")
                done
                # 关联数组键无序 → 选项号去重并按数字升序，保证导航顺序
                if (( ${#_ol[@]} > 1 )); then
                    _ol=($(printf '%s\n' "${_ol[@]}" | sort -nu 2>/dev/null))
                fi
                local _cur=0 _target=0 _i=0 _found=0
                if [[ -n "${sel}" ]]; then
                    for _i in "${!_ol[@]}"; do
                        if [[ "${_ol[$_i]}" == "${sel}" ]]; then
                            _cur="${_i}"; _found=1; break
                        fi
                    done
                else
                    # 尚无选中：默认光标在第一个可选项
                    _cur=-1; _found=1
                fi
                if [[ "${ev}" == "key:up" || "${ev}" == "key:left" ]]; then
                    _target=$(( _cur - 1 ))
                else
                    _target=$(( _cur + 1 ))
                fi
                (( _target < 0 )) && _target=0
                if (( _target >= ${#_ol[@]} )); then
                    _target=$(( ${#_ol[@]} - 1 ))
                fi
                if (( ${#_ol[@]} > 0 )); then
                    sel="${_ol[$_target]}"
                    _TUI_SELECTED="${sel}"
                    _tui_redraw_menu
                    echo -n "${prompt}" >&2
                fi
                ;;
            mouse:*)
                IFS=',' read -r btn x y <<< "${ev#mouse:}"
                # 滚轮：上(64)翻上一页，下(65)翻下一页（返回特殊值由主循环处理）
                if (( btn == 64 || btn == 65 )); then
                    _tui_mouse_off "${mouse}"
                    _TUI_SELECTED=""
                    if (( btn == 64 )); then
                        echo "PGUP"
                    else
                        echo "PGDN"
                    fi
                    return 0
                fi
                # 仅响应左键按下（btn==0；释放/拖拽忽略）
                if (( btn == 0 )); then
                    opt=$(_tui_row_to_opt "${y}" "${x}")
                    if [[ -n "${opt}" ]] && (( opt >= 0 && opt <= max )); then
                        if [[ "${sel}" == "${opt}" ]]; then
                            # 同项再次点击 → 确认进入
                            _tui_mouse_off "${mouse}"
                            _TUI_SELECTED=""
                            echo "${opt}"
                            return 0
                        fi
                        # 首次点击 → 选中并高亮重绘
                        sel="${opt}"
                        _TUI_SELECTED="${opt}"
                        _tui_redraw_menu
                        echo -n "${prompt}" >&2
                    elif [[ -n "${sel}" ]]; then
                        # 点击空白 → 取消选中
                        sel=""
                        _TUI_SELECTED=""
                        _tui_redraw_menu
                        echo -n "${prompt}" >&2
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
    local logo=""
    logo=$(cat <<'EOF'
 ███████╗███████╗████████╗ ██████╗ ██████╗ ███████╗
 ╚══███╔╝██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
   ███╔╝ █████╗     ██║   ██║   ██║██████╔╝███████╗
  ███╔╝  ██╔══╝     ██║   ██║   ██║██╔══██╗╚════██║
 ███████╗███████╗   ██║   ╚██████╔╝██║  ██║███████║
 ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝
EOF
)
    _tui_line "${COLOR_BOLD}${COLOR_BLUE}"
    # logo 进渲染缓冲（缓冲模式下与整屏内容一起一次性输出）
    if (( ${_TUI_BUF_ON:-0} == 1 )); then
        _TUI_RENDER_BUF+="${logo}"$'\n'
    else
        printf '%s\n' "${logo}"
    fi
    _TUI_ROW=$(( _TUI_ROW + 7 ))
    _tui_line "${COLOR_RESET}"
    _tui_line "  ${COLOR_BOLD}${COLOR_CYAN}交互式 Linux 运维全能工具箱${COLOR_RESET}   ${COLOR_GRAY}v${ZETOPS_VERSION:-1.5.8} | Interactive Linux Ops Toolkit${COLOR_RESET}"
    _tui_nl
}

# ------------------------------------------------------------
# 精简页眉（分页主页用：1 行品牌，省出屏幕空间给菜单，保证每页不滚动 → 点击精确）
# 参数：无
# ------------------------------------------------------------
_ui_banner_compact() {
    _tui_line "  ${COLOR_BOLD}${COLOR_BLUE}ZETOPS${COLOR_RESET} ${COLOR_BOLD}${COLOR_CYAN}交互式 Linux 运维工具箱${COLOR_RESET}  ${COLOR_GRAY}v${ZETOPS_VERSION:-1.5.8} | Interactive Linux Ops Toolkit${COLOR_RESET}"
    _tui_nl
}

# ------------------------------------------------------------
# 精简系统概览（分页主页用：1 行关键信息）
# 参数：无
# ------------------------------------------------------------
_ui_sysinfo_compact() {
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
    _tui_line "  ${COLOR_GRAY}OS: ${os:-?}  Kernel: ${krn:-?}  CPU: ${cores:-?}核  内存: ${mem:-N/A}  磁盘/: ${disk:-N/A}  主机: ${host:-?} (${ip})${COLOR_RESET}"
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
# 模块/插件单列分页列表（每页 _TUI_PAGE_SIZE 项，一屏内不滚动 → 点击精确）
# 参数：无
# 说明：选项号为全局编号（模块 1..N，插件 N+1..）；滚轮/PageUp/PageDown 翻页
# ------------------------------------------------------------
_ui_module_list() {
    local n=${#MODULE_NAMES[@]}
    local pn=${#PLUGIN_NAMES[@]}
    local total=$(( n + pn ))
    local page="${_TUI_PAGE:-0}"
    local psize="${_TUI_PAGE_SIZE:-12}"
    (( psize < 4 )) && psize=4
    local start_i=$(( page * psize ))
    if (( start_i >= total )); then
        local lastpg=$(( (total + psize - 1) / psize - 1 ))
        (( lastpg < 0 )) && lastpg=0
        start_i=$(( lastpg * psize ))
    fi
    local end_i=$(( start_i + psize ))
    (( end_i > total )) && end_i="${total}"
    local i idx=0
    for ((i = start_i; i < end_i; i++)); do
        idx=$(( i + 1 ))
        if (( i < n )); then
            echo "  ${COLOR_BOLD}$(printf '%2d.' "${idx}")${COLOR_RESET} ${MODULE_NAMES[$i]}"
        else
            echo "  ${COLOR_BOLD}$(printf '%2d.' "${idx}")${COLOR_RESET} ${COLOR_GRAY}[插件]${COLOR_RESET} ${PLUGIN_NAMES[$(( i - n ))]}"
        fi
    done
    if (( total == 0 )); then
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
# 渲染主菜单（不 finalize 行映射；重绘时单独调用）
# 参数：无
# 返回：无
# ------------------------------------------------------------
show_main_menu_render() {
    _tui_clear
    _TUI_OPT_ROW_OPT=()
    # 缓冲模式：整屏拼成大字符串，末尾一次性 printf（缩短渲染窗口，防鼠标事件堆积）
    _TUI_BUF_ON=1; _TUI_RENDER_BUF=""
    # 分页大小自适应终端高度：每页内容保证不超一屏（不滚动 → 点击精确命中）
    _TUI_PAGE_SIZE=12
    local _fm_rows=0
    # 仅在真实终端（stdout 是 tty）时用 stty 自适应页大小；重定向/子 shell 下跳过，
    # 避免无控制终端时 < /dev/tty 阻塞，同时保证真终端下每页不超一屏
    if [[ -t 1 ]]; then
        _fm_rows=$(stty size < /dev/tty 2>/dev/null | awk '{print $1}')
    fi
    _fm_rows=${_fm_rows:-0}
    [[ "${_fm_rows}" =~ ^[0-9]+$ ]] || _fm_rows=0
    if (( _fm_rows >= 22 )); then
        # 每页内容保证不超一屏：精简页眉+分隔+页码+提示固定开销约 11 行
        _TUI_PAGE_SIZE=$(( _fm_rows - 11 ))
    fi
    (( _TUI_PAGE_SIZE < 4 )) && _TUI_PAGE_SIZE=4
    _ui_banner_compact
    _ui_sysinfo_compact
    _tui_hr
    _tui_nl
    _tui_capture _ui_module_list
    _tui_nl
    _tui_hr
    # 页码提示
    local _fm_total=$(( ${#MODULE_NAMES[@]} + ${#PLUGIN_NAMES[@]} ))
    local _fm_pages=$(( (_fm_total + _TUI_PAGE_SIZE - 1) / _TUI_PAGE_SIZE ))
    (( _fm_pages < 1 )) && _fm_pages=1
    _tui_line "  ${COLOR_GRAY}第 $(( ${_TUI_PAGE:-0} + 1 ))/${_fm_pages} 页    （滚轮 或 PageUp/PageDown 翻页）${COLOR_RESET}"
    _tui_line "  ${COLOR_BOLD}${COLOR_CYAN}q${COLOR_RESET}. 退出    ${COLOR_GRAY}↑↓方向键/点击 = 选中（高亮），回车或再点同一项 = 确认进入；数字回车 = 直接进入${COLOR_RESET}"
    _tui_nl
    _TUI_BUF_ON=0
    _tui_flush_render
}

# ------------------------------------------------------------
# 渲染主菜单（完整入口：渲染 + 行映射校准）
# 参数：无
# 返回：无
# ------------------------------------------------------------
show_main_menu() {
    _TUI_CTX="main"
    show_main_menu_render
    _tui_finalize_rows
}

# ------------------------------------------------------------
# 渲染子菜单（不 finalize；两段式点击重绘时调用）
# 参数：$1 模块数组下标
# 返回：无
# ------------------------------------------------------------
show_sub_menu_render() {
    local idx="$1"
    _tui_clear
    _TUI_OPT_ROW_OPT=()
    _TUI_BUF_ON=1; _TUI_RENDER_BUF=""
    _tui_line "${COLOR_BOLD}${COLOR_CYAN}"
    _tui_line "  ┌────────────────────────────────────────────────────┐"
    _tui_line "  │  ${module_name}  ▸  输入 0 返回主菜单（方向键/鼠标选中，回车或再点确认）"
    _tui_line "  └────────────────────────────────────────────────────┘"
    _tui_line "${COLOR_RESET}"
    _tui_run module_description
    _tui_capture module_menu
    _TUI_BUF_ON=0
    _tui_flush_render
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
    _TUI_CTX="sub:${idx}"

    while true; do
        show_sub_menu_render "${idx}"
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
# 渲染插件子菜单（不 finalize；两段式点击重绘时调用）
# 参数：$1 插件数组下标
# 返回：无
# ------------------------------------------------------------
show_plugin_menu_render() {
    local idx="$1"
    _tui_clear
    _TUI_OPT_ROW_OPT=()
    _TUI_BUF_ON=1; _TUI_RENDER_BUF=""
    _tui_line "${COLOR_BOLD}${COLOR_CYAN}"
    _tui_line "  ┌────────────────────────────────────────────────────┐"
    _tui_line "  │  [插件] ${name}  ▸  输入 0 返回主菜单（方向键/鼠标选中，回车或再点确认）"
    _tui_line "  └────────────────────────────────────────────────────┘"
    _tui_line "${COLOR_RESET}"
    _tui_capture plugin_menu
    _TUI_BUF_ON=0
    _tui_flush_render
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
    _TUI_CTX="plugin:${idx}"

    while true; do
        show_plugin_menu_render "${idx}"
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
