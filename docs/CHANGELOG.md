# 更新日志 | Changelog

本文件记录 zc-easy-term-ops（ZETOPS）的版本更新历史。

## [1.0.0] - 2026-08-05

### 新增

- **核心框架**
  - `core/main.sh`：入口启动、依赖检查（check_deps）、单实例锁（check_lock）、Ctrl+C 安全退出、模块/插件自动扫描加载
  - `core/menu.sh`：主/子菜单渲染引擎、用户输入处理、插件动态加载
  - `core/logger.sh`：彩色日志（INFO蓝/SUCCESS绿/WARNING黄/ERROR红/DEBUG灰）、统一格式落盘
  - `core/utils.sh`：命令检查、发行版/架构/包管理器探测、IP/端口校验、危险操作确认、旋转动画
  - `core/config.sh`：配置文件加载、API 节点接口（api_fetch）
- **11 个功能模块**
  - `01_system_init`：系统更新、chrony 时间同步、主机名、Swap、ulimit、SELinux/AppArmor、内核调优
  - `02_package_manager`：镜像源切换（API 获取）、常用工具、批量安装/卸载、第三方源
  - `03_web_server`：Nginx 编译安装（SSL/Stream）、虚拟主机、Let's Encrypt、负载均衡、限流、日志分析；Apache；Tomcat
  - `04_database`：MySQL/PostgreSQL/Redis/MongoDB 安装、建库授权、备份恢复、主从复制、性能调优
  - `05_container`：Docker（API 获取安装脚本）、镜像/容器/网络/数据卷、Compose、Podman、Harbor
  - `06_firewall`：iptables/ufw/firewalld、NAT 转发、Fail2ban、SSH 安全加固、端口扫描
  - `07_network`：单网卡配置（禁用全局重启）、DNS、路由备份回滚、网络诊断、WireGuard/OpenVPN、代理
  - `08_monitor`：资源监控、CPU 高负载诊断（ps/strace/jstack）、进程/磁盘/LVM、权限诊断、日志管理
  - `09_backup`：tar/rsync 备份、增量备份、远程同步、数据库备份脚本、定时任务、LVM 快照
  - `10_devops`：pyenv/nvm/OpenJDK/Go/Rust、Git、Jenkins/SonarQube、Webhook、应用一键部署
  - `11_password_manager`：MySQL/PostgreSQL/Redis 密码重置、Linux 密码、sudo 恢复、SSH 密钥分发、密码策略检查
- **扩展机制**：插件自动扫描（`plugins/`）、用户配置文件覆盖默认参数、API 节点动态数据源
- **安装与文档**：install.sh 一键安装、README（中英双语 + SEO）、INSTALL/MODULES/CHANGELOG 文档、MIT 许可证

### 变更

- 首版发布，无历史变更。
