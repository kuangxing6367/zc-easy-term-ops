#!/bin/bash
# ============================================================
# 文件：modules/18_db_unified.sh
# 功能：统一数据库管理 [Unified Database Manager]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-06
# 说明：
#   - 实例清单 ~/.zetops/databases.ini（MySQL/PostgreSQL/Redis/MongoDB）
#   - 连接测试（多回退：mysql→mariadb，pg→psql）
#   - 统一备份/恢复（按实例类型自动选择工具）
#   - 慢查询集中查看、性能诊断
# ============================================================
set -euo pipefail

module_name="统一数据库管理"
module_short="db_unified"
module_version="1.0.0"

DBS_FILE="${DBS_FILE:-${HOME}/.zetops/databases.ini}"
BACKUP_ROOT="${BACKUP_ROOT:-${HOME}/zetops-backup}"

module_description() {
    echo "MySQL/PostgreSQL/Redis/MongoDB 实例统一管理、备份恢复、慢查询 [Unified DB Manager]"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. 查看所有数据库实例"
    echo " 2. 添加数据库实例"
    echo " 3. 删除数据库实例"
    echo " 4. 连接测试（多回退）"
    echo " 5. 统一备份（全部实例）"
    echo " 6. 恢复备份"
    echo " 7. 慢查询集中查看"
    echo " 8. 性能诊断"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) dbuni_list ;;
        2) dbuni_add ;;
        3) dbuni_delete ;;
        4) dbuni_test ;;
        5) dbuni_backup_all ;;
        6) dbuni_restore ;;
        7) dbuni_slow ;;
        8) dbuni_perf ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ------------------------------------------------------------
# 确保配置文件存在
# ------------------------------------------------------------
dbuni_ensure_file() {
    mkdir -p "$(dirname "${DBS_FILE}")" 2>/dev/null || true
    [[ -f "${DBS_FILE}" ]] || touch "${DBS_FILE}"
}

# ------------------------------------------------------------
# 列出实例节名称
# ------------------------------------------------------------
dbuni_sections() {
    grep -E '^\[' "${DBS_FILE}" 2>/dev/null | tr -d '[]' || true
}

# ------------------------------------------------------------
# 读取实例配置项
# 参数：$1 节名  $2 键名
# ------------------------------------------------------------
dbuni_get() {
    local section="$1" key="$2"
    awk -v sec="${section}" -v k="${key}" '
        $0 ~ "^\\[" sec "\\]$" { found=1; next }
        /^\[/ { found=0 }
        found && $1 ~ "^" k "=" { sub(/^[^=]*=/, ""); print; exit }
    ' "${DBS_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# 获取可用客户端命令（多回退）
# 参数：$1 类型(mysql/postgresql/redis/mongodb)
# 输出：客户端命令名，未找到输出空
# ------------------------------------------------------------
dbuni_client() {
    local type="$1"
    case "${type}" in
        mysql)
            check_command mariadb && { echo "mariadb"; return; }
            check_command mysql && { echo "mysql"; return; }
            ;;
        postgresql)
            check_command psql && { echo "psql"; return; }
            ;;
        redis)
            check_command redis-cli && { echo "redis-cli"; return; }
            ;;
        mongodb)
            check_command mongosh && { echo "mongosh"; return; }
            check_command mongo && { echo "mongo"; return; }
            ;;
    esac
    echo ""
}

