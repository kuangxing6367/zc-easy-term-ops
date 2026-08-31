#!/bin/bash
# ============================================================
# 文件：modules/02_package_manager.sh
# 功能：软件包与仓库管理 [Package & Repository Manager]
# 作者：zc 团队
# 版本：1.1.0
# 日期：2026-08-06
# 说明：软件源查看、镜像切换(API动态获取)、常用工具安装、
#       批量安装/卸载、搜索与信息查看、已安装列表、
#       第三方软件源(EPEL/IUS/PPA/Docker)
# ============================================================
set -euo pipefail

module_name="软件包与仓库管理"
module_short="package"
module_version="1.1.0"

module_description() {
    echo "软件源查看与镜像切换(清华/阿里/中科大)、常用工具安装、批量安装卸载、第三方源"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看当前软件源"
    echo " 2. 软件源镜像切换 (Mirror)"
    echo " 3. 常用工具一键安装"
    echo " 4. 批量安装软件包"
    echo " 5. 批量卸载软件包"
    echo " 6. 软件包搜索"
    echo " 7. 软件包信息查看"
    echo " 8. 查看已安装软件包列表"
    echo " 9. 查看第三方软件源"
    echo "10. 添加第三方软件源"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) repo_view ;;
        2) mirror_switch ;;
        3) tools_install ;;
        4) batch_install ;;
        5) batch_remove ;;
        6) pkg_search ;;
        7) pkg_info ;;
        8) pkg_list_installed ;;
        9) third_party_repo_view ;;
       10) third_party_repo ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [软件源] 查看当前软件源配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
