#!/bin/bash
# ============================================================
# 文件：modules/10_devops.sh
# 功能：开发环境与部署 [Development & Deployment]
# 作者：zc 团队
# 版本：1.1.0
# 日期：2026-08-06
# 说明：Python(pyenv)/Node(nvm)/Java/Go/Rust 环境、Git 管理、
#       CI/CD(Jenkins/SonarQube/Webhook)、应用一键部署
#       全部功能遵循"先看后改"原则，查看项置于菜单第一位
# 注意：函数统一使用 dev_/git_/ci_/webhook_/app_ 前缀，
#       避免与其他模块函数冲突
# ============================================================
set -euo pipefail

module_name="开发环境与部署"
module_short="devops"
module_version="1.1.0"

module_description() {
    echo "Python/Node/Java/Go/Rust 开发环境、Git管理、Jenkins/SonarQube CI/CD、应用部署"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 语言环境管理（查看/安装）"
    echo " 2. Git 安装与配置"
    echo " 3. Git 仓库管理（查看/克隆/分支）"
    echo " 4. CI/CD 管理 (Jenkins/SonarQube)"
    echo " 5. Webhook 配置"
    echo " 6. 应用一键部署"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) dev_lang_menu ;;
        2) git_config ;;
        3) git_repo_menu ;;
        4) ci_menu ;;
        5) webhook_menu ;;
        6) app_deploy_menu ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [语言环境] 二级菜单（查看在第一位）
# 参数：无
# 返回：无
# ------------------------------------------------------------
dev_lang_menu() {
    local act
    while true; do
        echo "--------------------------------------"
        echo "  语言环境管理"
        echo "--------------------------------------"
        echo " 1. 查看已安装的语言环境与版本"
        echo " 2. 安装语言环境 (Python/Node/Java/Go/Rust)"
        echo " 0. 返回上级菜单"
        echo "--------------------------------------"
        read -r -p "请选择 (0-2): " act || return 0
        case "${act}" in
            1) dev_lang_view ;;
            2) dev_lang_env ;;
            0) return 0 ;;
            *) log_error "无效选项: ${act}" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [语言环境] 查看已安装的语言环境与版本
# 依次检测 pyenv/nvm/java/go/rustc，检测到才显示（2>/dev/null 静默）
# 参数：无
# 返回：无
# ------------------------------------------------------------
dev_lang_view() {
    log_info "===== 已安装的语言环境与版本 ====="
    echo ""
    echo "== Python =="
    if check_command pyenv; then
        echo "  (pyenv 已安装，已安装版本:)"
        pyenv versions 2>/dev/null || echo "   （pyenv versions 无输出）"
    else
        echo "  pyenv 未安装"
        if check_command python3; then
            echo "  系统 Python3: $(python3 --version 2>/dev/null || true)"
        else
            echo "  python3 未安装"
        fi
    fi
    echo ""
    echo "== Node.js =="
    if [[ -d "${HOME}/.nvm" ]]; then
        echo "  (nvm 已安装，已安装版本:)"
        export NVM_DIR="${HOME}/.nvm"
        # shellcheck source=/dev/null
        [ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh"
        nvm ls 2>/dev/null || echo "   （nvm ls 无输出，尚未安装 Node 版本）"
    else
        echo "  nvm 未安装"
        if check_command node; then
            echo "  系统 Node: $(node -v 2>/dev/null || true)"
        else
            echo "  node 未安装"
        fi
    fi
    echo ""
    echo "== Java =="
    if check_command java; then
        java -version 2>&1 | head -n 3 || true
    else
        echo "  Java 未安装"
    fi
    echo ""
    echo "== Go =="
    if check_command go; then
        go version 2>/dev/null || true
    else
        echo "  Go 未安装"
    fi
    echo ""
    echo "== Rust =="
    if check_command rustc; then
        rustc --version 2>/dev/null || true
    else
        echo "  Rust 未安装"
    fi
}

# ------------------------------------------------------------
# [语言环境] Python(pyenv)/Node(nvm)/Java/Go/Rust 安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
dev_lang_env() {
    local lang
    echo "可安装语言环境:"
    echo "  1. Python (pyenv 多版本)"
    echo "  2. Node.js (nvm 多版本)"
    echo "  3. Java (OpenJDK 多版本)"
    echo "  4. Go"
    echo "  5. Rust"
    read_input lang "选择:" ""
    case "${lang}" in
        1) dev_python_env ;;
        2) dev_node_env ;;
        3) dev_java_env ;;
        4) dev_go_env ;;
        5) dev_rust_env ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Python] pyenv 安装与版本管理