# ------------------------------------------------------------
# 测试单个实例连接
# 参数：$1 节名
# 输出：ok + 详细信息 / fail + 原因
# 返回：0=连接成功 1=失败
# ------------------------------------------------------------
dbuni_test_one() {
    local sec="$1"
    local type host port user pass db
    type=$(dbuni_get "${sec}" "type")
    host=$(dbuni_get "${sec}" "host")
    port=$(dbuni_get "${sec}" "port")
    user=$(dbuni_get "${sec}" "user")
    pass=$(dbuni_get "${sec}" "password")
    db=$(dbuni_get "${sec}" "database")

    # 端口回退：未配置时按类型默认
    if [[ -z "${port}" ]]; then
        case "${type}" in
            mysql) port="3306" ;;
            postgresql) port="5432" ;;
            redis) port="6379" ;;
            mongodb) port="27017" ;;
        esac
    fi

    # TCP 连通性检查（超时 3 秒）
    if ! (exec 3<>/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
        echo "fail: 端口 ${host}:${port} 不可达"
        return 1
    fi
    exec 3>&- 2>/dev/null || true

    # 按类型认证测试
    local client
    client=$(dbuni_client "${type}")
    case "${type}" in
        mysql)
            if [[ -z "${client}" ]]; then
                echo "fail: 未安装 mysql/mariadb 客户端"
                return 1
            fi
            if timeout 5 "${client}" -h "${host}" -P "${port}" -u "${user}" "${pass:+-p${pass}}" -e "SELECT 1" >/dev/null 2>&1; then
                echo "ok: ${client} 认证成功 (${host}:${port})"
                return 0
            else
                echo "fail: ${client} 认证失败 (${host}:${port})"
                return 1
            fi
            ;;
        postgresql)
            if [[ -z "${client}" ]]; then
                echo "fail: 未安装 psql 客户端"
                return 1
            fi
            if PGPASSWORD="${pass}" timeout 5 "${client}" -h "${host}" -p "${port}" -U "${user}" -d "${db:-postgres}" -c "SELECT 1" >/dev/null 2>&1; then
                echo "ok: psql 认证成功 (${host}:${port}/${db:-postgres})"
                return 0
            else
                echo "fail: psql 认证失败 (${host}:${port})"
                return 1
            fi
            ;;
        redis)
            if [[ -z "${client}" ]]; then
                echo "fail: 未安装 redis-cli"
                return 1
            fi
            local auth_cmd=""
            [[ -n "${pass}" ]] && auth_cmd="-a ${pass}"
            if timeout 5 "${client}" -h "${host}" -p "${port}" ${auth_cmd} PING 2>/dev/null | grep -q PONG; then
                echo "ok: redis PONG (${host}:${port})"
                return 0
            else
                echo "fail: redis 无响应 (${host}:${port})"
                return 1
            fi
            ;;
        mongodb)
            if [[ -z "${client}" ]]; then
                echo "fail: 未安装 mongosh/mongo"
                return 1
            fi
            local auth_str=""
            [[ -n "${user}" ]] && auth_str="-u ${user} -p ${pass} --authenticationDatabase admin"
            if timeout 5 "${client}" --quiet --eval "db.runCommand({ping:1}).ok" ${auth_str} "mongodb://${host}:${port}/" 2>/dev/null | grep -q 1; then
                echo "ok: mongo ping 成功 (${host}:${port})"
                return 0
            else
                echo "fail: mongo 无响应 (${host}:${port})"
                return 1
            fi
            ;;
        *)
            echo "fail: 不支持的实例类型 ${type}"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# 1. 查看所有数据库实例
# ------------------------------------------------------------
dbuni_list() {
    dbuni_ensure_file
    local sections
    sections=$(dbuni_sections)
    echo ""
    log_info "数据库实例清单（${DBS_FILE}）"
    echo "--------------------------------------------------"
    if [[ -z "${sections}" ]]; then
        echo "  ${COLOR_GRAY}(暂无实例，请先添加: 菜单 2)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local sec type host port
    for sec in ${sections}; do
        type=$(dbuni_get "${sec}" "type")
        host=$(dbuni_get "${sec}" "host")
        port=$(dbuni_get "${sec}" "port")
        echo "  ${COLOR_BOLD}${type}:${sec}${COLOR_RESET}  ${host}:${port:-默认}"
    done
    echo "--------------------------------------------------"
    echo "  ${COLOR_GRAY}提示: 菜单 4 可对所有实例执行连接测试${COLOR_RESET}"
}

