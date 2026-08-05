#!/bin/bash
# ============================================================
# 文件：modules/03_web_server.sh
# 功能：Web 服务器与反向代理 [Web Server & Reverse Proxy]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：Nginx（编译安装/虚拟主机/SSL/负载均衡/限流/日志分析）、
#       Apache（安装/虚拟主机/模块）、Tomcat（安装/JVM/部署war包）
# ============================================================
set -euo pipefail

module_name="Web服务器与反向代理"
module_short="web_server"
module_version="1.0.0"

# 默认配置（可通过 ~/.zetops/zetops.conf 覆盖）
NGINX_PREFIX="${NGINX_PREFIX:-/usr/local/nginx}"

module_description() {
    echo "Nginx/Apache/Tomcat 安装与配置、SSL证书(Let's Encrypt)、反向代理(Reverse Proxy)"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. Nginx 管理（安装/虚拟主机/SSL/负载均衡）"
    echo " 2. Apache 管理"
    echo " 3. Tomcat 管理"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) nginx_manager ;;
        2) apache_manager ;;
        3) tomcat_manager ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ============================================================
# Nginx 二级管理菜单
# ============================================================
nginx_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [Nginx管理] 子菜单"
        echo "======================================"
        echo " 1. 编译安装 Nginx（可选SSL/Stream模块）"
        echo " 2. 虚拟主机配置 (VirtualHost)"
        echo " 3. SSL 证书配置 (Let's Encrypt)"
        echo " 4. 负载均衡配置 (Load Balancing)"
        echo " 5. 限流配置 (Rate Limit)"
        echo " 6. 配置语法检查 (nginx -t)"
        echo " 7. 日志分析"
        echo " 8. 重载配置"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-8) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) nginx_install ;;
            2) nginx_vhost ;;
            3) nginx_ssl ;;
            4) nginx_lb ;;
            5) nginx_limit ;;
            6) nginx_check ;;
            7) nginx_log_analysis ;;
            8) nginx_reload_config ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Nginx] 编译安装（交互选择 SSL(安全套接层)/Stream(流代理) 模块）
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_install() {
    check_root || return 1
    if [[ -x "${NGINX_PREFIX}/sbin/nginx" ]]; then
        log_success "Nginx 已安装: ${NGINX_PREFIX}/sbin/nginx"
        return 0
    fi
    local ver use_ssl use_stream
    read_input ver "Nginx 版本(Version):" "1.26.2"
    read_input use_ssl "启用 SSL 模块? [y/n]:" "y"
    read_input use_stream "启用 Stream(流代理)模块? [y/n]:" "y"

    log_info "安装编译依赖 ..."
    case "$(detect_pkg_manager)" in
        apt)  install_pkg build-essential libpcre3-dev zlib1g-dev libssl-dev libgeoip-dev ;;
        dnf|yum) install_pkg gcc make pcre-devel zlib-devel openssl-devel geoip-devel ;;
        *)    log_error "暂不支持的发行版"; return 1 ;;
    esac

    local work="/tmp/nginx-build-${ver}"
    rm -rf "${work}"; mkdir -p "${work}"
    show_spinner "下载 Nginx ${ver} 源码..."
    curl -fsSL "http://nginx.org/download/nginx-${ver}.tar.gz" -o "${work}/nginx.tar.gz" || { stop_spinner; log_error "下载失败"; return 1; }
    stop_spinner
    cd "${work}"
    tar xzf nginx.tar.gz
    cd "nginx-${ver}"
    local args="--prefix=${NGINX_PREFIX} --with-http_ssl_module --with-http_gzip_static_module --with-http_stub_status_module --with-pcre"
    if [[ "${use_ssl}" == "y" ]]; then args+=" --with-http_ssl_module --with-http_v2_module"; fi
    if [[ "${use_stream}" == "y" ]]; then args+=" --with-stream --with-stream_ssl_module"; fi
    show_spinner "编译安装中（耗时较长）..."
    ./configure ${args} >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null
    stop_spinner
    # 设置 systemd 服务
    cat > /etc/systemd/system/nginx.service <<EOF
[Unit]
Description=Nginx [Web Server]
After=network.target
[Service]
Type=forking
ExecStart=${NGINX_PREFIX}/sbin/nginx
ExecReload=${NGINX_PREFIX}/sbin/nginx -s reload
ExecStop=${NGINX_PREFIX}/sbin/nginx -s quit
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now nginx 2>/dev/null || "${NGINX_PREFIX}/sbin/nginx"
    log_success "Nginx ${ver} 编译安装完成（前缀: ${NGINX_PREFIX}）"
}

