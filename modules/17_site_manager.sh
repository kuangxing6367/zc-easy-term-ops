#!/bin/bash
# ============================================================
# 文件：modules/17_site_manager.sh
# 功能：站点与 SSL 统一管理 [Site & SSL Manager]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 站点清单 ~/.zetops/sites.ini（纯文本 INI，可手编）
#   - 站点列表（含证书倒计时/健康状态）、详情、增删
#   - SSL 证书统一检测（到期倒计时）、一键续期（certbot/手动）
#   - 站点健康检查（HTTP 多节点探测）
# ============================================================
set -euo pipefail

module_name="站点与SSL管理"
module_short="site_manager"
module_version="1.0.0"

SITES_FILE="${SITES_FILE:-${HOME}/.zetops/sites.ini}"

module_description() {
    echo "站点清单/SSL证书统一管理、批量到期检测、一键续期、健康检查 [Site & SSL Manager]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看所有站点列表"
    echo " 2. 查看站点详情"
    echo " 3. 添加站点"
    echo " 4. 修改站点"
    echo " 5. 删除站点"
    echo " 6. SSL 证书统一检测"
    echo " 7. 证书一键续期"
    echo " 8. 站点健康检查"
    echo " 9. 生成 Nginx 站点配置"
    echo "10. 设置 404 错误页"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) site_list ;;
        2) site_show_detail ;;
        3) site_add ;;
        4) site_edit ;;
        5) site_delete ;;
        6) site_ssl_check ;;
        7) site_ssl_renew ;;
        8) site_health_check ;;
        9) site_gen_nginx ;;
        10) site_set_404 ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 确保配置文件存在
# ------------------------------------------------------------
site_ensure_file() {
    mkdir -p "$(dirname "${SITES_FILE}")" 2>/dev/null || true
    [[ -f "${SITES_FILE}" ]] || touch "${SITES_FILE}"
}

# ------------------------------------------------------------
# 列出站点节名称
# 输出：每行一个站点节名
# ------------------------------------------------------------
site_list_sections() {
    grep -E '^\[' "${SITES_FILE}" 2>/dev/null | tr -d '[]' || true
}

# ------------------------------------------------------------
# 读取站点配置项
# 参数：$1 节名  $2 键名
# 输出：键值
# ------------------------------------------------------------
site_get() {
    local section="$1" key="$2"
    awk -v sec="${section}" -v k="${key}" '
        $0 ~ "^\\[" sec "\\]$" { found=1; next }
        /^\[/ { found=0 }
        found && $1 ~ "^" k "=" { sub(/^[^=]*=/, ""); print; exit }
    ' "${SITES_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 计算证书剩余天数
# 参数：$1 证书文件路径
# 输出：剩余天数（数字），无效输出空
# ------------------------------------------------------------
site_cert_days() {
    local cert="$1"
    [[ -f "${cert}" ]] || { echo ""; return; }
    local expiry
    expiry=$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2)
    [[ -z "${expiry}" ]] && { echo ""; return; }
    # 转换为 epoch（多时区格式兼容）
    local exp_epoch now_epoch
    exp_epoch=$(date -d "${expiry}" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "${expiry}" +%s 2>/dev/null || echo "")
    [[ -z "${exp_epoch}" ]] && { echo ""; return; }
    now_epoch=$(date +%s)
    echo $(( (exp_epoch - now_epoch) / 86400 ))
}

# ------------------------------------------------------------
# 站点健康探测（HTTP 状态码）
# 参数：$1 域名  $2 端口  $3 健康路径
# 输出：ok/fail/unknown
# ------------------------------------------------------------
site_probe() {
    local domain="$1" port="$2" path="${3:-/}"
    local url="http://${domain}:${port}${path}"
    [[ "${port}" == "443" ]] && url="https://${domain}${path}"
    if check_command curl; then
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null || echo "000")
        [[ "${code}" =~ ^[23] ]] && echo "ok" || echo "fail"
    elif check_command wget; then
        wget -q --spider --timeout=5 "${url}" 2>/dev/null && echo "ok" || echo "fail"
    else
        echo "unknown"
    fi
}

