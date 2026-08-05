#!/bin/bash
# ============================================================
# 文件：modules/10_devops.sh
# 功能：开发环境与部署 [Development & Deployment]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：Python(pyenv)/Node(nvm)/Java/Go/Rust 环境、Git 管理、
#       CI/CD(Jenkins/SonarQube/Webhook)、应用一键部署
# ============================================================
set -euo pipefail

module_name="开发环境与部署"
module_short="devops"
module_version="1.0.0"

module_description() {
    echo "Python/Node/Java/Go/Rust 开发环境、Git管理、Jenkins/SonarQube CI/CD、应用部署"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 开发语言环境安装"
    echo " 2. Git 安装与配置"
    echo " 3. Git 仓库管理（克隆/分支）"
    echo " 4. CI/CD 部署 (Jenkins/SonarQube)"
    echo " 5. Webhook 配置"
    echo " 6. 应用一键部署（Git拉取→编译→部署→重启）"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) lang_env ;;
        2) git_config ;;
        3) git_repo ;;
        4) cicd_deploy ;;
        5) webhook_config ;;
        6) app_deploy ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [语言环境] Python(pyenv)/Node(nvm)/Java/Go/Rust 安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
lang_env() {
    local lang
    echo "可安装语言环境:"
    echo "  1. Python (pyenv 多版本)"
    echo "  2. Node.js (nvm 多版本)"
    echo "  3. Java (OpenJDK 多版本)"
    echo "  4. Go"
    echo "  5. Rust"
    read_input lang "选择:" ""
    case "${lang}" in
        1) python_env ;;
        2) node_env ;;
        3) java_env ;;
        4) go_env ;;
        5) rust_env ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Python] pyenv 安装与版本管理
# 参数：无
# 返回：无
# ------------------------------------------------------------
python_env() {
    check_root || return 1
    if ! check_command pyenv; then
        log_info "安装 pyenv（Python版本管理器）..."
        install_pkg make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev 2>/dev/null || true
        curl -fsSL https://pyenv.run | bash || { log_error "pyenv 安装失败"; return 1; }
        grep -q pyenv ~/.bashrc || cat >> ~/.bashrc <<'EOF'
export PATH="$HOME/.pyenv/bin:$PATH"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
EOF
        log_warning "已写入 ~/.bashrc，请执行 source ~/.bashrc"
    fi
    local ver
    read_input ver "要安装的 Python 版本(如 3.12.4):" "3.12.4"
    export PATH="$HOME/.pyenv/bin:$PATH"
    pyenv install "${ver}" 2>/dev/null || true
    pyenv global "${ver}" 2>/dev/null || true
    log_success "Python ${ver} 安装完成"
}

# ------------------------------------------------------------
# [Node] nvm 安装与版本管理
# 参数：无
# 返回：无
# ------------------------------------------------------------
node_env() {
    if ! check_command nvm && [[ ! -d "${HOME}/.nvm" ]]; then
        log_info "安装 nvm（Node版本管理器）..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash || { log_error "nvm 安装失败"; return 1; }
        export NVM_DIR="$HOME/.nvm"
        # shellcheck source=/dev/null
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        log_warning "已写入 ~/.bashrc"
    fi
    local ver
    read_input ver "要安装的 Node 版本(如 20.15.0 或 lts):" "lts"
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install "${ver}" 2>/dev/null || true
    nvm use "${ver}" 2>/dev/null || true
    log_success "Node.js ${ver} 安装完成: $(node -v 2>/dev/null || true)"
}

# ------------------------------------------------------------
# [Java] OpenJDK 多版本安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
java_env() {
    check_root || return 1
    local ver
    read_input ver "OpenJDK 版本 [8/11/17/21]:" "17"
    case "$(detect_pkg_manager)" in
        apt)  install_pkg "openjdk-${ver}-jdk" ;;
        dnf|yum) install_pkg "java-${ver}-openjdk-devel" ;;
    esac
    log_success "OpenJDK ${ver} 安装完成"
    log_info "当前版本: $(java -version 2>&1 | head -n1)"
}

# ------------------------------------------------------------
# [Go] Go 语言安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
go_env() {
    check_root || return 1
    local ver arch
    read_input ver "Go 版本(Version):" "1.22.5"
    arch=$(get_arch)
    local gofile="go${ver}.linux-${arch}.tar.gz"
    show_spinner "下载 Go ${ver} ..."
    curl -fsSL "https://go.dev/dl/${gofile}" -o "/tmp/${gofile}"
    stop_spinner
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${gofile}"
    grep -q "/usr/local/go/bin" /etc/profile || echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    export PATH=$PATH:/usr/local/go/bin
    log_success "Go 安装完成: $(/usr/local/go/bin/go version 2>/dev/null || true)"
}

# ------------------------------------------------------------
# [Rust] Rust 安装（rustup）
# 参数：无
# 返回：无
# ------------------------------------------------------------
rust_env() {
    if ! check_command rustc; then
        log_info "安装 Rust（rustup）..."
        curl -fsSL https://sh.rustup.rs -sSf | sh -s -- -y || { log_error "rustup 安装失败"; return 1; }
        # shellcheck source=/dev/null
        [ -s "${HOME}/.cargo/env" ] && . "${HOME}/.cargo/env"
    fi
    log_success "Rust 安装完成: $(rustc --version 2>/dev/null || true)"
}

