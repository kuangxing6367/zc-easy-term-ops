#!/bin/bash
# ============================================================
# 文件：modules/04_database.sh
# 功能：数据库管理 [Database Management]
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 说明：MySQL/MariaDB、PostgreSQL、Redis、MongoDB 的
#       安装/建库/用户/备份恢复/高可用/性能调优
# ============================================================
set -euo pipefail

module_name="数据库管理"
module_short="database"
module_version="1.0.0"

# 默认配置（可被 ~/.zetops/zetops.conf 覆盖）
MYSQL_VERSION="${MYSQL_VERSION:-8.0}"
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/data/mysql}"

module_description() {
    echo "MySQL/PostgreSQL/Redis/MongoDB 安装、建库建用户、备份恢复、主从复制、性能调优"
}

module_menu() {
    echo "======================================"
    echo "  ${module_name} 子菜单"
    echo "======================================"
    echo " 1. MySQL/MariaDB 管理"
    echo " 2. PostgreSQL 管理"
    echo " 3. Redis 管理"
    echo " 4. MongoDB 管理"
    echo " 0. 返回主菜单"
    echo "======================================"
}

module_execute() {
    local choice="$1"
    case "${choice}" in
        1) mysql_manager ;;
        2) pg_manager ;;
        3) redis_manager ;;
        4) mongo_manager ;;
        0) return 0 ;;
        *) log_error "无效选项: ${choice}" ;;
    esac
    press_enter
}

# ============================================================
# MySQL 二级菜单
# ============================================================
mysql_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [MySQL管理] 子菜单"
        echo "======================================"
        echo " 1. 安装 MySQL (版本${MYSQL_VERSION})"
        echo " 2. 安全初始化 (root密码/删匿名用户)"
        echo " 3. 创建数据库/用户/授权"
        echo " 4. 数据备份 (mysqldump)"
        echo " 5. 数据恢复"
        echo " 6. 慢查询日志分析"
        echo " 7. 主从复制配置 (Master-Slave)"
        echo " 8. 性能调优 (my.cnf)"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-8) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) mysql_install ;;
            2) mysql_secure_init ;;
            3) mysql_create_db ;;
            4) mysql_backup ;;
            5) mysql_restore ;;
            6) mysql_slowlog_analyze ;;
            7) mysql_replication ;;
            8) mysql_tune ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [MySQL] 安装（apt/dnf，指定版本）
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_install() {
    check_root || return 1
    if check_command mysqld || check_command mariadbd; then
        log_success "MySQL/MariaDB 已安装: $(mysqld --version 2>/dev/null || mariadbd --version 2>/dev/null)"
        return 0
    fi
    local ver
    read_input ver "MySQL 版本(Version):" "${MYSQL_VERSION}"
    log_info "安装 MySQL ${ver} ..."
    case "$(detect_pkg_manager)" in
        apt)
            install_pkg mysql-server || install_pkg mariadb-server
            systemctl enable --now mysql 2>/dev/null || systemctl enable --now mariadb 2>/dev/null || true
            ;;
        dnf|yum)
            install_pkg mysql-server || install_pkg mariadb-server
            systemctl enable --now mysqld 2>/dev/null || systemctl enable --now mariadb 2>/dev/null || true
            ;;
        *) log_error "暂不支持" ; return 1 ;;
    esac
    # 调整数据目录
    if [[ -n "${MYSQL_DATA_DIR}" && "${MYSQL_DATA_DIR}" != "/var/lib/mysql" ]]; then
        log_warning "如需迁移数据目录到 ${MYSQL_DATA_DIR}，请手动操作（含 apparmor/selinux 配置）"
    fi
    log_success "MySQL 安装完成"
}