# ------------------------------------------------------------
# 1. 查看所有站点列表
# ------------------------------------------------------------
site_list() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    echo ""
    log_info "站点清单（${SITES_FILE}）"
    echo "--------------------------------------------------"
    if [[ -z "${sections}" ]]; then
        echo "  ${COLOR_GRAY}(暂无站点，请先添加: 菜单 3)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local sec domain port cert days health
    for sec in ${sections}; do
        domain=$(site_get "${sec}" "domain")
        port=$(site_get "${sec}" "port")
        cert=$(site_get "${sec}" "ssl_cert")
        days=$(site_cert_days "${cert}")
        health=$(site_probe "${domain}" "${port:-80}" "$(site_get "${sec}" "health_check")")

        local cert_txt health_txt
        if [[ -z "${days}" ]]; then
            cert_txt="${COLOR_GRAY}证书未知${COLOR_RESET}"
        elif (( days < 15 )); then
            cert_txt="${COLOR_RED}证书 ${days} 天到期${COLOR_RESET}"
        elif (( days < 30 )); then
            cert_txt="${COLOR_YELLOW}证书 ${days} 天到期${COLOR_RESET}"
        else
            cert_txt="${COLOR_GREEN}证书 ${days} 天到期${COLOR_RESET}"
        fi
        case "${health}" in
            ok)      health_txt="${COLOR_GREEN}健康✅${COLOR_RESET}" ;;
            fail)    health_txt="${COLOR_RED}异常❌${COLOR_RESET}" ;;
            unknown) health_txt="${COLOR_GRAY}未探测${COLOR_RESET}" ;;
        esac

        echo "  ${COLOR_BOLD}${domain}${COLOR_RESET} (${sec})"
        echo "      端口: ${port:-80}   ${cert_txt}   ${health_txt}"
    done
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 2. 查看站点详情
# ------------------------------------------------------------
site_show_detail() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无站点"
        return
    fi
    echo ""
    echo "  可选站点: ${sections}"
    read_input sec_name "输入站点节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${SITES_FILE}" 2>/dev/null; then
        log_error "站点节 [${sec_name}] 不存在"
        return
    fi
    echo ""
    log_info "站点 [${sec_name}] 详情"
    echo "--------------------------------------------------"
    awk -v sec="${sec_name}" '
        $0 ~ "^\\[" sec "\\]$" { found=1; next }
        /^\[/ { found=0 }
        found && NF { print "  " $0 }
    ' "${SITES_FILE}" | sed 's/^= / = /'
    echo "--------------------------------------------------"
}

# ------------------------------------------------------------
# 3. 添加站点
# ------------------------------------------------------------
site_add() {
    site_ensure_file
    echo ""
    read_input sec_name "站点节名（如 site_example_com）" ""
    [[ -z "${sec_name}" ]] && return
    if grep -q "^\[${sec_name}\]$" "${SITES_FILE}" 2>/dev/null; then
        log_error "站点 [${sec_name}] 已存在"
        return
    fi
    read_input domain "域名" ""
    read_input port "端口（默认 80）" "80"
    read_input cert "SSL 证书路径（可留空）" ""
    read_input key "SSL 私钥路径（可留空）" ""
    read_input backend "后端地址（如 10.0.0.2:8080，可留空）" ""
    read_input health "健康检查路径（默认 /）" "/"

    {
        echo ""
        echo "[${sec_name}]"
        echo "domain=${domain}"
        echo "port=${port}"
        [[ -n "${cert}" ]] && echo "ssl_cert=${cert}"
        [[ -n "${key}" ]] && echo "ssl_key=${key}"
        [[ -n "${backend}" ]] && echo "backend=${backend}"
        [[ -n "${health}" ]] && echo "health_check=${health}"
        echo "created=$(date '+%Y-%m-%d')"
    } >> "${SITES_FILE}"
    log_success "站点 [${sec_name}] 已添加"
    audit_log "添加站点 ${domain}" "成功"
}

