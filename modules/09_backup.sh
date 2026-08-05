#!/bin/bash
# ============================================================
# 文件：modules/09_backup.sh
# 功能：备份与灾备 [Backup & Disaster Recovery]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：文件备份(tar/rsync/增量/排除)、远程备份(rsync+免密)、
#       数据库自动备份脚本、定时备份(crontab)、LVM快照
# ============================================================
set -euo pipefail

module_name="备份与灾备"
module_short="backup"
module_version="1.0.0"

module_description() {
    echo "文件备份(tar/rsync/增量)、远程同步(rsync免密)、数据库备份脚本、定时备份、LVM快照"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 文件备份 (tar/rsync)"
    echo " 2. 增量备份"
    echo " 3. 远程备份 (rsync + SSH免密)"
    echo " 4. 数据库备份脚本生成"
    echo " 5. 定时备份 (crontab)"
    echo " 6. LVM 快照 (Snapshot)"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) file_backup ;;
        2) file_backup_incremental ;;
        3) remote_backup ;;
        4) db_backup_script ;;
        5) backup_cron ;;
        6) lvm_snapshot ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [文件备份] 本地目录备份（tar 或 rsync）
# 参数：无
# 返回：无
# ------------------------------------------------------------
file_backup() {
    check_root || return 1
    local src mode
    read_input src "要备份的源目录:" ""
    [[ -d "${src}" ]] || { log_error "目录不存在: ${src}"; return 1; }
    read_input mode "方式 [1=tar打包 2=rsync同步]:" "1"
    local dir="${BACKUP_DIR}"
    mkdir -p "${dir}"
    local name
    name=$(basename "${src}")
    case "${mode}" in
        1)
            local file="${dir}/${name}_$(date +%Y%m%d_%H%M%S).tar.gz"
            show_spinner "tar 打包压缩中..."
            tar czf "${file}" -C "$(dirname "${src}")" "${name}"
            stop_spinner
            log_success "备份完成: ${file}"
            ;;
        2)
            local dst
            read_input dst "目标目录:" "${dir}/${name}"
            mkdir -p "${dst}"
            show_spinner "rsync 同步中..."
            rsync -a --delete "${src}/" "${dst}/"
            stop_spinner
            log_success "rsync 同步完成: ${src} -> ${dst}"
            ;;
    esac
}

# ------------------------------------------------------------
# [文件备份] 增量备份（rsync --link-dest 硬链接增量）
# 参数：无
# 返回：无
# ------------------------------------------------------------
file_backup_incremental() {
    check_root || return 1
    check_command rsync || install_pkg rsync
    local src dst
    read_input src "源目录:" ""
    read_input dst "备份目录:" "${BACKUP_DIR}/incremental"
    [[ -d "${src}" ]] || { log_error "源目录不存在"; return 1; }
    mkdir -p "${dst}"
    # 上一次全量备份作为 link-dest 基础
    local base=""
    base=$(ls -d "${dst}"/full_* 2>/dev/null | tail -n1 || true)
    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    if [[ -n "${base}" ]]; then
        rsync -a --link-dest="${base}" "${src}/" "${dst}/incr_${stamp}/"
        log_success "增量备份完成: ${dst}/incr_${stamp}（基于 ${base}）"
    else
        rsync -a "${src}/" "${dst}/full_${stamp}/"
        log_success "首次全量备份完成: ${dst}/full_${stamp}"
    fi
}

# ------------------------------------------------------------
# [远程备份] rsync 同步到远程 + SSH 免密配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
remote_backup() {
    check_root || return 1
    check_command rsync || install_pkg rsync
    local src user host port dst_dir
    read_input src "源目录:" ""
    read_input user "远程用户名:" "root"
    read_input host "远程主机 IP:" ""
    validate_ip "${host}" || { log_error "IP 无效"; return 1; }
    read_input port "SSH 端口:" "22"
    validate_port "${port}" || { log_error "端口无效"; return 1; }
    read_input dst_dir "远程目标目录:" "${BACKUP_DIR}"
    [[ -d "${src}" ]] || { log_error "源目录不存在"; return 1; }
    # 检查免密
    if ! ssh -p "${port}" -o BatchMode=yes -o ConnectTimeout=5 "${user}@${host}" "true" 2>/dev/null; then
        log_warning "未配置免密登录，先配置 SSH 密钥(Key)"
        if [[ ! -f ~/.ssh/id_ed25519 && ! -f ~/.ssh/id_rsa ]]; then
            ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
        fi
        local key
        key=$(ls ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null | head -n1)
        ssh-copy-id -p "${port}" -i "${key}" "${user}@${host}" || { log_error "免密配置失败"; return 1; }
        log_success "SSH 免密已配置"
    fi
    show_spinner "rsync 远程同步中..."
    rsync -a -e "ssh -p ${port}" "${src}/" "${user}@${host}:${dst_dir}/"
    stop_spinner
    log_success "远程备份完成: ${src} -> ${user}@${host}:${dst_dir}"
}