# ------------------------------------------------------------
# 2. 添加数据库实例
# ------------------------------------------------------------
dbuni_add() {
    dbuni_ensure_file
    echo ""
    read_input sec_name "实例节名（如 db_master）" ""
    [[ -z "${sec_name}" ]] && return
    if grep -q "^\[${sec_name}\]$" "${DBS_FILE}" 2>/dev/null; then
        log_error "实例 [${sec_name}] 已存在"
        return
    fi
    echo ""
    echo "  可选类型: mysql / postgresql / redis / mongodb"
    read_input db_type "数据库类型" "mysql"
    read_input host "主机地址" "127.0.0.1"
    read_input port "端口（留空自动按类型默认）" ""
    read_input user "用户名（redis 可留空）" ""
    read_input pass "密码（redis/mongo 可留空）" ""
    read_input db "数据库名（postgresql 必填）" ""

    {
        echo ""
        echo "[${sec_name}]"
        echo "type=${db_type}"
        echo "host=${host}"
        [[ -n "${port}" ]] && echo "port=${port}"
        [[ -n "${user}" ]] && echo "user=${user}"
        [[ -n "${pass}" ]] && echo "password=${pass}"
        [[ -n "${db}" ]] && echo "database=${db}"
    } >> "${DBS_FILE}"
    log_success "实例 [${sec_name}] 已添加"
    audit_log "添加数据库实例 ${sec_name}" "成功"
}