# ------------------------------------------------------------
# 4. 修改站点（逐字段编辑，回车保留原值）
# ------------------------------------------------------------
site_edit() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无站点，请先添加（菜单 3）"
        return
    fi
    echo ""
    echo "  可选站点: ${sections}"
    read_input sec_name "输入要修改的站点节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${SITES_FILE}" 2>/dev/null; then
        log_error "站点节 [${sec_name}] 不存在"
        return
    fi

    # 读取当前值
    local cur_domain cur_port cur_cert cur_key cur_backend cur_health
    cur_domain=$(site_get "${sec_name}" "domain")
    cur_port=$(site_get "${sec_name}" "port")
    cur_cert=$(site_get "${sec_name}" "ssl_cert")
    cur_key=$(site_get "${sec_name}" "ssl_key")
    cur_backend=$(site_get "${sec_name}" "backend")
    cur_health=$(site_get "${sec_name}" "health_check")

    echo ""
    echo "  ${COLOR_GRAY}逐项修改，直接回车保留原值${COLOR_RESET}"
    read_input new_domain "域名 [${cur_domain}]" "${cur_domain}"
    read_input new_port "端口 [${cur_port:-80}]" "${cur_port:-80}"
    read_input new_cert "SSL 证书路径 [${cur_cert:-无}]" "${cur_cert}"
    read_input new_key "SSL 私钥路径 [${cur_key:-无}]" "${cur_key}"
    read_input new_backend "后端地址 [${cur_backend:-无}]" "${cur_backend}"
    read_input new_health "健康检查路径 [${cur_health:-/}]" "${cur_health:-/}"

    if ! confirm_action "确认保存修改?"; then
        return
    fi

    # 重写节内容：删除旧节，写入新节
    awk -v sec="${sec_name}" '
        $0 ~ "^\\[" sec "\\]$" { skip=1; next }
        /^\[/ { skip=0 }
        !skip { print }
    ' "${SITES_FILE}" > "${SITES_FILE}.tmp" && mv "${SITES_FILE}.tmp" "${SITES_FILE}"
    {
        echo ""
        echo "[${sec_name}]"
        echo "domain=${new_domain}"
        echo "port=${new_port}"
        [[ -n "${new_cert}" ]] && echo "ssl_cert=${new_cert}"
        [[ -n "${new_key}" ]] && echo "ssl_key=${new_key}"
        [[ -n "${new_backend}" ]] && echo "backend=${new_backend}"
        echo "health_check=${new_health}"
        echo "updated=$(date '+%Y-%m-%d %H:%M')"
    } >> "${SITES_FILE}"

    log_success "站点 [${sec_name}] 已修改"
    audit_log "修改站点 ${new_domain}" "成功"
}

# ------------------------------------------------------------
# 5. 删除站点
# ------------------------------------------------------------
site_delete() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无站点"
        return
    fi
    echo ""
    echo "  可选站点: ${sections}"
    read_input sec_name "输入要删除的站点节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${SITES_FILE}" 2>/dev/null; then
        log_error "站点节 [${sec_name}] 不存在"
        return
    fi
    local domain
    domain=$(site_get "${sec_name}" "domain")
    if confirm_action "确认删除站点 [${sec_name}] (${domain})?"; then
        # 删除节及其下所有键
        awk -v sec="${sec_name}" '
            $0 ~ "^\\[" sec "\\]$" { skip=1; next }
            /^\[/ { skip=0 }
            !skip { print }
        ' "${SITES_FILE}" > "${SITES_FILE}.tmp" && mv "${SITES_FILE}.tmp" "${SITES_FILE}"
        # 清理多余空行
        sed -i '/^$/N;/^\n$/D' "${SITES_FILE}" 2>/dev/null || true
        log_success "站点 [${sec_name}] 已删除"
        audit_log "删除站点 ${domain}" "成功"
    fi
}

