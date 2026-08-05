#!/bin/bash
# ============================================================
# 文件：modules/09_backup.sh
# 功能：备份与灾备 [Backup & Disaster Recovery]
# 作者：zc 团队
# 版本：1.1.0
# 日期：2026-08-06
# 说明：文件备份(tar/rsync/增量/排除)、远程备份(rsync+免密)、
#       数据库自动备份脚本、定时备份(crontab)、LVM快照
#       v1.1.0: 新增"查看备份总览"及各操作查看列表（备份/增量/远程/
#               脚本/定时任务/快照），所有备份操作完成提示文件路径与大小
# ============================================================
set -euo pipefail

module_name="备份与灾备"
module_short="backup"
module_version="1.1.0"

module_description() {
    echo "文件备份(tar/rsync/增量)、远程同步(rsync免密)、数据库备份脚本、定时备份、LVM快照"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看备份总览"
    echo " 2. 文件备份 (tar/rsync)"
    echo " 3. 增量备份"
    echo " 4. 远程备份 (rsync + SSH免密)"
    echo " 5. 数据库备份脚本生成"
    echo " 6. 定时备份 (crontab)"
    echo " 7. LVM 快照 (Snapshot)"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) bk_overview ;;
        2) bk_file_menu ;;
        3) bk_incremental_menu ;;
        4) bk_remote_menu ;;
        5) bk_db_menu ;;
        6) bk_cron_menu ;;
        7) bk_snapshot_menu ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [备份] 查看备份总览（磁盘空间/目录列表/最近备份时间）
# 参数：无
# 返回：无
# ------------------------------------------------------------
bk_overview() {
    log_info "== 备份目录所在磁盘空间 (${BACKUP_DIR}) =="
    df -h "${BACKUP_DIR}" 2>/dev/null || log_warning "备份目录不存在或无法访问: ${BACKUP_DIR}"
    log_info "== 备份目录列表 (${BACKUP_DIR}) =="
    if [[ -d "${BACKUP_DIR}" ]] && ls -A "${BACKUP_DIR}" 2>/dev/null | grep -q .; then
        ls -lht "${BACKUP_DIR}"
    else
        log_info "暂无备份，可先执行『文件备份』"
    fi
    log_info "== 最近一次备份时间 =="
    local latest
    latest=$(ls -t "${BACKUP_DIR}" 2>/dev/null | head -n1 || true)
    if [[ -n "${latest}" ]]; then
        if stat -c '%y  %n' "${BACKUP_DIR}/${latest}" >/dev/null 2>&1; then
            stat -c '最近备份: %y  %n' "${BACKUP_DIR}/${latest}"
        else
            ls -ld "${BACKUP_DIR}/${latest}"
        fi
    else
        log_info "暂无备份记录"
    fi
}

# ============================================================
# 文件备份（tar / rsync）
# ============================================================
bk_file_menu() {
    local c
    while true; do
        echo "======================================"
        echo "  [文件备份] 子菜单"
        echo "======================================"
        echo " 1. 查看备份列表"
        echo " 2. 执行文件备份 (tar/rsync)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) bk_list ;;
            2) file_backup ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [备份] 查看备份列表
# 参数：无
# 返回：无
# ------------------------------------------------------------
bk_list() {
    log_info "== 备份列表 (${BACKUP_DIR}) =="
    if [[ -d "${BACKUP_DIR}" ]] && ls -A "${BACKUP_DIR}" 2>/dev/null | grep -q .; then
        ls -lht "${BACKUP_DIR}"
    else
        log_info "暂无备份"
    fi
}

# ------------------------------------------------------------
# [文件备份] 本地目录备份（tar 或 rsync，执行前展示已有备份）
# 参数：无
# 返回：无
# ------------------------------------------------------------
file_backup() {
    check_root || return 1
    log_info "== 当前备份目录与已有备份 =="
    bk_list
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
            du -sh "${file}" 2>/dev/null || ls -lh "${file}"
            ;;
        2)
            local dst
            read_input dst "目标目录:" "${dir}/${name}"
            mkdir -p "${dst}"
            show_spinner "rsync 同步中..."
            rsync -a --delete "${src}/" "${dst}/"
            stop_spinner
            log_success "rsync 同步完成: ${src} -> ${dst}"
            du -sh "${dst}" 2>/dev/null || true
            ;;
    esac
}

