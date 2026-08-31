#!/bin/bash
# ============================================================
# 文件：modules/20_file_manager.sh
# 功能：TUI 可视化文件管理器 [File Manager - TUI]
# 作者：zc 团队
# 版本：2.0.0
# 日期：2026-08-07
# 说明：
#   - 纯 Bash 自绘 TUI（ANSI 转义，零外部依赖，无需 dialog/ranger）
#   - 备用屏幕缓冲 + 鼠标点击（SGR 模式，x10 兼容回退）+ 双击打开
#   - 顶部工具栏（返回/上级/刷新/新建/搜索/书签/目录树/复制/剪切/
#     粘贴/改名/删除/退出），点击即触发
#   - 文件剪贴板（~/.zetops/fm_clipboard）：复制/剪切/粘贴，多选标记(Space)
#   - 键盘：↑↓ 选择 Enter/双击打开 ←/Esc 返回 Space 多选 r 刷新
#     q 退出，快捷键全集同工具栏
#   - 文件操作：查看/编辑/复制/移动/重命名/删除(危险保护)/权限/压缩解压
#   - 安全：删除必须确认、危险目录(/、/etc 等)二次警告
# ============================================================
set -euo pipefail

module_name="文件管理器"
module_short="file_manager"
module_version="2.1.0"

FM_BOOKMARKS="${FM_BOOKMARKS:-${HOME}/.zetops/fm_bookmarks}"
FM_CLIPBOARD="${FM_CLIPBOARD:-${HOME}/.zetops/fm_clipboard}"
FM_PWD="${FM_PWD:-$HOME}"    # 当前目录

# ---- TUI 状态 ----
FM_LIST=()          # 当前目录条目（TYPE|name|full）
FM_LEN=0            # 条目总数
FM_CURSOR=0         # 光标条目索引
FM_OFFSET=0         # 可视窗口顶部索引
FM_WINH=10          # 可视窗口行数
FM_MARKED=()        # 多选标记的完整路径
FM_CLIP_MODE=""     # 剪贴板模式 copy/cut
FM_CLIP_LIST=()     # 剪贴板路径列表
FM_TOOLBAR_BOXES=() # 工具栏点击区域（start|width|id）
FM_STATUS_MSG=""    # 一次性状态消息
FM_QUIT=0           # 退出标志（工具栏点击）
FM_DBL_ROW=-1       # 双击检测：上次点击行
FM_DBL_TIME=0       # 双击检测：上次点击时间

module_description() {
    echo "TUI 文件管理器：鼠标点击、工具栏、复制/剪切/粘贴剪贴板、目录导航 [File Manager TUI]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name}"
    echo "======================================"
    echo " 1. 打开文件管理器（TUI 全屏界面）"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) fm_main ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ============================================================
# TUI 基础层（备用屏幕 / 鼠标 / 事件读取 / 渲染）
# ============================================================

# ------------------------------------------------------------
# 进入 TUI：备用屏幕 + 鼠标(SGR, x10 兼容) + 隐藏光标
# ------------------------------------------------------------
fm_tui_enter() {
    printf '\e[?1049h\e[?1000;1006h\e[?25l'
}

# ------------------------------------------------------------
# 退出 TUI：恢复光标 / 关闭鼠标 / 还原主屏幕
# ------------------------------------------------------------
fm_tui_leave() {
    printf '\e[?25h\e[?1000;1006l\e[?1049l'
}

# ------------------------------------------------------------
# 在临时离开 TUI 的上下文里执行操作函数（复用原行式交互）
# 参数：$@ 函数及参数
# ------------------------------------------------------------
fm_tui_do() {
    fm_tui_leave
    "$@" || true
    fm_tui_enter
}

# ------------------------------------------------------------
# 字符串显示宽度（非 ASCII 按 2 列估算，含中文/Emoji）
# 参数：$1 字符串
# 输出：列数
# 说明：手动 UTF-8 解码计数，不依赖 locale——在 LC_ALL=C 下
#       ${#s}/${s:i:1} 会按字节切分导致中文宽度算成 3 倍，
#       进而使工具栏点击区域与列表布局错位（"布局乱+点击不符"的常见根因）
# 实现已提升至 core/utils.sh（fm_str_w / fm_str_clip），此处复用公共函数

# ------------------------------------------------------------
# 读取一个输入事件（键盘或鼠标），结果写入 FM_EV/FM_EVK/FM_EVB/FM_EVX/FM_EVY
# ------------------------------------------------------------
FM_EV="key"; FM_EVK=""; FM_EVB=""; FM_EVX=0; FM_EVY=0; FM_EVPRESS=1
fm_read_event() {
    FM_EV="key"; FM_EVK=""; FM_EVB=""; FM_EVX=0; FM_EVY=0; FM_EVPRESS=1
    local ch="" ch2="" ch3=""
    IFS= read -rsn1 ch || { FM_EVK="QUIT"; return; }
    [[ -z "${ch}" ]] && { FM_EVK="NONE"; return; }
    case "${ch}" in
        $'\x1b')
            IFS= read -rsn1 ch2 || { FM_EVK="ESC"; return; }
            if [[ "${ch2}" == "[" ]]; then
                IFS= read -rsn1 ch3 || { FM_EVK="ESC"; return; }
                case "${ch3}" in
                    A) FM_EVK="UP" ;;
                    B) FM_EVK="DOWN" ;;
                    C) FM_EVK="RIGHT" ;;
                    D) FM_EVK="LEFT" ;;
                    H) FM_EVK="HOME" ;;
                    F) FM_EVK="END" ;;
                    5) IFS= read -rsn1 _; FM_EVK="PAGEUP" ;;
                    6) IFS= read -rsn1 _; FM_EVK="PAGEDOWN" ;;
                    M) fm_read_x10 ;;
                    '<') fm_read_sgr ;;
                    *) FM_EVK="ESC" ;;
                esac
            elif [[ "${ch2}" == "O" ]]; then
                IFS= read -rsn1 ch3 || { FM_EVK="ESC"; return; }
                case "${ch3}" in
                    A) FM_EVK="UP" ;;
                    B) FM_EVK="DOWN" ;;
                    C) FM_EVK="RIGHT" ;;
                    D) FM_EVK="LEFT" ;;
                    *) FM_EVK="ESC" ;;
                esac
            else
                FM_EVK="ESC"
            fi
            ;;
        $'\r'|$'\n') FM_EVK="ENTER" ;;
        $'\x7f'|$'\x08') FM_EVK="BACK" ;;
        $' ') FM_EVK="SPACE" ;;
        *) FM_EVK="${ch}" ;;
    esac
}