# ------------------------------------------------------------
# [数据库备份] 生成 MySQL/PostgreSQL 自动备份脚本
# 参数：无
# 返回：无
# ------------------------------------------------------------
db_backup_script() {
    check_root || return 1
    local dbtype pw dir
    read_input dbtype "数据库类型 [1=MySQL 2=PostgreSQL]:" "1"
    read_input pw "数据库密码(MySQL用):" ""
    dir="${BACKUP_DIR}"
    mkdir -p "${dir}"
    local script="${dir}/db_backup.sh"
    if [[ "${dbtype}" == "1" ]]; then
        cat > "${script}" <<EOF
#!/bin/bash
# 由 ZETOPS 生成的 MySQL 自动备份脚本
BACKUP_DIR="${dir}"
MYSQL_PW="${pw}"
stamp=\$(date +%Y%m%d_%H%M%S)
mysqldump -uroot -p"\${MYSQL_PW}" --all-databases --single-transaction | gzip > "\${BACKUP_DIR}/mysql_\${stamp}.sql.gz"
# 保留最近30份
ls -t \${BACKUP_DIR}/mysql_*.sql.gz | tail -n +31 | xargs -r rm -f
EOF
    else
        cat > "${script}" <<EOF
#!/bin/bash
# 由 ZETOPS 生成的 PostgreSQL 自动备份脚本
BACKUP_DIR="${dir}"
stamp=\$(date +%Y%m%d_%H%M%S)
su - postgres -c "pg_dumpall" > "\${BACKUP_DIR}/pg_all_\${stamp}.dump" 2>/dev/null || runuser -u postgres -- pg_dumpall > "\${BACKUP_DIR}/pg_all_\${stamp}.dump"
# 保留最近30份
ls -t \${BACKUP_DIR}/pg_all_*.dump | tail -n +31 | xargs -r rm -f
EOF
    fi
    chmod +x "${script}"
    log_success "备份脚本已生成: ${script}"
}

# ------------------------------------------------------------
# [定时备份] 配置 crontab 定时任务
# 参数：无
# 返回：无
# ------------------------------------------------------------
backup_cron() {
    check_root || return 1
    local script time
    read_input script "备份脚本路径(留空使用默认):" "${BACKUP_DIR}/db_backup.sh"
    [[ -f "${script}" ]] || { log_error "脚本不存在: ${script}"; return 1; }
    read_input time "执行时间(如 每日凌晨2点=0 2 * * *):" "0 2 * * *"
    (crontab -l 2>/dev/null | grep -v "${script}" || true; echo "${time} ${script} >> ${LOG_DIR}/backup_cron.log 2>&1") | crontab -
    log_success "定时备份已配置: ${time} ${script}"
    log_info "当前 crontab:"
    crontab -l 2>/dev/null || true
}

# ------------------------------------------------------------
# [LVM快照] 快照创建/恢复
# 参数：无
# 返回：无
# ------------------------------------------------------------
lvm_snapshot() {
    check_root || return 1
    check_command lvs || { log_error "缺少 LVM 工具"; return 1; }
    local act lv vg snap
    read_input lv "逻辑卷路径(如 /dev/vg0/lv_data):" ""
    vg=$(echo "${lv}" | awk -F/ '{print $3}')
    read_input act "操作 [1=创建快照 2=恢复快照]:" "1"
    case "${act}" in
        1)
            local size
            read_input size "快照大小(如 5G):" "5G"
            snap="${lv}_snap_$(date +%s)"
            show_spinner "创建 LVM 快照..."
            lvcreate -L "${size}" -s -n "$(basename "${snap}")" "${lv}"
            stop_spinner
            log_success "快照已创建: /dev/${vg}/$(basename "${snap}")"
            log_info "恢复方式: lvconvert --merge /dev/${vg}/$(basename "${snap}")（需先卸载）"
            ;;
        2)
            local snaps
            echo "可用快照:"
            lvs -a -o lv_name,vg_name,size,origin | grep -i snap || true
            read_input snap "快照卷名:" ""
            confirm_action "合并快照 ${snap}（覆盖当前数据）" || return 1
            umount "${lv}" 2>/dev/null
            lvconvert --merge "/dev/${vg}/${snap}" -y
            log_success "快照已合并，请重新挂载 ${lv}"
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
