#!/bin/bash
# ============================================================
# ZETOPS 内置纯 Bash TUI 文本编辑器（零外部依赖）
# 不依赖 nano/vim/vi/ed，原生支持：光标移动/插入/删除/拆行/合并/
# 保存/退出/鼠标点击定位/中文宽字符/大文件滚动窗口。
# 依赖 core/utils.sh 的 fm_str_w/fm_str_clip（UTF-8 宽字符计算）。
# 由 core/main.sh 显式 source（不注册为独立模块，供文件管理器与
# 其他模块复用 tui_edit_file）。
# ============================================================
module_version="1.0.0"

# ---- 全局编辑状态 ----
ED_BUF=()        # 行数组（每行一个 UTF-8 字符串，无换行符）
ED_FILE=""       # 当前文件路径
ED_ROW=0         # 光标行（0-based）
ED_COL=0         # 光标列（字节偏移）
ED_TOP=0         # 可视窗口顶部行
ED_MOD=0         # 修改标记（1=有未保存修改）
ED_ROWS=24       # 终端行数
ED_COLS=80       # 终端列数
ED_GUTTER=6      # 行号列宽（nano 风格为 0，无行号）
ED_READONLY=0    # 只读标记
ED_HELP=0        # 帮助页模式
ED_UNDO=()       # 撤销栈（完整快照字符串；\x1e 行分隔、\x1f 元数据分隔）
ED_REDO=()       # 重做栈
ED_UNDO_LIMIT=100 # 撤销步数上限

