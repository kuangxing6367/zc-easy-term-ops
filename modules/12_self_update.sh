#!/bin/bash
# ============================================================
# 文件：modules/12_self_update.sh
# 功能：工具箱自我更新与版本管理 [Self Update & Version]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：查看版本/安装信息、检查远程更新、从 GitHub 拉取
#       最新代码（支持加速镜像）、查看更新日志、配置更新源
# ============================================================
set -euo pipefail

module_name="自我更新与版本管理"
module_short="self_update"
module_version="1.0.0"

# ------------------------------------------------------------
# 模块描述（进入模块时显示）
# 参数：无
# 返回：无
# ------------------------------------------------------------
module_description() {
    echo "查看当前版本、检查更新、从 GitHub 拉取最新代码、配置 GitHub 加速镜像"
}

# ------------------------------------------------------------
# 子菜单
# 参数：无
# 返回：无
# ------------------------------------------------------------
module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看当前版本与安装信息"
    echo " 2. 检查远程更新"
    echo " 3. 执行更新 (GitHub 拉取)"
    echo " 4. 查看更新日志 (CHANGELOG)"
    echo " 5. 配置更新源 (加速镜像/直连)"
    echo " 0. 返回主菜单"
    echo "======================================"
}

# ------------------------------------------------------------
# 执行入口（参数为子菜单选项）
# 参数：$1 选项数字
# 返回：无
# ------------------------------------------------------------
module_execute() {
    local choice="$1"
    case "${choice}" in
        1) self_status_view ;;
        2) self_check_update ;;
        3) self_do_update ;;
        4) self_changelog_view ;;
        5) self_mirror_config ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 获取安装根目录（被 main.sh source 时用全局变量，独立执行时推导）