# ------------------------------------------------------------
# 5. SSL 证书统一检测
# ------------------------------------------------------------
site_ssl_check() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    echo ""
    log_info "SSL 证书批量检测"
    echo "--------------------------------------------------"
    if [[ -z "${sections}" ]]; then
        echo "  ${COLOR_GRAY}(暂无站点)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local sec cert days expiring=0
    for sec in ${sections}; do
        cert=$(site_get "${sec}" "ssl_cert")
        if [[ -z "${cert}" ]]; then
            echo "  ${COLOR_GRAY}${sec}: 未配置证书${COLOR_RESET}"
            continue
        fi
        if [[ ! -f "${cert}" ]]; then
            echo "  ${COLOR_RED}${sec}: 证书文件不存在 (${cert})${COLOR_RESET}"
            expiring=$((expiring + 1))
            continue
        fi
        days=$(site_cert_days "${cert}")
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2)
        if [[ -z "${days}" ]]; then
            echo "  ${COLOR_GRAY}${sec}: 证书解析失败${COLOR_RESET}"
        elif (( days < 0 )); then
            echo "  ${COLOR_RED}${sec}: 已过期 ${days#-} 天 (${expiry})${COLOR_RESET}"
            expiring=$((expiring + 1))
        elif (( days < 15 )); then
            echo "  ${COLOR_RED}${sec}: ${days} 天后到期 (${expiry})${COLOR_RESET}"
            expiring=$((expiring + 1))
        elif (( days < 30 )); then
            echo "  ${COLOR_YELLOW}${sec}: ${days} 天后到期 (${expiry})${COLOR_RESET}"
        else
            echo "  ${COLOR_GREEN}${sec}: ${days} 天后到期 (${expiry})${COLOR_RESET}"
        fi
    done
    echo "--------------------------------------------------"
    if (( expiring > 0 )); then
        log_warning "${expiring} 个站点证书即将过期或已失效，建议立即续期"
    else
        log_success "所有证书状态正常"
    fi
    audit_log "SSL 证书批量检测" "完成"
}

# ------------------------------------------------------------
# 6. 证书一键续期
# ------------------------------------------------------------
site_ssl_renew() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无站点"
        return
    fi
    echo ""
    echo "  可选站点: ${sections}"
    read_input sec_name "输入要续期的站点节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${SITES_FILE}" 2>/dev/null; then
        log_error "站点节 [${sec_name}] 不存在"
        return
    fi
    local domain cert
    domain=$(site_get "${sec_name}" "domain")
    cert=$(site_get "${sec_name}" "ssl_cert")

    echo ""
    log_info "续期方式选择:"
    echo "  1. Let's Encrypt (certbot) 自动续期"
    echo "  2. 手动指定新证书文件"
    read_input renew_mode "选择 (1/2)" "1"

    case "${renew_mode}" in
        1)
            if ! check_command certbot; then
                log_warning "未安装 certbot，请先安装: sudo apt install certbot python3-certbot-nginx"
                return
            fi
            if confirm_action "为 ${domain} 执行 certbot 续期?"; then
                certbot renew --cert-name "${domain}" 2>&1 | sed 's/^/  /'
                log_success "certbot 续期完成"
                audit_log "certbot 续期 ${domain}" "成功"
            fi
            ;;
        2)
            read_input new_cert "新证书文件路径" ""
            read_input new_key "新私钥文件路径" ""
            if [[ -z "${new_cert}" || -z "${new_key}" ]]; then
                log_warning "证书/私钥路径不能为空"
                return
            fi
            # 更新 sites.ini 中的路径
            awk -v sec="${sec_name}" -v c="${new_cert}" -v k="${new_key}" '
                $0 ~ "^\\[" sec "\\]$" { found=1 }
                /^\[/ && $0 !~ "^\\[" sec "\\]$" { found=0 }
                found && $1 ~ /^ssl_cert=/ { print "ssl_cert=" c; next }
                found && $1 ~ /^ssl_key=/ { print "ssl_key=" k; next }
                { print }
            ' "${SITES_FILE}" > "${SITES_FILE}.tmp" && mv "${SITES_FILE}.tmp" "${SITES_FILE}"
            log_success "站点 [${sec_name}] 证书路径已更新"
            audit_log "更新证书 ${domain}" "成功"
            ;;
        *)
            log_warning "无效选择"
            ;;
    esac
}

