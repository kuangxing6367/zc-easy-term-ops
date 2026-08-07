# 更新日志 | Changelog

本文件记录 zc-easy-term-ops（ZETOPS）的版本更新历史。

## [1.3.4] - 2026-08-07

### 增强（自我更新模块 12）

- **更新检查升级为"版本号+提交 SHA"双维度**：调用 GitHub API 获取分支最新提交 SHA，本地记录上次更新到的 SHA（`~/.zetops/.last_commit`）。版本号未变但代码有更新（纯 bugfix 不涨版本号）时也能识别并提示更新
- **修复文件管理器 `rest: unbound variable`（模块 20）**：SGR 鼠标解析中 `local` 同处声明并在本行引用 `rest`，`set -u` 下展开顺序导致崩溃；拆行赋值
- **AI 配置输入支持 readline 行编辑（模块 13）**：方向键/退格可编辑，非终端自动回退
- **新增一键在线安装 `install-online.sh`**：支持 GitHub 加速镜像下载并自动调用 install.sh
- **AI 助手对话崩溃修复（COLOR_CYAN 未定义）**
- **自更新远程版本解析兼容 `${VAR:-默认}` 写法**；config.sh 的 `ZETOPS_VERSION` 改为纯字面量

## [1.3.3] - 2026-08-07

### 修复

- **AI 助手对话崩溃（模块 13）**：`ai_llm_chat_once` 引用了未定义的 `COLOR_CYAN`，在 `set -u` 下报 `COLOR_CYAN: unbound variable` 导致对话中断；改用 `COLOR_BLUE`
- **远程版本解析（模块 12）**：`self_fetch_remote_version` 只匹配 `ZETOPS_VERSION="x.x.x"` 无法解析 `ZETOPS_VERSION="${ZETOPS_VERSION:-x.x.x}"` 的默认值写法（此前远程版本号被显示为字面量 `${ZETOPS_VERSION:-1.3.2}`）；改为提取三位版本号，兼容两种写法
- **版本号改为纯字面量**：`core/config.sh` 中 `ZETOPS_VERSION` 由 `${ZETOPS_VERSION:-1.3.3}` 改为 `"1.3.3"`，避免自更新检查误解析

## [1.3.2] - 2026-08-07

### 增强（AI 智能运维助手 + 文件管理器 TUI，模块 13/20）

- **OpenAI 交互式配置（模块 13）**：子菜单 3 可直接填写 API Key/接口地址/模型/超时、连接测试、一键停用，写入 `~/.zetops/zetops.conf` 即时生效无需重启
- **纯 Bash 自绘 TUI 文件管理器（模块 20，v2.0.0）**
  - 全屏界面：备用屏幕缓冲、隐藏光标、动态终端行列自适应
  - 鼠标支持：SGR 鼠标模式（x10 兼容回退），点击选中/双击打开目录、滚轮上下移动、点击顶部工具栏按钮
  - 顶部工具栏：返回/上级/刷新/新建/搜索/书签/目录树/复制/剪切/粘贴/改名/删除/退出
  - 文件剪贴板 `~/.zetops/fm_clipboard`：复制(c)/剪切(x)/粘贴(v)，Space 多选标记，批量删除(d)带危险保护
  - 键盘全套快捷键：↑↓ Enter ← Space r f a b t m n e o q 等，翻页 PgUp/PgDn、Home/End
  - 保留原全部文件操作（查看/编辑/压缩解压/权限/书签），零外部依赖
- **修正**：`fm_refresh_list` 等函数在 `set -e` 下返回非零导致循环中止的问题；非 TTY 环境 stty 失败导致崩溃的问题；鼠标释放事件被误判为点击的问题
- **版本号统一**：工具箱整体版本号对齐为 1.3.2（config.sh / 主菜单 / 配置示例 / 更新日志）

## [1.3.1] - 2026-08-07

### 增强（AI 智能运维助手）

- **OpenAI / 大模型对话接入（纯 Bash，零 Python/Node 依赖）**
  - 新增配置项：`~/.zetops/zetops.conf` 中 `OPENAI_API_KEY` / `OPENAI_BASE_URL` / `OPENAI_MODEL` / `OPENAI_TIMEOUT`
  - 配置 Key 后 AI 对话自动切换为大模型模式，流式输出（curl + SSE 解析，含转义引号/换行还原）
  - 未配置 Key 自动回退内置规则引擎，互不影响
  - 兼容任何 OpenAI Chat 格式接口：官方 / 国内中转 / DeepSeek / Qwen 等
  - 子菜单新增"OpenAI 配置状态/连接测试"，API Key 脱敏显示
  - 多轮上下文（保留最近 8 轮），`re` 命令可随时重置上下文

## [1.3.0] - 2026-08-06

### 新增（模块 23~26，共 4 个新模块）

- **运维任务编排（23_task_pipeline.sh）**
  - 多步骤任务定义 `~/.zetops/tasks/*.ztask`（纯文本：`task_desc=` / `step:名称 命令`）
  - 交互式创建/模板创建/编辑/删除，进度显示（spinner + 步骤计数）
  - 3 种失败策略：失败即中止 / 失败询问 / 忽略失败全部执行
  - 执行历史记录（成功/失败统计），典型场景：发布 = git pull → 构建 → 重启 → 健康检查