# ------------------------------------------------------------
# 加载文件到行数组（容错：不存在/二进制仍可建空缓冲区）
# 参数：$1 路径
# ------------------------------------------------------------
ed_load() {
    ED_BUF=()
    ED_FILE="$1"
    ED_ROW=0; ED_COL=0; ED_TOP=0; ED_MOD=0; ED_READONLY=0
    ED_UNDO=(); ED_REDO=()   # 新文件清空撤销/重做栈
    ED_HELP=0
    if [[ -e "${ED_FILE}" ]]; then
        if [[ ! -w "${ED_FILE}" ]]; then
            ED_READONLY=1
        fi
        # 用 while read 逐行（保留空行；不解析二进制内容，仅作字节文本）
        local line=""
        while IFS= read -r line || [[ -n "${line}" ]]; do
            ED_BUF+=("${line}")
        done < "${ED_FILE}" 2>/dev/null
    fi
    if (( ${#ED_BUF[@]} == 0 )); then
        ED_BUF+=("")
    fi
    return 0
}

# ------------------------------------------------------------
# 保存缓冲到文件
# 返回：0=成功 1=失败/只读
# ------------------------------------------------------------
ed_save() {
    [[ "${ED_READONLY}" == "1" ]] && return 1
    local i
    : > "${ED_FILE}" 2>/dev/null || return 1
    for i in "${!ED_BUF[@]}"; do
        printf '%s\n' "${ED_BUF[$i]}" >> "${ED_FILE}" 2>/dev/null || return 1
    done
    ED_MOD=0
    return 0
}

# ------------------------------------------------------------
# 序列化当前编辑状态（行数组 + 光标 + 修改标记）
# 输出：单个字符串（行间 \x1e，元数据 \x1f）
# 说明：正常文本不含 \x1e/\x1f 控制字符，作为快照分隔安全
# ------------------------------------------------------------
ed_snapshot() {
    local out="" i
    for i in "${!ED_BUF[@]}"; do
        out+="${ED_BUF[$i]}"$'\x1e'
    done
    out+=$'\x1f'"${ED_ROW}"$'\x1f'"${ED_COL}"$'\x1f'"${ED_MOD}"
    printf '%s' "${out}"
}

# ------------------------------------------------------------
# 从快照恢复编辑状态
# 参数：$1 快照字符串
# ------------------------------------------------------------
ed_restore() {
    local snap="$1" body="" entry="" rest=""
    # 非贪婪：meta=第一个 \x1f 之后（ROW\x1fCOL\x1fMOD），body=第一个 \x1f 之前（行部分）
    local meta="${snap#*$'\x1f'}"
    body="${snap%%$'\x1f'*}"
    ED_BUF=()
    while [[ "${body}" == *$'\x1e'* ]]; do
        entry="${body%%$'\x1e'*}"
        ED_BUF+=("${entry}")
        body="${body#*$'\x1e'}"
    done
    if (( ${#ED_BUF[@]} == 0 )); then
        ED_BUF+=("")
    fi
    rest="${meta#*$'\x1f'}"
    ED_ROW="${meta%%$'\x1f'*}"
    ED_COL="${rest%%$'\x1f'*}"
    ED_MOD="${rest#*$'\x1f'}"
    return 0
}

# ------------------------------------------------------------
# 编辑前入撤销栈（在每次修改缓冲的操作前调用）
# 同时清空重做栈（新编辑使旧重做失效）
# ------------------------------------------------------------
ed_undo_push() {
    if (( ${#ED_UNDO[@]} >= ED_UNDO_LIMIT )); then
        ED_UNDO=("${ED_UNDO[@]:1}")
    fi
    ED_UNDO+=("$(ed_snapshot)")
    ED_REDO=()
    return 0
}

# ------------------------------------------------------------
# 撤销（Ctrl+Z）：恢复到上一次编辑前状态
# ------------------------------------------------------------
ed_undo() {
    if (( ${#ED_UNDO[@]} == 0 )); then
        return 0
    fi
    local last=$(( ${#ED_UNDO[@]} - 1 ))
    ED_REDO+=("$(ed_snapshot)")
    ed_restore "${ED_UNDO[$last]}"
    unset "ED_UNDO[$last]"
    ED_UNDO=("${ED_UNDO[@]}")
    ed_ensure_cursor
    return 0
}

# ------------------------------------------------------------
# 重做（Ctrl+Y）：恢复被撤销的编辑
# ------------------------------------------------------------
ed_redo() {
    if (( ${#ED_REDO[@]} == 0 )); then
        return 0
    fi
    local last=$(( ${#ED_REDO[@]} - 1 ))
    ED_UNDO+=("$(ed_snapshot)")
    ed_restore "${ED_REDO[$last]}"
    unset "ED_REDO[$last]"
    ED_REDO=("${ED_REDO[@]}")
    ed_ensure_cursor
    return 0
}

# ------------------------------------------------------------
# 光标越界修正（行内列裁剪、空行列归零）
# ------------------------------------------------------------
ed_ensure_cursor() {
    local n=${#ED_BUF[@]}
    (( ED_ROW < 0 )) && ED_ROW=0
    (( ED_ROW >= n )) && ED_ROW=$((n - 1))
    local len=${#ED_BUF[ED_ROW]}
    (( ED_COL < 0 )) && ED_COL=0
    (( ED_COL > len )) && ED_COL="${len}"
    # 窗口滚动跟随（nano 布局：顶部标题1 + 编辑区 + 状态1 + 快捷键2）
    local win=$(( ED_ROWS - 4 ))
    if (( win < 3 )); then
        win=3
    fi
    if (( ED_ROW < ED_TOP )); then
        ED_TOP="${ED_ROW}"
    elif (( ED_ROW >= ED_TOP + win )); then
        ED_TOP=$(( ED_ROW - win + 1 ))
    fi
    return 0
}

# ------------------------------------------------------------
# 在当前光标处插入字符（可为多字节 UTF-8 字符）
# 参数：$1 字符
# ------------------------------------------------------------
ed_insert_char() {
    local ch="$1" line="${ED_BUF[ED_ROW]}"
    ed_undo_push
    ED_BUF[ED_ROW]="${line:0:ED_COL}${ch}${line:ED_COL}"
    ED_COL=$(( ED_COL + ${#ch} ))
    ED_MOD=1
}

# ------------------------------------------------------------
# 退格：删除光标前一字符（若在行首则与上一行合并）
# ------------------------------------------------------------
ed_backspace() {
    if (( ED_COL == 0 && ED_ROW == 0 )); then
        return 0
    fi
    ed_undo_push
    if (( ED_COL > 0 )); then
        local line="${ED_BUF[ED_ROW]}"
        # 删除前一个 UTF-8 字符（向前跳过 1 个完整字符）
        local del=1
        while (( del <= ED_COL )); do
            local c="${line:ED_COL-del:1}"
            local ob
            LC_ALL=C printf -v ob '%d' "'${c}"
            if (( ob < 0x80 || ob >= 0xC0 )); then break; fi
            del=$((del + 1))
        done
        ED_BUF[ED_ROW]="${line:0:ED_COL-del}${line:ED_COL}"
        ED_COL=$(( ED_COL - del ))
        ED_MOD=1
    elif (( ED_ROW > 0 )); then
        # 行首：与上一行合并
        local above="${ED_BUF[ED_ROW-1]}"
        ED_COL="${#above}"
        ED_BUF[ED_ROW-1]="${above}${ED_BUF[ED_ROW]}"
        unset 'ED_BUF[ED_ROW]'
        ED_BUF=("${ED_BUF[@]}")
        ED_ROW=$(( ED_ROW - 1 ))
        ED_MOD=1
    fi
}

# ------------------------------------------------------------
# 删除光标处字符（Delete）；行尾则与下一行合并
# ------------------------------------------------------------
ed_delete_char() {
    local line="${ED_BUF[ED_ROW]}"
    local len=${#line}
    if (( ED_COL == len && ED_ROW + 1 >= ${#ED_BUF[@]} )); then
        return 0
    fi
    ed_undo_push
    if (( ED_COL < len )); then
        local del=1 c=""
        c="${line:ED_COL:1}"
        local ob
        LC_ALL=C printf -v ob '%d' "'${c}"
        if (( ob >= 0xC0 )); then
            # 首字节是 UTF-8 引导字节 → 删整个字符（按引导字节定长）
            local nbytes=1
            if (( ob >= 0xF0 )); then nbytes=4
            elif (( ob >= 0xE0 )); then nbytes=3
            elif (( ob >= 0xC0 )); then nbytes=2
            fi
            while (( del < nbytes )) && (( ED_COL + del < len )); do
                c="${line:ED_COL+del:1}"
                LC_ALL=C printf -v ob '%d' "'${c}"
                (( ob >= 0x80 && ob < 0xC0 )) || break
                del=$((del + 1))
            done
        fi
        ED_BUF[ED_ROW]="${line:0:ED_COL}${line:ED_COL+del}"
        ED_MOD=1
    elif (( ED_ROW + 1 < ${#ED_BUF[@]} )); then
        # 行尾：与下一行合并
        local next="${ED_BUF[ED_ROW+1]}"
        ED_BUF[ED_ROW]="${line}${next}"
        unset 'ED_BUF[ED_ROW+1]'
        ED_BUF=("${ED_BUF[@]}")
        ED_MOD=1
    fi
}

# ------------------------------------------------------------
# 回车：在光标处拆行
# ------------------------------------------------------------
ed_enter() {
    local line="${ED_BUF[ED_ROW]}"
    ed_undo_push
    local left="${line:0:ED_COL}" right="${line:ED_COL}"
    ED_BUF[ED_ROW]="${left}"
    local after=()
    local i
    for ((i = ED_ROW + 1; i < ${#ED_BUF[@]}; i++)); do
        after+=("${ED_BUF[$i]}")
    done
    ED_BUF=("${ED_BUF[@]:0:ED_ROW+1}" "${right}" "${after[@]}")
    ED_ROW=$(( ED_ROW + 1 ))
    ED_COL=0
    ED_MOD=1
}

# ------------------------------------------------------------
# 光标移动
# 参数：$1 方向 up/down/left/right/home/end/pgup/pgdn
# ------------------------------------------------------------
ed_move() {
    case "$1" in
        up)    (( ED_ROW > 0 )) && ED_ROW=$(( ED_ROW - 1 )) ;;
        down)  (( ED_ROW + 1 < ${#ED_BUF[@]} )) && ED_ROW=$(( ED_ROW + 1 )) ;;
        left)
            # 字符级左移：跳到前一个 UTF-8 字符开头（避免落在多字节中间）
            if (( ED_COL > 0 )); then
                local del=1 line="${ED_BUF[ED_ROW]}" ob=0 c=""
                while (( del <= ED_COL )); do
                    c="${line:ED_COL-del:1}"
                    LC_ALL=C printf -v ob '%d' "'${c}"
                    (( ob >= 0x80 && ob < 0xC0 )) || break
                    del=$((del + 1))
                done
                ED_COL=$(( ED_COL - del ))
            fi
            ;;
        right)
            # 字符级右移：确保光标在字符边界，跳过完整 UTF-8 字符
            if (( ED_COL < ${#ED_BUF[ED_ROW]} )); then
                local line="${ED_BUF[ED_ROW]}" ob=0 c="" nb=1 b=0
                # 1) 若当前字节是续字节（不在字符开头），先回退到引导字节
                c="${line:ED_COL:1}"
                LC_ALL=C printf -v ob '%d' "'${c}"
                if (( ob >= 0x80 && ob < 0xC0 )); then
                    b="${ED_COL}"
                    while (( b > 0 )); do
                        b=$((b - 1))
                        c="${line:b:1}"
                        LC_ALL=C printf -v ob '%d' "'${c}"
                        (( ob < 0x80 || ob >= 0xC0 )) && break
                    done
                    ED_COL="${b}"
                fi
                # 2) 按引导字节跳过完整字符
                c="${line:ED_COL:1}"
                LC_ALL=C printf -v ob '%d' "'${c}"
                if (( ob >= 0xF0 )); then nb=4
                elif (( ob >= 0xE0 )); then nb=3
                elif (( ob >= 0xC0 )); then nb=2
                fi
                ED_COL=$(( ED_COL + nb ))
            fi
            ;;
        home)  ED_COL=0 ;;
        end)   ED_COL=${#ED_BUF[ED_ROW]} ;;
        pgup)  ED_TOP=$(( ED_TOP - (ED_ROWS - 3) )); if (( ED_TOP < 0 )); then ED_TOP=0; fi
               ED_ROW="${ED_TOP}" ;;
        pgdn)  ED_TOP=$(( ED_TOP + (ED_ROWS - 3) ))
               ED_ROW="${ED_TOP}" ;;
    esac
    ed_ensure_cursor
    return 0
}

# ------------------------------------------------------------
# 光标显示列（字节偏移 → 含行号列宽的显示列）
# 参数：$1 行内容  $2 字节偏移
# 输出：显示列号（1-based，含行号 gutter）
# ------------------------------------------------------------
ed_col_to_screen() {
    local line="$1" off="$2"
    local w=0 i=0 c="" ob=0 nb=1 cw=1
    local LC_ALL=C
    while (( i < off )); do
        c="${line:i:1}"
        printf -v ob '%d' "'${c}"
        if (( ob < 0x80 )); then
            nb=1; cw=1
        else
            nb=1; cw=2
            if (( ob >= 0xF0 )); then nb=4
            elif (( ob >= 0xE0 )); then nb=3
            elif (( ob >= 0xC0 )); then nb=2
            fi
        fi
        w=$((w + cw))
        i=$((i + nb))
    done
    echo $(( ED_GUTTER + w + 1 ))
}

# ------------------------------------------------------------
# 屏幕列 → 行内字节偏移（鼠标点击定位；宽字符按 2 列计）
# 参数：$1 行内容  $2 显示列（减去行号 gutter 后的相对列，1-based）
# 输出：字节偏移
# ------------------------------------------------------------
ed_screen_to_col() {
    local line="$1" want="$2"
    (( want < 1 )) && want=1
    local w=1 i=0 c="" ob=0 nb=1 cw=1
    local LC_ALL=C
    local len=${#line}
    while (( i < len )); do
        c="${line:i:1}"
        printf -v ob '%d' "'${c}"
        if (( ob < 0x80 )); then
            nb=1; cw=1
        else
            nb=1; cw=2
            if (( ob >= 0xF0 )); then nb=4
            elif (( ob >= 0xE0 )); then nb=3
            elif (( ob >= 0xC0 )); then nb=2
            fi
        fi
        if (( want < w + cw )); then
            break
        fi
        w=$((w + cw)); i=$((i + nb))
    done
    echo "${i}"
}

# ------------------------------------------------------------
# 渲染整屏（缓冲一次性输出；光标定位在内容区）
# ------------------------------------------------------------
# 渲染整屏（nano 风格：顶部标题栏 + 无行号编辑区 + 状态行 + 两行快捷键栏）
# ED_HELP=1 时编辑区显示快捷键帮助页
# ------------------------------------------------------------
ed_render() {
    local buf="" line="" i r sc scol txt
    local n=${#ED_BUF[@]}
    # nano 布局：标题(1) + 编辑区(2..rows-3) + 状态(rows-2) + 快捷键(rows-1, rows)
    local win=$(( ED_ROWS - 4 ))
    (( win < 3 )) && win=3
    ED_GUTTER=0   # nano 风格：编辑区无行号列
    # 顶部标题栏（nano 风格：程序名 版本  文件路径  修改状态）
    local modmark="" romark=""
    [[ "${ED_MOD}" == "1" ]] && modmark="● 已修改"
    [[ "${ED_READONLY}" == "1" ]] && romark=" [只读]"
    printf -v line '\e[H\e[30;47m %s v%s   %s  %s%s\e[0m\e[K\n' \
        "ZETOPS 编辑器" "${ZETOPS_VERSION:-1.5.7}" "${ED_FILE:-<new>}" "${modmark}" "${romark}"
    buf+="${line}"
    # 编辑区（帮助页或文件内容）
    if (( ED_HELP == 1 )); then
        local hl=(
            ""
            "  ZETOPS 内置 TUI 编辑器 —— 快捷键"
            ""
            "  ^G 帮助      ^O / ^S 保存文件"
            "  ^X / Esc    退出（有未保存修改时询问）"
            "  M-U 撤销    M-E 重做（Alt+U / Alt+E）"
            "  ↑ ↓ ← →     移动光标"
            "  Enter       换行    Backspace  删除前一字符"
            "  Del         删除光标处字符    PgUp/PgDn  翻页"
            "  鼠标点击    定位光标"
            ""
            "  任意键返回编辑")
        for ((r = 0; r < win; r++)); do
            printf -v line '\e[%d;1H\e[K' $(( 2 + r ))
            buf+="${line}"
            if (( r < ${#hl[@]} )); then
                buf+="${hl[r]}"
            fi
            buf+=$'\n'
        done
    else
        for ((r = 0; r < win; r++)); do
            sc=$(( ED_TOP + r ))
            printf -v line '\e[%d;1H\e[K' $(( 2 + r ))
            buf+="${line}"
            if (( sc < n )); then
                txt="${ED_BUF[sc]}"
                local budget=$(( ED_COLS - 1 ))
                (( budget < 5 )) && budget=5
                if (( $(fm_str_w "${txt}") > budget )); then
                    txt="$(fm_str_clip "${txt}" "${budget}")"
                fi
                if (( sc == ED_ROW )); then
                    printf -v line '\e[30;47m%s\e[0m' "${txt}"
                else
                    printf -v line '%s' "${txt}"
                fi
            else
                printf -v line '~'
            fi
            buf+="${line}"
            buf+=$'\n'
        done
    fi
    # 状态行（nano 风格：行列/行数/只读）
    local ronly="否"
    [[ "${ED_READONLY}" == "1" ]] && ronly="是"
    printf -v line '\e[%d;1H\e[K\e[30;47m 行 %d / %d   列 %d   共 %d 行   只读: %s\e[0m' \
        $(( ED_ROWS - 2 )) $(( ED_ROW + 1 )) "${n}" $(( ED_COL + 1 )) "${n}" "${ronly}"
    buf+="${line}"
    # 快捷键栏（两行，nano 风格）
    printf -v line '\e[%d;1H\e[K\e[30;47m ^G 帮助   ^O 保存   ^X 退出   M-U 撤销   M-E 重做\e[0m' $(( ED_ROWS - 1 ))
    buf+="${line}"
    printf -v line '\e[%d;1H\e[K\e[90m 方向键移动  Enter 换行  Backspace 退格  Del 删除  PgUp/PgDn 翻页  鼠标点击定位\e[0m' "${ED_ROWS}"
    buf+="${line}"
    # 光标定位（nano 风格：显示光标，无行号列）
    if (( ED_HELP == 0 )); then
        scol=$(ed_col_to_screen "${ED_BUF[ED_ROW]}" "${ED_COL}")
        printf -v line '\e[%d;%dH' $(( 2 + ED_ROW - ED_TOP )) "${scol}"
        buf+="${line}"
    fi
    printf '%s' "${buf}"
}

# ------------------------------------------------------------
# 读一个交互事件（原始模式，兼容键盘方向键/功能键/SGR鼠标）
# 输出：KEY_UP/KEY_DOWN/KEY_LEFT/KEY_RIGHT/KEY_HOME/KEY_END/
#       KEY_PGUP/KEY_PGDN/KEY_DEL/KEY_ENTER/KEY_BACK/KEY_ESC/
#       KEY_CTRL_Q/KEY_CTRL_S/CHAR:<字符>/MOUSE:<btn>,<x>,<y>
# ------------------------------------------------------------
ed_read_event() {
    local k="" k2="" k3="" k4=""
    IFS= LC_ALL=C read -r -s -n 1 k < /dev/tty || return 1
    case "${k}" in
        $'\x1b')
            IFS= LC_ALL=C read -r -s -n 1 -t 1 k2 < /dev/tty || { echo KEY_ESC; return 0; }
            case "${k2}" in
                '[')
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 k3 < /dev/tty || { echo KEY_ESC; return 0; }
                    case "${k3}" in
                        'A') echo KEY_UP ;;
                        'B') echo KEY_DOWN ;;
                        'C') echo KEY_RIGHT ;;
                        'D') echo KEY_LEFT ;;
                        'H') echo KEY_HOME ;;
                        'F') echo KEY_END ;;
                        '1'|'3'|'5'|'6'|'7'|'8')
                            IFS= LC_ALL=C read -r -s -n 1 -t 1 k4 < /dev/tty || return 1
                            [[ "${k4}" == "~" ]] || return 1
                            case "${k3}" in
                                '1'|'7') echo KEY_HOME ;;
                                '3') echo KEY_DEL ;;
                                '5') echo KEY_PGUP ;;
                                '6') echo KEY_PGDN ;;
                                '8') echo KEY_END ;;
                                *) return 1 ;;
                            esac
                            ;;
                        '<')
                            # SGR 鼠标：ESC [ < btn ; x ; y M|m
                            local btn="" x="" y="" num="" phase=0 c=""
                            while IFS= LC_ALL=C read -r -s -n 1 -t 1 c < /dev/tty; do
                                if [[ "${c}" =~ [0-9] ]]; then
                                    num+="${c}"
                                elif [[ "${c}" == ";" ]]; then
                                    if (( phase == 0 )); then btn="${num}"; elif (( phase == 1 )); then x="${num}"; fi
                                    num=""; phase=$(( phase + 1 ))
                                elif [[ "${c}" == "M" || "${c}" == "m" ]]; then
                                    y="${num}"
                                    if [[ -n "${btn}" && -n "${x}" && -n "${y}" ]]; then
                                        # 释放(m)/滚轮/拖拽：btn>=32 或 phase 判定
                                        if (( btn >= 32 )); then
                                            # 仅左键按下 btn==0；其余（移动/悬停/滚轮/拖拽/释放）忽略
                                            echo "NONE"
                                        else
                                            echo "MOUSE:${btn},${x},${y}"
                                        fi
                                        return 0
                                    fi
                                    return 1
                                else
                                    return 1
                                fi
                            done
                            return 1
                            ;;
                        'M')
                            # X10 鼠标：ESC [ M b x y（字节已 +32）
                            local b x y
                            IFS= LC_ALL=C read -r -s -n 1 -t 1 b < /dev/tty || return 1
                            IFS= LC_ALL=C read -r -s -n 1 -t 1 x < /dev/tty || return 1
                            IFS= LC_ALL=C read -r -s -n 1 -t 1 y < /dev/tty || return 1
                            local ob ox oy
                            LC_ALL=C printf -v ob '%d' "'${b}"
                            LC_ALL=C printf -v ox '%d' "'${x}"
                            LC_ALL=C printf -v oy '%d' "'${y}"
                            (( ob -= 32 )); (( ox -= 32 )); (( oy -= 32 ))
                            if (( ob == 0 )); then
                                echo "MOUSE:0,${ox},${oy}"
                            else
                                echo "NONE"
                            fi
                            ;;
                        *) return 1 ;;
                    esac
                    ;;
                'O')
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 k3 < /dev/tty || return 1
                    case "${k3}" in
                        'H') echo KEY_HOME ;;
                        'F') echo KEY_END ;;
                        *) return 1 ;;
                    esac
                    ;;
                *) echo KEY_ESC ;;
            esac
            ;;
        'u') echo KEY_UNDO ;;   # Alt+U 撤销（nano 键位）
        'e') echo KEY_REDO ;;   # Alt+E 重做（nano 键位）
        $'\r') echo KEY_ENTER ;;
        $'\x7f'|$'\x08') echo KEY_BACK ;;
        $'\x11') echo KEY_CTRL_Q ;;
        $'\x13') echo KEY_CTRL_S ;;
        $'\x03') echo KEY_CTRL_Q ;;   # Ctrl+C 也作退出
        $'\x07') echo KEY_CTRL_G ;;   # Ctrl+G 帮助
        $'\x1a'|$'\x19') echo NONE ;; # Ctrl+Z/Ctrl+Y 丢弃（避免 shell 挂起语义）
        *)
            # 可打印：组完整 UTF-8 字符
            local ch="${k}" ob=0 more=0 i2=0
            LC_ALL=C printf -v ob '%d' "'${k}"
            if (( ob >= 0xF0 )); then more=3
            elif (( ob >= 0xE0 )); then more=2
            elif (( ob >= 0xC0 )); then more=1
            fi
            for ((i2 = 0; i2 < more; i2++)); do
                IFS= LC_ALL=C read -r -s -n 1 -t 1 k2 < /dev/tty || break
                ch+="${k2}"
            done
            printf 'CHAR:%s' "${ch}"
            ;;
    esac
    return 0
}

# ------------------------------------------------------------
# TUI 编辑器主入口
# 参数：$1 文件路径（空=交互选择）
# 返回：0=正常结束 1=失败/用户取消
# 说明：独立备用屏 + 原始模式；退出时恢复终端状态。
# ------------------------------------------------------------
tui_edit_file() {
    local path="$1"
    if [[ -z "${path}" ]]; then
        printf '请输入要编辑的文件路径: ' >&2
        IFS= read -r path < /dev/tty
        path="$(echo "${path}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    fi
    [[ -n "${path}" ]] || return 1
    # 目录不可编辑
    if [[ -d "${path}" ]]; then
        echo "错误：${path} 是目录，不能编辑" >&2
        return 1
    fi
    if [[ -e "${path}" && ! -f "${path}" ]]; then
        echo "错误：${path} 不是普通文件" >&2
        return 1
    fi

    ed_load "${path}"

    # 终端尺寸
    local sz=""
    sz=$(stty size < /dev/tty 2>/dev/null) || sz=""
    ED_ROWS=$(printf '%s' "${sz}" | awk '{print $1}')
    ED_COLS=$(printf '%s' "${sz}" | awk '{print $2}')
    ED_ROWS=${ED_ROWS:-24}; ED_COLS=${ED_COLS:-80}
    (( ED_ROWS < 12 )) && ED_ROWS=12
    (( ED_COLS < 40 )) && ED_COLS=40

    # 保存原始终端状态并进入编辑器模式
    local old_ttystate=""
    old_ttystate=$(stty -g < /dev/tty 2>/dev/null || true)
    stty raw -echo < /dev/tty 2>/dev/null
    # 备用屏 + 显示光标（nano 风格：光标可见便于定位）
    printf '\e[?1049h\e[?25h' > /dev/tty 2>/dev/null
    # 鼠标：仅开启点击（1000）与 SGR（1006），不启用拖拽/移动（1002）
    printf '\e[?1000h\e[?1006h' > /dev/tty 2>/dev/null

    local ev="" act="" key=""
    local quit=0
    ED_HELP=0
    ed_ensure_cursor
    while (( quit == 0 )); do
        ed_render > /dev/tty 2>/dev/null
        ev=$(ed_read_event) || { ev="KEY_ESC"; }
        case "${ev}" in
            KEY_UP) ed_move up; ED_HELP=0 ;;
            KEY_DOWN) ed_move down; ED_HELP=0 ;;
            KEY_LEFT) ed_move left; ED_HELP=0 ;;
            KEY_RIGHT) ed_move right; ED_HELP=0 ;;
            KEY_HOME) ed_move home; ED_HELP=0 ;;
            KEY_END) ed_move end; ED_HELP=0 ;;
            KEY_PGUP) ed_move pgup; ED_HELP=0 ;;
            KEY_PGDN) ed_move pgdn; ED_HELP=0 ;;
            KEY_ENTER) if (( ED_HELP == 1 )); then ED_HELP=0; else ed_enter; fi ;;
            KEY_BACK) if (( ED_HELP == 1 )); then ED_HELP=0; else ed_backspace; fi ;;
            KEY_DEL) if (( ED_HELP == 1 )); then ED_HELP=0; else ed_delete_char; fi ;;
            KEY_CTRL_G) ED_HELP=1 ;;
            KEY_UNDO) if (( ED_HELP == 1 )); then ED_HELP=0; else ed_undo; fi ;;
            KEY_REDO) if (( ED_HELP == 1 )); then ED_HELP=0; else ed_redo; fi ;;
            KEY_CTRL_S)
                if (( ED_HELP == 1 )); then ED_HELP=0; fi
                ed_save || true
                ;;
            KEY_CTRL_Q)
                if (( ED_HELP == 1 )); then ED_HELP=0; continue; fi
                if (( ED_MOD == 1 )); then
                    # 退出确认
                    printf '\e[%d;1H\e[K\e[30;43m 有未保存修改！[y] 保存并退出 [n] 放弃退出 [c] 取消\e[0m' "${ED_ROWS}" > /dev/tty
                    local c=""
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 c < /dev/tty
                    case "${c}" in
                        y|Y) if ed_save; then quit=1; fi ;;
                        n|N) quit=1 ;;
                        *) : ;;
                    esac
                else
                    quit=1
                fi
                ;;
            KEY_ESC)
                if (( ED_HELP == 1 )); then ED_HELP=0; continue; fi
                if (( ED_MOD == 1 )); then
                    printf '\e[%d;1H\e[K\e[30;43m 有未保存修改！[y] 保存并退出 [n] 放弃退出 [c] 取消\e[0m' "${ED_ROWS}" > /dev/tty
                    local c=""
                    IFS= LC_ALL=C read -r -s -n 1 -t 1 c < /dev/tty
                    case "${c}" in
                        y|Y) if ed_save; then quit=1; fi ;;
                        n|N) quit=1 ;;
                        *) : ;;
                    esac
                else
                    quit=1
                fi
                ;;
            CHAR:*)
                if (( ED_HELP == 1 )); then ED_HELP=0; else ed_insert_char "${ev#CHAR:}"; fi
                ;;
            MOUSE:*)
                local bx by bcol
                bx="${ev#MOUSE:}"; by="${bx#*,}"; bx="${bx%%,*}"
                if [[ "${bx}" == "0" ]]; then
                    local mx="${by%%,*}" my="${by#*,}"
                    local rel=$(( my - 2 ))
                    if (( rel >= 0 && rel < ED_ROWS - 4 )); then
                        ED_ROW=$(( ED_TOP + rel ))
                        (( ED_ROW >= ${#ED_BUF[@]} )) && ED_ROW=$(( ${#ED_BUF[@]} - 1 ))
                        bcol=$(ed_screen_to_col "${ED_BUF[ED_ROW]}" "${mx}")
                        ED_COL="${bcol}"
                        ed_ensure_cursor
                        ED_HELP=0
                    fi
                fi
                ;;
            NONE) : ;;
            *) : ;;
        esac
    done

    # 退出编辑器：恢复终端
    printf '\e[?1000l\e[?1006l\e[?25h\e[?1049l' > /dev/tty 2>/dev/null
    stty "${old_ttystate}" < /dev/tty 2>/dev/null
    return 0
}