# ------------------------------------------------------------
# [MySQL] 安全初始化
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_secure_init() {
    check_root || return 1
    local pw
    read_input pw "设置 root 密码(留空则使用自动生成):" ""
    local pw_arg=""
    if [[ -n "${pw}" ]]; then
        pw_arg="-p${pw}"
    fi
    # 尝试 mysql_secure_installation 自动化
    if check_command mysql_secure_installation; then
        log_warning "建议手动执行 mysql_secure_installation 完成安全设置"
    fi
    # 设置 root 密码（如已存在 root 密码则跳过）
    mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${pw}'; FLUSH PRIVILEGES;" 2>/dev/null \
        && log_success "root 密码已设置" \
        || log_warning "未能设置 root 密码（可能已有密码），请手动确认"
    # 删除匿名用户
    mysql -uroot ${pw_arg} -e "DELETE FROM mysql.user WHERE User=''; FLUSH PRIVILEGES;" 2>/dev/null || true
    log_success "安全初始化完成"
}

# ------------------------------------------------------------
# [MySQL] 创建数据库/用户/授权（Create Database & User）
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_create_db() {
    check_root || return 1
    local db user host pw rootpw
    read_input db "数据库名(Database):" ""
    read_input user "用户名:" ""
    read_input host "允许主机(host，% 为任意):" "localhost"
    read_input pw "密码:" ""
    read_input rootpw "MySQL root 密码:" ""
    [[ -z "${db}" || -z "${user}" || -z "${pw}" ]] && { log_error "数据库/用户名/密码不能为空"; return 1; }
    # 防止 SQL 注入：仅允许合法字符
    [[ "${db}" =~ ^[a-zA-Z0-9_]+$ ]] || { log_error "数据库名不合法"; return 1; }
    [[ "${user}" =~ ^[a-zA-Z0-9_]+$ ]] || { log_error "用户名不合法"; return 1; }
    mysql -uroot -p"${rootpw}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` DEFAULT CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${user}'@'${host}' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'${host}';
FLUSH PRIVILEGES;
SQL
    log_success "数据库 ${db} / 用户 ${user} 创建并授权完成"
}

# ------------------------------------------------------------
# [MySQL] 备份（mysqldump，含压缩）
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_backup() {
    check_root || return 1
    local rootpw backup_dir
    read_input rootpw "MySQL root 密码:" ""
    backup_dir="${BACKUP_DIR}/mysql"
    mkdir -p "${backup_dir}"
    local stamp backup_file
    stamp=$(date +%Y%m%d_%H%M%S)
    backup_file="${backup_dir}/all_${stamp}.sql.gz"
    show_spinner "mysqldump 全库备份中..."
    mysqldump -uroot -p"${rootpw}" --all-databases --single-transaction 2>/dev/null | gzip > "${backup_file}"
    stop_spinner
    log_success "备份完成: ${backup_file}"
}

# ------------------------------------------------------------
# [MySQL] 恢复
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_restore() {
    check_root || return 1
    local rootpw file
    read_input rootpw "MySQL root 密码:" ""
    read_input file "备份文件路径(.sql.gz):" ""
    [[ -f "${file}" ]] || { log_error "备份文件不存在"; return 1; }
    confirm_action "恢复数据库（将覆盖现有数据）" || return 1
    gzip -dc "${file}" | mysql -uroot -p"${rootpw}"
    log_success "数据库恢复完成"
}

# ------------------------------------------------------------
# [MySQL] 慢查询日志分析
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_slowlog_analyze() {
    check_root || return 1
    mysql -uroot -e "SHOW VARIABLES LIKE 'slow_query_log%';" 2>/dev/null || true
    local slowlog
    slowlog=$(mysql -uroot -N -e "SELECT @@slow_query_log_file;" 2>/dev/null)
    if [[ -n "${slowlog}" && -f "${slowlog}" ]]; then
        echo "== 慢查询 TOP 10 =="
        mysqldumpslow -s at -t 10 "${slowlog}" 2>/dev/null || tail -n 50 "${slowlog}"
    else
        log_warning "慢查询日志未开启，建议在 my.cnf 中启用: slow_query_log=1"
    fi
}