# 参数：无
# 返回：无
# ------------------------------------------------------------
dev_python_env() {
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
dev_node_env() {
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
dev_java_env() {
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
dev_go_env() {
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
dev_rust_env() {
    if ! check_command rustc; then
        log_info "安装 Rust（rustup）..."
        curl -fsSL https://sh.rustup.rs -sSf | sh -s -- -y || { log_error "rustup 安装失败"; return 1; }
        # shellcheck source=/dev/null
        [ -s "${HOME}/.cargo/env" ] && . "${HOME}/.cargo/env"
    fi
    log_success "Rust 安装完成: $(rustc --version 2>/dev/null || true)"
}

# ------------------------------------------------------------
# [Git] 安装与全局配置（先看后改，配置后回显 git config --list）
# 参数：无
# 返回：无
# ------------------------------------------------------------
git_config() {
    check_root || return 1
    check_command git || install_pkg git
    # 先看后改：先展示当前 Git 全局配置
    log_info "===== 当前 Git 全局配置 ====="
    git config --list --global 2>/dev/null || echo "  （暂无全局配置）"
    local name email
    read_input name "Git 用户名(留空跳过):" ""
    read_input email "Git 邮箱(留空跳过):" ""
    if [[ -n "${name}" ]]; then
        git config --global user.name "${name}"
    fi
    if [[ -n "${email}" ]]; then
        git config --global user.email "${email}"
    fi
    git config --global init.defaultBranch main
    git config --global pull.rebase false
    log_success "Git 配置完成，当前生效配置 (git config --list):"
    git config --list || true
}

# ------------------------------------------------------------
# [Git] 仓库管理二级菜单（进入先显示仓库状态）
# 参数：无
# 返回：无
# ------------------------------------------------------------
git_repo_menu() {
    check_command git || { log_error "Git 未安装"; return 1; }
    # 先看后改：进入即显示仓库状态
    local repo
    read_input repo "仓库路径(用于查看状态):" "."
    log_info "===== 仓库 ${repo} 当前状态 (git status --short) ====="
    if [[ -d "${repo}/.git" ]]; then
        (cd "${repo}" && git status --short) 2>/dev/null || true
    else
        echo "  ${repo} 不是有效的 Git 仓库"
    fi
    local act
    while true; do
        echo "--------------------------------------"
        echo "  Git 仓库管理"
        echo "--------------------------------------"
        echo " 1. 查看仓库状态/分支/远程"
        echo " 2. 克隆仓库"
        echo " 3. 分支管理"
        echo " 0. 返回上级菜单"
        echo "--------------------------------------"
        read -r -p "请选择 (0-3): " act || return 0
        case "${act}" in
            1) git_repo_view ;;
            2) git_repo_clone ;;
            3) git_repo_branch ;;
            0) return 0 ;;
            *) log_error "无效选项: ${act}" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Git] 查看仓库状态/分支/远程
# 参数：无
# 返回：无
# ------------------------------------------------------------
git_repo_view() {
    local repo
    read_input repo "仓库路径:" "."
    [[ -d "${repo}/.git" ]] || { log_error "${repo} 不是有效的 Git 仓库"; return 1; }
    log_info "===== Git 仓库状态 (${repo}) ====="
    (cd "${repo}" && git status) || true
    log_info "===== 分支列表 (git branch -a) ====="
    (cd "${repo}" && git branch -a) || true
    log_info "===== 远程仓库 (git remote -v) ====="
    (cd "${repo}" && git remote -v) || true
}

# ------------------------------------------------------------
# [Git] 克隆仓库
# 参数：无
# 返回：无
# ------------------------------------------------------------
git_repo_clone() {
    local url dir
    read_input url "仓库地址(URL):" ""
    read_input dir "保存目录(留空自动):" ""
    [[ -n "${url}" ]] || { log_error "仓库地址不能为空"; return 1; }
    if [[ -n "${dir}" ]]; then
        git clone "${url}" "${dir}"
    else
        git clone "${url}"
    fi
    log_success "仓库克隆完成"
}

# ------------------------------------------------------------
# [Git] 分支管理（切换前先显示当前分支）
# 参数：无
# 返回：无
# ------------------------------------------------------------
git_repo_branch() {
    local repo branch
    read_input repo "仓库路径:" "."
    read_input branch "要切换的分支:" ""
    [[ -d "${repo}/.git" ]] || { log_error "${repo} 不是有效的 Git 仓库"; return 1; }
    log_info "===== 切换前当前分支 ====="
    (cd "${repo}" && git branch --show-current) 2>/dev/null || true
    (cd "${repo}" && git checkout "${branch}" && git pull 2>/dev/null || true)
    log_success "已切换分支: ${branch}"
}

