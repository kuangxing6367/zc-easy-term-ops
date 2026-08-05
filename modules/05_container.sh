#!/bin/bash
# ============================================================
# 文件：modules/05_container.sh
# 功能：容器管理 [Container Management]
# 作者：zc 团队
# 版本：1.1.0
# 日期：2026-08-06
# 说明：Docker/Podman 安装、镜像(image)/容器/网络/数据卷管理、
#       Docker Compose 一键部署、私有镜像仓库(Harbor)
#       先看后改：提供 Docker 状态/资源占用/Compose 状态查看
# ============================================================
set -euo pipefail

module_name="容器管理"
module_short="container"
module_version="1.1.0"

DOCKER_REGISTRY="${DOCKER_REGISTRY:-docker.io}"

module_description() {
    echo "Docker/Podman 安装与镜像(Image)/容器(Container)/网络/数据卷管理、Compose部署、Harbor仓库"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. Docker 安装（从 API 获取安装脚本）"
    echo " 2. Docker 状态查看（daemon/空间/容器占用）"
    echo " 3. Docker 镜像管理"
    echo " 4. Docker 容器管理"
    echo " 5. Docker 网络管理"
    echo " 6. Docker 数据卷管理"
    echo " 7. Docker Compose 安装"
    echo " 8. Compose 项目管理（查看/部署/停止）"
    echo " 9. Podman 安装"
    echo "10. 私有镜像仓库 (Harbor)"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) docker_install ;;
        2) docker_view ;;
        3) docker_images ;;
        4) docker_containers ;;
        5) docker_network ;;
        6) docker_volume ;;
        7) docker_compose_install ;;
        8) docker_compose_manager ;;
        9) podman_install ;;
        10) harbor_deploy ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [Docker] 安装（优先从 API 获取安装脚本/下载地址）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_install() {
    check_root || return 1
    if check_command docker; then
        log_success "Docker 已安装: $(docker --version)"
        return 0
    fi
    # 从 API 节点获取安装脚本地址（Install Script）
    local script_url
    script_url=$(api_fetch "docker/install-script?distro=$(get_distro)" || true)
    if [[ -n "${script_url}" ]]; then
        show_spinner "从 API 下载安装脚本..."
        curl -fsSL "${script_url}" -o /tmp/zetops-docker-install.sh || { stop_spinner; log_error "脚本下载失败"; return 1; }
        stop_spinner
        bash /tmp/zetops-docker-install.sh
    else
        log_warning "API 未配置，使用官方 get.docker.com 脚本"
        curl -fsSL https://get.docker.com | sh || { log_error "Docker 安装失败"; return 1; }
    fi
    systemctl enable --now docker 2>/dev/null || true
    docker --version && log_success "Docker 安装完成"
    log_info "添加当前用户到 docker 组（免 sudo）: usermod -aG docker $USER"
}

# ============================================================
# Docker 状态查看 二级菜单（先看后改）
# ============================================================
docker_view() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    local c
    while true; do
        echo "======================================"
        echo "  [Docker状态查看] 子菜单"
        echo "======================================"
        echo " 1. 查看 Docker 守护进程信息 (docker info)"
        echo " 2. 查看 Docker 空间占用 (docker system df)"
        echo " 3. 查看容器资源占用 (docker stats --no-stream)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-3) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) docker_info_view ;;
            2) docker_df_view ;;
            3) docker_stats_view ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Docker] 查看守护进程信息（docker info 关键字段）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_info_view() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    log_info "Docker 守护进程信息（关键字段）:"
    docker info 2>/dev/null | grep -E "^(Server Version|Storage Driver|Containers:|Images:|Operating System|Kernel Version|Cgroup Version)" \
        || log_error "无法获取 docker info（请确认 docker 服务已启动）"
}

# ------------------------------------------------------------
# [Docker] 查看空间占用（docker system df）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_df_view() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    log_info "Docker 空间占用 (docker system df):"
    docker system df 2>/dev/null \
        || log_error "无法获取空间占用（请确认 docker 服务已启动）"
}

# ------------------------------------------------------------
# [Docker] 查看容器资源占用（docker stats --no-stream）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_stats_view() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    log_info "容器资源占用 (docker stats --no-stream):"
    docker stats --no-stream 2>/dev/null \
        || log_error "无法获取容器资源占用（请确认 docker 服务已启动）"
}