# ============================================================
# 增量备份
# ============================================================
bk_incremental_menu() {
    local c
    while true; do
        echo "======================================"
        echo "  [增量备份] 子菜单"
        echo "======================================"
        echo " 1. 查看已有增量备份列表"
        echo " 2. 执行增量备份"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) bk_incremental_list ;;
            2) file_backup_incremental ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [备份] 查看已有增量备份列表
# 参数：无
# 返回：无
# ------------------------------------------------------------
bk_incremental_list() {
    local inc_dir="${BACKUP_DIR}/incremental"
    local found=0
    log_info "== 已有增量备份列表 =="
    if [[ -d "${inc_dir}" ]] && ls -A "${inc_dir}" 2>/dev/null | grep -q .; then
        found=1
        echo "---- ${inc_dir} ----"
        ls -lht "${inc_dir}"
    fi
    # 兼容旧结构：BACKUP_DIR 下直接的 full_*/incr_*
    if ls -d "${BACKUP_DIR}"/full_* "${BACKUP_DIR}"/incr_* >/dev/null 2>&1; then
        found=1
        echo "---- ${BACKUP_DIR} ----"
        ls -ldht "${BACKUP_DIR}"/full_* "${BACKUP_DIR}"/incr_* 2>/dev/null
    fi
    if [[ ${found} == 0 ]]; then
        log_info "暂无增量备份，可先执行『增量备份』"
    fi
}

# ------------------------------------------------------------
# [文件备份] 增量备份（rsync --link-dest 硬链接增量，执行前展示已有备份）
# 参数：无
# 返回：无
# ------------------------------------------------------------
file_backup_incremental() {
    check_root || return 1
    check_command rsync || install_pkg rsync
    log_info "== 已有增量备份 =="
    bk_incremental_list
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
        du -sh "${dst}/incr_${stamp}" 2>/dev/null || true
    else
        rsync -a "${src}/" "${dst}/full_${stamp}/"
        log_success "首次全量备份完成: ${dst}/full_${stamp}"
        du -sh "${dst}/full_${stamp}" 2>/dev/null || true
    fi
}

# ============================================================
# 远程备份
# ============================================================
bk_remote_menu() {
    local c
    while true; do
        echo "======================================"
        echo "  [远程备份] 子菜单"
        echo "======================================"
        echo " 1. 查看已配置的远程备份信息"
        echo " 2. 配置并执行远程备份"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) bk_remote_info ;;
            2) remote_backup ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [备份] 查看已配置的远程备份信息（SSH config/密钥/同步记录）
# 参数：无
# 返回：无
# ------------------------------------------------------------
bk_remote_info() {
    local found=0 rlog
    log_info "== 已配置的远程备份信息 =="
    if [[ -f ~/.ssh/config ]]; then
        found=1
        log_info "-- ~/.ssh/config 中的远程主机 --"
        grep -E '^\s*(Host|HostName)\s' ~/.ssh/config | head -n 30 || true
    fi
    if ls ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub >/dev/null 2>&1; then
        found=1
        log_info "-- 已配置的免密密钥 --"
        ls -l ~/.ssh/id_*.pub 2>/dev/null || true
    fi
    rlog=$(ls -t "${LOG_DIR}"/remote_backup*.log "${LOG_DIR}"/rsync*.log 2>/dev/null | head -n1 || true)
    if [[ -n "${rlog}" ]]; then
        found=1
        log_info "-- 上次同步记录 (${rlog}) --"
        tail -n 10 "${rlog}"
    fi
    if [[ ${found} == 0 ]]; then
        log_info "未检测到远程备份配置，可先执行『远程备份』"
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
    mkdir -p "${LOG_DIR}"
    echo "$(date '+%F %T') 远程备份完成: ${src}/ -> ${user}@${host}:${dst_dir}/" >> "${LOG_DIR}/remote_backup.log"
}

