#!/bin/bash
# ============================================================
# 文件：modules/24_batch_ops.sh
# 功能：批量主机运维 [Batch Host Ops - Ansible-lite]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 主机清单 ~/.zetops/hosts.ini（分组 + ip/user/port）
#   - 批量执行命令（SSH 并行，逐主机结果显示，成功/失败统计）
#   - 批量上传/下载文件（scp）
#   - 依赖 SSH 密钥认证（BatchMode=yes 防密码交互卡死）
# ============================================================
set -euo pipefail

module_name="批量主机运维"
module_short="batch_ops"
module_version="1.0.0"

HOSTS_FILE="${HOSTS_FILE:-${HOME}/.zetops/hosts.ini}"
BATCH_TIMEOUT="${BATCH_TIMEOUT:-10}"

module_description() {
    echo "多主机批量命令/上传/下载（Ansible-lite，SSH 并行） [Batch Host Ops]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看主机清单"
    echo " 2. 编辑主机清单"
    echo " 3. 批量执行命令"
    echo " 4. 批量上传文件"
    echo " 5. 批量下载文件"
    echo " 6. 批量主机连通性测试"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) batch_hosts_view ;;
        2) batch_hosts_edit ;;
        3) batch_exec_cmd ;;
        4) batch_upload ;;
        5) batch_download ;;
        6) batch_ping_test ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 确保主机清单存在
# ------------------------------------------------------------
batch_ensure_file() {
    mkdir -p "$(dirname "${HOSTS_FILE}")" 2>/dev/null || true
    if [[ ! -f "${HOSTS_FILE}" ]]; then
        cat > "${HOSTS_FILE}" <<EOF
# ZETOPS 主机清单
# 格式: [组名] / 主机IP  user=用户名  port=端口
# 兼容 ansible 写法: ansible_user= / ansible_port=

[web_servers]
# 192.168.1.10 user=root port=22

[db_servers]
# 192.168.1.20 user=root port=22
EOF
    fi
}

# ------------------------------------------------------------
# 列出所有主机（含组名）
# 输出：每行 "组名|IP|user|port"
# ------------------------------------------------------------
batch_hosts_all() {
    local group="default" line ip user port
    while IFS= read -r line; do
        # 组
        if [[ "${line}" =~ ^\[(.*)\]$ ]]; then
            group="${BASH_REMATCH[1]}"
            continue
        fi
        # 跳过注释和空行
        [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
        ip=$(echo "${line}" | awk '{print $1}')
        user=$(echo "${line}" | grep -oE 'user=[^ ]+' | cut -d= -f2 || true)
        port=$(echo "${line}" | grep -oE 'port=[^ ]+' | cut -d= -f2 || true)
        # 兼容 ansible_user/ansible_port
        [[ -z "${user}" ]] && user=$(echo "${line}" | grep -oE 'ansible_user=[^ ]+' | cut -d= -f2 || true)
        [[ -z "${port}" ]] && port=$(echo "${line}" | grep -oE 'ansible_port=[^ ]+' | cut -d= -f2 || true)
        echo "${group}|${ip}|${user:-root}|${port:-22}"
    done < "${HOSTS_FILE}"
}

# ------------------------------------------------------------
# 解析主机行为 ssh 目标串
# 参数：$1 "组|IP|user|port"
# 输出："user@ip -p port"
# ------------------------------------------------------------
batch_ssh_target() {
    local line="$1" ip user port
    ip=$(echo "${line}" | cut -d'|' -f2)
    user=$(echo "${line}" | cut -d'|' -f3)
    port=$(echo "${line}" | cut -d'|' -f4)
    echo "${user}@${ip} -p ${port}"
}

# ------------------------------------------------------------
# 1. 查看主机清单
# ------------------------------------------------------------
batch_hosts_view() {
    batch_ensure_file
    local hosts
    hosts=$(batch_hosts_all)
    echo ""
    log_info "主机清单（${HOSTS_FILE}）"
    echo "--------------------------------------------------"
    if [[ -z "${hosts}" ]]; then
        echo "  ${COLOR_GRAY}(清单为空，请先编辑: 菜单 2)${COLOR_RESET}"
    else
        local line group ip user port
        while IFS= read -r line; do
            group=$(echo "${line}" | cut -d'|' -f1)
            ip=$(echo "${line}" | cut -d'|' -f2)
            user=$(echo "${line}" | cut -d'|' -f3)
            port=$(echo "${line}" | cut -d'|' -f4)
            printf "  [%s] %-18s %s@%s (port %s)\n" "${group}" "${ip}" "${user}" "${ip}" "${port}"
        done <<< "${hosts}"
    fi
    echo "--------------------------------------------------"
    echo "  ${COLOR_GRAY}提示: 批量操作需提前配置 SSH 密钥（ssh-copy-id），否则会失败${COLOR_RESET}"
}

# ------------------------------------------------------------
# 2. 编辑主机清单
# ------------------------------------------------------------
batch_hosts_edit() {
    batch_ensure_file
    if check_command nano; then
        nano "${HOSTS_FILE}"
    elif check_command vi; then
        vi "${HOSTS_FILE}"
    else
        log_error "未找到 nano/vi"
        return
    fi
    log_success "主机清单已保存"
}

# ------------------------------------------------------------
# 选择执行范围
# 参数：无
# 输出：匹配的主机行列表（stdout）
# ------------------------------------------------------------
batch_select_hosts() {
    local hosts
    hosts=$(batch_hosts_all)
    [[ -z "${hosts}" ]] && { log_warning "主机清单为空"; return 1; }
    echo ""
    echo "  可选范围:"
    echo "  1. 全部主机"
    local groups
    groups=$(echo "${hosts}" | cut -d'|' -f1 | sort -u)
    local g i=2
    for g in ${groups}; do
        echo "  $((i++)). 分组 [${g}]"
    done
    read_input scope "选择（输入序号或直接输入 IP/组名）" "1"
    case "${scope}" in
        1) echo "${hosts}"; return 0 ;;
        *)
            local selected=""
            local line
            while IFS= read -r line; do
                local g ip
                g=$(echo "${line}" | cut -d'|' -f1)
                ip=$(echo "${line}" | cut -d'|' -f2)
                if [[ "${scope}" == "${g}" || "${scope}" == "${ip}" ]]; then
                    selected+="${line}\n"
                fi
            done <<< "${hosts}"
            if [[ -n "${selected}" ]]; then
                echo -e "${selected}"
                return 0
            fi
            log_error "未匹配到主机: ${scope}"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# 3. 批量执行命令