# ------------------------------------------------------------
# [Nginx] 配置虚拟主机
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_vhost() {
    check_root || return 1
    local domain root port
    read_input domain "域名(如 example.com):" ""
    read_input root "网站根目录:" "/var/www/html"
    read_input port "监听端口:" "80"
    [[ -z "${domain}" ]] && { log_error "域名不能为空"; return 1; }
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    mkdir -p "${root}"
    local conf="${NGINX_PREFIX}/conf/conf.d/${domain}.conf"
    mkdir -p "$(dirname "${conf}")"
    cat > "${conf}" <<EOF
# 由 ZETOPS 生成 - 虚拟主机(VirtualHost) ${domain}
server {
    listen ${port};
    server_name ${domain} www.${domain};
    root ${root};
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
    access_log logs/${domain}.access.log;
    error_log  logs/${domain}.error.log;
}
EOF
    nginx_check && nginx_reload_config
    log_success "虚拟主机已创建: ${domain} (${port})"
}

# ------------------------------------------------------------
# [Nginx] 申请与配置 SSL 证书（Let's Encrypt / certbot）
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_ssl() {
    check_root || return 1
    if ! check_command certbot; then
        log_info "安装 certbot（Let's Encrypt 客户端）..."
        install_pkg certbot python3-certbot-nginx || { log_error "certbot 安装失败"; return 1; }
    fi
    local domain email
    read_input domain "域名(必须已解析到本机):" ""
    read_input email "邮箱(用于证书续期通知):" ""
    [[ -z "${domain}" ]] && { log_error "域名不能为空"; return 1; }
    certbot --nginx -d "${domain}" -d "www.${domain}" --non-interactive --agree-tos -m "${email}" || true
    log_success "SSL 证书配置完成（自动续期由 certbot.timer 负责）"
}

# ------------------------------------------------------------
# [Nginx] 配置负载均衡（Load Balancing / 反向代理集群）
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_lb() {
    check_root || return 1
    local domain port upstream_servers
    read_input domain "负载均衡域名:" ""
    read_input port "对外监听端口:" "80"
    read_input upstream_servers "后端服务器列表（IP:端口，空格分隔，如 10.0.0.2:8080 10.0.0.3:8080）:" ""
    [[ -z "${upstream_servers}" ]] && { log_error "后端服务器不能为空"; return 1; }
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    local conf="${NGINX_PREFIX}/conf/conf.d/${domain}-lb.conf"
    local servers=""
    local s
    for s in ${upstream_servers}; do servers+="        server ${s};\n"; done
    printf '# 由 ZETOPS 生成 - 负载均衡\nupstream %s_backend {\n    least_conn;\n%b}\nserver {\n    listen %s;\n    server_name %s;\n    location / {\n        proxy_pass http://%s_backend;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n    }\n}\n' \
        "${domain}" "${servers}" "${port}" "${domain}" "${domain}" > "${conf}"
    nginx_check && nginx_reload_config
    log_success "负载均衡配置完成: ${domain}:${port} -> ${upstream_servers}"
}

# ------------------------------------------------------------
# [Nginx] 配置限流（Rate Limit，防刷）
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_limit() {
    check_root || return 1
    local rate
    read_input rate "限流速率（如 5r/s 或 20r/m）:" "5r/s"
    grep -q "limit_req_zone" "${NGINX_PREFIX}/conf/nginx.conf" || \
        sed -i "s|http {|http {\n    limit_req_zone \$binary_remote_addr zone=ztlimit:10m rate=${rate};|" "${NGINX_PREFIX}/conf/nginx.conf"
    log_success "限流 Zone 已配置（rate=${rate}），可在 server 中使用: limit_req zone=ztlimit burst=10;"
    nginx_check && nginx_reload_config
}

# ------------------------------------------------------------
# [Nginx] 配置语法检查（nginx -t）
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_check() {
    if [[ -x "${NGINX_PREFIX}/sbin/nginx" ]]; then
        "${NGINX_PREFIX}/sbin/nginx" -t
    elif check_command nginx; then
        nginx -t
    else
        log_error "Nginx 未安装"
        return 1
    fi
}

# ------------------------------------------------------------
# [Nginx] 重载配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_reload_config() {
    check_root || return 1
    if check_command systemctl; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
    "${NGINX_PREFIX}/sbin/nginx" -s reload 2>/dev/null || true
    log_success "Nginx 配置已重载"
}

