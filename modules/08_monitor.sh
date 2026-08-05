#!/bin/bash
# ============================================================
# 文件：modules/08_monitor.sh
# 功能：监控与日志管理 [Monitoring & Log Management]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：系统资源监控(CPU高负载自动诊断)、进程管理、磁盘/LVM管理、
#       权限诊断(ACL/挂载选项)、日志收集(logrotate/journalctl)
# ============================================================
set -euo pipefail

module_name="监控与日志管理"
module_short="monitor"
module_version="1.0.0"

module_description() {
    echo "资源监控(CPU/内存/磁盘/网络)、进程管理、LVM磁盘管理、权限诊断、日志收集分析"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 系统资源监控"
    echo " 2. CPU 高负载自动诊断"
    echo " 3. 进程管理（查看/杀死/优先级）"
    echo " 4. 磁盘与 LVM 管理"
    echo " 5. 权限诊断与修复"
    echo " 6. 日志收集与分析"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) resource_monitor ;;
        2) cpu_diag ;;
        3) process_manager ;;
        4) disk_manager ;;
        5) perm_diag ;;
        6) log_manager ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# [资源] 实时查看 CPU/内存/磁盘/网络
# 参数：无
# 返回：无
# ------------------------------------------------------------
resource_monitor() {
    check_command htop && { htop; return 0; }
    check_command glances && { glances; return 0; }
    check_root || return 1
    log_info "安装 glances（系统监控面板）..."
    install_pkg glances 2>/dev/null || pip3 install -U glances 2>/dev/null || true
    if check_command glances; then glances; else
        echo "== 系统负载 =="; uptime
        echo "== 内存 =="; free -h
        echo "== 磁盘 =="; df -h
        echo "== TOP 进程 =="; ps aux --sort=-%cpu | head -n 15
    fi
}

# ------------------------------------------------------------
# [CPU诊断] CPU 高负载自动诊断（ps→top→strace→jstack 链路）
# 参数：无
# 返回：无
# ------------------------------------------------------------
cpu_diag() {
    log_info "CPU 负载诊断开始（1分钟采样）..."
    echo "== 1. 系统负载 =="
    uptime
    echo "== 2. TOP 10 CPU 进程 =="
    ps aux --sort=-%cpu | head -n 11
    local top_pid
    top_pid=$(ps aux --sort=-%cpu | awk 'NR==2{print $2}')
    echo "== 3. 最高进程详情 (PID=${top_pid}) =="
    ps -p "${top_pid}" -o pid,user,pcpu,pmem,cmd --no-headers 2>/dev/null || true
    log_info "是否对该进程做系统调用跟踪(strace)?"
    read_input do_strace "strace 跟踪10秒? [y/n]:" "n"
    if [[ "${do_strace}" == "y" ]]; then
        check_command strace || install_pkg strace
        timeout 10 strace -p "${top_pid}" -c -f 2>&1 | tail -n 30 || true
    fi
    # 若是 Java 进程，提示 jstack 线程转储
    if ps -p "${top_pid}" -o cmd --no-headers 2>/dev/null | grep -q java; then
        check_command jstack && {
            read_input dump "Java线程转储(jstack)? [y/n]:" "y"
            [[ "${dump}" == "y" ]] && jstack "${top_pid}" > "/tmp/jstack_${top_pid}.txt" && log_success "线程转储已保存: /tmp/jstack_${top_pid}.txt"
        } || log_warning "未找到 jstack，请安装 JDK"
    fi
    log_success "CPU 诊断完成"
}

# ============================================================
# 进程管理
# ============================================================
process_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [进程管理] 子菜单"
        echo "======================================"
        echo " 1. 查看进程树"
        echo " 2. 杀死进程（交互选择 PID）"
        echo " 3. 调整进程优先级 (nice/renice)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-3) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) process_tree ;;
            2) process_kill ;;
            3) process_nice ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [进程] 查看进程树
# 参数：无
# 返回：无
# ------------------------------------------------------------
process_tree() {
    check_command pstree && pstree -ap || ps -ef --forest
}

# ------------------------------------------------------------
# [进程] 杀死进程（交互选择 PID）
# 参数：无
# 返回：无
# ------------------------------------------------------------
process_kill() {
    log_info "当前进程列表（前20）:"
    ps aux --sort=-%cpu | head -n 21 | awk '{printf "%s %s %s\n", $2, $3"%", $11}'
    local pid sig
    read_input pid "要操作的 PID:" ""
    [[ "${pid}" =~ ^[0-9]+$ ]] || { log_error "无效 PID"; return 1; }
    ps -p "${pid}" >/dev/null 2>&1 || { log_error "进程不存在: ${pid}"; return 1; }
    read_input sig "信号 [9=强杀 15=正常结束]:" "15"
    kill -"${sig}" "${pid}" 2>/dev/null || kill -9 "${pid}"
    log_success "已向进程 ${pid} 发送信号 ${sig}"
}

