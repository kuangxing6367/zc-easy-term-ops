# 更新日志 | Changelog

本文件记录 zc-easy-term-ops（ZETOPS）的版本更新历史。

## [1.5.1] - 2026-08-31

### 修复（两段式点击在 SGR 终端退化）

- **修复"点一次就进入"（core/menu.sh）**
  - 根因：SGR 鼠标协议的一次点击会发送「按下(`ESC[<b;x;yM`)」和「释放(`ESC[<b;x;y m`)」两个事件，二者按钮号相同(0)。原实现未区分按下/释放，把一次点击的"按下+释放"误判成两次点击 → 第一次选中、释放被当作第二次点击直接确认，表现为"点一次就进"
  - 修复：解析时保留 `M`/`m` 区分，释放事件按钮号置 3（与 X10 释放一致），两段式点击逻辑按 `btn==0` 只响应按下 → 现在**一次点击仅选中高亮，需再次点击同一项或回车才确认进入**
  - 键盘数字输入仍可直接进入（不受影响）
- **自动化测试（tests/run_tests.sh）**：新增「SGR 按下/释放事件流两段式」「仅一次点击不进入」「`_tui_read_event` SGR/X10 解析」断言（89/89 通过）

## [1.5.0] - 2026-08-31

### 新增 / 改进（真 TUI 交互：两段式点击 + 网页化菜单 + 文件管理器布局修复）

- **鼠标两段式点击（core/menu.sh）**
  - 点击菜单项 = 选中并整行反色高亮（`▸` 标记），再次点击同一项 = 确认进入
  - 支持点击空白取消选中；回车可直接确认当前高亮项；键盘输入数字仍可直接进入（兼容旧习惯）
  - 新增 `_tui_redraw_menu` 按当前菜单上下文（主/子/插件）重绘，选中态只影响当前交互、不污染父级
  - 子菜单/插件菜单同步支持两段式点击与高亮
- **菜单界面网页/TUI 化（core/menu.sh）**
  - 操作提示行改为「点击选中，再次点击确认」交互引导；分隔线、双列网格、系统概览保持统一蓝色主题
- **文件管理器布局修复（modules/20_file_manager.sh）**
  - 终端行列改从 `/dev/tty` 读取（`stty size` 从 stdin 读在嵌套/重定向下会拿错尺寸，导致列表窗口高度与鼠标坐标错位）
  - 列表从第 4 行渲染，消除标题/表头与列表间的空白缝隙，布局更紧凑
  - 新增 `fm_str_w`/`fm_str_clip` 纯 Bash UTF-8 解码：中文宽度按 2 列、截断保持字符边界，**不再依赖 locale**（`LC_ALL=C` 下原实现会把中文按 3 倍宽度算，导致工具栏点击区域与列表布局全部错位）
  - SGR 鼠标坐标解析防御性整数化：剥离非数字字节，尾随分号/异常字符不再产生 `10;` 之类非法坐标
  - 表头与列表列宽动态对齐（替代写死宽度）
- **自动化测试扩展（tests/run_tests.sh）**：新增「鼠标两段式点击」与「文件管理器宽度/SGR 坐标（C locale）」断言

## [1.4.1] - 2026-08-31

### 修复（菜单交互 / 软件源检测 / AI 工具模式）

- **菜单交互修复（core/menu.sh / core/main.sh / core/utils.sh）**
  - 鼠标点击进入对应功能（点击仅触发一次，不再重复累加输入）
  - 菜单操作后正确 `clear` 清屏，避免图形错乱
  - 修复提示自动刷新导致「请输入操作编号」重复堆积
- **软件源查看修复（modules/02）**
  - `repo_view` 兼容 `/etc/apt/sources.list.d/` 下的 `.sources`（deb822 新格式，Debian 12+/阿里云默认）与 `.list`
  - 主文件 `/etc/apt/sources.list` 缺失时给出正常提示，不再误报「文件不存在」；增加有效源条目汇总
- **AI 工具模式回复提取修复（modules/13）**
  - 精确识别 `"tool_calls":[...]` 数组，最终文本回复中的 `"tool_calls":null` 不再被误判为工具调用
  - 工具轮数用尽或接口报错时，自动补发一次纯文本请求兜底，确保模型回复可提取
- **附带修正（modules/03 / modules/21 等）**：细节稳定性修复

## [1.4.0] - 2026-08-20

### 新增（备份 / 自动化验证 / 双协议 CLI-TUI）