# ------------------------------------------------------------
# [CI/CD] 二级菜单（查看在第一位）
# 参数：无
# 返回：无
# ------------------------------------------------------------
ci_menu() {
    check_root || return 1
    local act
    while true; do
        echo "--------------------------------------"
        echo "  CI/CD 管理 (Jenkins/SonarQube)"
        echo "--------------------------------------"
        echo " 1. 查看 Jenkins 服务状态与构建列表"
        echo " 2. 查看 SonarQube 服务状态"
        echo " 3. 部署 Jenkins"
        echo " 4. 部署 SonarQube"
        echo " 0. 返回上级菜单"
        echo "--------------------------------------"
        read -r -p "请选择 (0-4): " act || return 0
        case "${act}" in
            1) ci_jenkins_view ;;
            2) ci_sonar_view ;;
            3) ci_jenkins_deploy ;;
            4) ci_sonar_deploy ;;
            0) return 0 ;;
            *) log_error "无效选项: ${act}" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [CI/CD] 查看 Jenkins 服务状态与构建列表
# 参数：无
# 返回：无
# ------------------------------------------------------------
ci_jenkins_view() {
    log_info "===== Jenkins 服务状态 ====="
    if systemctl list-unit-files 2>/dev/null | grep -q '^jenkins'; then
        systemctl status jenkins --no-pager 2>/dev/null | head -n 12 || echo "  服务已注册但未运行"
    else
        echo "  Jenkins 未注册 systemd 服务"
        if check_command java; then
            echo "  Java 已安装: $(java -version 2>&1 | head -n1)"
        else
            echo "  Java 未安装（Jenkins 依赖 Java）"
        fi
        if [[ -f /opt/jenkins/jenkins.war ]]; then
            echo "  已存在 WAR 包: /opt/jenkins/jenkins.war"
        else
            echo "  （未找到 /opt/jenkins/jenkins.war）"
        fi
    fi
    log_info "===== Jenkins 构建任务列表 ====="
    if [[ -d /var/lib/jenkins/jobs ]]; then
        ls /var/lib/jenkins/jobs 2>/dev/null || echo "  （jobs 目录为空或不可读）"
    else
        echo "  （未找到 /var/lib/jenkins/jobs）"
    fi
}

# ------------------------------------------------------------
# [CI/CD] 查看 SonarQube 服务状态（systemd + Docker 容器）
# 参数：无
# 返回：无
# ------------------------------------------------------------
ci_sonar_view() {
    log_info "===== SonarQube 服务状态 ====="
    if systemctl list-unit-files 2>/dev/null | grep -q sonarqube; then
        systemctl status sonarqube --no-pager 2>/dev/null | head -n 12 || echo "  服务已注册但未运行"
    elif check_command docker && docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null | grep -i sonarqube; then
        :
    else
        echo "  未检测到 SonarQube 服务（本地安装或 Docker 容器均未发现）"
    fi
    log_info "===== SonarQube Web 端口探测 (9000) ====="
    curl -s --max-time 3 -o /dev/null -w "  http://localhost:9000 -> HTTP %{http_code}\n" http://localhost:9000 2>/dev/null \
        || echo "  http://localhost:9000 未响应"
}

# ------------------------------------------------------------
# [CI/CD] 部署 Jenkins（WAR + systemd）
# 参数：无
# 返回：无
# ------------------------------------------------------------
ci_jenkins_deploy() {
    check_root || return 1
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
}

# ------------------------------------------------------------
# [CI/CD] 部署 SonarQube（推荐 Docker 方式）
# 参数：无
# 返回：无
# ------------------------------------------------------------
ci_sonar_deploy() {
    log_info "SonarQube 推荐用 Docker 部署（容器模块）:"
    log_info "  docker run -d --name sonarqube -p 9000:9000 sonarqube:lts-community"
    log_warning "如需本地安装，请手动下载社区版: https://www.sonarsource.com/products/sonarqube/downloads/"
}

# ------------------------------------------------------------
# [Webhook] 二级菜单（查看在第一位）
# 参数：无
# 返回：无
# ------------------------------------------------------------
webhook_menu() {
    local act
    while true; do
        echo "--------------------------------------"
        echo "  Webhook 配置"
        echo "--------------------------------------"
        echo " 1. 查看已配置的 Webhook"
        echo " 2. 配置 Webhook"
        echo " 0. 返回上级菜单"
        echo "--------------------------------------"
        read -r -p "请选择 (0-2): " act || return 0
        case "${act}" in
            1) webhook_view ;;
            2) webhook_config ;;
            0) return 0 ;;
            *) log_error "无效选项: ${act}" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Webhook] 查看已配置的 Webhook（${CONFIG_DIR}/webhooks.conf）
