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
| 12 自我更新 | 查看版本、检查更新、从 GitHub 拉取升级（支持国内加速镜像）、更新日志 |
| 13 AI 智能助手 | 双引擎：配置 OpenAI Key 后直达大模型对话（纯 Bash curl，兼容 OpenAI 官方/中转/DeepSeek/Qwen），支持「函数调用」——AI 可调用工具读取服务器真实状态（系统/磁盘/服务/端口/日志/Docker/MySQL）并申请执行命令（高危拒绝、写操作二次确认）；未配置回退纯内置规则引擎零依赖，11 大场景+一键全面体检，交互式修复+验证，多回退策略 |
| 14 安全基线加固 | CIS 风格基线扫描（空密码/UID=0/权限/SUID/防火墙/SSH/密码策略），逐项确认一键加固 |
| 15 硬件信息查看 | CPU/内存/磁盘(含smartctl健康度)/网卡/PCI/系统信息一键汇总，纯命令零依赖 |
| 16 操作审计日志 | 时间\|用户\|模块\|操作\|结果 审计记录（只追加），按用户/模块筛选、统计概览，全局 audit_log() 可被任何模块调用 |
| 17 站点与SSL管理 | 站点清单 sites.ini、增删改查、证书到期倒计时批量检测（<15天红色告警）、certbot/手动续期、HTTP健康检查、Nginx站点配置生成、404错误页设置 |
| 18 统一数据库管理 | MySQL/PostgreSQL/Redis/MongoDB 实例清单 databases.ini、多回退连接测试、统一备份恢复、慢查询、性能诊断 |
| 19 容灾回退链 | 回退链配置（primary→fallback_N）、链式降级执行（自动重试）、--dry-run 演练、Watchdog 自动切换、回退历史 |
| 20 文件管理器 | 纯Bash自绘TUI：鼠标点击/双击打开/滚轮、顶部工具栏一键操作、复制/剪切/粘贴剪贴板（Space多选）、目录导航/分页列表/目录树/查看/编辑/重命名/删除(危险保护)/chmod/tar zip压缩解压/搜索/书签 |
| 21 FTP服务管理 | vsftpd 安装/启停/状态总览、FTP用户增删/锁解锁、匿名开关、端口/限速/chroot/被动端口配置、语法校验+连接测试 |
| 22 配置文件中心 | Nginx/Apache/MySQL/Redis/SSH/系统常用配置自动探测、查看/编辑(自动备份)、备份恢复(一键回滚)、语法校验 |
| 23 运维任务编排 | 多步骤任务定义(.ztask)/交互创建/进度执行(3种失败策略)/执行历史，发布=git pull→构建→重启→健康检查 |
| 24 批量主机运维 | 主机清单 hosts.ini(分组)、并行SSH批量执行、scp批量上传/下载、连通性测试、结果✅/❌汇总 |
| 25 每日巡检报告 | 负载/磁盘/内存/失败服务/SSL证书到期一键采集，危险项自动标红，crontab定时巡检(每日08:00)，历史报告留存 |
| 26 计划任务管理 | crontab可视化：增删改查/暂停恢复/手动执行/清空，时间表达式自动翻译中文(每天08:00/每5分钟)，快捷模板 |

> 每个模块均遵循"先看后改"：管理类操作前可随时查看当前状态/规则/列表（如 ufw 查看已开放端口、备份列表、数据库用户等）。

## 快速开始 | Quick Start

```bash
# 一键安装（检测环境/安装依赖/创建软链接/初始化配置）
sudo bash install.sh

# 启动工具箱（默认 CLI，显示帮助与模块列表）
zetops

# 或直接在仓库目录运行
./zetops

# 进入交互式 TUI（蓝色主题，支持鼠标点击）
zetops --tui

# 非交互执行模块菜单项（适合脚本/定时任务）
zetops --run 15 2            # 模块15（硬件信息）第2项：CPU 信息
zetops --run ai_assistant 1  # 按模块短名执行

# 命令行备份文件（生成 .bak.<时间戳> 副本）
zetops --backup /etc/nginx/nginx.conf

# 其他
zetops --list        # 列出全部模块与插件
zetops --version     # 版本号
zetops --help        # 帮助
```

> 默认 CLI 协议：无参数显示帮助与模块列表；`--tui` 进入交互界面（键盘输入或鼠标点击均可）。

## 自动化测试 | Tests

```bash
bash tests/run_tests.sh
```

覆盖：全部脚本语法检查、模块/插件接口完整性、颜色变量、版本一致性、conf 模板解析、AI 工具调用解析/意图识别/命令安全层、菜单渲染与鼠标映射、CLI 协议、备份单元测试。

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
├── modules/           # 26 个功能模块（统一接口，可单独执行）
├── plugins/           # 插件目录（自动扫描动态加载）
├── tests/             # 自动化测试套件（run_tests.sh）
├── config/            # 配置模板（zetops.conf / api.conf）
└── docs/              # 文档（INSTALL/MODULES/CHANGELOG）
```

## 文档 | Documentation

- [安装指南](docs/INSTALL.md)
- [模块开发指南](docs/MODULES.md)
- [更新日志](docs/CHANGELOG.md)

## 许可证 | License

[MIT](LICENSE)