# ------------------------------------------------------------
# [进程] 优先级调整（nice/renice）
# 参数：无
# 返回：无
# ------------------------------------------------------------
process_nice() {
    local pid val
    read_input pid "PID:" ""
    read_input val "新优先级(-20~19，越小越优先):" "0"
    [[ "${val}" =~ ^-?[0-9]+$ ]] && (( val >= -20 && val <= 19 )) || { log_error "优先级无效"; return 1; }
    renice "${val}" -p "${pid}"
    log_success "进程 ${pid} 优先级已调整为 ${val}"
}

# ============================================================
# 磁盘 / LVM 管理
# ============================================================
disk_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [磁盘管理] 子菜单"
        echo "======================================"
        echo " 1. 查看分区使用"
        echo " 2. LVM 管理（创建/扩展/缩小）"
        echo " 3. 磁盘挂载/卸载"
        echo " 4. 查找被删除但未释放的文件"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-4) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) disk_usage ;;
            2) lvm_manager ;;
            3) disk_mount ;;
            4) disk_deleted_find ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [磁盘] 分区使用情况
# 参数：无
# 返回：无
# ------------------------------------------------------------
disk_usage() {
    df -h
}

# ------------------------------------------------------------
# [磁盘] LVM 管理（创建/扩展/缩小）
# 参数：无
# 返回：无
# ------------------------------------------------------------
lvm_manager() {
    check_root || return 1
    check_command lvs || { log_error "LVM 工具未安装，请安装 lvm2"; return 1; }
    local act
    echo "== 当前 LVM 状态 =="
    vgs 2>/dev/null || true
    lvs 2>/dev/null || true
    read_input act "操作 [1=扩展LV 2=缩小LV 3=创建PV/VG]:" ""
    case "${act}" in
        1)
            local lv size
            read_input lv "逻辑卷(如 /dev/vg0/lv_data):" ""
            read_input size "扩展大小(如 +10G 或 100%FREE):" "+10G"
            lvextend -L "${size}" "${lv}"
            read_input do_resize "同时扩展文件系统? [y/n]:" "y"
            if [[ "${do_resize}" == "y" ]]; then
                resize2fs "${lv}" 2>/dev/null || xfs_growfs "${lv}" 2>/dev/null || true
            fi
            log_success "LV ${lv} 已扩展 ${size}"
            ;;
        2)
            local lv size
            read_input lv "逻辑卷:" ""
            read_input size "缩小到(如 20G):" ""
            confirm_action "缩小 LV ${lv} 到 ${size}（危险操作，先备份数据）" || return 1
            umount "${lv}" 2>/dev/null
            e2fsck -f "${lv}" 2>/dev/null
            resize2fs "${lv}" "${size}" 2>/dev/null
            lvreduce -L "${size}" "${lv}" -y
            log_success "LV 已缩小到 ${size}"
            ;;
        3)
            local pv vg
            read_input pv "物理磁盘(如 /dev/sdb):" ""
            read_input vg "卷组名(留空=使用pv名):" ""
            pvcreate "${pv}"
            if [[ -n "${vg}" ]]; then vgcreate "${vg}" "${pv}"; fi
            log_success "PV/VG 创建完成"
            ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [磁盘] 挂载/卸载
# 参数：无
# 返回：无
# ------------------------------------------------------------
disk_mount() {
    check_root || return 1
    local act dev dir fstype
    read_input act "操作 [1=挂载 2=卸载]:" "1"
    case "${act}" in
        1)
            read_input dev "设备(如 /dev/sdb1):" ""
            read_input dir "挂载点:" "/mnt/data"
            read_input fstype "文件系统(留空自动):" ""
            mkdir -p "${dir}"
            if [[ -n "${fstype}" ]]; then
                mount -t "${fstype}" "${dev}" "${dir}"
            else
                mount "${dev}" "${dir}"
            fi
            read_input fstab "写入 /etc/fstab 开机自动挂载? [y/n]:" "n"
            if [[ "${fstab}" == "y" ]]; then
                grep -q "${dir}" /etc/fstab || echo -e "${dev}\t${dir}\t${fstype:-auto}\tdefaults\t0 2" >> /etc/fstab
            fi
            log_success "挂载完成: ${dev} -> ${dir}"
            ;;
        2)
            read_input dir "挂载点:" ""
            umount "${dir}" || fuser -km "${dir}" && umount "${dir}"
            log_success "卸载完成: ${dir}"
            ;;
    esac
}