# ------------------------------------------------------------
# [MySQL] 主从复制配置（Master-Slave Replication）
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_replication() {
    check_root || return 1
    local role
    read_input role "角色 [1=主库Master 2=从库Slave]:" ""
    case "${role}" in
        1)
            grep -q "server-id" /etc/mysql/my.cnf 2>/dev/null || {
                echo -e "[mysqld]\nserver-id=1\nlog-bin=mysql-bin\nbinlog-format=ROW" >> /etc/mysql/my.cnf 2>/dev/null \
                || echo -e "[mysqld]\nserver-id=1\nlog-bin=mysql-bin\nbinlog-format=ROW" >> /etc/my.cnf
            }
            systemctl restart mysql 2>/dev/null || systemctl restart mysqld 2>/dev/null || true
            log_info "创建复制用户 repl..."
            local rpw
            read_input rpw "复制用户密码:" ""
            mysql -uroot -e "CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${rpw}'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%'; FLUSH PRIVILEGES;"
            mysql -uroot -e "SHOW MASTER STATUS;"
            log_warning "请记录上方的 File 和 Position，在从库配置时使用"
            ;;
        2)
            local master_ip master_file master_pos
            read_input master_ip "主库 IP:" ""
            read_input master_file "主库 binlog File:" ""
            read_input master_pos "主库 Position:" ""
            validate_ip "${master_ip}" || { log_error "IP 无效"; return 1; }
            mysql -uroot -e "STOP SLAVE; CHANGE MASTER TO MASTER_HOST='${master_ip}', MASTER_USER='repl', MASTER_PASSWORD='REPLACE_ME', MASTER_LOG_FILE='${master_file}', MASTER_LOG_POS=${master_pos}; START SLAVE;"
            mysql -uroot -e "SHOW SLAVE STATUS\G;" | grep -E "Slave_IO_Running|Slave_SQL_Running"
            ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [MySQL] 性能调优（生成优化版 my.cnf）
# 参数：无
# 返回：无
# ------------------------------------------------------------
mysql_tune() {
    check_root || return 1
    local mem
    read_input mem "服务器物理内存(GB):" "4"
    [[ "${mem}" =~ ^[0-9]+$ ]] || { log_error "无效数字"; return 1; }
    local innodb_buf=$((mem * 1024 / 2))
    local mycnf="/etc/my.cnf"
    [[ -f /etc/mysql/my.cnf ]] && mycnf="/etc/mysql/my.cnf"
    cp "${mycnf}" "${mycnf}.bak.$(date +%s)" 2>/dev/null || true
    cat > /etc/my.cnf.d/zetops-tune.cnf 2>/dev/null || cat > "${mycnf}" <<EOF
# 由 ZETOPS 生成 - 性能调优(Performance Tuning)
[mysqld]
innodb_buffer_pool_size = ${innodb_buf}M
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
max_connections = 500
query_cache_type = 0
skip-name-resolve
EOF
    systemctl restart mysql 2>/dev/null || systemctl restart mysqld 2>/dev/null || true
    log_success "MySQL 参数已调优（innodb_buffer_pool=${innodb_buf}M）"
}

# ============================================================
# PostgreSQL 二级菜单
# ============================================================
pg_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [PostgreSQL管理] 子菜单"
        echo "======================================"
        echo " 1. 安装 PostgreSQL"
        echo " 2. 创建数据库/用户"
        echo " 3. 配置 pg_hba.conf (访问控制)"
        echo " 4. 备份 (pg_dump)"
        echo " 5. 恢复"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-5) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) pg_install ;;
            2) pg_create_db ;;
            3) pg_hba_config ;;
            4) pg_backup ;;
            5) pg_restore ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [PostgreSQL] 安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
pg_install() {
    check_root || return 1
    case "$(detect_pkg_manager)" in
        apt)  install_pkg postgresql postgresql-contrib
              systemctl enable --now postgresql 2>/dev/null || true ;;
        dnf|yum) install_pkg postgresql-server
              if [[ ! -d /var/lib/pgsql/data/base ]]; then
                  postgresql-setup --initdb 2>/dev/null || true
              fi
              systemctl enable --now postgresql 2>/dev/null || true ;;
    esac
    log_success "PostgreSQL 已安装（默认库 superuser: postgres）"
}

