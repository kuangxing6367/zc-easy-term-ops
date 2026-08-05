# zc-easy-term-ops - 交互式Linux运维全能工具箱 | Interactive Linux Ops Toolkit

**关键词 (Keywords):** Linux运维, 一键部署, Nginx, Docker, MySQL, iptables, 防火墙管理, 代理设置, Python环境, 数据库备份, SSH安全加固, Fail2ban, 容器管理, 监控告警, 运维工具, Shell脚本, 自动化运维

一个**模块化、可维护、可扩展**的交互式 Linux 运维工具箱（ZETOPS）。通过多级菜单实现系统初始化、软件源切换、Web 服务、数据库、容器、防火墙、网络诊断、监控、备份、密码管理、CI/CD 等常用运维场景的一键操作，**能诊断、能修复、可二次开发**。

An interactive, modular Linux operations toolbox (ZETOPS). Provides multi-level menus covering system init, mirror switching, web servers, databases, containers, firewall, network diagnosis, monitoring, backup, password management and CI/CD — diagnosis-first, fix-ready and easy to extend.

---

## 功能总览 | Features

| 模块 Module | 功能 Features |
|---|---|
| 01 系统初始化 | 系统更新、chrony 时间同步、主机名、Swap、ulimit、SELinux/AppArmor、内核调优(sysctl) |
| 02 软件包管理 | 镜像源切换(清华/阿里/中科大)、常用工具、批量安装/卸载、搜索、第三方源(EPEL/PPA/Docker) |
| 03 Web 服务器 | Nginx 编译安装(SSL/Stream)、虚拟主机、Let's Encrypt、负载均衡、限流、日志分析；Apache；Tomcat |
| 04 数据库管理 | MySQL/MariaDB、PostgreSQL、Redis、MongoDB 安装/建库/备份恢复/主从/性能调优 |
| 05 容器管理 | Docker/Podman、镜像(image)/容器/网络/数据卷、Compose 一键部署、Harbor 私有仓库 |
| 06 防火墙安全 | iptables/ufw/firewalld 规则、NAT 转发、Fail2ban 防暴力破解、SSH 安全加固、端口扫描 |
| 07 网络配置 | 网卡(静态IP/DHCP/MTU/VLAN/Bond，单网卡安全切换)、DNS、路由备份回滚、网络诊断、VPN、代理 |
| 08 监控日志 | 资源监控、CPU 高负载自动诊断(ps/strace/jstack)、进程/磁盘/LVM、权限诊断、journalctl/logrotate |
| 09 备份灾备 | tar/rsync 备份、增量备份、远程同步(免密)、数据库备份脚本、定时任务、LVM 快照 |
| 10 开发部署 | pyenv/nvm/OpenJDK/Go/Rust、Git、Jenkins/SonarQube、Webhook、应用一键部署 |
| 11 密码权限 | MySQL/PostgreSQL/Redis 密码重置、Linux 密码、sudo 恢复、SSH 密钥生成分发、密码策略检查 |

## 快速开始 | Quick Start

```bash
# 一键安装（检测环境/安装依赖/创建软链接/初始化配置）
sudo bash install.sh

# 启动工具箱
zetops

# 或直接在仓库目录运行
./zetops
```

## 环境要求 | Requirements

- Linux 发行版：Debian/Ubuntu/CentOS/RHEL/Rocky/Alma/Fedora/openSUSE 等
- Bash 4+，建议 root 权限运行
- 外部数据（镜像源/NTP/Docker脚本）可配置 API 节点：`~/.zetops/api.conf`

## 目录结构 | Structure

```
zc-easy-term-ops/
├── install.sh         # 一键安装（入口）
├── zetops             # 主程序入口
├── core/              # 核心框架（main/menu/logger/utils/config）
├── modules/           # 11 个功能模块（统一接口，可单独执行）
├── plugins/           # 插件目录（自动扫描动态加载）
├── config/            # 配置模板（zetops.conf / api.conf）
└── docs/              # 文档（INSTALL/MODULES/CHANGELOG）
```

## 文档 | Documentation

- [安装指南](docs/INSTALL.md)
- [模块开发指南](docs/MODULES.md)
- [更新日志](docs/CHANGELOG.md)

## 许可证 | License

[MIT](LICENSE)