# ------------------------------------------------------------
batch_exec_cmd() {
    local hosts
    hosts=$(batch_select_hosts) || return
    echo ""
    read_input cmd "输入要在所有主机执行的命令" ""
    [[ -z "${cmd}" ]] && return
    echo ""
    echo "  ${COLOR_BOLD}批量执行: ${cmd}${COLOR_RESET}"
    echo "  ${COLOR_GRAY}目标主机: $(echo "${hosts}" | wc -l | tr -d ' ') 台（并行执行，超时 ${BATCH_TIMEOUT}s）${COLOR_RESET}"
    if ! confirm_action "确认执行？"; then
        return
    fi

    local line ok=0 fail=0 tmpdir
    tmpdir=$(mktemp -d)
    local i=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        i=$((i + 1))
        local target ip
        target=$(batch_ssh_target "${line}")
        ip=$(echo "${line}" | cut -d'|' -f2)
        (
            ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new ${target} "${cmd}" > "${tmpdir}/r${i}.out" 2>&1
            echo $? > "${tmpdir}/r${i}.code"
        ) &
    done <<< "${hosts}"
    wait

    echo ""
    echo "  ${COLOR_GRAY}========== 执行结果 ==========${COLOR_RESET}"
    i=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        i=$((i + 1))
        local ip code
        ip=$(echo "${line}" | cut -d'|' -f2)
        code=$(cat "${tmpdir}/r${i}.code" 2>/dev/null || echo 255)
        if (( code == 0 )); then
            echo "  ${COLOR_GREEN}✅ ${ip}: 执行成功${COLOR_RESET}"
            ok=$((ok + 1))
        else
            echo "  ${COLOR_RED}❌ ${ip}: 失败 (exit ${code})${COLOR_RESET}"
            fail=$((fail + 1))
        fi
        # 显示输出（限 10 行）
        if [[ -s "${tmpdir}/r${i}.out" ]]; then
            echo "  ${COLOR_GRAY}    --- 输出 ---${COLOR_RESET}"
            head -10 "${tmpdir}/r${i}.out" | sed 's/^/      /'
        fi
    done <<< "${hosts}"
    echo "  ${COLOR_GRAY}=============================${COLOR_RESET}"
    echo "  ${COLOR_BOLD}结果统计: 成功 ${ok} / 失败 ${fail}${COLOR_RESET}"
    audit_log "批量执行命令" "成功${ok} 失败${fail}"
    rm -rf "${tmpdir}"
}

