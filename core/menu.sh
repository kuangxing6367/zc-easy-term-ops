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
# 读取用户选择（1..max，0 退出，q 返回）
# 参数：$1 最大选项数
# 输出：用户选择数字
# ------------------------------------------------------------
get_user_choice() {
    local max="$1"
    local ans=""
    # 注意：本函数通过命令替换调用（choice=$(get_user_choice ...)），
    # 因此提示/告警必须输出到 stderr，stdout 只返回最终选择数字
    while true; do
        echo -n "请选择 (0-${max}) [q=返回/退出]: " >&2
        read -r ans || ans="q"
        [[ "${ans}" == "q" || "${ans}" == "Q" ]] && { echo "q"; return 0; }
        if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 0 && ans <= max )); then
            echo "${ans}"
            return 0
        fi
        echo -e "\033[1;33m[WARNING] [menu] 输入无效，请输入 0-${max} 的数字\033[0m" >&2
    done
}

# ------------------------------------------------------------
# 渲染主菜单
# 参数：无
# 返回：无
# ------------------------------------------------------------
show_main_menu() {
    clear
    echo "=============================================="
    echo "  ZETOPS - 交互式Linux运维全能工具箱 v1.1.0"
    echo "  Interactive Linux Ops Toolkit [Linux运维]"
    echo "=============================================="
    local i
    for i in "${!MODULE_NAMES[@]}"; do
        printf "  %2d. %s\n" "$((i + 1))" "${MODULE_NAMES[$i]}"
    done
    if [[ ${#PLUGIN_NAMES[@]} -gt 0 ]]; then
        local base=$(( ${#MODULE_NAMES[@]} + 1 ))
        for i in "${!PLUGIN_NAMES[@]}"; do
            printf "  %2d. [插件] %s\n" "$((base + i))" "${PLUGIN_NAMES[$i]}"
        done
    fi
    echo "  q. 退出"
    echo "=============================================="
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
        module_description
        module_menu
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
    local choice

    # shellcheck source=/dev/null
    source "${file}"
    CURRENT_MODULE="plugin"

    while true; do
        clear
        plugin_menu
        choice=$(get_user_choice 99)
        [[ "${choice}" == "q" ]] && break
        case "${choice}" in
            0) break ;;
            *) plugin_execute "${choice}" || true ;;
        esac
    done
    CURRENT_MODULE="menu"
}