# ------------------------------------------------------------
# x10 鼠标协议解析（\e[M Cb Cx Cy，兼容旧终端）
# ------------------------------------------------------------
fm_read_x10() {
    FM_EV="mouse"
    local b="" x="" y=""
    IFS= read -rsn1 b; IFS= read -rsn1 x; IFS= read -rsn1 y
    FM_EVB=$(( $(printf '%d' "'${b}") - 32 ))
    FM_EVX=$(( $(printf '%d' "'${x}") - 32 ))
    FM_EVY=$(( $(printf '%d' "'${y}") - 32 ))
    # x10 按下=按钮位，释放=按钮位高 2 位(bit0,1)置位
    FM_EVPRESS=1
    if (( (FM_EVB & 3) == 3 )); then
        FM_EVPRESS=0
    fi
}

# ------------------------------------------------------------
# SGR 鼠标协议解析（\e[<b;x;yM 按下 / m 释放，主流终端）
# ------------------------------------------------------------
fm_read_sgr() {
    FM_EV="mouse"
    local buf="" c="" term="M"
    while :; do
        IFS= read -rsn1 c || break
        if [[ "${c}" == "M" || "${c}" == "m" ]]; then
            term="${c}"
            break
        fi
        buf+="${c}"
    done
    local b="" x="" y="" tmp=""
    # 防御：剥离所有非数字/分号字节，避免尾随分号或异常字节把坐标变成
    # "10;" 之类的非整数字符串，导致后续算术与行映射错乱（点击位置不符的常见根因）
    tmp="${buf//[^0-9;]/}"
    b="${tmp%%;*}"
    tmp="${tmp#*;}"
    x="${tmp%%;*}"
    tmp="${tmp#*;}"
    y="${tmp%%;*}"
    [[ "${b}" =~ ^[0-9]+$ ]] || b=0
    [[ "${x}" =~ ^[0-9]+$ ]] || x=0
    [[ "${y}" =~ ^[0-9]+$ ]] || y=0
    FM_EVB=$(( b + 0 )); FM_EVX=$(( x + 0 )); FM_EVY=$(( y + 0 ))
    FM_EVPRESS=1
    [[ "${term}" == "m" ]] && FM_EVPRESS=0
}