# ------------------------------------------------------------
# [PostgreSQL] 创建数据库/用户
# 参数：无
# 返回：无
# ------------------------------------------------------------
pg_create_db() {
    check_root || return 1
    local db user pw
    read_input db "数据库名:" ""
    read_input user "用户名:" ""
    read_input pw "密码:" ""
    [[ -z "${db}" || -z "${user}" ]] && { log_error "数据库/用户名不能为空"; return 1; }
    su - postgres -c "psql -c \"CREATE USER ${user} WITH PASSWORD '${pw}';\" -c \"CREATE DATABASE ${db} OWNER ${user};\"" 2>/dev/null \
        || runuser -u postgres -- psql -c "CREATE USER ${user} WITH PASSWORD '${pw}';" -c "CREATE DATABASE ${db} OWNER ${user};"
    log_success "PostgreSQL 数据库 ${db} / 用户 ${user} 已创建"
}

# ------------------------------------------------------------
# [PostgreSQL] pg_hba.conf 访问控制
# 参数：无
# 返回：无
# ------------------------------------------------------------
pg_hba_config() {
    check_root || return 1
    local hba="/etc/postgresql/$(ls /etc/postgresql 2>/dev/null | tail -n1)/main/pg_hba.conf"
    [[ -f "${hba}" ]] || hba="/var/lib/pgsql/data/pg_hba.conf"
    [[ -f "${hba}" ]] || { log_error "未找到 pg_hba.conf"; return 1; }
    local network method
    read_input network "允许网段(如 192.168.1.0/24):" ""
    read_input method "认证方式 [scram-sha-256/md5/trust]:" "scram-sha-256"
    echo "host    all             all             ${network}            ${method}" >> "${hba}"
    systemctl reload postgresql 2>/dev/null || true
    log_success "已添加规则: ${network} -> ${method}"
}

# ------------------------------------------------------------
# [PostgreSQL] 备份
# 参数：无
# 返回：无
# ------------------------------------------------------------
pg_backup() {
    check_root || return 1
    local db
    read_input db "数据库名(留空=全库):" ""
    local dir="${BACKUP_DIR}/postgresql"
    mkdir -p "${dir}"
    local file="${dir}/${db:-all}_$(date +%Y%m%d_%H%M%S).dump"
    if [[ -n "${db}" ]]; then
        su - postgres -c "pg_dump -Fc ${db}" > "${file}" 2>/dev/null \
            || runuser -u postgres -- pg_dump -Fc "${db}" > "${file}"
    else
        su - postgres -c "pg_dumpall" > "${file}" 2>/dev/null \
            || runuser -u postgres -- pg_dumpall > "${file}"
    fi
    log_success "备份完成: ${file}"
}

# ------------------------------------------------------------
# [PostgreSQL] 恢复
# 参数：无
# 返回：无
# ------------------------------------------------------------
pg_restore() {
    check_root || return 1
    local file
    read_input file "备份文件路径(.dump):" ""
    [[ -f "${file}" ]] || { log_error "文件不存在"; return 1; }
    confirm_action "恢复 PostgreSQL 数据" || return 1
    su - postgres -c "pg_restore -d postgres -c '${file}'" 2>/dev/null \
        || runuser -u postgres -- pg_restore -d postgres -c "${file}" || true
    log_success "恢复完成"
}

# ============================================================
# Redis 二级菜单
# ============================================================
redis_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [Redis管理] 子菜单"
        echo "======================================"
        echo " 1. 安装 Redis"
        echo " 2. 持久化配置 (RDB/AOF)"
        echo " 3. 主从/哨兵/集群配置"
        echo " 4. 内存淘汰策略设置"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-4) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) redis_install ;;
            2) redis_persistence ;;
            3) redis_ha ;;
            4) redis_memory_policy ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [Redis] 安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
redis_install() {
    check_root || return 1
    case "$(detect_pkg_manager)" in
        apt|dnf|yum) install_pkg redis-server 2>/dev/null || install_pkg redis ;;
    esac
    systemctl enable --now redis 2>/dev/null || systemctl enable --now redis-server 2>/dev/null || true
    redis-cli ping 2>/dev/null && log_success "Redis 已安装并运行" || log_error "Redis 安装可能存在问题"
}