# ------------------------------------------------------------
# [Nginx] 日志分析（访问量 TOP IP / 状态码统计）
# 参数：无
# 返回：无
# ------------------------------------------------------------
nginx_log_analysis() {
    local log="${NGINX_PREFIX}/logs/access.log"
    [[ -f "${log}" ]] || log="/var/log/nginx/access.log"
    [[ -f "${log}" ]] || { log_error "未找到访问日志（access.log）"; return 1; }
    echo "== 访问量 TOP 10 IP =="
    awk '{print $1}' "${log}" | sort | uniq -c | sort -rn | head -n 10
    echo "== HTTP 状态码统计 =="
    awk '{print $9}' "${log}" | sort | uniq -c | sort -rn | head -n 10
    echo "== 访问量 TOP 10 URL =="
    awk '{print $7}' "${log}" | sort | uniq -c | sort -rn | head -n 10
}

# ============================================================
# Apache 二级管理菜单
# ============================================================
apache_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [Apache管理] 子菜单"
        echo "======================================"
        echo " 1. 安装 Apache (httpd)"
        echo " 2. 卸载 Apache"
        echo " 3. 配置虚拟主机 (VirtualHost)"
        echo " 4. 启用/禁用模块"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-4) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) apache_install ;;
            2) apache_remove ;;
            3) apache_vhost ;;
            4) apache_module ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Apache] 安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
apache_install() {
    check_root || return 1
    case "$(detect_pkg_manager)" in
        apt)  install_pkg apache2
              systemctl enable --now apache2 2>/dev/null || true
              log_success "Apache2 已安装"; log_info "虚拟主机目录: /etc/apache2/sites-available/"
              ;;
        dnf|yum) install_pkg httpd
              systemctl enable --now httpd 2>/dev/null || true
              log_success "httpd 已安装"; log_info "虚拟主机目录: /etc/httpd/conf.d/"
              ;;
        *)    log_error "暂不支持" ;;
    esac
}

# ------------------------------------------------------------
# [Apache] 卸载
# 参数：无
# 返回：无
# ------------------------------------------------------------
apache_remove() {
    check_root || return 1
    confirm_action "卸载 Apache" || return 1
    case "$(detect_pkg_manager)" in
        apt)  systemctl stop apache2 2>/dev/null || true; apt-get purge -y apache2 apache2-utils ;;
        dnf|yum) systemctl stop httpd 2>/dev/null || true; "$(detect_pkg_manager)" remove -y httpd ;;
    esac
    log_success "Apache 已卸载"
}

# ------------------------------------------------------------
# [Apache] 虚拟主机配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
apache_vhost() {
    check_root || return 1
    local domain root port
    read_input domain "域名:" ""
    read_input root "网站根目录:" "/var/www/html"
    read_input port "监听端口:" "80"
    [[ -z "${domain}" ]] && { log_error "域名不能为空"; return 1; }
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    mkdir -p "${root}"
    case "$(detect_pkg_manager)" in
        apt)
            cat > "/etc/apache2/sites-available/${domain}.conf" <<EOF
<VirtualHost *:${port}>
    ServerName ${domain}
    ServerAlias www.${domain}
    DocumentRoot ${root}
    <Directory ${root}>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
            a2ensite "${domain}" >/dev/null 2>&1 || true
            systemctl reload apache2 2>/dev/null || true
            ;;
        dnf|yum)
            cat > "/etc/httpd/conf.d/${domain}.conf" <<EOF
<VirtualHost *:${port}>
    ServerName ${domain}
    DocumentRoot ${root}
    <Directory ${root}>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
            systemctl reload httpd 2>/dev/null || true
            ;;
    esac
    log_success "Apache 虚拟主机已创建: ${domain}"
}