# 参数：无
# 输出：根目录路径
# ------------------------------------------------------------
self_root() {
    if [[ -n "${ZETOPS_ROOT:-}" ]]; then
        echo "${ZETOPS_ROOT}"
    else
        (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    fi
}

# ------------------------------------------------------------
# 从 ZETOPS_REPO_URL 提取 owner/repo
# 参数：无
# 输出："owner repo"（空格分隔）
# ------------------------------------------------------------
self_repo_parts() {
    echo "${ZETOPS_REPO_URL}" | sed -E 's#^.*github\.com[:/]##; s#\.git$##' | awk -F/ '{print $1, $2}'
}

# ------------------------------------------------------------
# 获取远程版本号（读取远程 core/config.sh 的 ZETOPS_VERSION）
# 兼容两种写法：ZETOPS_VERSION="1.3.2" 与 ${ZETOPS_VERSION:-1.3.2}
# 参数：$1 owner  $2 repo  $3 branch
# 输出：版本号（失败时为空）
# ------------------------------------------------------------
self_fetch_remote_version() {
    local owner="$1" repo="$2" branch="$3"
    local raw_url="${ZETOPS_GITHUB_MIRROR}https://raw.githubusercontent.com/${owner}/${repo}/${branch}/core/config.sh"
    curl -fsSL --max-time 20 "${raw_url}" 2>/dev/null \
        | grep -oE 'ZETOPS_VERSION=[^#[:space:]]*' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n1 || true
}

# ------------------------------------------------------------
# [查看] 查看当前版本与安装信息
# 参数：无
# 返回：无
# ------------------------------------------------------------
self_status_view() {
    local root
    root=$(self_root)
    log_info "================ 当前版本与安装信息 ================"
    echo "  版本号: ${ZETOPS_VERSION}"
    echo "  安装目录: ${root}"
    echo "  更新分支: ${ZETOPS_UPDATE_BRANCH}"
    echo "  GitHub 仓库: ${ZETOPS_REPO_URL}"
    if [[ -n "${ZETOPS_GITHUB_MIRROR:-}" ]]; then
        echo "  加速镜像: ${ZETOPS_GITHUB_MIRROR}"
    else
        echo "  加速镜像: (未配置，直连 GitHub)"
    fi
    if [[ -d "${root}/.git" ]]; then
        echo "  部署方式: git 仓库（git pull 更新）"
        git -C "${root}" log --oneline -n1 2>/dev/null | sed 's/^/  最近提交: /'
    else
        echo "  部署方式: 文件部署（下载覆盖更新）"
    fi
    echo "  功能模块: $(ls "${root}"/modules/*.sh 2>/dev/null | wc -l) 个"
    echo "  配置文件: ${CONFIG_FILE}"
    echo "  日志文件: ${LOG_DIR}/zetops.log"
    echo "-----------------------------------------------"
}

# ------------------------------------------------------------
# [检查] 检查远程更新（对比版本号）
# 参数：无
# 返回：0=最新 1=检查失败
# ------------------------------------------------------------
self_check_update() {
    local owner repo branch remote_ver
    read -r owner repo <<<"$(self_repo_parts)"
    branch="${ZETOPS_UPDATE_BRANCH}"
    log_info "正在检查远程更新（${owner}/${repo} @ ${branch}）..."
    remote_ver=$(self_fetch_remote_version "${owner}" "${repo}" "${branch}")
    if [[ -z "${remote_ver}" ]]; then
        log_error "获取远程版本失败。可能原因：网络不可达 / GitHub 被墙，建议配置加速镜像（菜单 5）"
        return 1
    fi
    echo "  本地版本: ${ZETOPS_VERSION}"
    echo "  远程版本: ${remote_ver}"
    if [[ "${ZETOPS_VERSION}" == "${remote_ver}" ]]; then
        log_success "已是最新版本"
    else
        log_warning "检测到新版本 ${remote_ver}，可进入菜单 3 执行更新"
    fi
}

# ------------------------------------------------------------
# [更新] 从 GitHub 拉取最新代码（git 方式 / 下载覆盖方式）
# 参数：无
# 返回：0=成功 1=失败
# ------------------------------------------------------------
self_do_update() {
    check_root || return 1
    local root owner repo branch remote_ver local_ver
    root=$(self_root)
    read -r owner repo <<<"$(self_repo_parts)"
    branch="${ZETOPS_UPDATE_BRANCH}"
    local_ver="${ZETOPS_VERSION}"
    remote_ver=$(self_fetch_remote_version "${owner}" "${repo}" "${branch}")
    if [[ -z "${remote_ver}" ]]; then
        log_error "获取远程版本失败，请检查网络或配置加速镜像（菜单 5）"
        return 1
    fi
    if [[ "${local_ver}" == "${remote_ver}" ]]; then
        log_success "已是最新版本: ${local_ver}，无需更新"
        return 0
    fi
    log_info "本地 ${local_ver} -> 远程 ${remote_ver}"
    confirm_action "从 GitHub(${branch} 分支) 更新到 ${remote_ver}" || return 1

    if [[ -d "${root}/.git" ]]; then
        self_do_update_git "${root}" "${branch}" || return 1
    else
        self_do_update_tarball "${root}" "${owner}" "${repo}" "${branch}" || return 1
    fi

    # 同步用户配置中的版本号（config.sh 覆盖后其默认值被用户配置覆盖时不生效，此处修正）
    if [[ -f "${CONFIG_FILE}" ]] && grep -q '^ZETOPS_VERSION=' "${CONFIG_FILE}"; then
        sed -i "s/^ZETOPS_VERSION=.*/ZETOPS_VERSION=\"${remote_ver}\"/" "${CONFIG_FILE}"
    fi
    log_success "更新完成：${local_ver} -> ${remote_ver}"
    log_warning "请退出并重新运行 zetops 使更新生效"
}

# ------------------------------------------------------------
# [更新] git 仓库方式更新
# 参数：$1 根目录  $2 分支
# 返回：0=成功 1=失败
# ------------------------------------------------------------
self_do_update_git() {
    local root="$1" branch="$2"
    local dirty
    dirty=$(git -C "${root}" status --porcelain 2>/dev/null | wc -l)
    if (( dirty > 0 )); then
        log_warning "检测到 ${dirty} 个本地未提交修改，更新将覆盖它们（git reset --hard）"
        confirm_action "继续覆盖本地未提交修改" || return 1
    fi
    log_info "git fetch 拉取更新..."
    git -C "${root}" fetch origin "${branch}" 2>/dev/null \
        || git -C "${root}" fetch "${ZETOPS_GITHUB_MIRROR}${ZETOPS_REPO_URL}" "${branch}" || {
            log_error "git fetch 失败"; return 1; }
    git -C "${root}" checkout "${branch}" 2>/dev/null || git -C "${root}" checkout -b "${branch}" "origin/${branch}" 2>/dev/null || true
    git -C "${root}" reset --hard "origin/${branch}" || {
        log_error "git reset 失败"; return 1; }
    log_success "git 更新完成（分支 ${branch}）"
}

# ------------------------------------------------------------
# [更新] 下载 tarball 覆盖更新（非 git 部署）
# 参数：$1 根目录  $2 owner  $3 repo  $4 branch
# 返回：0=成功 1=失败
# ------------------------------------------------------------
self_do_update_tarball() {
    local root="$1" owner="$2" repo="$3" branch="$4"
    local tmpdir tarball_url src bak
    tmpdir=$(mktemp -d) || return 1
    tarball_url="${ZETOPS_GITHUB_MIRROR}https://github.com/${owner}/${repo}/archive/refs/heads/${branch}.tar.gz"
    log_info "下载更新包: ${tarball_url}"
    if ! curl -fSL --max-time 180 "${tarball_url}" -o "${tmpdir}/update.tar.gz"; then
        log_error "下载失败，请检查网络或加速镜像配置（菜单 5）"
        rm -rf "${tmpdir}"
        return 1
    fi
    if ! tar -xzf "${tmpdir}/update.tar.gz" -C "${tmpdir}"; then
        log_error "解压失败"
        rm -rf "${tmpdir}"
        return 1
    fi
    src=$(find "${tmpdir}" -maxdepth 1 -type d -name "${repo}-*" | head -n1)
    if [[ -z "${src}" ]]; then
        log_error "未找到解压目录"
        rm -rf "${tmpdir}"
        return 1
    fi

    # 备份当前版本（排除 .git）
    bak="${BACKUP_DIR}/zetops-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${bak}"
    log_info "备份当前版本到 ${bak}"
    (cd "${root}" && tar cf - --exclude='./.git' .) | (cd "${bak}" && tar xf -) || {
        log_error "备份失败，已中止更新"; rm -rf "${tmpdir}"; return 1; }

    # 覆盖更新（排除 .git）
    log_info "应用更新到 ${root} ..."
    (cd "${src}" && tar cf - --exclude='./.git' .) | (cd "${root}" && tar xf -) || {
        log_error "更新应用失败，可手动从备份恢复: ${bak}"
        rm -rf "${tmpdir}"; return 1; }

    # 权限修复
    chmod +x "${root}"/core/*.sh "${root}"/modules/*.sh \
             "${root}"/plugins/*.sh "${root}"/zetops 2>/dev/null || true
    rm -rf "${tmpdir}"
    log_success "旧版本已备份至: ${bak}"
}

# ------------------------------------------------------------
# [日志] 查看更新日志（CHANGELOG 最近内容）
# 参数：无
# 返回：无
# ------------------------------------------------------------
self_changelog_view() {
    local root
    root=$(self_root)
    if [[ -f "${root}/docs/CHANGELOG.md" ]]; then
        log_info "================ 更新日志 (最近 50 行) ================"
        tail -n 50 "${root}/docs/CHANGELOG.md"
    else
        log_warning "未找到 docs/CHANGELOG.md"
    fi
}

# ------------------------------------------------------------
# [配置] 配置 GitHub 加速镜像（默认镜像源）/ 恢复直连
# 参数：无
# 返回：无
# ------------------------------------------------------------
self_mirror_config() {
    local current="${ZETOPS_GITHUB_MIRROR:-}"
    echo "当前加速镜像: ${current:-（未配置，直连 GitHub）}"
    echo ""
    echo "常见加速镜像（前缀形式，如 https://ghfast.top/）："
    echo "  - https://ghfast.top/"
    echo "  - https://gh-proxy.com/"
    echo "  - https://mirror.ghproxy.com/"
    echo "留空保存则恢复直连 GitHub"
    echo ""
    local input
    read_input input "请输入加速镜像前缀" "${current}"
    input="${input%/}"
    [[ -n "${input}" ]] && input="${input}/"
    mkdir -p "${CONFIG_DIR}"
    if [[ -f "${CONFIG_FILE}" ]] && grep -q '^ZETOPS_GITHUB_MIRROR=' "${CONFIG_FILE}"; then
        sed -i "s|^ZETOPS_GITHUB_MIRROR=.*|ZETOPS_GITHUB_MIRROR=\"${input}\"|" "${CONFIG_FILE}"
    else
        echo "ZETOPS_GITHUB_MIRROR=\"${input}\"" >> "${CONFIG_FILE}"
    fi
    # 同步当前会话
    ZETOPS_GITHUB_MIRROR="${input}"
    if [[ -n "${input}" ]]; then
        log_success "加速镜像已配置: ${input}（已写入 ${CONFIG_FILE}）"
    else
        log_success "已恢复直连 GitHub"
    fi
}

# ---- 独立执行入口 ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../core/logger.sh"
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../core/utils.sh"
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../core/config.sh"
    log_init; load_config; load_api_config
    CURRENT_MODULE="${module_short}"
    while true; do
        module_description; module_menu
        read -r -p "请选择 (0-9) [q=退出]: " _c || break
        [[ "${_c}" == "q" ]] && break
        module_execute "${_c}" || true
        [[ "${_c}" == "0" ]] && break
    done
fi