# ------------------------------------------------------------
# [Git] 安装与全局配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
git_config() {
    check_root || return 1
    check_command git || install_pkg git
    local name email
    read_input name "Git 用户名:" ""
    read_input email "Git 邮箱:" ""
    git config --global user.name "${name}"
    git config --global user.email "${email}"
    git config --global init.defaultBranch main
    git config --global pull.rebase false
    log_success "Git 配置完成"
    git config --list --global | grep user || true
}

# ------------------------------------------------------------
# [Git] 仓库管理（克隆/分支切换）
# 参数：无
# 返回：无
# ------------------------------------------------------------
git_repo() {
    check_command git || { log_error "Git 未安装"; return 1; }
    local act
    read_input act "操作 [1=克隆仓库 2=分支管理]:" "1"
    case "${act}" in
        1)
            local url dir
            read_input url "仓库地址(URL):" ""
            read_input dir "保存目录(留空自动):" ""
            if [[ -n "${dir}" ]]; then
                git clone "${url}" "${dir}"
            else
                git clone "${url}"
            fi
            log_success "仓库克隆完成"
            ;;
        2)
            local repo branch
            read_input repo "仓库路径:" "."
            read_input branch "要切换的分支:" ""
            (cd "${repo}" && git checkout "${branch}" && git pull 2>/dev/null || true)
            log_success "已切换分支: ${branch}"
            ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [CI/CD] Jenkins / SonarQube 一键部署
# 参数：无
# 返回：无
# ------------------------------------------------------------
cicd_deploy() {
    check_root || return 1
    local tool
    read_input tool "选择 [1=Jenkins 2=SonarQube]:" ""
    case "${tool}" in
        1)
            check_command java || { log_error "请先安装 Java（开发环境菜单）"; return 1; }
            local war_dir="/opt/jenkins"
            mkdir -p "${war_dir}"
            show_spinner "下载 Jenkins WAR 包（较新版本）..."
            curl -fsSL "https://get.jenkins.io/war-stable/latest/jenkins.war" -o "${war_dir}/jenkins.war"
            stop_spinner
            cat > /etc/systemd/system/jenkins.service <<EOF
[Unit]
Description=Jenkins CI [Continuous Integration]
After=network.target
[Service]
User=root
ExecStart=/usr/bin/java -jar ${war_dir}/jenkins.war --httpPort=8080
Restart=always
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now jenkins 2>/dev/null || true
            log_success "Jenkins 已启动（端口 8080），首次解锁密钥:"
            cat /root/.jenkins/secrets/initialAdminPassword 2>/dev/null || log_info "查看密钥: cat /root/.jenkins/secrets/initialAdminPassword"
            ;;
        2)
            log_info "SonarQube 推荐用 Docker 部署（容器模块）:"
            log_info "  docker run -d --name sonarqube -p 9000:9000 sonarqube:lts-community"
            log_warning "如需本地安装，请手动下载社区版: https://www.sonarsource.com/products/sonarqube/downloads/"
            ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Webhook] 配置 CI/CD Webhook 回调
# 参数：无
# 返回：无
# ------------------------------------------------------------
webhook_config() {
    local url token
    read_input url "Webhook URL:" ""
    read_input token "Secret Token(留空跳过):" ""
    log_info "Webhook 配置示例（curl 触发）:"
    echo "  curl -X POST '${url}' \\"
    if [[ -n "${token}" ]]; then
        echo "       -H 'Content-Type: application/json' \\"
        echo "       -d '{\"token\":\"${token}\",\"event\":\"deploy\"}'"
    else
        echo "       -H 'Content-Type: application/json' \\"
        echo "       -d '{\"event\":\"deploy\"}'"
    fi
    log_warning "请将以上命令配置到 Git 仓库 Webhook 设置中"
}

# ------------------------------------------------------------
# [应用部署] 应用一键部署（Git拉取→编译/打包→部署→重启）
# 参数：无
# 返回：无
# ------------------------------------------------------------
app_deploy() {
    check_root || return 1
    check_command git || { log_error "Git 未安装"; return 1; }
    local repo dir build_cmd deploy_dir svc
    read_input repo "Git 仓库地址:" ""
    read_input dir "项目工作目录:" "/opt/app"
    read_input build_cmd "编译/打包命令(如 mvn package -DskipTests; 留空跳过):" ""
    read_input deploy_dir "部署目录(如 /opt/deploy):" "/opt/deploy"
    read_input svc "重启服务名(systemd，留空跳过):" ""
    mkdir -p "${dir}"
    if [[ -d "${dir}/.git" ]]; then
        (cd "${dir}" && git pull)
    else
        git clone "${repo}" "${dir}" 2>/dev/null || { log_error "克隆失败"; return 1; }
    fi
    if [[ -n "${build_cmd}" ]]; then
        log_info "执行编译/打包..."
        (cd "${dir}" && eval "${build_cmd}") || { log_error "构建失败"; return 1; }
    fi
    # 同步构建产物到部署目录（排除 .git）
    mkdir -p "${deploy_dir}"
    rsync -a --exclude '.git' "${dir}/" "${deploy_dir}/" 2>/dev/null || cp -r "${dir}"/* "${deploy_dir}/"
    if [[ -n "${svc}" ]]; then
        systemctl restart "${svc}" 2>/dev/null || systemctl reload "${svc}" 2>/dev/null || true
        log_success "服务已重启: ${svc}"
    fi
    log_success "应用部署完成: ${repo} -> ${deploy_dir}"
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