# ------------------------------------------------------------
# 3. 删除数据库实例
# ------------------------------------------------------------
dbuni_delete() {
    dbuni_ensure_file
    local sections
    sections=$(dbuni_sections)
    if [[ -z "${sections}" ]]; then
        log_warning "暂无实例"
        return
    fi
    echo ""
    echo "  可选实例: ${sections}"
    read_input sec_name "输入要删除的实例节名" ""
    [[ -z "${sec_name}" ]] && return
    if ! grep -q "^\[${sec_name}\]$" "${DBS_FILE}" 2>/dev/null; then
        log_error "实例节 [${sec_name}] 不存在"
        return
    fi
    if confirm_action "确认删除实例 [${sec_name}]?"; then
        awk -v sec="${sec_name}" '
            $0 ~ "^\\[" sec "\\]$" { skip=1; next }
            /^\[/ { skip=0 }
            !skip { print }
        ' "${DBS_FILE}" > "${DBS_FILE}.tmp" && mv "${DBS_FILE}.tmp" "${DBS_FILE}"
        sed -i '/^$/N;/^\n$/D' "${DBS_FILE}" 2>/dev/null || true
        log_success "实例 [${sec_name}] 已删除"
        audit_log "删除数据库实例 ${sec_name}" "成功"
    fi
}

# ------------------------------------------------------------
# 4. 连接测试（全部实例，多回退）
# ------------------------------------------------------------
dbuni_test() {
    dbuni_ensure_file
    local sections
    sections=$(dbuni_sections)
    echo ""
    log_info "数据库连接测试（多回退: mysql→mariadb, mongosh→mongo）"
    echo "--------------------------------------------------"
    if [[ -z "${sections}" ]]; then
        echo "  ${COLOR_GRAY}(暂无实例)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local sec result ok=0 fail=0
    for sec in ${sections}; do
        result=$(dbuni_test_one "${sec}")
        if [[ "${result}" == ok:* ]]; then
            echo "  ${COLOR_GREEN}✅ ${sec}: ${result#ok: }${COLOR_RESET}"
            ok=$((ok + 1))
        else
            echo "  ${COLOR_RED}❌ ${sec}: ${result#fail: }${COLOR_RESET}"
            fail=$((fail + 1))
        fi
    done
    echo "--------------------------------------------------"
    echo "  正常 ${ok} / 异常 ${fail}"
    audit_log "数据库连接测试" "正常${ok} 异常${fail}"
}

# ------------------------------------------------------------
# 备份单个实例
# 参数：$1 节名
# 输出：备份文件路径（成功） / 空（失败）
# ------------------------------------------------------------
dbuni_backup_one() {
    local sec="$1"
    local type host port user pass db
    type=$(dbuni_get "${sec}" "type")
    host=$(dbuni_get "${sec}" "host")
    port=$(dbuni_get "${sec}" "port")
    user=$(dbuni_get "${sec}" "user")
    pass=$(dbuni_get "${sec}" "password")
    db=$(dbuni_get "${sec}" "database")
    [[ -z "${port}" ]] && port="3306"

    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local outfile="${BACKUP_ROOT}/${sec}_${ts}.sql.gz"
    mkdir -p "${BACKUP_ROOT}"

    case "${type}" in
        mysql)
            local dump_tool
            if check_command mariadb-dump; then
                dump_tool="mariadb-dump"
            else
                dump_tool="mysqldump"
            fi
            if ! check_command "${dump_tool}"; then
                log_warning "${sec}: 未安装 ${dump_tool}"
                return 1
            fi
            timeout 300 "${dump_tool}" -h "${host}" -P "${port}" -u "${user}" ${pass:+-p"${pass}"} --single-transaction --routines "${db:---all-databases}" 2>/dev/null | gzip > "${outfile}" && {
                echo "${outfile}"
                return 0
            }
            rm -f "${outfile}"
            return 1
            ;;
        postgresql)
            if ! check_command pg_dump; then
                log_warning "${sec}: 未安装 pg_dump"
                return 1
            fi
            [[ -z "${port}" ]] && port="5432"
            if PGPASSWORD="${pass}" timeout 300 pg_dump -h "${host}" -p "${port}" -U "${user}" "${db:-postgres}" 2>/dev/null | gzip > "${outfile}" && [[ -s "${outfile}" ]]; then
                echo "${outfile}"
                return 0
            fi
            rm -f "${outfile}"
            return 1
            ;;
        redis)
            local client
            client=$(dbuni_client "redis")
            if [[ -z "${client}" ]]; then
                log_warning "${sec}: 未安装 redis-cli"
                return 1
            fi
            [[ -z "${port}" ]] && port="6379"
            local auth_cmd=""
            [[ -n "${pass}" ]] && auth_cmd="-a ${pass}"
            if timeout 120 "${client}" -h "${host}" -p "${port}" ${auth_cmd} --rdb "${outfile}.rdb" >/dev/null 2>&1; then
                # 备份 aof/rbd 的同时保存一份 dump.rdb 副本；此处直接压缩保存
                mv "${outfile}.rdb" "${outfile}.rdb.mv" 2>/dev/null || true
                cp "${outfile}.rdb.mv" "${outfile}.rdb" 2>/dev/null || true
                echo "${outfile}.rdb"
                return 0
            fi
            return 1
            ;;
        *)
            log_warning "${sec}: 类型 ${type} 暂不支持备份"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------
# 5. 统一备份（全部实例）
# ------------------------------------------------------------
dbuni_backup_all() {
    dbuni_ensure_file
    local sections
    sections=$(dbuni_sections)
    echo ""
    log_info "统一备份所有实例 → ${BACKUP_ROOT}"
    echo "--------------------------------------------------"
    if [[ -z "${sections}" ]]; then
        echo "  ${COLOR_GRAY}(暂无实例)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    local sec result ok=0 fail=0
    for sec in ${sections}; do
        echo "  备份 ${sec} ..."
        if result=$(dbuni_backup_one "${sec}"); then
            echo "  ${COLOR_GREEN}✅ ${sec}: ${result}${COLOR_RESET}"
            ok=$((ok + 1))
        else
            echo "  ${COLOR_RED}❌ ${sec}: 备份失败${COLOR_RESET}"
            fail=$((fail + 1))
        fi
    done
    echo "--------------------------------------------------"
    echo "  成功 ${ok} / 失败 ${fail}"
    audit_log "数据库统一备份" "成功${ok} 失败${fail}"
}