- **批量主机运维（24_batch_ops.sh）**
  - 主机清单 `~/.zetops/hosts.ini`：`[分组]` + `IP user= port=`（兼容 ansible_user/ansible_port）
  - 批量执行命令（并行 SSH 后台进程 + 每台独立输出 + ✅/❌ 汇总统计）
  - 批量上传/下载文件（scp，支持端口）、连通性测试（BatchMode 免交互）
  - 选择范围：全部主机 / 分组 / 单台 IP
- **每日巡检报告（25_report_daily.sh）**
  - 一键采集：系统负载/CPU 核数/内存/磁盘/失败服务/监听端口/SSL 证书到期
  - 报告保存 `~/.zetops/reports/daily-YYYY-MM-DD.txt`，历史不覆盖
  - 危险项自动标红：磁盘>80% / 负载>核数 / 可用内存<10% / 证书<30天 / 失败服务
  - crontab 定时巡检（默认每日 08:00，可改时间），命令行 `cron_run` 可直接调度
- **计划任务管理（26_cron_manager.sh）**
  - crontab 可视化：任务列表自动翻译为中文时间说明（每天 08:00 / 每5分钟 / 每周一 09:00 ...）
  - 增删改查、暂停/恢复（注释标记，不丢失原配置）、手动执行一次、清空全部
  - 快捷模板（每分钟/每5分钟/每小时/每天/每周/每月/开机启动）+ 时间字段合法性校验
  - 临时文件编辑后统一写回，保留用户原有环境变量与注释

### 新增（模块增强）

- **容器管理（05_container.sh）**：Docker 镜像加速器一键配置（国内加速源，写 daemon.json + 重启）；容器"进入 shell"（exec -it bash/sh 自动回退）；"查看 IP/端口"（docker inspect）；"一键清理"（prune 前先展示磁盘占用）

### 变更

- 版本号升级至 1.3.0

## [1.2.0] - 2026-08-06

### 新增（模块 13~22，共 10 个新模块）

- **AI 智能运维助手（13_ai_assistant.sh）**
  - 纯 Bash 规则引擎，零外部依赖（无 Python/Node/AI API）
  - 自然语言输入 → 意图识别 → 自动诊断 → 交互确认 → 执行修复 → 验证
  - 9 大场景：Web 502/503、服务宕机、磁盘满、CPU 高负载、内存 OOM、网络不通、Docker 容器、MySQL 连接、端口不通
  - 多轮对话上下文、危险命令检测、bash -c 隔离执行、超时保护、docker→podman / mysql→mariadb 多回退
- **安全基线加固（14_security_harden.sh）**
  - CIS 风格基线扫描：空密码/UID=0/文件权限/世界可写/SUID/防火墙/SSH/密码策略/IP转发/开放端口
  - 一键交互式加固，危险项二次确认，操作写审计
- **硬件信息查看（15_hardware_info.sh）**：CPU/内存/磁盘(含 smartctl 健康度)/网卡/PCI/系统一键汇总，纯命令零依赖
- **操作审计日志（16_audit_log.sh）**：`时间|用户|模块|操作|结果` 只追加记录，按用户/模块筛选、统计概览，全局 `audit_log()` 可被任何模块调用
- **站点与 SSL 管理（17_site_manager.sh）**
  - 站点清单 sites.ini 增删改查、证书到期倒计时批量检测、certbot/手动续期、HTTP 健康检查
  - Nginx 站点配置自动生成（反代/静态/HTTPS/健康路径/404 规则）、自定义 404 错误页
- **统一数据库管理（18_db_unified.sh）**：MySQL/PostgreSQL/Redis/MongoDB 实例清单、多回退连接测试、统一备份恢复、慢查询、性能诊断
- **容灾回退链（19_fallback.sh）**：primary→fallback_N 链式降级执行（自动重试）、--dry-run 演练、Watchdog 自动故障切换、回退历史
- **文件管理器（20_file_manager.sh）**：类 Windows 资源管理器——目录导航/分页列表/目录树(t)/查看/编辑/复制/移动/重命名/删除(危险保护)/chmod/tar zip 压缩解压/搜索/书签
- **FTP 服务管理（21_ftp_manager.sh）**：vsftpd 安装/启停/状态总览、用户增删锁解锁、匿名开关、端口/限速/chroot/被动端口配置、语法校验+连接测试
- **配置文件中心（22_config_center.sh）**：15+ 常用配置自动探测、查看/编辑(自动备份)、备份一键回滚、语法校验（nginx -t/sshd -t 等）

### 新增（核心库）

- `core/detect_env.sh`：容器/LXC/WSL/虚拟化/环境类型检测
- `core/utils.sh`：新增 `try()`（失败告警继续）/`require()`（失败终止）统一错误处理
- `core/logger.sh`：日志轮转（超 10MB 自动归档，保留 5 份）
- `install.sh`：新增 `--uninstall` 交互式卸载（软链接/安装目录/配置/日志逐项询问）

### 修复

- 修复 INI 解析函数 `$1 == k "="` 优先级错误导致配置读取永远为空（影响 17/18/19 模块）
- 修复回退链排序错误（fallback_1 被字母序排到 primary 前）
- 修复 `set -e` 下函数末行短路判断导致模块中途退出
- 修复 clear 在非 tty 环境导致文件管理器退出

## [1.1.0] - 2026-08-06

### 变更

- 模块统一重写"先看后改"：管理类操作前先展示当前状态/规则/列表（ufw 已开放端口、备份列表、数据库用户等）
- 新增自我更新模块（12_self_update.sh）：版本查看、远程更新检查（GitHub raw 对比版本号）、git/tarball 两种更新方式（含备份回滚）、GitHub 加速镜像配置
- 各模块补齐"查看"类功能入口

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