# ------------------------------------------------------------
# [Apache] 启用/禁用模块
# 参数：无
# 返回：无
# ------------------------------------------------------------
apache_module() {
    check_root || return 1
    local module act
    echo "已启用模块:"
    case "$(detect_pkg_manager)" in
        apt)  ls /etc/apache2/mods-enabled/*.load 2>/dev/null | xargs -n1 basename | sed 's/.load//' ;;
        dnf|yum) httpd -M 2>/dev/null | grep -E '^\s*[a-z_]+_module' || true ;;
    esac
    read_input module "模块名(如 rewrite/ssl/proxy):" ""
    read_input act "操作 [1=启用 2=禁用]:" "1"
    case "$(detect_pkg_manager)" in
        apt)
            if [[ "${act}" == "1" ]]; then a2enmod "${module}"; else a2dismod "${module}"; fi
            systemctl reload apache2 2>/dev/null || true
            ;;
        dnf|yum)
            if [[ "${act}" == "1" ]]; then
                grep -q "^LoadModule" "/etc/httpd/conf.modules.d/"*.conf && log_warning "RHEL 系请手动编辑 /etc/httpd/conf.modules.d/ 启用 ${module}_module"
            fi
            ;;
    esac
    log_success "模块操作完成: ${module}"
}

# ============================================================
# Tomcat 二级管理菜单
# ============================================================
tomcat_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [Tomcat管理] 子菜单"
        echo "======================================"
        echo " 1. 安装 Tomcat"
        echo " 2. JVM 参数配置 (堆内存等)"
        echo " 3. 部署 WAR 包"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-3) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) tomcat_install ;;
            2) tomcat_jvm ;;
            3) tomcat_deploy_war ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Tomcat] 安装（从 API 获取下载地址，默认官方镜像）
# 参数：无
# 返回：无
# ------------------------------------------------------------
tomcat_install() {
    check_root || return 1
    local ver dl
    read_input ver "Tomcat 版本(Version):" "10.1.31"
    # 从 API 获取下载地址，失败使用官方镜像
    dl=$(api_fetch "tomcat/download?version=${ver}" || true)
    [[ -z "${dl}" ]] && dl="https://dlcdn.apache.org/tomcat/tomcat-10/v${ver}/bin/apache-tomcat-${ver}.tar.gz"
    check_command java || { log_error "请先安装 JDK（可在 开发环境模块 中安装）"; return 1; }
    local inst="/opt/tomcat-${ver}"
    show_spinner "下载 Tomcat ${ver}..."
    curl -fsSL "${dl}" -o /tmp/tomcat.tar.gz || { stop_spinner; log_error "下载失败"; return 1; }
    stop_spinner
    mkdir -p "${inst}"
    tar xzf /tmp/tomcat.tar.gz -C "${inst}" --strip-components=1
    chmod +x "${inst}/bin/"*.sh
    # systemd 服务
    cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat [Java Servlet Container]
After=network.target
[Service]
Type=forking
Environment=CATALINA_HOME=${inst}
Environment=CATALINA_BASE=${inst}
ExecStart=${inst}/bin/startup.sh
ExecStop=${inst}/bin/shutdown.sh
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now tomcat 2>/dev/null || "${inst}/bin/startup.sh"
    log_success "Tomcat ${ver} 已安装到 ${inst}"
}

# ------------------------------------------------------------
# [Tomcat] JVM 参数配置（内存/GC）
# 参数：无
# 返回：无
# ------------------------------------------------------------
tomcat_jvm() {
    check_root || return 1
    local home
    read_input home "CATALINA_HOME 路径:" "/opt/tomcat-10.1.31"
    [[ -f "${home}/bin/catalina.sh" ]] || { log_error "无效的 CATALINA_HOME: ${home}"; return 1; }
    local xms xmx
    read_input xms "初始堆内存 -Xms:" "512m"
    read_input xmx "最大堆内存 -Xmx:" "1024m"
    local setenv="${home}/bin/setenv.sh"
    cat > "${setenv}" <<EOF
# 由 ZETOPS 生成 - JVM 参数
export CATALINA_OPTS="-Xms${xms} -Xmx${xmx} -XX:+UseG1GC -XX:MaxMetaspaceSize=256m -Dfile.encoding=UTF-8"
EOF
    chmod +x "${setenv}"
    systemctl restart tomcat 2>/dev/null || true
    log_success "JVM 参数已配置: Xms=${xms} Xmx=${xmx}"
}

# ------------------------------------------------------------
# [Tomcat] 部署 WAR 包
# 参数：无
# 返回：无
# ------------------------------------------------------------
tomcat_deploy_war() {
    check_root || return 1
    local home war name
    read_input home "CATALINA_HOME 路径:" "/opt/tomcat-10.1.31"
    read_input war "WAR 包路径:" ""
    [[ -f "${war}" ]] || { log_error "WAR 包不存在: ${war}"; return 1; }
    name=$(basename "${war}" .war)
    cp "${war}" "${home}/webapps/${name}.war"
    log_success "WAR 包已部署，等待自动解压: ${home}/webapps/${name}.war"
    log_info "访问路径: http://<服务器IP>:8080/${name}/"
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