# 参数：无
# 返回：无
# ------------------------------------------------------------
webhook_view() {
    local wf="${CONFIG_DIR}/webhooks.conf"
    log_info "===== 已配置的 Webhook (${wf}) ====="
    if [[ -f "${wf}" ]]; then
        cat "${wf}" 2>/dev/null || true
    else
        echo "  （未找到配置文件，尚未配置任何 Webhook）"
    fi
}

# ------------------------------------------------------------
# [Webhook] 配置 CI/CD Webhook 回调（记录配置供查看）
# 参数：无
# 返回：无
# ------------------------------------------------------------
webhook_config() {
    local url token
    read_input url "Webhook URL:" ""
    read_input token "Secret Token(留空跳过):" ""
    [[ -n "${url}" ]] || { log_error "Webhook URL 不能为空"; return 1; }
    # 记录配置（token 属敏感信息，仅记录 URL 与时间，不落盘）
    mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
    if [[ -n "${token}" ]]; then
        echo "# $(date '+%Y-%m-%d %H:%M:%S') URL=${url} (token 已配置: 是)" >> "${CONFIG_DIR}/webhooks.conf" 2>/dev/null || true
    else
        echo "# $(date '+%Y-%m-%d %H:%M:%S') URL=${url} (token 已配置: 否)" >> "${CONFIG_DIR}/webhooks.conf" 2>/dev/null || true
    fi
    log_info "Webhook 配置示例（curl 触发）:"
    echo "  curl -X POST '${url}' \\"
    if [[ -n "${token}" ]]; then
        echo "       -H 'Content-Type: application/json' \\"
        echo "       -d '{\"token\":\"${token}\",\"event\":\"deploy\"}'"
    else
        echo "       -H 'Content-Type: application/json' \\"
        echo "       -d '{\"event\":\"deploy\"}'"
    fi
    log_success "已记录到 ${CONFIG_DIR}/webhooks.conf"
    log_warning "请将以上命令配置到 Git 仓库 Webhook 设置中"
}

# ------------------------------------------------------------
# [应用部署] 二级菜单（查看在第一位）
# 参数：无
# 返回：无
# ------------------------------------------------------------
app_deploy_menu() {
    check_root || return 1
    local act
    while true; do
        echo "--------------------------------------"
        echo "  应用一键部署"
        echo "--------------------------------------"
        echo " 1. 查看已部署应用/进程状态"
        echo " 2. 一键部署（Git拉取→编译→部署→重启）"
        echo " 0. 返回上级菜单"
        echo "--------------------------------------"
        read -r -p "请选择 (0-2): " act || return 0
        case "${act}" in
            1) app_view ;;
            2) app_deploy ;;
            0) return 0 ;;
            *) log_error "无效选项: ${act}" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [应用部署] 查看已部署应用/进程状态
# 列出部署记录，并按记录检查 systemd 服务与进程
# 参数：无
# 返回：无
# ------------------------------------------------------------
app_view() {
    local record="${CONFIG_DIR}/deployments.conf"
    log_info "===== 已部署应用/进程状态 ====="
    if [[ -f "${record}" ]]; then
        echo "== 部署记录 (${record}) =="
        cat "${record}" 2>/dev/null || true
        # 根据部署记录逐一检查服务与进程
        local line svc deploy_dir
        while IFS= read -r line; do
            [[ "${line}" == \#* ]] || continue
            svc=$(echo "${line}" | grep -oE 'svc=[^ ]+' | head -n1 | cut -d= -f2- || true)
            deploy_dir=$(echo "${line}" | grep -oE 'deploy_dir=[^ ]+' | head -n1 | cut -d= -f2- || true)
            if [[ -n "${svc}" && "${svc}" != "无" ]]; then
                log_info "服务 ${svc} 状态:"
                systemctl status "${svc}" --no-pager 2>/dev/null | head -n 5 || echo "  服务 ${svc} 未运行"
            fi
            if [[ -n "${deploy_dir}" && "${deploy_dir}" != "无" ]]; then
                log_info "部署目录 ${deploy_dir} 相关进程:"
                ps aux 2>/dev/null | grep -F "${deploy_dir}" | grep -v grep | head -n 5 || echo "  无匹配进程"
            fi
        done < "${record}"
    else
        echo "  （未找到部署记录 ${record}，尚无已部署应用）"
    fi
}

# ------------------------------------------------------------
# [应用部署] 应用一键部署（Git拉取→编译/打包→部署→重启）
# 部署成功后记录信息供"查看已部署应用"使用
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
    [[ -n "${repo}" ]] || { log_error "仓库地址不能为空"; return 1; }
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
    # 记录部署信息，供"查看已部署应用"使用
    mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
    echo "# $(date '+%Y-%m-%d %H:%M:%S') repo=${repo} dir=${dir} deploy_dir=${deploy_dir} svc=${svc:-无}" >> "${CONFIG_DIR}/deployments.conf" 2>/dev/null || true
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