# ------------------------------------------------------------
# 4. 批量上传文件
# ------------------------------------------------------------
batch_upload() {
    local hosts
    hosts=$(batch_select_hosts) || return
    read_input src "本地文件路径" ""
    [[ -z "${src}" ]] && return
    [[ -f "${src}" || -d "${src}" ]] || { log_error "本地路径不存在"; return; }
    read_input dest "远程目标路径" "/tmp/"
    echo ""
    echo "  ${COLOR_BOLD}上传: ${src} → 所有主机:${dest}${COLOR_RESET}"
    if ! confirm_action "确认上传？"; then
        return
    fi
    local line ok=0 fail=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local target ip
        target=$(batch_ssh_target "${line}")
        ip=$(echo "${line}" | cut -d'|' -f2)
        echo -n "  ${ip}: "
        if scp -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -P "$(echo "${target}" | grep -oE '\-p [0-9]+' | cut -d' ' -f2)" "${src}" "${target%% -p*}@${ip}:${dest}" 2>/dev/null; then
            echo "${COLOR_GREEN}✅ 上传成功${COLOR_RESET}"
            ok=$((ok + 1))
        else
            echo "${COLOR_RED}❌ 上传失败${COLOR_RESET}"
            fail=$((fail + 1))
        fi
    done <<< "${hosts}"
    echo ""
    echo "  ${COLOR_BOLD}结果: 成功 ${ok} / 失败 ${fail}${COLOR_RESET}"
    audit_log "批量上传 ${src}" "成功${ok} 失败${fail}"
}

# ------------------------------------------------------------
# 5. 批量下载文件
# ------------------------------------------------------------
batch_download() {
    local hosts
    hosts=$(batch_select_hosts) || return
    read_input src "远程文件路径" ""
    [[ -z "${src}" ]] && return
    read_input dest "本地保存目录（默认 ./batch_download）" "./batch_download"
    mkdir -p "${dest}"
    echo ""
    echo "  ${COLOR_BOLD}下载: 所有主机:${src} → ${dest}/${COLOR_RESET}"
    if ! confirm_action "确认下载？"; then
        return
    fi
    local line ok=0 fail=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local target ip
        target=$(batch_ssh_target "${line}")
        ip=$(echo "${line}" | cut -d'|' -f2)
        local outfile="${dest}/$(basename "${src}")"
        [[ -f "${outfile}" ]] && outfile="${dest}/${ip}_$(basename "${src}")"
        echo -n "  ${ip}: "
        if scp -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -P "$(echo "${target}" | grep -oE '\-p [0-9]+' | cut -d' ' -f2)" "${target%% -p*}@${ip}:${src}" "${outfile}" 2>/dev/null; then
            echo "${COLOR_GREEN}✅ 下载成功 → ${outfile}${COLOR_RESET}"
            ok=$((ok + 1))
        else
            echo "${COLOR_RED}❌ 下载失败${COLOR_RESET}"
            fail=$((fail + 1))
        fi
    done <<< "${hosts}"
    echo ""
    echo "  ${COLOR_BOLD}结果: 成功 ${ok} / 失败 ${fail}${COLOR_RESET}"
    audit_log "批量下载 ${src}" "成功${ok} 失败${fail}"
}

# ------------------------------------------------------------
# 6. 批量主机连通性测试
# ------------------------------------------------------------
batch_ping_test() {
    local hosts
    hosts=$(batch_select_hosts) || return
    echo ""
    log_info "SSH 连通性测试（${BATCH_TIMEOUT}s 超时）"
    echo "--------------------------------------------------"
    local line ok=0 fail=0
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local target ip user port
        ip=$(echo "${line}" | cut -d'|' -f2)
        user=$(echo "${line}" | cut -d'|' -f3)
        port=$(echo "${line}" | cut -d'|' -f4)
        echo -n "  ${user}@${ip}:${port}  "
        if timeout "${BATCH_TIMEOUT}" ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "${port}" "${user}@${ip}" "echo ok" 2>/dev/null | grep -q ok; then
            echo "${COLOR_GREEN}✅ 连通${COLOR_RESET}"
            ok=$((ok + 1))
        else
            echo "${COLOR_RED}❌ 不通（未配密钥/网络不可达）${COLOR_RESET}"
            fail=$((fail + 1))
        fi
    done <<< "${hosts}"
    echo "--------------------------------------------------"
    echo "  ${COLOR_BOLD}连通 ${ok} / 不通 ${fail}${COLOR_RESET}"
    audit_log "批量连通性测试" "连通${ok} 不通${fail}"
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
    batch_hosts_view
fi
