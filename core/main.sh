#!/bin/bash
# ============================================================
# 文件：core/main.sh
# 功能：主程序入口（主菜单调度核心）
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：加载核心库 → 环境检查 → 锁检查 → 扫描模块/插件 → 主菜单循环
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
    if [[ -n "${_LOCK_FD:-}" ]]; then
        flock -u "${_LOCK_FD}" 2>/dev/null || true
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
# 参数：无
# 返回：0=获得锁 1=已被占用
# ------------------------------------------------------------
check_lock() {
    if ! check_command flock; then
        log_debug "环境无 flock，跳过单实例锁"
        _LOCK_FD=""
        return 0
    fi
    mkdir -p /var/run 2>/dev/null || true
    exec {_LOCK_FD}>"${LOCK_FILE}"
    if ! flock -n "${_LOCK_FD}"; then
        log_error "ZETOPS 已在运行（锁文件 ${LOCK_FILE}），请勿重复启动"
        return 1
    fi
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
# 主入口
# 参数：$@（预留，暂不支持参数）
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
    source "${ZETOPS_ROOT}/core/menu.sh"

    log_init
    load_config
    load_api_config
    check_deps || exit 1
    check_lock || exit 1
    load_modules
    load_plugins
    main_loop
    cleanup
}

# 直接执行入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