# ------------------------------------------------------------
# 7. 站点健康检查
# ------------------------------------------------------------
site_health_check() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    echo ""
    log_info "站点健康检查（HTTP 探测）"
    echo "--------------------------------------------------"
    if [[ -z "${sections}" ]]; then
        echo "  ${COLOR_GRAY}(暂无站点)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local sec domain port health ok=0 fail=0
    for sec in ${sections}; do
        domain=$(site_get "${sec}" "domain")
        port=$(site_get "${sec}" "port")
        [[ -z "${port}" ]] && port="80"
        health=$(site_probe "${domain}" "${port}" "$(site_get "${sec}" "health_check")")
        case "${health}" in
            ok)
                echo "  ${COLOR_GREEN}✅ ${domain}:${port} 正常${COLOR_RESET}"
                ok=$((ok + 1))
                ;;
            fail)
                echo "  ${COLOR_RED}❌ ${domain}:${port} 无响应${COLOR_RESET}"
                fail=$((fail + 1))
                ;;
            unknown)
                echo "  ${COLOR_GRAY}⚠️  ${domain}:${port} 无法探测（无 curl/wget）${COLOR_RESET}"
                ;;
        esac
    done
    echo "--------------------------------------------------"
    echo "  正常 ${ok} / 异常 ${fail}"
    if (( fail > 0 )); then
        log_warning "存在异常站点，建议使用 AI 助手诊断"
        audit_log "站点健康检查" "发现 ${fail} 个异常"
    else
        log_success "所有站点健康"
        audit_log "站点健康检查" "全部正常"
    fi
}

# ------------------------------------------------------------
# 9. 生成 Nginx 站点配置（基于 sites.ini 信息）
# ------------------------------------------------------------
site_gen_nginx() {
    site_ensure_file
    local sections
    sections=$(site_list_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无站点，请先添加（菜单 3）"
        return
    fi
    echo ""
    echo "  可选站点: ${sections}"
    read_input sec_name "输入要生成配置的站点节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${SITES_FILE}" 2>/dev/null; then
        log_error "站点节 [${sec_name}] 不存在"
        return
    fi

    local domain port cert key backend root
    domain=$(site_get "${sec_name}" "domain")
    port=$(site_get "${sec_name}" "port")
    cert=$(site_get "${sec_name}" "ssl_cert")
    key=$(site_get "${sec_name}" "ssl_key")
    backend=$(site_get "${sec_name}" "backend")
    root=$(site_get "${sec_name}" "root_dir")

    echo ""
    echo "  ${COLOR_BOLD}生成方式:${COLOR_RESET}"
    echo "  1. 反向代理模式（backend 后端地址）"
    echo "  2. 静态站点模式（root 根目录）"
    read_input gen_mode "选择" "1"

    local conf="# ZETOPS 自动生成: $(date '+%Y-%m-%d %H:%M')
# 站点: ${domain} (${sec_name})

server {
    listen ${port:-80};
    server_name ${domain};

    # 访问日志
    access_log /var/log/nginx/${domain}.access.log;
    error_log /var/log/nginx/${domain}.error.log;

    # 404 错误页
    error_page 404 /404.html;
    location = /404.html {
        root /usr/share/nginx/html;
        internal;
    }
"

    if [[ "${gen_mode}" == "1" ]] && [[ -n "${backend}" ]]; then
        conf+="
    # 反向代理到后端
    location / {
        proxy_pass http://${backend};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
    }
"
    else
        conf+="
    # 静态站点
    root ${root:-/var/www/${domain}};
    index index.html index.htm;
"
    fi

    # HTTPS 证书（若配置了证书路径）
    if [[ -n "${cert}" && -n "${key}" ]]; then
        conf+="
    listen 443 ssl;
    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
"
    fi

    conf+="
    # 健康检查路径
    location = /health {
        access_log off;
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
"

    echo ""
    echo "  ${COLOR_BOLD}生成预览:${COLOR_RESET}"
    echo "--------------------------------------------------"
    echo "${conf}" | sed 's/^/  /'
    echo "--------------------------------------------------"

    local target="/etc/nginx/conf.d/${domain}.conf"
    echo ""
    read_input conf_path "保存路径（默认 ${target}）" "${target}"

    if confirm_action "写入配置文件 ${conf_path}?"; then
        if echo "${conf}" | sudo tee "${conf_path}" >/dev/null 2>&1; then
            log_success "配置已写入: ${conf_path}"
            if check_command nginx; then
                if sudo nginx -t 2>/dev/null; then
                    if confirm_action "语法校验通过，是否立即重载 Nginx？"; then
                        sudo nginx -s reload 2>/dev/null && log_success "Nginx 已重载"
                    fi
                else
                    log_error "Nginx 语法校验失败，请检查"
                fi
            fi
            audit_log "生成 Nginx 配置 ${domain}" "成功"
        else
            log_error "写入失败（权限不足）"
        fi
    fi
}

# ------------------------------------------------------------
# 10. 设置 404 错误页
# ------------------------------------------------------------
site_set_404() {
    echo ""
    log_info "设置自定义 404 错误页"
    echo "--------------------------------------------------"
    echo "  1. 为单个站点生成 404 页"
    echo "  2. 为 Nginx 全局生成 404 页"
    read_input act "选择" "1"

    local page_dir="/usr/share/nginx/html"
    local domain=""
    case "${act}" in
        1)
            site_ensure_file
            local sections
            sections=$(site_list_sections)
            if [[ -z "${sections}" ]]; then
                log_warning "暂无站点，使用全局模式"
                act="2"
            else
                echo ""
                echo "  可选站点: ${sections}"
                read_input sec_name "输入站点节名" ""
                [[ -z "${sec_name}" ]] && return
                domain=$(site_get "${sec_name}" "domain")
                page_dir="/usr/share/nginx/html"
            fi
            ;;
        2) ;;
        *) return ;;
    esac

    echo ""
    echo "  ${COLOR_BOLD}404 页面内容模板:${COLOR_RESET}"
    echo "  1. 简洁版（纯文本）"
    echo "  2. 美化版（HTML 样式）"
    read_input style "选择样式" "1"

    local page_file="${page_dir}/404.html"
    local content=""
    case "${style}" in
        1)
            content="404 Not Found