# ------------------------------------------------------------
# [Docker] 镜像（Image）管理
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_images() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    local act
    log_info "当前镜像列表:"
    docker images
    read_input act "操作 [1=拉取 2=删除 3=构建 0=仅查看返回]:" "0"
    case "${act}" in
        1)
            local img
            read_input img "镜像名(如 ${DOCKER_REGISTRY}/nginx:latest):" "nginx:latest"
            show_spinner "拉取镜像 ${img} ..."
            docker pull "${img}"
            stop_spinner
            log_success "镜像拉取完成"
            ;;
        2)
            local img
            read_input img "要删除的镜像 ID/名称:" ""
            confirm_action "删除镜像 ${img}" || return 1
            docker rmi "${img}"
            log_success "镜像已删除"
            ;;
        3)
            local dir tag
            read_input dir "Dockerfile 目录:" "."
            read_input tag "镜像标签:" "myapp:latest"
            docker build -t "${tag}" "${dir}"
            log_success "镜像构建完成: ${tag}"
            ;;
        0) return ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Docker] 容器（Container）管理
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_containers() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    local act
    log_info "运行中容器列表:"
    docker ps
    read_input act "操作 [1=运行新容器 2=停止 3=启动 4=删除 5=日志 0=仅查看返回]:" "0"
    local cid
    case "${act}" in
        1)
            local img name port
            read_input img "镜像名:" "nginx:latest"
            read_input name "容器名:" "web1"
            read_input port "端口映射(如 8080:80):" ""
            docker run -d --name "${name}" -p "${port}" "${img}"
            log_success "容器已启动: ${name}"
            ;;
        2) read_input cid "容器 ID/名称:" ""; docker stop "${cid}" ;;
        3) read_input cid "容器 ID/名称:" ""; docker start "${cid}" ;;
        4) read_input cid "容器 ID/名称:" ""; confirm_action "删除容器 ${cid}" || return 1; docker rm -f "${cid}" ;;
        5) read_input cid "容器 ID/名称:" ""; docker logs -f --tail 100 "${cid}" ;;
        0) return ;;
        *) log_error "无效选择" ;;
    esac
}
# ------------------------------------------------------------
# [Docker] 网络管理
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_network() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    local act
    log_info "网络列表:"
    docker network ls
    read_input act "操作 [1=创建 2=删除 0=仅查看返回]:" "0"
    local name
    case "${act}" in
        1) read_input name "网络名:" "mynet"; docker network create "${name}" && log_success "网络已创建" ;;
        2) read_input name "网络名:" ""; confirm_action "删除网络 ${name}" || return 1; docker network rm "${name}" ;;
        0) return ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Docker] 数据卷（Volume）管理
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_volume() {
    check_command docker || { log_error "Docker 未安装"; return 1; }
    local act
    log_info "数据卷列表:"
    docker volume ls
    read_input act "操作 [1=创建 2=删除 0=仅查看返回]:" "0"
    local name
    case "${act}" in
        1) read_input name "卷名:" "data1"; docker volume create "${name}" && log_success "数据卷已创建" ;;
        2) read_input name "卷名:" ""; confirm_action "删除数据卷 ${name}" || return 1; docker volume rm "${name}" ;;
        0) return ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Compose] 安装 docker-compose
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_compose_install() {
    check_root || return 1
    if check_command docker-compose; then
        log_success "docker-compose 已安装: $(docker-compose --version)"
        return 0
    fi
    local ver
    read_input ver "Compose 版本(Version):" "v2.29.7"
    show_spinner "下载 docker-compose ..."
    curl -fsSL "https://github.com/docker/compose/releases/download/${ver}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    stop_spinner
    chmod +x /usr/local/bin/docker-compose
    docker-compose --version && log_success "docker-compose 安装完成"
}