# ------------------------------------------------------------
# 6. 恢复备份
# ------------------------------------------------------------
dbuni_restore() {
    mkdir -p "${BACKUP_ROOT}"
    local backups
    backups=$(ls -1 "${BACKUP_ROOT}" 2>/dev/null || true)
    echo ""
    log_info "可用备份文件（${BACKUP_ROOT}）"
    echo "--------------------------------------------------"
    if [[ -z "${backups}" ]]; then
        echo "  ${COLOR_GRAY}(暂无备份)${COLOR_RESET}"
        echo "--------------------------------------------------"
        return
    fi
    echo "${backups}" | sed 's/^/  /'
    echo "--------------------------------------------------"
    read_input bk_file "输入要恢复的备份文件名" ""
    [[ -z "${bk_file}" ]] && return
    local bk_path="${BACKUP_ROOT}/${bk_file}"
    [[ -f "${bk_path}" ]] || { log_error "备份文件不存在"; return; }

    # 从文件名推导实例名（实例_时间戳.sql.gz）
    local sec
    sec=$(basename "${bk_file}" | cut -d_ -f1)
    local type
    type=$(dbuni_get "${sec}" "type")
    if [[ -z "${type}" ]]; then
        log_error "无法从文件名推导实例节，请在清单中确认"
        return
    fi
    local host port user pass db
    host=$(dbuni_get "${sec}" "host")
    port=$(dbuni_get "${sec}" "port")
    user=$(dbuni_get "${sec}" "user")
    pass=$(dbuni_get "${sec}" "password")
    db=$(dbuni_get "${sec}" "database")

    if ! confirm_action "确认将 ${bk_file} 恢复到实例 [${sec}] (${type})?"; then
        return
    fi

    case "${type}" in
        mysql)
            local client
            client=$(dbuni_client "mysql")
            if [[ -z "${client}" ]]; then
                log_error "未安装 mysql/mariadb 客户端"
                return
            fi
            [[ -z "${port}" ]] && port="3306"
            gunzip -c "${bk_path}" | timeout 600 "${client}" -h "${host}" -P "${port}" -u "${user}" ${pass:+-p"${pass}"} "${db:-}" 2>&1 | sed 's/^/  /'
            log_success "MySQL 恢复完成"
            ;;
        postgresql)
            if ! check_command psql; then
                log_error "未安装 psql"
                return
            fi
            [[ -z "${port}" ]] && port="5432"
            gunzip -c "${bk_path}" | PGPASSWORD="${pass}" timeout 600 psql -h "${host}" -p "${port}" -U "${user}" -d "${db:-postgres}" 2>&1 | sed 's/^/  /'
            log_success "PostgreSQL 恢复完成"
            ;;
        *)
            log_warning "类型 ${type} 暂不支持自动恢复"
            return
            ;;
    esac
    audit_log "恢复备份 ${bk_file} → ${sec}" "成功"
}

