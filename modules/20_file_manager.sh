#!/bin/bash
# ============================================================
# 文件：modules/20_file_manager.sh
# 功能：可视化文件管理器 [File Manager - Explorer Style]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 类 Windows 资源管理器：当前路径显示、目录进入/返回、
#     分页列表（目录/文件/大小/权限/时间/图标）、刷新
#   - 文件操作：查看/编辑/复制/移动/重命名/删除(危险保护)/
#     权限修改/压缩解压/新建文件目录/搜索
#   - 书签管理：~/.zetops/fm_bookmarks 快速跳转
#   - 安全：删除必须确认、危险目录(/、/etc 等)二次警告
# ============================================================
set -euo pipefail

module_name="文件管理器"
module_short="file_manager"
module_version="1.0.0"

FM_BOOKMARKS="${FM_BOOKMARKS:-${HOME}/.zetops/fm_bookmarks}"
FM_PWD="${FM_PWD:-$HOME}"    # 当前目录
FM_PAGE=1                    # 当前页码
FM_PAGE_SIZE=18              # 每页条目数
FM_ITEMS=()                  # 当前页条目数组

module_description() {
    echo "类 Windows 资源管理器：目录导航、文件操作、权限、压缩解压、书签 [File Manager]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name}"
    echo "======================================"
    echo " 1. 打开文件管理器"
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

# ------------------------------------------------------------
# 主循环
# ------------------------------------------------------------
fm_main() {
    # 校验初始目录
    [[ -d "${FM_PWD}" ]] || FM_PWD="${HOME}"
    local input=""
    while true; do
        fm_render
        echo -n "  ${COLOR_BOLD}${COLOR_GREEN}FM>${COLOR_RESET} "
        read -r input || { echo ""; break; }
        input=$(echo "${input}" | tr '[:upper:]' '[:lower:]')
        case "${input}" in
            q|quit|exit) break ;;
            r|refresh)   continue ;;
            ..)          fm_go_parent ;;
            b|bookmark)  fm_bookmark_menu ;;
            s|search)    fm_search ;;
            t|tree)      fm_tree_menu ;;
            a|action)    fm_action_menu ;;
            *)           fm_select "${input}" ;;
        esac
    done
}

# ------------------------------------------------------------
# 渲染文件列表（分页）
# ------------------------------------------------------------
fm_render() {
    clear 2>/dev/null || true
    echo "${COLOR_BOLD}${COLOR_BLUE}"
    echo "======================================="
    echo "  文件管理器 | $(fm_icon_path "${FM_PWD}")"
    echo "======================================="
    echo "${COLOR_RESET}"

    # 收集条目（含隐藏文件，目录优先）
    local entries=()
    local f
    # shellcheck disable=SC2086
    for f in "${FM_PWD}"/.[!.]* "${FM_PWD}"/..?*; do
        [[ -e "${f}" ]] && entries+=("${f}")
    done 2>/dev/null || true
    for f in "${FM_PWD}"/*; do
        [[ -e "${f}" ]] && entries+=("${f}")
    done 2>/dev/null || true

    # 排序：目录在前，文件在后，按名称
    entries=($(for e in "${entries[@]}"; do
        [[ -d "${e}" ]] && echo "D|$(basename "${e}")|${e}"
    done | sort -t'|' -k2; for e in "${entries[@]}"; do
        [[ -f "${e}" ]] && echo "F|$(basename "${e}")|${e}"
    done | sort -t'|' -k2))

    local total=${#entries[@]}
    local total_pages=$(( (total + FM_PAGE_SIZE - 1) / FM_PAGE_SIZE ))
    (( total_pages < 1 )) && total_pages=1
    (( FM_PAGE > total_pages )) && FM_PAGE=${total_pages}

    local start=$(( (FM_PAGE - 1) * FM_PAGE_SIZE ))
    local end=$(( start + FM_PAGE_SIZE ))
    (( end > total )) && end=${total}

    # 上级目录
    if [[ "${FM_PWD}" != "/" ]]; then
        echo "  ${COLOR_BOLD}[1]${COLOR_RESET}  ${COLOR_YELLOW}📁  ..${COLOR_RESET} (上级目录)"
    fi

    FM_ITEMS=()
    local idx=0 i=0
    for ((i = start; i < end; i++)); do
        local line="${entries[$i]}"
        local type="${line%%|*}"
        local rest="${line#*|}"
        local name="${rest%%|*}"
        local full="${rest#*|}"
        idx=$((idx + 1))
        FM_ITEMS+=("${type}|${name}|${full}")
        if [[ "${type}" == "D" ]]; then
            echo "  ${COLOR_BOLD}[$((idx + 1))]${COLOR_RESET}  ${COLOR_BLUE}📁  ${name}/${COLOR_RESET}"
        else
            local size perm mtime
            size=$(fm_human_size "$(stat -c%s "${full}" 2>/dev/null || echo 0)")
            perm=$(stat -c '%A' "${full}" 2>/dev/null || echo "?")
            mtime=$(stat -c '%y' "${full}" 2>/dev/null | cut -d. -f1 || echo "?")
            echo "  ${COLOR_BOLD}[$((idx + 1))]${COLOR_RESET}  ${COLOR_GREEN}📄  ${name}${COLOR_RESET}  ${COLOR_GRAY}${size} | ${perm} | ${mtime}${COLOR_RESET}"
        fi
    done

    if (( total == 0 )); then
        echo "  ${COLOR_GRAY}(空目录)${COLOR_RESET}"
    fi

    echo ""
    echo "  ${COLOR_GRAY}--- 第 ${FM_PAGE}/${total_pages} 页 | 共 ${total} 项 ---${COLOR_RESET}"
    echo ""
    echo "  ${COLOR_BOLD}命令:${COLOR_RESET} 序号=进入/操作  ..=上级  a=操作菜单  s=搜索"
    echo "        t=目录树  b=书签  r=刷新  q=退出"
    echo "  ${COLOR_GRAY}直接输入序号进入目录，输入 a 选择文件操作${COLOR_RESET}"
}

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
    FM_PAGE=1
}

# ------------------------------------------------------------
# 数字/名称选择处理
# 参数：$1 用户输入
# ------------------------------------------------------------
fm_select() {
    local input="$1"
    # 支持直接输入目录名
    if [[ "${input}" =~ ^[0-9]+$ ]]; then
        local n=$((input - 2))   # 1=.. 实际从 2 开始
        if [[ "${input}" == "1" ]]; then
            fm_go_parent
            return
        fi
        local item="${FM_ITEMS[$((n - 1))]:-}"
        [[ -z "${item}" ]] && return
        local type="${item%%|*}"
        local rest="${item#*|}"
        local full="${rest#*|}"
        if [[ "${type}" == "D" ]]; then
            FM_PWD="${full}"
            FM_PAGE=1
        fi
        return
    fi

    # 支持直接输入相对路径进入
    if [[ -d "${FM_PWD}/${input}" ]]; then
        FM_PWD="${FM_PWD}/${input}"
        FM_PAGE=1
    elif [[ -e "${FM_PWD}/${input}" ]]; then
        fm_operate_single "${FM_PWD}/${input}" "$(basename "${input}")"
    else
        log_warning "无效输入: ${input}"
        sleep 1
    fi
}

# ------------------------------------------------------------
# 单文件快捷操作（输入文件名直接命中时）
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
    # 列出当前目录的文件
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
        # 支持绝对路径或相对当前目录
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
    # 列出可打包对象（当前目录下所有条目）
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

    # 收集条目（排除隐藏）
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
                    FM_PAGE=1
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