抱歉，您访问的页面不存在。
"
            ;;
        2)
            content='<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>404 - 页面未找到</title>
<style>
body { font-family: "Microsoft YaHei", Arial, sans-serif; background: #f5f7fa; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
.container { text-align: center; }
h1 { font-size: 120px; margin: 0; color: #e74c3c; text-shadow: 3px 3px 10px rgba(0,0,0,0.1); }
p { color: #666; font-size: 18px; }
a { color: #3498db; text-decoration: none; }
a:hover { text-decoration: underline; }
</style>
</head>
<body>
<div class="container">
<h1>404</h1>
<p>抱歉，您访问的页面不存在或已被移除</p>
<p><a href="/">返回首页</a></p>
</div>
</body>
</html>
'
            ;;
        *) return ;;
    esac

    echo ""
    echo "  页面文件: ${page_file}"
    if confirm_action "写入 404 错误页？"; then
        if echo "${content}" | sudo tee "${page_file}" >/dev/null 2>&1; then
            log_success "404 页面已生成: ${page_file}"
            echo ""
            echo "  ${COLOR_GRAY}如站点配置已含 error_page 404 /404.html; 则自动生效${COLOR_RESET}"
            echo "  ${COLOR_GRAY}若使用菜单 9 生成的配置，已自动包含该规则${COLOR_RESET}"
            if check_command nginx; then
                if confirm_action "重载 Nginx 使配置生效？"; then
                    sudo nginx -s reload 2>/dev/null && log_success "Nginx 已重载"
                fi
            fi
            audit_log "设置 404 错误页 ${domain:-全局}" "成功"
        else
            log_error "写入失败（权限不足）"
        fi
    fi
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
    site_list
fi