# ------------------------------------------------------------
# [磁盘] 查找被删除但未释放的文件（lsof | grep deleted）
# 参数：无
# 返回：无
# ------------------------------------------------------------
disk_deleted_find() {
    check_command lsof || { install_pkg lsof 2>/dev/null || { log_error "缺少 lsof"; return 1; }; }
    log_info "查找被删除但仍在占用的文件（磁盘空间未释放）..."
    lsof +L1 2>/dev/null | head -n 30 || lsof 2>/dev/null | grep deleted | head -n 30
    log_info "处理方式: 找到对应 PID 后 kill 该进程即可释放空间"
}

# ============================================================
# 权限诊断
# ============================================================
# ------------------------------------------------------------
# [权限] 权限诊断（常规权限→ACL→挂载选项链条）与一键修复
# 参数：无
# 返回：无
# ------------------------------------------------------------
perm_diag() {
    check_root || return 1
    local target
    read_input target "要诊断的路径:" "/"
    [[ -d "${target}" || -f "${target}" ]] || { log_error "路径不存在: ${target}"; return 1; }
    echo "== 1. 常规权限 =="
    ls -ld "${target}"
    echo "== 2. ACL 权限 (Access Control List) =="
    getfacl "${target}" 2>/dev/null || log_warning "缺少 getfacl（安装 acl 包）"
    echo "== 3. 挂载选项（noexec/nosuid 检查） =="
    local dev
    dev=$(df "${target}" | awk 'NR==2{print $1}')
    findmnt "${dev}" 2>/dev/null || mount | grep "${dev}"
    local opts
    opts=$(findmnt -n -o OPTIONS "${dev}" 2>/dev/null || echo "")
    if [[ "${opts}" == *"noexec"* ]]; then
        log_warning "检测到 noexec 选项，该挂载点无法执行二进制程序"
    else
        log_success "未启用 noexec"
    fi
    read_input do_fix "一键修复(恢复权限到合理默认值)? [y/n]:" "n"
    if [[ "${do_fix}" == "y" ]]; then
        confirm_action "递归修复权限: chmod 755/chown root" || return 1
        chmod 755 "${target}" 2>/dev/null
        chown root:root "${target}" 2>/dev/null
        log_success "权限已修复"
    fi
}

# ============================================================
# 日志管理
# ============================================================
log_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [日志管理] 子菜单"
        echo "======================================"
        echo " 1. journalctl 交互式过滤"
        echo " 2. logrotate 配置"
        echo " 3. 日志打包归档"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-3) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) journal_filter ;;
            2) logrotate_config ;;
            3) log_archive ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [日志] journalctl 交互式过滤
# 参数：无
# 返回：无
# ------------------------------------------------------------
journal_filter() {
    local act svc
    echo "journalctl 过滤选项:"
    echo "  1. 最近1小时错误日志"
    echo "  2. 指定服务日志"
    echo "  3. 按关键字搜索"
    read_input act "选择:" "1"
    case "${act}" in
        1) journalctl --since "-1 hour" -p err --no-pager | tail -n 50 ;;
        2) read_input svc "服务名(如 sshd/nginx):" ""; journalctl -u "${svc}" --no-pager | tail -n 80 ;;
        3) local kw; read_input kw "关键字:" ""; journalctl --no-pager | grep -i "${kw}" | tail -n 50 ;;
    esac
}

# ------------------------------------------------------------
# [日志] logrotate 配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
logrotate_config() {
    check_root || return 1
    local logpath days
    read_input logpath "日志路径模式(如 /var/log/app/*.log):" ""
    read_input days "保留天数:" "30"
    [[ "${days}" =~ ^[0-9]+$ ]] || { log_error "无效天数"; return 1; }
    cat > /etc/logrotate.d/zetops-app <<EOF
${logpath} {
    daily
    rotate ${days}
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    logrotate -d /etc/logrotate.d/zetops-app 2>/dev/null || true
    log_success "logrotate 配置已生成（每日轮转，保留 ${days} 天，gzip压缩）"
}

# ------------------------------------------------------------
# [日志] 日志打包归档
# 参数：无
# 返回：无
# ------------------------------------------------------------
log_archive() {
    check_root || return 1
    local src dir
    read_input src "要归档的日志目录:" "/var/log"
    read_input dir "归档保存目录:" "${BACKUP_DIR}/logs"
    [[ -d "${src}" ]] || { log_error "目录不存在"; return 1; }
    mkdir -p "${dir}"
    local file="${dir}/logs_$(date +%Y%m%d_%H%M%S).tar.gz"
    show_spinner "打包日志 ${src} ..."
    tar czf "${file}" -C "$(dirname "${src}")" "$(basename "${src}")" 2>/dev/null
    stop_spinner
    log_success "日志已归档: ${file}"
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