# ------------------------------------------------------------
# [Compose] 获取可用的 compose 命令（docker compose 插件优先）
# 参数：无
# 输出：docker compose / docker-compose / 空
# ------------------------------------------------------------
docker_compose_bin() {
    if check_command docker && docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif check_command docker-compose; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# ------------------------------------------------------------
# [Compose] 项目管理 二级菜单（查看/部署/停止）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_compose_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [Compose项目管理] 子菜单"
        echo "======================================"
        echo " 1. 查看 Compose 项目运行状态"
        echo " 2. 部署 (up -d)"
        echo " 3. 停止 (down)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-3) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) docker_compose_view ;;
            2) docker_compose_up ;;
            3) docker_compose_down ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Compose] 查看项目运行状态（docker compose ps 或 docker-compose ps）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_compose_view() {
    local dir cmd
    read_input dir "Compose 项目目录:" "."
    [[ -f "${dir}/compose.yaml" || -f "${dir}/docker-compose.yml" || -f "${dir}/compose.yml" ]] \
        || { log_error "目录中未找到 compose 文件"; return 1; }
    cmd=$(docker_compose_bin)
    [[ -n "${cmd}" ]] || { log_error "未找到 docker compose / docker-compose"; return 1; }
    log_info "Compose 项目运行状态 (${dir}):"
    (cd "${dir}" && ${cmd} ps) 2>/dev/null || log_warning "项目未运行或状态获取失败"
}

# ------------------------------------------------------------
# [Compose] 部署（up -d）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_compose_up() {
    local dir cmd
    read_input dir "Compose 项目目录:" "."
    [[ -f "${dir}/compose.yaml" || -f "${dir}/docker-compose.yml" || -f "${dir}/compose.yml" ]] \
        || { log_error "目录中未找到 compose 文件"; return 1; }
    cmd=$(docker_compose_bin)
    [[ -n "${cmd}" ]] || { log_error "未找到 docker compose / docker-compose"; return 1; }
    show_spinner "Compose 部署中..."
    (cd "${dir}" && ${cmd} up -d) || { stop_spinner; log_error "Compose 部署失败"; return 1; }
    stop_spinner
    log_success "Compose 部署完成"
}

# ------------------------------------------------------------
# [Compose] 停止（down）
# 参数：无
# 返回：无
# ------------------------------------------------------------
docker_compose_down() {
    local dir cmd
    read_input dir "Compose 项目目录:" "."
    [[ -f "${dir}/compose.yaml" || -f "${dir}/docker-compose.yml" || -f "${dir}/compose.yml" ]] \
        || { log_error "目录中未找到 compose 文件"; return 1; }
    cmd=$(docker_compose_bin)
    [[ -n "${cmd}" ]] || { log_error "未找到 docker compose / docker-compose"; return 1; }
    (cd "${dir}" && ${cmd} down) || { log_error "Compose 停止失败"; return 1; }
    log_success "Compose 已停止"
}
# ------------------------------------------------------------
# [Podman] 安装（兼容 Docker 命令）
# 参数：无
# 返回：无
# ------------------------------------------------------------
podman_install() {
    check_root || return 1
    case "$(detect_pkg_manager)" in
        apt)  install_pkg podman ;;
        dnf|yum) install_pkg podman ;;
        *)    log_error "暂不支持" ;;
    esac
    log_success "Podman 已安装"
    log_info "兼容使用: alias docker=podman 即可用 Docker 命令"
}

# ------------------------------------------------------------
# [Harbor] 私有镜像仓库部署（docker compose 方式）
# 参数：无
# 返回：无
# ------------------------------------------------------------
harbor_deploy() {
    check_root || return 1
    check_command docker || { log_error "请先安装 Docker"; return 1; }
    local ver
    read_input ver "Harbor 版本(Version):" "v2.11.1"
    local inst="/opt/harbor"
    show_spinner "下载 Harbor offline 安装包（较大）..."
    curl -fsSL "https://github.com/goharbor/harbor/releases/download/${ver}/harbor-offline-installer-${ver}.tgz" -o /tmp/harbor.tgz
    stop_spinner
    mkdir -p "${inst}"
    tar xzf /tmp/harbor.tgz -C /opt --strip-components=1 2>/dev/null || tar xzf /tmp/harbor.tgz -C /opt
    cd /opt/harbor 2>/dev/null || cd /opt
    cp harbor.yml.tmpl harbor.yml 2>/dev/null || true
    log_info "请编辑 harbor.yml（hostname/端口/密码），然后执行:"
    log_info "  ./install.sh --with-trivy"
    log_success "Harbor 安装包已就绪: /opt/harbor"
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
        read -r -p "请选择 (0-10) [q=退出]: " _c || break
        [[ "${_c}" == "q" ]] && break
        module_execute "${_c}" || true
        [[ "${_c}" == "0" ]] && break
    done
fi