repo_view() {
    local pm f found=0 n_active=0 line
    pm=$(detect_pkg_manager)
    log_info "================ 当前软件源配置 ================"
    case "${pm}" in
        apt)
            # 主配置文件 /etc/apt/sources.list
            echo "--- /etc/apt/sources.list ---"
            if [[ -f /etc/apt/sources.list ]]; then
                cat /etc/apt/sources.list
                found=1
                # 统计主文件中的有效源条目
                while IFS= read -r line; do
                    case "${line}" in
                        deb\ *|deb-src\ *) n_active=$((n_active + 1)) ;;
                    esac
                done < /etc/apt/sources.list 2>/dev/null || true
            else
                echo "  （未检测到该文件）"
                echo "  （现代 Debian/Ubuntu 默认将源配置放在 /etc/apt/sources.list.d/ 下，属正常情况；请查看下方目录内容）"
            fi
            # 附加源目录：兼容 .list（旧格式）与 .sources（deb822 新格式，Debian 12+/阿里云等默认）及任意命名文件
            echo "--- /etc/apt/sources.list.d/ ---"
            for f in /etc/apt/sources.list.d/*; do
                [[ -f "${f}" ]] || continue
                found=1
                echo ">>> ${f}"
                cat "${f}" 2>/dev/null || true
                # 统计有效源条目（.list 的 deb/deb-src 行 与 .sources 的 URIs 行）
                while IFS= read -r line; do
                    case "${line}" in
                        deb\ *|deb-src\ *|URIs:\ *) n_active=$((n_active + 1)) ;;
                    esac
                done < "${f}" 2>/dev/null || true
            done
            if (( found == 0 )); then
                echo "  （未找到任何 apt 源配置文件，apt 可能无法正常安装软件）"
            else
                echo "  汇总: 共发现 ${n_active} 条有效源条目（deb/URIs 行）"
            fi
            ;;
        dnf|yum)
            "${pm}" repolist 2>/dev/null || log_warning "repolist 获取失败"
            ;;
        *)
            log_warning "暂不支持 ${pm} 的软件源查看"
            ;;
    esac
    echo "-----------------------------------------------"
}

# ------------------------------------------------------------
# [镜像源] 切换软件源镜像（切换前先展示当前源，从 API 获取镜像列表）
# 参数：无
# 返回：无
# ------------------------------------------------------------
mirror_switch() {
    check_root || return 1
    log_info "切换前先展示当前软件源配置:"
    repo_view
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
    local sel
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
            local codename
            codename=$(get_codename)
            if [[ -z "${codename}" ]]; then
                log_error "无法获取发行版代号，已中止切换（备份: ${bak}）"
                return 1
            fi
            case "$(get_distro)" in
                ubuntu)
                    {
                        echo "deb ${target_url%/}/ubuntu/ ${codename} main restricted universe multiverse"
                        echo "deb ${target_url%/}/ubuntu/ ${codename}-updates main restricted universe multiverse"
                        echo "deb ${target_url%/}/ubuntu/ ${codename}-security main restricted universe multiverse"
                    } > /etc/apt/sources.list
                    ;;
                debian|*)
                    {
                        echo "deb ${target_url%/}/debian/ ${codename} main contrib non-free"
                        echo "deb ${target_url%/}/debian/ ${codename}-updates main contrib non-free"
                        echo "deb ${target_url%/}/debian-security/ ${codename}-security main contrib non-free"
                    } > /etc/apt/sources.list
                    ;;
            esac
            if apt-get update -qq; then
                log_success "apt 源已切换（备份: ${bak}）"
            else
                log_error "apt 源切换后更新失败（备份: ${bak}），请检查镜像地址与发行版是否匹配"
                return 1
            fi
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
    if install_pkg "${need[@]}"; then
        log_success "工具安装完成"
    else
        log_error "部分或全部工具安装失败，请检查软件源配置后重试"
        return 1
    fi
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
    if install_pkg "${pkgs[@]}"; then
        log_success "批量安装完成"
    else
        log_error "部分或全部软件包安装失败，请检查软件源配置后重试"
        return 1
    fi
}

# ------------------------------------------------------------
# [批量卸载] 从列表文件或交互输入批量卸载
# 参数：无
# 返回：无
# ------------------------------------------------------------
batch_remove() {
    check_root || return 1
    local file pm
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
    pm=$(detect_pkg_manager)
    local rc=0
    case "${pm}" in
        apt)  apt-get purge -y "${pkgs[@]}"; rc=$? ;;
        dnf|yum) "${pm}" remove -y "${pkgs[@]}"; rc=$? ;;
        *)    log_error "暂不支持"; return 1 ;;
    esac
    if [[ "${rc}" -eq 0 ]]; then
        log_success "批量卸载完成"
    else
        log_error "部分或全部软件包卸载失败"
        return 1
    fi
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
        apt)  apt-cache search "${keyword}" 2>/dev/null | head -n 30 || true ;;
        dnf|yum) "$(detect_pkg_manager)" search "${keyword}" 2>/dev/null | head -n 30 || true ;;
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
        apt)  apt-cache show "${pkg}" 2>/dev/null | head -n 40 || true ;;
        dnf|yum) "$(detect_pkg_manager)" info "${pkg}" 2>/dev/null | head -n 40 || true ;;
        *)    log_error "暂不支持" ;;
    esac
}

# ------------------------------------------------------------
# [已安装] 查看已安装软件包列表（支持关键字过滤）
# 参数：无
# 返回：无
# ------------------------------------------------------------
pkg_list_installed() {
    local keyword pm
    read_input keyword "输入过滤关键字（留空显示全部）:" ""
    pm=$(detect_pkg_manager)
    log_info "================ 已安装软件包列表 ================"
    case "${pm}" in
        apt)
            if [[ -n "${keyword}" ]]; then
                dpkg -l 2>/dev/null | grep '^ii' | grep -i "${keyword}" || log_info "未找到匹配的软件包: ${keyword}"
            else
                dpkg -l 2>/dev/null | grep '^ii' || log_info "未查询到已安装软件包"
            fi
            ;;
        dnf|yum)
            if [[ -n "${keyword}" ]]; then
                rpm -qa 2>/dev/null | grep -i "${keyword}" || log_info "未找到匹配的软件包: ${keyword}"
            else
                rpm -qa 2>/dev/null || log_info "未查询到已安装软件包"
            fi
            ;;
        *)
            log_warning "暂不支持 ${pm} 的已安装列表查询"
            ;;
    esac
    echo "-----------------------------------------------"
}

# ------------------------------------------------------------
# [第三方源] 查看已添加的第三方软件源
# 参数：无
# 返回：无
# ------------------------------------------------------------
third_party_repo_view() {
    local pm f
    pm=$(detect_pkg_manager)
    log_info "================ 已添加的第三方软件源 ================"
    case "${pm}" in
        apt)
            echo "--- /etc/apt/sources.list.d/ ---"
            if ls /etc/apt/sources.list.d/*.list >/dev/null 2>&1; then
                for f in /etc/apt/sources.list.d/*.list; do
                    echo ">>> ${f}"
                    cat "${f}" 2>/dev/null || true
                done
            else
                echo "（无附加第三方源）"
            fi
            ;;
        dnf|yum)
            echo "--- /etc/yum.repos.d/ ---"
            if ls /etc/yum.repos.d/*.repo >/dev/null 2>&1; then
                for f in /etc/yum.repos.d/*.repo; do
                    echo ">>> ${f}"
                    head -n 8 "${f}" 2>/dev/null || true
                done
            else
                echo "（无第三方源文件）"
            fi
            ;;
        *)
            log_warning "暂不支持 ${pm} 的第三方源查看"
            ;;
    esac
    echo "-----------------------------------------------"
}

# ------------------------------------------------------------
# [第三方源] 添加 EPEL/IUS/PPA/Docker 软件源
# 参数：无
# 返回：无
# ------------------------------------------------------------
third_party_repo() {
    check_root || return 1
    local pm distro sel
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
                if yum install -y "https://repo.ius.io/ius-release-el7.rpm"; then
                    log_success "IUS 源已添加"
                else
                    log_error "IUS 源安装失败"
                fi
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
                if apt-get update -qq; then
                    log_success "PPA 已添加: ${ppa}"
                else
                    log_error "PPA 已添加但索引刷新失败，请检查网络或 PPA 名称"
                    return 1
                fi
            else
                log_error "PPA 仅适用于 Ubuntu/Debian"
            fi
            ;;
        4)
            if [[ "${pm}" == "apt" ]]; then
                install_pkg ca-certificates curl gnupg
                install -m 0755 -d /etc/apt/keyrings
                local docker_distro
                case "$(get_distro)" in
                    ubuntu)  docker_distro="ubuntu" ;;
                    debian|*) docker_distro="debian" ;;
                esac
                curl -fsSL "https://download.docker.com/linux/${docker_distro}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_distro} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
                if apt-get update -qq; then
                    log_success "Docker CE 源已添加"
                else
                    log_error "Docker CE 源已添加但索引刷新失败，请检查网络连通性"
                    return 1
                fi
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