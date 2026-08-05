#!/bin/bash
# ============================================================
# 文件：modules/02_package_manager.sh
# 功能：软件包与仓库管理 [Package & Repository Manager]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：镜像源切换(API动态获取)、常用工具安装、批量安装/卸载、
#       搜索与信息查看、第三方软件源(EPEL/IUS/PPA/Docker)
# ============================================================
set -euo pipefail

module_name="软件包与仓库管理"
module_short="package"
module_version="1.0.0"

module_description() {
    echo "软件源镜像配置(清华/阿里/中科大)、常用工具安装、批量安装卸载、第三方源"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 软件源镜像切换 (Mirror)"
    echo " 2. 常用工具一键安装"
    echo " 3. 批量安装软件包"
    echo " 4. 批量卸载软件包"
    echo " 5. 软件包搜索"
    echo " 6. 软件包信息查看"
    echo " 7. 添加第三方软件源"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) mirror_switch ;;
        2) tools_install ;;
        3) batch_install ;;
        4) batch_remove ;;
        5) pkg_search ;;
        6) pkg_info ;;
        7) third_party_repo ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [镜像源] 切换软件源镜像（从 API 获取镜像源列表）
# 参数：无
# 返回：无
# ------------------------------------------------------------
mirror_switch() {
    check_root || return 1
    local distro pm
    distro=$(get_distro)
    pm=$(detect_pkg_manager)
    log_info "当前发行版: ${distro} | 包管理器: ${pm}"

    # 从 API 节点获取镜像源列表（JSON 或纯文本，每行: 名称|基础URL）
    local mirrors
    mirrors=$(api_fetch "mirrors/list?distro=${distro}" || true)
    if [[ -z "${mirrors}" ]]; then
        log_warning "API 未配置或获取失败，使用内置镜像列表"
        mirrors="清华(Tuna)|https://mirrors.tuna.tsinghua.edu.cn
阿里云(Aliyun)|https://mirrors.aliyun.com
中科大(USTC)|https://mirrors.ustc.edu.cn"
    fi

    echo "可用镜像源:"
    local i=0 name url
    while IFS='|' read -r name url; do
        i=$((i + 1))
        printf "  %d. %-20s %s\n" "${i}" "${name}" "${url}"
    done <<< "${mirrors}"
    read_input sel "选择镜像源序号" "1"
    if ! [[ "${sel}" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > i )); then
        log_error "无效选择"
        return 1
    fi
    # 提取所选 URL
    local target_url=""
    local line_no=0
    while IFS='|' read -r name url; do
        line_no=$((line_no + 1))
        if (( line_no == sel )); then target_url="${url}"; break; fi
    done <<< "${mirrors}"

    confirm_action "将软件源切换为 ${target_url}" || return 1
    # 备份原源配置
    case "${pm}" in
        apt)
            local bak="/etc/apt/sources.list.bak.$(date +%s)"
            cp /etc/apt/sources.list "${bak}" 2>/dev/null || true
            echo "deb ${target_url%/}/ubuntu/ $(lsb_release -cs) main restricted universe multiverse" > /etc/apt/sources.list
            echo "deb ${target_url%/}/ubuntu/ $(lsb_release -cs)-updates main restricted universe multiverse" >> /etc/apt/sources.list
            echo "deb ${target_url%/}/ubuntu/ $(lsb_release -cs)-security main restricted universe multiverse" >> /etc/apt/sources.list
            apt-get update -qq
            log_success "apt 源已切换（备份: ${bak}）"
            ;;
        dnf|yum)
            local repo
            for repo in /etc/yum.repos.d/*.repo; do
                [[ -f "${repo}" ]] || continue
                sed -i "s|^baseurl=.*|baseurl=${target_url%/}/centos/\$releasever/BaseOS/\$basearch/os/|" "${repo}" 2>/dev/null || true
            done
            "${pm}" makecache
            log_success "yum/dnf 源已切换"
            ;;
        *)
            log_error "暂不支持 ${pm} 的镜像切换"
            ;;
    esac
}

# ------------------------------------------------------------
# [工具] 常用运维工具一键安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
tools_install() {
    check_root || return 1
    local tools=(htop iftop ncdu iotop mtr iperf3 jq yq)
    local need=()
    local t
    for t in "${tools[@]}"; do
        check_command "${t}" || need+=("${t}")
    done
    if [[ ${#need[@]} -eq 0 ]]; then
        log_success "常用工具已全部安装"
        return 0
    fi
    log_info "安装缺失工具: ${need[*]}"
    install_pkg "${need[@]}"
    log_success "工具安装完成"
}

# ------------------------------------------------------------
# [批量安装] 从列表文件或交互输入批量安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
batch_install() {
    check_root || return 1
    local file
    read_input file "包名列表文件路径（留空则手动输入，空格分隔）:" ""
    local pkgs=()
    if [[ -n "${file}" ]]; then
        if [[ ! -f "${file}" ]]; then
            log_error "文件不存在: ${file}"
            return 1
        fi
        mapfile -t pkgs < "${file}"
    else
        local input
        read_input input "输入包名（空格分隔）:" ""
        pkgs=(${input})
    fi
    [[ ${#pkgs[@]} -eq 0 ]] && { log_error "未输入任何软件包"; return 1; }
    log_info "批量安装: ${pkgs[*]}"
    install_pkg "${pkgs[@]}"
    log_success "批量安装完成"
}

# ------------------------------------------------------------
# [批量卸载] 从列表文件或交互输入批量卸载
# 参数：无
# 返回：无
# ------------------------------------------------------------
batch_remove() {
    check_root || return 1
    local file
    read_input file "包名列表文件路径（留空则手动输入，空格分隔）:" ""
    local pkgs=()
    if [[ -n "${file}" ]]; then
        [[ -f "${file}" ]] || { log_error "文件不存在: ${file}"; return 1; }
        mapfile -t pkgs < "${file}"
    else
        local input
        read_input input "输入包名（空格分隔）:" ""
        pkgs=(${input})
    fi
    [[ ${#pkgs[@]} -eq 0 ]] && { log_error "未输入任何软件包"; return 1; }
    confirm_action "卸载软件包: ${pkgs[*]}" || return 1
    case "$(detect_pkg_manager)" in
        apt)  apt-get purge -y "${pkgs[@]}" ;;
        dnf|yum) "${pm}" remove -y "${pkgs[@]}" ;;
        *)    log_error "暂不支持" ;;
    esac
    log_success "批量卸载完成"
}

# ------------------------------------------------------------
# [搜索] 搜索软件包
# 参数：无
# 返回：无
# ------------------------------------------------------------
pkg_search() {
    local keyword
    read_input keyword "输入搜索关键字:" ""
    [[ -z "${keyword}" ]] && { log_error "关键字不能为空"; return 1; }
    case "$(detect_pkg_manager)" in
        apt)  apt-cache search "${keyword}" | head -n 30 ;;
        dnf|yum) "$(detect_pkg_manager)" search "${keyword}" 2>/dev/null | head -n 30 ;;
        *)    log_error "暂不支持" ;;
    esac
}

# ------------------------------------------------------------
# [信息] 查看软件包详细信息
# 参数：无
# 返回：无
# ------------------------------------------------------------
pkg_info() {
    local pkg
    read_input pkg "输入软件包名:" ""
    [[ -z "${pkg}" ]] && { log_error "包名不能为空"; return 1; }
    case "$(detect_pkg_manager)" in
        apt)  apt-cache show "${pkg}" 2>/dev/null | head -n 40 ;;
        dnf|yum) "$(detect_pkg_manager)" info "${pkg}" 2>/dev/null | head -n 40 ;;
        *)    log_error "暂不支持" ;;
    esac
}

# ------------------------------------------------------------
# [第三方源] 添加 EPEL/IUS/PPA/Docker 软件源
# 参数：无
# 返回：无
# ------------------------------------------------------------
third_party_repo() {
    check_root || return 1
    local pm distro
    pm=$(detect_pkg_manager)
    distro=$(get_distro)
    echo "可添加的第三方源:"
    echo "  1. EPEL（RHEL系扩展包）"
    echo "  2. IUS（新版软件包）"
    echo "  3. PPA（Ubuntu个人软件源）"
    echo "  4. Docker CE 官方源"
    read_input sel "选择要添加的源:" ""
    case "${sel}" in
        1)
            if [[ "${pm}" == "dnf" || "${pm}" == "yum" ]]; then
                install_pkg epel-release || "${pm}" install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -q --qf '%{version}' rpm 2>/dev/null).noarch.rpm"
                log_success "EPEL 源已添加"
            else
                log_error "EPEL 仅适用于 RHEL/CentOS/Rocky/Alma"
            fi
            ;;
        2)
            confirm_action "添加 IUS 源（仅 CentOS 7）" || return 1
            if [[ "${distro}" == "centos" ]]; then
                yum install -y "https://repo.ius.io/ius-release-el7.rpm" && log_success "IUS 源已添加"
            else
                log_error "IUS 仅适用于 CentOS 7"
            fi
            ;;
        3)
            if [[ "${pm}" == "apt" ]]; then
                local ppa
                read_input ppa "输入 PPA 名称（如 ppa:deadsnakes/ppa）:" ""
                install_pkg software-properties-common
                add-apt-repository -y "${ppa}"
                apt-get update -qq
                log_success "PPA 已添加: ${ppa}"
            else
                log_error "PPA 仅适用于 Ubuntu/Debian"
            fi
            ;;
        4)
            if [[ "${pm}" == "apt" ]]; then
                install_pkg ca-certificates curl gnupg
                install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
                apt-get update -qq
                log_success "Docker CE 源已添加"
            else
                install_pkg yum-utils
                "${pm}" config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
                    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                log_success "Docker CE 源已添加"
            fi
            ;;
        *) log_error "无效选择" ;;
    esac
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