# ------------------------------------------------------------
# 7. 慢查询集中查看
# ------------------------------------------------------------
dbuni_slow() {
    dbuni_ensure_file
    local sections
    sections=$(dbuni_sections)
    echo ""
    log_info "慢查询集中查看"
    echo "--------------------------------------------------"
    local sec type client found=0
    for sec in ${sections}; do
        type=$(dbuni_get "${sec}" "type")
        case "${type}" in
            mysql)
                local host port user pass
                host=$(dbuni_get "${sec}" "host")
                port=$(dbuni_get "${sec}" "port")
                user=$(dbuni_get "${sec}" "user")
                pass=$(dbuni_get "${sec}" "password")
                [[ -z "${port}" ]] && port="3306"
                client=$(dbuni_client "mysql")
                echo ""
                echo "  ${COLOR_BOLD}-- ${sec} (mysql) --${COLOR_RESET}"
                if timeout 5 "${client}" -h "${host}" -P "${port}" -u "${user}" ${pass:+-p"${pass}"} -e "SHOW GLOBAL STATUS LIKE 'Slow_queries'; SHOW VARIABLES LIKE 'long_query_time';" 2>/dev/null | sed 's/^/    /'; then
                    found=$((found + 1))
                else
                    echo "    ${COLOR_RED}连接失败${COLOR_RESET}"
                fi
                ;;
            postgresql)
                local pghost pgport pguser pgpass pgdb
                pghost=$(dbuni_get "${sec}" "host")
                pgport=$(dbuni_get "${sec}" "port")
                pguser=$(dbuni_get "${sec}" "user")
                pgpass=$(dbuni_get "${sec}" "password")
                pgdb=$(dbuni_get "${sec}" "database")
                [[ -z "${pgport}" ]] && pgport="5432"
                echo ""
                echo "  ${COLOR_BOLD}-- ${sec} (postgresql) --${COLOR_RESET}"
                if PGPASSWORD="${pgpass}" timeout 5 psql -h "${pghost}" -p "${pgport}" -U "${pguser}" -d "${pgdb:-postgres}" -c "SELECT query, calls, total_exec_time FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;" 2>/dev/null | sed 's/^/    /'; then
                    found=$((found + 1))
                else
                    echo "    ${COLOR_RED}连接失败（需启用 pg_stat_statements）${COLOR_RESET}"
                fi
                ;;
        esac
    done
    echo "--------------------------------------------------"
    if (( found == 0 )); then
        echo "  ${COLOR_GRAY}(无 MySQL/PostgreSQL 实例)${COLOR_RESET}"
    fi
}

# ------------------------------------------------------------
# 8. 性能诊断
# ------------------------------------------------------------
dbuni_perf() {
    dbuni_ensure_file
    local sections
    sections=$(dbuni_sections)
    echo ""
    log_info "数据库性能诊断"
    echo "--------------------------------------------------"
    local sec type client
    for sec in ${sections}; do
        type=$(dbuni_get "${sec}" "type")
        local host port user pass db
        host=$(dbuni_get "${sec}" "host")
        port=$(dbuni_get "${sec}" "port")
        user=$(dbuni_get "${sec}" "user")
        pass=$(dbuni_get "${sec}" "password")
        db=$(dbuni_get "${sec}" "database")
        echo ""
        echo "  ${COLOR_BOLD}-- ${sec} (${type}) --${COLOR_RESET}"
        case "${type}" in
            mysql)
                [[ -z "${port}" ]] && port="3306"
                client=$(dbuni_client "mysql")
                if [[ -n "${client}" ]]; then
                    timeout 5 "${client}" -h "${host}" -P "${port}" -u "${user}" ${pass:+-p"${pass}"} -e "
                        SELECT '连接数' k, @@max_connections v
                        UNION SELECT '当前连接', (SELECT COUNT(*) FROM information_schema.processlist)
                        UNION SELECT '慢查询阈值(s)', @@long_query_time
                        UNION SELECT '缓冲池(MB)', ROUND(@@innodb_buffer_pool_size/1024/1024)
                        UNION SELECT '线程缓存', @@thread_cache_size;" 2>/dev/null | sed 's/^/    /'
                else
                    echo "    ${COLOR_RED}未安装客户端${COLOR_RESET}"
                fi
                ;;
            redis)
                [[ -z "${port}" ]] && port="6379"
                client=$(dbuni_client "redis")
                if [[ -n "${client}" ]]; then
                    local auth_cmd=""
                    [[ -n "${pass}" ]] && auth_cmd="-a ${pass}"
                    timeout 5 "${client}" -h "${host}" -p "${port}" ${auth_cmd} INFO 2>/dev/null | grep -E '^(used_memory_human|connected_clients|keyspace_hits|keyspace_misses|mem_fragmentation_ratio|uptime_in_days)' | sed 's/^/    /'
                else
                    echo "    ${COLOR_RED}未安装 redis-cli${COLOR_RESET}"
                fi
                ;;
            *)
                echo "    ${COLOR_GRAY}类型 ${type} 暂不支持性能诊断${COLOR_RESET}"
                ;;
        esac
    done
    echo "--------------------------------------------------"
    audit_log "数据库性能诊断" "完成"
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
    dbuni_list
fi