# ============================================================
# 数据库备份脚本
# ============================================================
bk_db_menu() {
    local c
    while true; do
        echo "======================================"
        echo "  [数据库备份脚本] 子菜单"
        echo "======================================"
        echo " 1. 查看已生成的备份脚本列表"
        echo " 2. 生成备份脚本 (MySQL/PostgreSQL)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) bk_scripts_list ;;
            2) db_backup_script ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [备份] 查看已生成的备份脚本列表
# 参数：无
# 返回：无
# ------------------------------------------------------------
bk_scripts_list() {
    local found=0 d scripts
    log_info "== 已生成的备份脚本列表 =="
    for d in "${BACKUP_DIR}" "${BACKUP_DIR}/scripts" "/root/scripts"; do
        if [[ -d "${d}" ]] && ls -A "${d}" 2>/dev/null | grep -q .; then
            scripts=$(ls -lht "${d}" 2>/dev/null | grep -E '\.sh$' || true)
            if [[ -n "${scripts}" ]]; then
                found=1
                echo "---- ${d} ----"
                echo "${scripts}" | head -n 20
            fi
        fi
    done
    if [[ ${found} == 0 ]]; then
        log_info "暂无备份脚本（生成位置: ${BACKUP_DIR}/db_backup.sh，或 ${BACKUP_DIR}/scripts、/root/scripts）"
    fi
}

# ------------------------------------------------------------
# [数据库备份] 生成 MySQL/PostgreSQL 自动备份脚本（生成前展示已有脚本）
# 参数：无
# 返回：无
# ------------------------------------------------------------
db_backup_script() {
    check_root || return 1
    log_info "== 已生成的备份脚本（生成前查看） =="
    bk_scripts_list
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
    ls -lh "${script}" | awk '{print "脚本大小: " $5}'
}
# ============================================================
# 定时备份（crontab）
# ============================================================
bk_cron_menu() {
    local c
    while true; do
        echo "======================================"
        echo "  [定时备份] 子菜单"
        echo "======================================"
        echo " 1. 查看当前定时任务"
        echo " 2. 配置定时备份"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) bk_cron_view ;;
            2) backup_cron ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [备份] 查看当前定时任务
# 参数：无
# 返回：无
# ------------------------------------------------------------
bk_cron_view() {
    log_info "== 当前定时任务 (crontab -l) =="
    crontab -l 2>/dev/null || log_info "暂无定时任务"
}

# ------------------------------------------------------------
# [定时备份] 配置 crontab 定时任务（配置前后均回显 crontab）
# 参数：无
# 返回：无
# ------------------------------------------------------------
backup_cron() {
    check_root || return 1
    local script time
    log_info "== 配置前当前 crontab =="
    crontab -l 2>/dev/null || log_info "暂无定时任务"
    read_input script "备份脚本路径(留空使用默认):" "${BACKUP_DIR}/db_backup.sh"
    [[ -f "${script}" ]] || { log_error "脚本不存在: ${script}"; return 1; }
    read_input time "执行时间(如 每日凌晨2点=0 2 * * *):" "0 2 * * *"
    (crontab -l 2>/dev/null | grep -v "${script}" || true; echo "${time} ${script} >> ${LOG_DIR}/backup_cron.log 2>&1") | crontab -
    log_success "定时备份已配置: ${time} ${script}"
    log_info "当前 crontab:"
    crontab -l 2>/dev/null || true
}

# ============================================================
# LVM 快照
# ============================================================
bk_snapshot_menu() {
    local c
    while true; do
        echo "======================================"
        echo "  [LVM快照] 子菜单"
        echo "======================================"
        echo " 1. 查看快照列表"
        echo " 2. 创建/恢复快照"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-2) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) bk_snapshot_list ;;
            2) lvm_snapshot ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [备份] 查看快照列表
# 参数：无
# 返回：无
# ------------------------------------------------------------
bk_snapshot_list() {
    log_info "== LVM 快照列表 =="
    if check_command lvs; then
        lvs -a -o lv_name,vg_name,size,origin 2>/dev/null | grep -i snap || log_info "暂无 LVM 快照"
    else
        log_warning "缺少 LVM 工具 (lvm2)"
    fi
}

# ------------------------------------------------------------
# [LVM快照] 快照创建/恢复（恢复前列出快照）
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