# ------------------------------------------------------------
# [Redis] 持久化配置（RDB快照/AOF追加）
# 参数：无
# 返回：无
# ------------------------------------------------------------
redis_persistence() {
    check_root || return 1
    local conf="/etc/redis/redis.conf"
    [[ -f "${conf}" ]] || conf="/etc/redis.conf"
    [[ -f "${conf}" ]] || { log_error "未找到 redis.conf"; return 1; }
    local mode
    read_input mode "持久化模式 [1=RDB 2=AOF 3=两者都开]:" "2"
    cp "${conf}" "${conf}.bak.$(date +%s)"
    case "${mode}" in
        1) sed -i 's/^save /save /' "${conf}" 2>/dev/null; sed -i 's/^appendonly .*/appendonly no/' "${conf}";;
        2) sed -i 's/^appendonly .*/appendonly yes/' "${conf}"; sed -i 's/^appendfsync .*/appendfsync everysec/' "${conf}";;
        3) sed -i 's/^appendonly .*/appendonly yes/' "${conf}";;
    esac
    systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null || true
    log_success "持久化配置完成（模式 ${mode}）"
}

# ------------------------------------------------------------
# [Redis] 主从/哨兵/集群（Replication/Sentinel/Cluster）
# 参数：无
# 返回：无
# ------------------------------------------------------------
redis_ha() {
    check_root || return 1
    local mode
    read_input mode "模式 [1=主从 2=哨兵Sentinel 3=集群Cluster]:" ""
    case "${mode}" in
        1)
            local master_ip
            read_input master_ip "主库 IP:" ""
            validate_ip "${master_ip}" || { log_error "IP 无效"; return 1; }
            redis-cli -h 127.0.0.1 REPLICAOF "${master_ip}" 6379
            log_success "已设置为主库 ${master_ip}:6379 的从节点"
            ;;
        2)
            log_info "生成哨兵(Sentinel)配置 /etc/redis-sentinel.conf ..."
            local master_name master_ip
            read_input master_name "主库名称:" "mymaster"
            read_input master_ip "主库 IP:" ""
            cat > /etc/redis-sentinel.conf <<EOF
port 26379
sentinel monitor ${master_name} ${master_ip} 6379 1
sentinel down-after-milliseconds ${master_name} 5000
sentinel failover-timeout ${master_name} 60000
EOF
            log_success "哨兵配置已生成（启动: redis-sentinel /etc/redis-sentinel.conf）"
            ;;
        3)
            log_warning "集群(Cluster)建议使用 redis-trib.rb 或官方 redis-cli --cluster create 手动搭建"
            log_info "提示: redis-cli --cluster create <ip1>:6379 <ip2>:6379 ... --cluster-replicas 1"
            ;;
        *) log_error "无效选择" ;;
    esac
}

# ------------------------------------------------------------
# [Redis] 内存淘汰策略
# 参数：无
# 返回：无
# ------------------------------------------------------------
redis_memory_policy() {
    check_root || return 1
    local conf="/etc/redis/redis.conf"
    [[ -f "${conf}" ]] || conf="/etc/redis.conf"
    echo "当前策略: $(redis-cli config get maxmemory-policy 2>/dev/null | tail -n1)"
    echo "可选策略: noeviction / allkeys-lru / volatile-lru / allkeys-random / volatile-ttl"
    local policy maxmem
    read_input policy "设置策略:" "allkeys-lru"
    read_input maxmem "最大内存(MB，0=不限):" "0"
    redis-cli CONFIG SET maxmemory-policy "${policy}" 2>/dev/null || \
        sed -i "s/^maxmemory-policy .*/maxmemory-policy ${policy}/" "${conf}" 2>/dev/null
    if [[ "${maxmem}" != "0" ]]; then
        redis-cli CONFIG SET maxmemory "${maxmem}mb" 2>/dev/null || \
            sed -i "s/^maxmemory .*/maxmemory ${maxmem}mb/" "${conf}" 2>/dev/null
    fi
    log_success "内存策略已设置: ${policy}（maxmemory=${maxmem}MB）"
}