- **统一备份入口（core/utils.sh）**：新增 `backup_file`，安全修改配置前自动生成 `${文件}.bak.<时间戳>` 副本，返回备份路径
- **默认 CLI + 可切换 TUI 双协议（core/main.sh）**
  - 默认 CLI：`zetops` 无参数显示帮助与模块列表
  - `-l, --list` 列出全部模块（序号/短名/名称）与插件
  - `-r, --run <模块|短名> <选项号>` 非交互执行模块菜单项（适合脚本/定时任务，stdin 接 /dev/null）
  - `-b, --backup <路径>` 命令行直接备份文件
  - `-v/--version`、`-h/--help`；`-t, --tui` 进入交互界面
- **蓝色主题纯字符 TUI + 鼠标点击（core/menu.sh）**
  - 主题全面切换为青色/蓝色系（Logo 副标题、分隔线、系统概览、菜单提示）
  - X10 鼠标协议（`\e[?1000h\e[?1002h`）：主菜单双列网格、子菜单、插件菜单均可点击选择
  - `_tui_capture` 渲染时记录「屏幕行号 → 选项号」映射（自动剥离 ANSI 转义序列），键盘输入与鼠标点击并存
  - 退出/异常路径自动关闭鼠标捕获
- **自动化测试套件（tests/run_tests.sh）**：一键运行语法检查、模块/插件接口完整性、颜色变量、版本一致性、conf 模板解析、AI 工具解析/意图识别/命令安全层、菜单渲染与鼠标映射、CLI 协议、备份单元测试，全部失败不中断并汇总
- **AI 功能调用可靠性修复（模块 13）**
  - 工具参数提取按 OpenAI 响应转义层级处理（`\\\"` / `\"` / 裸数字），带引号命令可正确还原
  - 意图识别顺序修复：`diag_all` 最先，`web_error` 先于 `nginx_conf`，`mysql_issue`/`port_blocked` 先于 `network_issue`
  - 命令安全层强化：只读命令白名单（含 `-t` 检查与输出重定向识别）直接执行，管道命令一律二次确认

## [1.3.5] - 2026-08-19

### 增强（AI 智能运维助手 + 界面美化 + 数据库可靠性）

- **AI 大模型接入「函数调用」(Function Calling，模块 13)**：纯 Bash + curl 实现 OpenAI 工具协议
  - 8 个可调用工具：`get_system_info` / `get_disk_usage` / `get_service_status` / `get_port_status` / `get_logs` / `get_docker_status` / `get_mysql_status` / `run_command`
  - AI 可读取服务器真实状态（非空想），再基于结果诊断与修复；最多 4 轮工具循环
  - `run_command` 工具：高危命令（rm -rf /、格式化、清空防火墙等）自动拒绝，其余命令由用户在终端二次确认
  - 非流式多轮（工具回合）+ 最终文本输出；未开启时保持原流式对话，互不影响
  - 配置项 `OPENAI_TOOLS`（默认 on），AI 配置菜单新增选项 7 一键开关
- **MySQL 性能调优可靠性修复（模块 04）**
  - 修复覆盖主配置 `my.cnf` 的隐患：优先写入 drop-in 配置（`/etc/mysql/conf.d/` 等自动探测），不再整文件覆盖
  - 修复 MySQL 8.0+ 因写入 `query_cache_type=0` 导致启动失败的问题（8.x/9.x 自动剔除该参数）
  - `innodb_flush_method=O_DIRECT` 按数据目录文件系统判断（overlayfs/tmpfs 自动省略）
  - innodb_buffer_pool 钳制为实际内存 70%（≥128M），防止小内存机器 OOM
  - `mysqld --validate-config` 校验通过后才落盘；重启失败自动回滚配置并恢复服务；重启后验证服务状态
- **界面美化（core/menu.sh）**
  - 主菜单全新华丽渲染：彩色 ASCII Logo、系统概览（OS/Kernel/CPU/内存/磁盘/主机/IP/时间）、模块双列网格、彩色分隔线、彩色输入提示
  - 子菜单/插件菜单增加彩色标题栏
- **功能补全（模块 13）**
  - 新增「一键全面体检」：负载/磁盘/内存/失败服务/Web/Docker/数据库 7 项快速只读诊断（子菜单 4 或对话输入"体检"）
  - 新增诊断场景：Nginx/Apache 配置检查（`nginx -t` 语法检查）、日志分析（journalctl/常见日志文件）
  - 对话历史支持 `diag`/`体检` 命令

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