# ------------------------------------------------------------
# 刷新当前目录条目列表（目录在前，文件在后，各自按名称排序）
# ------------------------------------------------------------
fm_refresh_list() {
    local d f d_entries=() f_entries=() sd=()
    for d in "${FM_PWD}"/.[!.]* "${FM_PWD}"/..?*; do
        [[ -d "${d}" ]] && d_entries+=("D|$(basename "${d}")|${d}")
    done 2>/dev/null || true
    for f in "${FM_PWD}"/.[!.]* "${FM_PWD}"/..?*; do
        [[ -f "${f}" ]] && f_entries+=("F|$(basename "${f}")|${f}")
    done 2>/dev/null || true
    for d in "${FM_PWD}"/*; do
        [[ -d "${d}" ]] && d_entries+=("D|$(basename "${d}")|${d}")
    done 2>/dev/null || true
    for f in "${FM_PWD}"/*; do
        [[ -f "${f}" ]] && f_entries+=("F|$(basename "${f}")|${f}")
    done 2>/dev/null || true

    FM_LIST=()
    # 上级目录入口（固定第一项，等价于普通文件管理器的 ../）；
    # 根目录 / 的上级仍为 /，不重复添加避免死循环
    local parent=""
    parent=$(dirname "${FM_PWD}" 2>/dev/null || true)
    if [[ -n "${parent}" && "${parent}" != "${FM_PWD}" ]]; then
        FM_LIST+=("D|..|${parent}")
    fi
    if (( ${#d_entries[@]} > 0 )); then
        mapfile -t sd < <(printf '%s\n' "${d_entries[@]}" | LC_ALL=C sort -t'|' -k2 2>/dev/null || true)
        FM_LIST+=("${sd[@]}")
    fi
    if (( ${#f_entries[@]} > 0 )); then
        mapfile -t sd < <(printf '%s\n' "${f_entries[@]}" | LC_ALL=C sort -t'|' -k2 2>/dev/null || true)
        FM_LIST+=("${sd[@]}")
    fi
    FM_LEN=${#FM_LIST[@]}

    # 光标/窗口越界修正
    if (( FM_LEN > 0 )); then
        (( FM_CURSOR >= FM_LEN )) && FM_CURSOR=$((FM_LEN - 1))
    else
        FM_CURSOR=0
    fi
    (( FM_OFFSET > FM_CURSOR )) && FM_OFFSET=${FM_CURSOR}
    if (( FM_CURSOR - FM_OFFSET >= FM_WINH )); then
        FM_OFFSET=$(( FM_CURSOR - FM_WINH + 1 ))
    fi
    (( FM_OFFSET < 0 )) && FM_OFFSET=0
    return 0
}

# ------------------------------------------------------------
# 全屏渲染（顶部标题 + 工具栏 + 列表 + 底部状态/帮助）
# ------------------------------------------------------------
fm_render() {
    local rows cols
    # 从 /dev/tty 读取终端行列：stty size 默认从 stdin 读，在嵌套/重定向/某些
    # 终端组合下会拿到错误值，导致列表窗口高度与鼠标坐标错位——即"布局乱 + 点击位置不符"
    if [[ -e /dev/tty ]]; then
        local sz=""
        sz=$(stty size < /dev/tty 2>/dev/null) || sz=""
        rows=$(printf '%s' "${sz}" | awk '{print $1}')
        cols=$(printf '%s' "${sz}" | awk '{print $2}')
    fi
    rows=${rows:-24}; cols=${cols:-80}
    (( rows < 12 )) && rows=12
    (( cols < 40 )) && cols=40
    # 布局：标题(1)+工具栏(2)+表头(3)+列表(4..rows-3)+状态行(rows-1)+帮助行(rows)
    # 列表从第 4 行起，无空白缝隙；FM_WINH 即列表窗口高度
    FM_WINH=$(( rows - 5 ))
    (( FM_WINH < 4 )) && FM_WINH=4

    local i r

    # 标题行
    printf '\e[H\e[30;47m ZETOPS 文件管理器 v%s │ %s \e[0m\e[K\n' "${module_version}" "$(fm_icon_path "${FM_PWD}")"

    # 工具栏（记录点击区域）
    FM_TOOLBAR_BOXES=()
    local tb_id=(back up ref new srch bm tree copy cut paste ren del quit)
    local tb_lb=("返回" "上级" "刷新" "新建" "搜索" "书签" "目录树" "复制" "剪切" "粘贴" "改名" "删除" "退出")
    local col=1 w
    printf '\e[44;37m'
    for ((i = 0; i < ${#tb_id[@]}; i++)); do
        w=$(fm_str_w "[${tb_lb[$i]}]")
        FM_TOOLBAR_BOXES+=("${col}|${w}|${tb_id[$i]}")
        printf '[%s] ' "${tb_lb[$i]}"
        col=$(( col + w + 1 ))
    done
    printf '\e[0m\e[K\n'

    # 表头（与列表列宽对齐：名称列占 cols-28，右侧为大小/权限）
    local hdr_budget=$(( cols - 28 ))
    (( hdr_budget < 10 )) && hdr_budget=10
    printf '\e[33m  %-*s%s\e[0m\e[K\n' "$(( hdr_budget - 2 ))" "名称" " 大小 权限"

    # 文件列表窗口
    local idx item type rest name full prefix p size perm mtime name_disp
    for ((r = 0; r < FM_WINH; r++)); do
        idx=$(( FM_OFFSET + r ))
        printf '\e[%d;1H\e[K' $(( 4 + r ))
        (( idx >= FM_LEN )) && continue
        item="${FM_LIST[$idx]}"
        type="${item%%|*}"; rest="${item#*|}"; name="${rest%%|*}"; full="${rest#*|}"
        prefix="  "
        [[ "${idx}" == "${FM_CURSOR}" ]] && prefix="▶ "
        for p in "${FM_MARKED[@]}"; do
            if [[ "${p}" == "${full}" ]]; then
                [[ "${prefix}" == "▶ " ]] && prefix="▶✓" || prefix="✓ "
                break
            fi
        done
        size=""; perm=""
        if [[ "${type}" == "F" ]]; then
            # 单次 stat 同时取大小与权限，避免每个文件两次系统调用（大目录渲染提速）
            local _sz _pm
            read -r _sz _pm < <(stat -c '%s %A' "${full}" 2>/dev/null || true)
            _sz="${_sz:-0}"; _pm="${_pm:-?}"
            size=$(fm_human_size "${_sz}")
            perm="${_pm}"
        fi
        name_disp="${name}"
        [[ "${type}" == "D" ]] && name_disp="${name}/"
        local budget=$(( cols - 28 ))
        (( budget < 10 )) && budget=10
        if (( $(fm_str_w "${name_disp}") > budget )); then
            name_disp="$(fm_str_clip "${name_disp}" "${budget}")"
        fi
        if [[ "${type}" == "D" ]]; then
            printf '\e[36m%s %s\e[0m\e[K\n' "${prefix}" "${name_disp}"
        else
            local meta=""
            [[ -n "${size}" || -n "${perm}" ]] && meta="${size} ${perm}"
            local pad=$(( cols - 2 - $(fm_str_w "${name_disp}") - $(fm_str_w "${meta}") - 2 ))
            (( pad < 1 )) && pad=1
            printf '\e[32m%s %s\e[0m%*s\e[90m%s\e[0m\e[K\n' "${prefix}" "${name_disp}" "${pad}" "" "${meta}"
        fi
    done

    # 状态行
    local clip_txt="剪贴板: 空" marked_txt="标记: ${#FM_MARKED[@]}"
    if [[ -n "${FM_CLIP_MODE}" && ${#FM_CLIP_LIST[@]} -gt 0 ]]; then
        clip_txt="剪贴板: ${FM_CLIP_MODE} ${#FM_CLIP_LIST[@]} 项"
    fi
    printf '\e[%d;1H\e[K\e[30;47m %s │ %s │ %s\e[0m' $(( rows - 1 )) "${clip_txt}" "${marked_txt}" "${FM_STATUS_MSG}"
    FM_STATUS_MSG=""

    # 帮助行
    printf '\e[%d;1H\e[K\e[90m ↑↓选择 Enter/双击打开 ←返回 Space多选 c复制 x剪切 v粘贴 d删除 a操作 n新建 f搜索 b书签 t目录树 q退出\e[0m' "${rows}"

    # 光标放回当前行
    printf '\e[%d;1H' $(( 4 + FM_CURSOR - FM_OFFSET ))
}

# ------------------------------------------------------------
# 光标移动（带滚动）
# 参数：$1 增量（负=上）
# ------------------------------------------------------------
fm_cursor_move() {
    local delta="$1" nc
    (( FM_LEN == 0 )) && return
    nc=$(( FM_CURSOR + delta ))
    (( nc < 0 )) && nc=0
    (( nc >= FM_LEN )) && nc=$(( FM_LEN - 1 ))
    FM_CURSOR=${nc}
    if (( FM_CURSOR < FM_OFFSET )); then
        FM_OFFSET=${FM_CURSOR}
    fi
    if (( FM_CURSOR - FM_OFFSET >= FM_WINH )); then
        FM_OFFSET=$(( FM_CURSOR - FM_WINH + 1 ))
    fi
}

# ------------------------------------------------------------
# 当前光标条目完整路径
# 输出：路径（空=无条目）
# ------------------------------------------------------------
fm_cur_full() {
    if (( FM_CURSOR < FM_LEN )); then
        local rest="${FM_LIST[$FM_CURSOR]#*|}"
        echo "${rest#*|}"
    fi
}

# ------------------------------------------------------------
# 光标是否位于上级目录（../）项
# 说明：../ 项的 full 是父目录路径，任何删除/标记/复制/剪切/
#       重命名/权限修改都不应作用到它，否则会误操作整个父目录
# 返回：0=是上级目录  1=否
# ------------------------------------------------------------
fm_cur_is_parent() {
    [[ "${FM_LIST[${FM_CURSOR}]:-}" == "D|..|"* ]]
}

# ------------------------------------------------------------
# 打开光标条目：目录→进入；文件→快捷操作菜单
# ------------------------------------------------------------
fm_open_cursor() {
    local full
    full=$(fm_cur_full)
    [[ -z "${full}" ]] && return
    if [[ -d "${full}" ]]; then
        FM_PWD="${full}"
        FM_CURSOR=0; FM_OFFSET=0
    else
        fm_tui_do fm_operate_single "${full}" "$(basename "${full}")"
    fi
}

# ------------------------------------------------------------
# 切换光标条目多选标记
# ------------------------------------------------------------
fm_toggle_mark() {
    local full
    if fm_cur_is_parent; then
        FM_STATUS_MSG="上级目录 ../ 不可标记"
        return
    fi
    full=$(fm_cur_full)
    [[ -z "${full}" ]] && return
    local i p
    for i in "${!FM_MARKED[@]}"; do
        if [[ "${FM_MARKED[$i]}" == "${full}" ]]; then
            unset 'FM_MARKED[$i]'
            FM_MARKED=("${FM_MARKED[@]}")
            return
        fi
    done
    FM_MARKED+=("${full}")
}

# ============================================================
# 剪贴板（复制/剪切/粘贴）
# ============================================================

# ------------------------------------------------------------
# 读剪贴板文件（第一行模式，其余为路径）
# ------------------------------------------------------------
fm_clip_read() {
    FM_CLIP_MODE=""; FM_CLIP_LIST=()
    [[ -f "${FM_CLIPBOARD}" ]] || return
    local line="" i=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        i=$((i + 1))
        if (( i == 1 )); then
            FM_CLIP_MODE="${line}"
        else
            FM_CLIP_LIST+=("${line}")
        fi
    done < "${FM_CLIPBOARD}"
}

# ------------------------------------------------------------
# 写入剪贴板：光标条目 + 已标记条目
# 参数：$1 模式 copy/cut
# ------------------------------------------------------------
fm_clip_set() {
    local mode="$1" paths=() cur="" p
    if fm_cur_is_parent; then
        FM_STATUS_MSG="上级目录 ../ 不可复制/剪切"
        return
    fi
    cur=$(fm_cur_full)
    [[ -n "${cur}" ]] && paths+=("${cur}")
    for p in "${FM_MARKED[@]}"; do
        [[ "${p}" != "${cur}" ]] && paths+=("${p}")
    done
    if (( ${#paths[@]} == 0 )); then
        FM_STATUS_MSG="无选中条目，请用 ↑↓ 移动或 Space 标记"
        return
    fi
    mkdir -p "$(dirname "${FM_CLIPBOARD}")" 2>/dev/null || true
    printf '%s\n' "${mode}" > "${FM_CLIPBOARD}"
    printf '%s\n' "${paths[@]}" >> "${FM_CLIPBOARD}"
    FM_CLIP_MODE="${mode}"
    FM_CLIP_LIST=("${paths[@]}")
    FM_STATUS_MSG="已${mode} ${#paths[@]} 项，按 v 粘贴"
    audit_log "剪贴板${mode} ${#paths[@]}项" "成功"
}

# ------------------------------------------------------------
# 粘贴：copy=复制 cut=移动，目标为当前目录
# ------------------------------------------------------------
fm_clip_paste() {
    fm_clip_read
    if [[ -z "${FM_CLIP_MODE}" || ${#FM_CLIP_LIST[@]} -eq 0 ]]; then
        echo "  剪贴板为空，请先在文件管理器中 c/x 复制或剪切"
        press_enter
        return
    fi
    echo "  将${FM_CLIP_MODE} ${#FM_CLIP_LIST[@]} 项 → $(fm_icon_path "${FM_PWD}")"
    local p name target
    for p in "${FM_CLIP_LIST[@]}"; do
        echo "    - ${p}"
    done
    echo ""
    if ! confirm_action "执行${FM_CLIP_MODE}粘贴？"; then
        return
    fi
    local ok=0 fail=0
    for p in "${FM_CLIP_LIST[@]}"; do
        [[ -e "${p}" ]] || { echo "   跳过（不存在）: ${p}"; fail=$((fail + 1)); continue; }
        name=$(basename "${p}")
        target="${FM_PWD}/${name}"
        if [[ "${FM_CLIP_MODE}" == "cut" ]]; then
            if [[ "$(dirname "${p}")" == "${FM_PWD}" ]]; then
                echo "   跳过（同目录）: ${name}"
                continue
            fi
            if mv "${p}" "${target}" 2>/dev/null; then ok=$((ok + 1)); else fail=$((fail + 1)); echo "   移动失败: ${p}"; fi
        else
            if cp -r "${p}" "${target}" 2>/dev/null; then ok=$((ok + 1)); else fail=$((fail + 1)); echo "   复制失败: ${p}"; fi
        fi
    done
    echo "  完成：成功 ${ok}，失败 ${fail}"
    audit_log "粘贴(${FM_CLIP_MODE}) 成功${ok}/失败${fail}" "成功"
    if [[ "${FM_CLIP_MODE}" == "cut" ]]; then
        : > "${FM_CLIPBOARD}"
        FM_CLIP_MODE=""; FM_CLIP_LIST=()
    fi
    press_enter
}

# ------------------------------------------------------------
# 删除：光标条目 + 已标记条目（危险保护）
# ------------------------------------------------------------
fm_delete_marked() {
    local paths=() cur="" p
    if fm_cur_is_parent; then
        echo "  上级目录 ../ 不可删除"
        press_enter
        return
    fi
    cur=$(fm_cur_full)
    [[ -n "${cur}" ]] && paths+=("${cur}")
    for p in "${FM_MARKED[@]}"; do
        [[ "${p}" != "${cur}" ]] && paths+=("${p}")
    done
    if (( ${#paths[@]} == 0 )); then
        echo "  无选中条目"
        press_enter
        return
    fi
    echo "  将删除 ${#paths[@]} 项："
    for p in "${paths[@]}"; do
        echo "    - ${p}"
    done
    echo ""
    if ! confirm_action "确认删除？此操作不可恢复"; then
        return
    fi
    local ok=0 fail=0
    for p in "${paths[@]}"; do
        if rm -rf "${p}" 2>/dev/null; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            echo "   删除失败: ${p}"
        fi
    done
    echo "  删除完成：成功 ${ok}，失败 ${fail}"
    audit_log "批量删除 ${ok} 项" "成功"
    FM_MARKED=()
    press_enter
}

# ============================================================
# 鼠标事件处理
# ============================================================

# ------------------------------------------------------------
# 命中工具栏按钮
# 参数：$1 列号
# 输出：按钮 id（无命中则空）
# ------------------------------------------------------------
fm_toolbar_hit() {
    local x="$1" line id start w
    for line in "${FM_TOOLBAR_BOXES[@]}"; do
        start="${line%%|*}"
        w="${line#*|}"
        id="${w#*|}"
        w="${w%%|*}"
        if (( x >= start && x < start + w )); then
            echo "${id}"
            return
        fi
    done
}

# ------------------------------------------------------------
# 工具栏按钮动作
# 参数：$1 按钮 id
# ------------------------------------------------------------
fm_toolbar_action() {
    local id="$1"
    case "${id}" in
        back|up) fm_go_parent; FM_CURSOR=0; FM_OFFSET=0 ;;
        ref) : ;;
        new) fm_tui_do fm_mkdir_prompt ;;
        srch) fm_tui_do fm_search ;;
        bm) fm_tui_do fm_bookmark_menu ;;
        tree) fm_tui_do fm_tree_menu ;;
        copy) fm_clip_set "copy" ;;
        cut) fm_clip_set "cut" ;;
        paste) fm_tui_do fm_clip_paste ;;
        ren) fm_tui_do fm_rename_file "$(fm_cur_full)" ;;
        del) fm_tui_do fm_delete_marked ;;
        quit) FM_QUIT=1 ;;
        *) : ;;
    esac
}

# ------------------------------------------------------------
# 鼠标事件分发：滚轮/左键/工具栏/列表行（双击打开）
# ------------------------------------------------------------
fm_handle_mouse() {
    local b="${FM_EVB}" x="${FM_EVX}" y="${FM_EVY}" idx now
    # 仅处理按下事件，忽略释放/拖拽/修饰/右键
    if (( FM_EVPRESS == 0 )); then return; fi
    # 滚轮
    if (( b == 64 )); then fm_cursor_move -1; return; fi
    if (( b == 65 )); then fm_cursor_move 1; return; fi
    # 仅处理左键（忽略拖拽/修饰/右键）
    if (( b != 0 )); then return; fi
    # 工具栏（第 2 行）
    if (( y == 2 )); then
        local hit
        hit=$(fm_toolbar_hit "${x}")
        [[ -n "${hit}" ]] && fm_toolbar_action "${hit}"
        return
    fi
    # 列表区（从第 4 行开始）
    if (( y >= 4 )); then
        idx=$(( FM_OFFSET + y - 4 ))
        (( idx >= FM_LEN )) && return
        now=$(date +%s 2>/dev/null || echo 0)
        if [[ "${idx}" == "${FM_DBL_ROW}" && $(( now - FM_DBL_TIME )) -lt 1 ]]; then
            # 双击：打开
            FM_CURSOR=${idx}
            fm_open_cursor
            FM_DBL_ROW=-1; FM_DBL_TIME=0
        else
            FM_CURSOR=${idx}
            FM_DBL_ROW=${idx}
            FM_DBL_TIME=${now}
        fi
    fi
}

# ============================================================
# 键盘/鼠标事件总分发（返回非零=退出 TUI）
# ============================================================
fm_handle_event() {
    if [[ "${FM_EV}" == "mouse" ]]; then
        fm_handle_mouse
        return 0
    fi
    case "${FM_EVK}" in
        q|Q|QUIT) return 1 ;;
        ESC|LEFT|BACK) fm_go_parent; FM_CURSOR=0; FM_OFFSET=0 ;;
        UP) fm_cursor_move -1 ;;
        DOWN) fm_cursor_move 1 ;;
        PAGEUP) fm_cursor_move -FM_WINH ;;
        PAGEDOWN) fm_cursor_move FM_WINH ;;
        HOME) FM_CURSOR=0; FM_OFFSET=0 ;;
        END) FM_CURSOR=$(( FM_LEN - 1 )); FM_OFFSET=0 ;;
        ENTER|RIGHT) fm_open_cursor ;;
        SPACE) fm_toggle_mark ;;
        r|R) : ;;
        f|F|/) fm_tui_do fm_search ;;
        c|C) fm_clip_set "copy" ;;
        x|X) fm_clip_set "cut" ;;
        v|V) fm_tui_do fm_clip_paste ;;
        d|D) fm_tui_do fm_delete_marked ;;
        a|A) fm_tui_do fm_action_menu ;;
        b|B) fm_tui_do fm_bookmark_menu ;;
        t|T) fm_tui_do fm_tree_menu ;;
        m|M) if fm_cur_is_parent; then FM_STATUS_MSG="上级目录 ../ 不可修改权限"; else fm_tui_do fm_chmod_file "$(fm_cur_full)"; fi ;;
        n|N) fm_tui_do fm_mkdir_prompt ;;
        e|E) if fm_cur_is_parent; then FM_STATUS_MSG="上级目录 ../ 不可编辑"; else fm_tui_do fm_edit_file "$(fm_cur_full)"; fi ;;
        o|O) if fm_cur_is_parent; then FM_STATUS_MSG="上级目录 ../ 不可查看"; else fm_tui_do fm_view_file "$(fm_cur_full)"; fi ;;
        *) : ;;
    esac
    return 0
}

# ============================================================
# 主循环
# ============================================================
fm_main() {
    # 校验初始目录
    [[ -d "${FM_PWD}" ]] || FM_PWD="${HOME}"
    if [[ ! -t 0 ]]; then
        echo "文件管理器 TUI 需要 TTY 终端运行（请直接登录终端后执行）"
        return 1
    fi
    FM_LIST=(); FM_LEN=0
    FM_CURSOR=0; FM_OFFSET=0; FM_WINH=10
    FM_MARKED=(); FM_CLIP_MODE=""; FM_CLIP_LIST=()
    FM_TOOLBAR_BOXES=(); FM_STATUS_MSG=""; FM_QUIT=0
    FM_DBL_ROW=-1; FM_DBL_TIME=0

    fm_tui_enter
    while (( FM_QUIT == 0 )); do
        fm_refresh_list
        fm_render
        fm_read_event
        if ! fm_handle_event; then
            break
        fi
    done
    fm_tui_leave
    return 0
}

# ============================================================
# 通用工具
# ============================================================

# ------------------------------------------------------------
# 路径显示（home 缩写）
# 参数：$1 路径
# 输出：显示用路径
# ------------------------------------------------------------
fm_icon_path() {
    local p="$1"
    if [[ "${p}" == "${HOME}" ]]; then
        echo "~"
    elif [[ "${p}" == "${HOME}"/* ]]; then
        echo "~/${p#"${HOME}"/}"
    else
        echo "${p}"
    fi
}

# ------------------------------------------------------------
# 人类可读大小
# 参数：$1 字节数
# ------------------------------------------------------------
fm_human_size() {
    local b="$1"
    if (( b >= 1073741824 )); then
        awk -v n="${b}" 'BEGIN{printf "%.1fG", n/1073741824}'
    elif (( b >= 1048576 )); then
        awk -v n="${b}" 'BEGIN{printf "%.1fM", n/1048576}'
    elif (( b >= 1024 )); then
        awk -v n="${b}" 'BEGIN{printf "%.1fK", n/1024}'
    else
        echo "${b}B"
    fi
}

# ------------------------------------------------------------
# 进入上级目录
# ------------------------------------------------------------
fm_go_parent() {
    FM_PWD="$(dirname "${FM_PWD}")"
}

# ------------------------------------------------------------
# 单文件快捷操作（Enter/双击/右键打开文件时）
# 参数：$1 完整路径  $2 显示名
# ------------------------------------------------------------
fm_operate_single() {
    local full="$1" name="$2"
    echo ""
    echo "  文件: ${name}"
    echo "  1. 查看内容   2. 编辑   3. 复制   4. 移动   5. 重命名"
    echo "  6. 删除       7. 修改权限"
    read_input op "选择操作" ""
    case "${op}" in
        1) fm_view_file "${full}" ;;
        2) fm_edit_file "${full}" ;;
        3) fm_copy_file "${full}" ;;
        4) fm_move_file "${full}" ;;
        5) fm_rename_file "${full}" ;;
        6) fm_delete_file "${full}" ;;
        7) fm_chmod_file "${full}" ;;
        *) return ;;
    esac
}

# ============================================================
# 操作菜单（对当前目录中的文件）
# ============================================================
fm_action_menu() {
    echo ""
    echo "  ${COLOR_BOLD}文件操作菜单（当前目录: $(fm_icon_path "${FM_PWD}")）${COLOR_RESET}"
    echo "  ${COLOR_GRAY}------------------------------------------------${COLOR_RESET}"
    echo "  1. 查看文件内容    2. 编辑文件        3. 复制文件"
    echo "  4. 移动文件        5. 重命名          6. 删除文件"
    echo "  7. 修改权限        8. 创建目录        9. 创建文件"
    echo "  a. 压缩打包        b. 解压            c. 目录树"
    echo "  0. 返回"
    echo "  ${COLOR_GRAY}------------------------------------------------${COLOR_RESET}"
    read_input act "选择操作" ""
    case "${act}" in
        1) fm_view_file "" ;;
        2) fm_edit_file "" ;;
        3) fm_copy_file "" ;;
        4) fm_move_file "" ;;
        5) fm_rename_file "" ;;
        6) fm_delete_file "" ;;
        7) fm_chmod_file "" ;;
        8) fm_mkdir_prompt ;;
        9) fm_touch_prompt ;;
        a) fm_compress_prompt ;;
        b) fm_extract_prompt ;;
        c) fm_tree_menu ;;
        *) return ;;
    esac
}

# ------------------------------------------------------------
# 交互选择文件（从当前目录列出）
# 参数：$1 提示语
# 输出：所选文件完整路径（空=取消）
# ------------------------------------------------------------
fm_pick_file() {
    local prompt="$1"
    local files=()
    local f i=0
    for f in "${FM_PWD}"/*; do
        [[ -f "${f}" ]] && files+=("$(basename "${f}")")
    done
    if (( ${#files[@]} == 0 )); then
        log_warning "当前目录没有文件"
        return 1
    fi
    echo ""
    echo "  ${COLOR_BOLD}当前目录文件:${COLOR_RESET}"
    for ((i = 0; i < ${#files[@]}; i++)); do
        echo "  [$((i + 1))] ${files[$i]}"
    done
    echo ""
    read_input sel "${prompt}（输入序号或文件名）" ""
    [[ -z "${sel}" ]] && return 1
    if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#files[@]} )); then
        echo "${FM_PWD}/${files[$((sel - 1))]}"
        return 0
    fi
    if [[ -f "${FM_PWD}/${sel}" ]]; then
        echo "${FM_PWD}/${sel}"
        return 0
    fi
    log_error "文件不存在: ${sel}"
    return 1
}

# ------------------------------------------------------------
# 1. 查看文件内容（文本前 40 行，二进制提示）
# 参数：$1 完整路径（空=交互选择）
# ------------------------------------------------------------
fm_view_file() {
    local full="$1"
    [[ -z "${full}" ]] && { full="$(fm_pick_file "查看哪个文件")"; }
    [[ -z "${full}" ]] && return
    [[ -f "${full}" ]] || { log_error "不是文件"; return; }
    local ftype
    ftype=$(file -b "${full}" 2>/dev/null || echo "unknown")
    if echo "${ftype}" | grep -qiE 'text|script|json|xml|config|empty|shell'; then
        echo ""
        echo "  ${COLOR_BOLD}--- ${full} (${ftype}) ---${COLOR_RESET}"
        local lines
        lines=$(wc -l < "${full}" 2>/dev/null | tr -d ' ')
        if (( lines > 40 )); then
            echo "  ${COLOR_GRAY}文件共 ${lines} 行，显示前 40 行${COLOR_RESET}"
            head -40 "${full}" | sed 's/^/  /'
        else
            cat "${full}" | sed 's/^/  /'
        fi
        echo ""
        if (( lines > 40 )); then
            echo "  ${COLOR_GRAY}查看完整内容请用: less ${full}${COLOR_RESET}"
        fi
    else
        echo ""
        echo "  ${COLOR_YELLOW}⚠️  二进制文件: ${ftype}，无法直接查看${COLOR_RESET}"
        local size
        size=$(fm_human_size "$(stat -c%s "${full}" 2>/dev/null || echo 0)")
        echo "  ${COLOR_GRAY}大小: ${size}  建议用 less/xxd 查看${COLOR_RESET}"
    fi
    echo ""
    press_enter
}

# ------------------------------------------------------------
# 2. 编辑文件（nano 优先，vi 回退）
# 参数：$1 完整路径（空=交互选择）
# ------------------------------------------------------------
fm_edit_file() {
    local full="$1"
    [[ -z "${full}" ]] && { full="$(fm_pick_file "编辑哪个文件")"; }
    [[ -z "${full}" ]] && return
    [[ -f "${full}" ]] || { log_error "不是文件"; return; }
    if check_command nano; then
        nano "${full}"
    elif check_command vi; then
        vi "${full}"
    else
        log_error "未找到 nano/vi 编辑器"
        return
    fi
    log_success "编辑完成: ${full}"
    audit_log "编辑文件 ${full}" "成功"
}

# ------------------------------------------------------------
# 3. 复制文件
# 参数：$1 完整路径（空=交互选择）
# ------------------------------------------------------------
fm_copy_file() {
    local full="$1"
    [[ -z "${full}" ]] && { full="$(fm_pick_file "复制哪个文件")"; }
    [[ -z "${full}" ]] && return
    read_input dest "目标路径（默认当前目录副本）" ""
    local target
    if [[ -z "${dest}" ]]; then
        local base
        base=$(basename "${full}")
        target="${FM_PWD}/副本_${base}"
    else
        if [[ "${dest}" == /* ]]; then
            target="${dest}"
        else
            target="${FM_PWD}/${dest}"
        fi
    fi
    if [[ -d "${target}" ]]; then
        cp -r "${full}" "${target}/" 2>/dev/null
    else
        cp -r "${full}" "${target}" 2>/dev/null
    fi
    log_success "已复制 → ${target}"
    audit_log "复制 ${full} → ${target}" "成功"
}

# ------------------------------------------------------------
# 4. 移动文件
# ------------------------------------------------------------
fm_move_file() {
    local full="$1"
    [[ -z "${full}" ]] && { full="$(fm_pick_file "移动哪个文件")"; }
    [[ -z "${full}" ]] && return
    read_input dest "目标路径" ""
    [[ -z "${dest}" ]] && return
    local target
    if [[ "${dest}" == /* ]]; then
        target="${dest}"
    else
        target="${FM_PWD}/${dest}"
    fi
    if ! mv "${full}" "${target}" 2>/dev/null; then
        log_error "移动失败（目标存在或权限不足）"
        return
    fi
    log_success "已移动 → ${target}"
    audit_log "移动 ${full} → ${target}" "成功"
}

# ------------------------------------------------------------
# 5. 重命名
# ------------------------------------------------------------
fm_rename_file() {
    local full="$1"
    [[ -z "${full}" ]] && { full="$(fm_pick_file "重命名哪个文件")"; }
    [[ -z "${full}" ]] && return
    local old_name new_name
    old_name=$(basename "${full}")
    read_input new_name "新名称" ""
    [[ -z "${new_name}" ]] && return
    if mv "${full}" "${FM_PWD}/${new_name}" 2>/dev/null; then
        log_success "已重命名: ${old_name} → ${new_name}"
        audit_log "重命名 ${old_name} → ${new_name}" "成功"
    else
        log_error "重命名失败（同名文件存在或权限不足）"
    fi
}

# ------------------------------------------------------------
# 6. 删除文件（危险保护）
# ------------------------------------------------------------
fm_delete_file() {
    local full="$1"
    [[ -z "${full}" ]] && { full="$(fm_pick_file "删除哪个文件")"; }
    [[ -z "${full}" ]] && return
    [[ -e "${full}" ]] || { log_error "文件不存在"; return; }

    local size
    size=$(fm_human_size "$(stat -c%s "${full}" 2>/dev/null || echo 0)")
    echo ""
    echo "  ${COLOR_YELLOW}删除确认: ${full} (${size})${COLOR_RESET}"
    if confirm_action "确认删除？此操作不可恢复"; then
        rm -rf "${full}" 2>/dev/null && {
            log_success "已删除: ${full}"
            audit_log "删除 ${full}" "成功"
        } || log_error "删除失败（权限不足）"
    fi
}

# ------------------------------------------------------------
# 7. 修改权限
# ------------------------------------------------------------
fm_chmod_file() {
    local full="$1"
    [[ -z "${full}" ]] && { full="$(fm_pick_file "修改哪个文件")"; }
    [[ -z "${full}" ]] && return
    local current
    current=$(stat -c '%A (%a)' "${full}" 2>/dev/null || echo "?")
    echo "  当前权限: ${current}"
    read_input mode "输入权限（如 644/755）" ""
    [[ -z "${mode}" ]] && return
    if chmod "${mode}" "${full}" 2>/dev/null; then
        log_success "权限已修改: ${mode}"
        audit_log "chmod ${mode} ${full}" "成功"
    else
        log_error "修改权限失败（无权限或模式无效）"
    fi
}

# ------------------------------------------------------------
# 8. 创建目录
# ------------------------------------------------------------
fm_mkdir_prompt() {
    read_input dirname "新目录名" ""
    [[ -z "${dirname}" ]] && return
    mkdir -p "${FM_PWD}/${dirname}" 2>/dev/null && {
        log_success "目录已创建: ${FM_PWD}/${dirname}"
        audit_log "创建目录 ${dirname}" "成功"
    } || log_error "创建失败"
}

# ------------------------------------------------------------
# 9. 创建文件
# ------------------------------------------------------------
fm_touch_prompt() {
    read_input filename "新文件名" ""
    [[ -z "${filename}" ]] && return
    touch "${FM_PWD}/${filename}" 2>/dev/null && {
        log_success "文件已创建: ${FM_PWD}/${filename}（可用菜单 2 编辑）"
        audit_log "创建文件 ${filename}" "成功"
    } || log_error "创建失败"
}

# ------------------------------------------------------------
# a. 压缩打包（tar.gz/zip 自动判断）
# ------------------------------------------------------------
fm_compress_prompt() {
    local items=()
    local f i=0
    for f in "${FM_PWD}"/*; do
        [[ -e "${f}" ]] && items+=("$(basename "${f}")")
    done
    if (( ${#items[@]} == 0 )); then
        log_warning "当前目录为空，无可打包内容"
        return
    fi
    echo ""
    echo "  可打包条目:"
    for ((i = 0; i < ${#items[@]}; i++)); do
        echo "  [$((i + 1))] ${items[$i]}"
    done
    read_input sel "选择条目（序号/名称，留空打包全部）" ""
    local target=""
    if [[ -n "${sel}" ]]; then
        if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#items[@]} )); then
            target="${items[$((sel - 1))]}"
        else
            target="${sel}"
        fi
    fi
    read_input arc_name "归档文件名（默认 backup_$(date +%Y%m%d_%H%M%S).tar.gz）" "backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    local arc_path="${FM_PWD}/${arc_name}"
    if [[ "${arc_name}" == *.zip ]]; then
        check_command zip || { log_error "未安装 zip，请先安装"; return; }
        if [[ -n "${target}" ]]; then
            zip -r "${arc_path}" "${FM_PWD}/${target}" >/dev/null 2>&1
        else
            (cd "${FM_PWD}" && zip -r "${arc_name}" . >/dev/null 2>&1)
        fi
    else
        if [[ -n "${target}" ]]; then
            tar -czf "${arc_path}" -C "${FM_PWD}" "${target}" 2>/dev/null
        else
            tar -czf "${arc_path}" -C "${FM_PWD}" . 2>/dev/null
        fi
    fi
    if [[ -f "${arc_path}" ]]; then
        log_success "已打包: ${arc_path} ($(fm_human_size "$(stat -c%s "${arc_path}")"))"
        audit_log "压缩 ${target:-全部} → ${arc_name}" "成功"
    else
        log_error "打包失败"
    fi
}

# ------------------------------------------------------------
# b. 解压
# ------------------------------------------------------------
fm_extract_prompt() {
    local full
    full=$(fm_pick_file "解压哪个压缩包") || return
    [[ -z "${full}" ]] && return
    read_input extract_to "解压到（留空=当前目录）" ""
    local dest="${FM_PWD}"
    if [[ -n "${extract_to}" ]]; then
        if [[ "${extract_to}" == /* ]]; then
            dest="${extract_to}"
        else
            dest="${FM_PWD}/${extract_to}"
        fi
    fi
    mkdir -p "${dest}" 2>/dev/null || true
    case "${full}" in
        *.tar.gz|*.tgz) tar -xzf "${full}" -C "${dest}" 2>/dev/null ;;
        *.tar.bz2)      tar -xjf "${full}" -C "${dest}" 2>/dev/null ;;
        *.tar)          tar -xf "${full}" -C "${dest}" 2>/dev/null ;;
        *.zip)          check_command unzip || { log_error "未安装 unzip"; return; }
                        unzip -q "${full}" -d "${dest}" 2>/dev/null ;;
        *.gz)           gunzip -k "${full}" 2>/dev/null ;;
        *)              log_error "不支持的压缩格式"; return ;;
    esac
    log_success "已解压 → ${dest}"
    audit_log "解压 ${full} → ${dest}" "成功"
}

# ------------------------------------------------------------
# 目录树递归渲染（内部）
# 参数：$1 目录  $2 前缀  $3 深度  $4 最大深度  $5 文件计数
# 输出：目录树（stdout）
# ------------------------------------------------------------
fm_tree_walk() {
    local dir="$1" prefix="$2" depth="$3" max_depth="$4"
    local -n cnt="$5"
    (( depth >= max_depth )) && return
    (( cnt > 500 )) && { echo "${prefix}${COLOR_GRAY}... (条目过多，已截断)${COLOR_RESET}"; return; }

    local entries=()
    local f
    for f in "${dir}"/*; do
        [[ -e "${f}" ]] && entries+=("$(basename "${f}")")
    done 2>/dev/null || true
    local total=${#entries[@]}
    local i=0 name
    for name in "${entries[@]}"; do
        i=$((i + 1))
        cnt=$((cnt + 1))
        local connector="├── "
        [[ "${i}" == "${total}" ]] && connector="└── "
        local child_prefix="${prefix}│   "
        [[ "${i}" == "${total}" ]] && child_prefix="${prefix}    "
        local full="${dir}/${name}"
        if [[ -d "${full}" ]]; then
            echo "${prefix}${connector}${COLOR_BLUE}📁 ${name}/${COLOR_RESET}"
            fm_tree_walk "${full}" "${child_prefix}" "$((depth + 1))" "${max_depth}" cnt
        else
            local size
            size=$(fm_human_size "$(stat -c%s "${full}" 2>/dev/null || echo 0)")
            echo "${prefix}${connector}${COLOR_GREEN}📄 ${name}${COLOR_RESET} ${COLOR_GRAY}(${size})${COLOR_RESET}"
        fi
    done
}

# ------------------------------------------------------------
# 目录树查看（tree 风格，无需 tree 命令）
# ------------------------------------------------------------
fm_tree_menu() {
    local max_depth=3
    echo ""
    read_input depth_input "目录树深度（默认 3，最大 6）" "3"
    max_depth="${depth_input:-3}"
    (( max_depth > 6 )) && max_depth=6
    echo ""
    echo "  ${COLOR_BOLD}📁 $(fm_icon_path "${FM_PWD}")${COLOR_RESET}"
    local count=0
    fm_tree_walk "${FM_PWD}" "" 0 "${max_depth}" count
    echo ""
    echo "  ${COLOR_GRAY}--- 显示 ${count} 个条目（深度 ${max_depth}）---${COLOR_RESET}"
    press_enter
}

# ------------------------------------------------------------
# 搜索文件（当前目录递归）
# ------------------------------------------------------------
fm_search() {
    read_input keyword "搜索关键词（文件名包含）" ""
    [[ -z "${keyword}" ]] && return
    echo ""
    log_info "在 $(fm_icon_path "${FM_PWD}") 中搜索 *${keyword}* ..."
    local results
    results=$(find "${FM_PWD}" -maxdepth 4 -name "*${keyword}*" 2>/dev/null | head -30 || true)
    if [[ -n "${results}" ]]; then
        echo "${results}" | sed 's/^/  /'
        echo ""
        echo "  ${COLOR_GRAY}--- 共 $(echo "${results}" | wc -l | tr -d ' ') 条（最多显示 30 条）---${COLOR_RESET}"
    else
        echo "  ${COLOR_GRAY}(未找到匹配文件)${COLOR_RESET}"
    fi
    press_enter
}

# ------------------------------------------------------------
# 书签管理
# ------------------------------------------------------------
fm_bookmark_menu() {
    echo ""
    echo "  ${COLOR_BOLD}书签管理${COLOR_RESET}"
    echo "  ${COLOR_GRAY}------------------------------------------------${COLOR_RESET}"
    if [[ -f "${FM_BOOKMARKS}" ]]; then
        local i=0 line
        while read -r line; do
            [[ -z "${line}" ]] && continue
            i=$((i + 1))
            echo "  [$((i + 1))] ${line}"
        done < "${FM_BOOKMARKS}"
    else
        echo "  ${COLOR_GRAY}(暂无书签)${COLOR_RESET}"
    fi
    echo "  ${COLOR_GRAY}------------------------------------------------${COLOR_RESET}"
    echo "  1. 添加当前目录为书签"
    echo "  2. 跳转到书签"
    echo "  3. 删除书签"
    read_input bk_act "选择" ""
    case "${bk_act}" in
        1)
            mkdir -p "$(dirname "${FM_BOOKMARKS}")" 2>/dev/null || true
            if grep -qxF "${FM_PWD}" "${FM_BOOKMARKS}" 2>/dev/null; then
                log_warning "该书签已存在"
            else
                echo "${FM_PWD}" >> "${FM_BOOKMARKS}"
                log_success "已添加书签: ${FM_PWD}"
            fi
            ;;
        2)
            local n=0 line
            while read -r line; do
                [[ -z "${line}" ]] && continue
                n=$((n + 1))
                echo "  [$((n + 1))] ${line}"
            done < "${FM_BOOKMARKS}" 2>/dev/null
            read_input bk_idx "跳转到书签序号" ""
            if [[ -n "${bk_idx}" ]]; then
                local target
                target=$(sed -n "$((bk_idx - 1))p" "${FM_BOOKMARKS}" 2>/dev/null)
                if [[ -d "${target}" ]]; then
                    FM_PWD="${target}"
                else
                    log_error "书签路径不存在: ${target}"
                fi
            fi
            ;;
        3)
            local m=0 line
            while read -r line; do
                [[ -z "${line}" ]] && continue
                m=$((m + 1))
                echo "  [$((m + 1))] ${line}"
            done < "${FM_BOOKMARKS}" 2>/dev/null
            read_input bk_del "删除书签序号" ""
            if [[ -n "${bk_del}" ]]; then
                local del_line
                del_line=$(sed -n "$((bk_del - 1))p" "${FM_BOOKMARKS}" 2>/dev/null)
                sed -i "${bk_del}d" "${FM_BOOKMARKS}" 2>/dev/null
                log_success "已删除书签: ${del_line}"
            fi
            ;;
        *) return ;;
    esac
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
    fm_main
fi