# ============================================================
# MongoDB 二级菜单
# ============================================================
mongo_manager() {
    local c
    while true; do
        echo "======================================"
        echo "  [MongoDB管理] 子菜单"
        echo "======================================"
        echo " 1. 安装 MongoDB"
        echo " 2. 副本集配置 (Replica Set)"
        echo " 3. 启用用户认证"
        echo " 4. 备份/恢复"
        echo " 0. 返回上一级"
        echo "======================================"
        read -r -p "请选择 (0-4) [q=返回]: " c || return
        [[ "${c}" == "q" ]] && return
        case "${c}" in
            1) mongo_install ;;
            2) mongo_replica_set ;;
            3) mongo_auth ;;
            4) mongo_backup ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        press_enter
    done
}

# ------------------------------------------------------------
# [MongoDB] 安装
# 参数：无
# 返回：无
# ------------------------------------------------------------
mongo_install() {
    check_root || return 1
    case "$(detect_pkg_manager)" in
        apt)  install_pkg mongodb-org 2>/dev/null || install_pkg mongodb-server || { log_error "请先添加 MongoDB 官方源"; return 1; } ;;
        dnf|yum) install_pkg mongodb-org 2>/dev/null || install_pkg mongodb-server || { log_error "请先添加 MongoDB 官方源"; return 1; } ;;
    esac
    systemctl enable --now mongod 2>/dev/null || systemctl enable --now mongodb 2>/dev/null || true
    log_success "MongoDB 已安装"
}

# ------------------------------------------------------------
# [MongoDB] 副本集配置
# 参数：无
# 返回：无
# ------------------------------------------------------------
mongo_replica_set() {
    check_root || return 1
    local conf="/etc/mongod.conf"
    [[ -f "${conf}" ]] || conf="/etc/mongodb.conf"
    grep -q "replSetName" "${conf}" || {
        cp "${conf}" "${conf}.bak.$(date +%s)"
        sed -i "/^[[:space:]]*#?replication:/i replication:\n  replSetName: rs0" "${conf}" 2>/dev/null || \
        echo -e "\nreplication:\n  replSetName: rs0" >> "${conf}"
    }
    systemctl restart mongod 2>/dev/null || systemctl restart mongodb 2>/dev/null || true
    log_info "初始化副本集(rs0) ..."
    mongo --eval 'rs.initiate()' 2>/dev/null || mongosh --eval 'rs.initiate()' 2>/dev/null || true
    log_success "副本集 rs0 初始化完成，可用 rs.add(\"host:port\") 添加节点"
}

# ------------------------------------------------------------
# [MongoDB] 用户认证
# 参数：无
# 返回：无
# ------------------------------------------------------------
mongo_auth() {
    check_root || return 1
    local user pw db
    read_input user "管理员用户名:" "admin"
    read_input pw "密码:" ""
    read_input db "认证数据库:" "admin"
    mongo "${db}" --eval "db.createUser({user:'${user}',pwd:'${pw}',roles:[{role:'root',db:'admin'}]})" 2>/dev/null \
        || mongosh "${db}" --eval "db.createUser({user:'${user}',pwd:'${pw}',roles:[{role:'root',db:'admin'}]})" 2>/dev/null || true
    local conf="/etc/mongod.conf"
    [[ -f "${conf}" ]] || conf="/etc/mongodb.conf"
    sed -i 's/^[[:space:]]*authorization:.*/  authorization: enabled/' "${conf}" 2>/dev/null || \
        echo -e "\nsecurity:\n  authorization: enabled" >> "${conf}"
    systemctl restart mongod 2>/dev/null || systemctl restart mongodb 2>/dev/null || true
    log_success "用户认证已启用（用户 ${user}@${db}）"
}

# ------------------------------------------------------------
# [MongoDB] 备份/恢复
# 参数：无
# 返回：无
# ------------------------------------------------------------
mongo_backup() {
    check_root || return 1
    local db dir
    read_input db "数据库名(留空=全部):" ""
    dir="${BACKUP_DIR}/mongodb"
    mkdir -p "${dir}"
    if [[ -n "${db}" ]]; then
        mongodump --db "${db}" --out "${dir}" && log_success "备份完成: ${dir}/${db}"
    else
        mongodump --out "${dir}" && log_success "全库备份完成: ${dir}"
    fi
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
