# zc-easy-term-ops (ZETOPS) - 交互式 Linux 运维全能工具箱

**关键词 (Keywords):** Linux运维, 纯Bash零依赖, TUI交互, 一键部署, Nginx, Docker, MySQL, iptables, 防火墙, 数据库备份, SSH安全加固, 容器管理, 监控告警, AI智能运维, 自动化运维

> 一个**纯 Bash 实现、零外部依赖**的交互式 Linux 运维工具箱（ZETOPS）。系统初始化、软件源、Web 服务、数据库、容器、防火墙、网络诊断、监控备份、密码权限、AI 智能运维等 26+ 场景**一键直达**，**能诊断、能修复、可二次开发**。

---

## 主要特点 | Highlights

### 1. 纯 Bash 零依赖
整个工具箱由**标准 Shell 脚本**写成，不依赖 Python / Node / ncurses 等任何第三方运行时，只要有 `bash + curl + coreutils` 就能跑——装完即用，绝无依赖地狱。内置的 TUI 编辑器、菜单渲染、JSON 解析全部手写实现。

### 2. 全 TUI 交互界面（真终端体验）
多级菜单采用**真 TUI 排版**：主菜单 / 26 个子菜单 / 文件管理器 / 文本编辑器统一交互，支持——
- **鼠标点击**：点击选中（高亮），再次点击同一项确认进入（两段式防误触）
- **方向键导航**：↑↓←→ 移动选中，回车确认
- **数字键**：直接输入编号回车
- **滚轮翻页**：主页菜单自动分页，滚轮 / PgUp / PgDn 翻页
- 渲染内容拼成**超大字符串一次性输出**，避免鼠标事件堆积错位

### 3. 内置 TUI 文本编辑器（不依赖 nano/vim）
文件管理器直接打开**内置编辑器**（`core/editor.sh`）：方向键 / Home / End / PgUp / PgDn 移动、退格 / Delete / 回车拆行、**完整支持中文多字节字符**、鼠标点击定位光标、行号 + 状态栏 + 底部快捷键栏（nano 风格）、`Alt+U` 撤销 / `Alt+E` 重做、`Ctrl+S` 保存 / `Ctrl+Q` 退出（未保存二次确认）、只读保护。

### 4. AI 智能运维助手
内置大模型对话（OpenAI 兼容接口），**函数调用 (Function Calling)** 让 AI 读取服务器真实状态（系统信息 / 磁盘 / 服务 / 端口 / 日志 / Docker / MySQL），给出诊断与修复建议；写操作由用户二次确认，高危命令内置拦截。

### 5. 双模式：TUI 交互 + CLI 直达
每个功能既能进界面交互操作，也能**一条命令非交互直达**（适合脚本 / 定时任务）：
```bash
zetops                  # 进入交互式 TUI
zetops --run 13 1       # 非交互执行模块13第1项
zetops --run ai_assistant 1   # 按模块短名执行
zetops --list / --help / --version / --backup
```

### 6. 安全加固内置
命令白名单 + 高危命令拦截（`rm -rf /`、`dd`、`mkfs`、`iptables -F` 等自动阻断）、写操作二次确认、只读命令免确认、单实例 PID 锁、审计日志。

### 7. 模块化可扩展
`modules/` 每模块 = 4 个标准函数（`module_name/description/menu/execute`），新增运维场景只需复制一个模块模板；`plugins/` 支持插件；自动化测试套件 **170+ 断言**（语法 / 接口 / 版本一致性 / 菜单渲染 / 鼠标映射 / 方向键 / 编辑器逻辑 / 安全拦截 / CLI 协议）。

---

## 功能模块一览 | Modules (26+)

| 分类 | 模块 |
|---|---|
| 系统 | 系统初始化优化 / 软件包仓库 / 硬件信息 / 密码与权限 / 自我更新 |
| 服务 | Web服务器与反代 / 站点与SSL / 数据库管理 / 统一数据库管理 / FTP服务 |
| 网络 | 防火墙加固 / 网络配置诊断 / 容器管理 |
| 运维 | 监控日志 / 备份灾备 / 容灾回退链 / 每日巡检报告 / 批量主机运维 / 任务编排 / 计划任务 |
| 开发 | 开发环境部署 / 配置文件中心 / 操作审计日志 |
| 智能 | **AI 智能运维助手** / 安全基线加固 |
| 辅助 | 文件管理器（内置编辑器） / 配置中心 |

---

## 一键安装 | Quick Install

```bash
# 方式一：在线安装（推荐）
curl -fsSL https://raw.githubusercontent.com/kuangxing6367/zc-easy-term-ops/main/install-online.sh | sudo bash

# 国内网络慢？用加速镜像
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/kuangxing6367/zc-easy-term-ops/main/install-online.sh | sudo bash

# 方式二：克隆仓库后执行
git clone https://github.com/kuangxing6367/zc-easy-term-ops.git
cd zc-easy-term-ops
sudo bash install.sh
```

安装完成后输入 `zetops` 即可启动。

## 使用方式 | Usage

```bash
zetops                # 交互式 TUI（方向键/鼠标/数字 三选一导航）
zetops --run 模块 选项  # 非交互 CLI 直达（模块支持序号或短名）
zetops --list          # 列出全部模块
zetops --version       # 版本号
zetops --help          # 帮助
```

**界面交互约定**：`↑↓←→` 或鼠标点击 = 选中（高亮）；回车 / 再次点击同一项 = 确认进入；`q` = 退出；主菜单滚轮 / `PgUp` / `PgDn` = 翻页。

## 目录结构 | Structure

```
zc-easy-term-ops/
├── install.sh         # 一键安装脚本
├── zetops             # 主程序入口
├── core/              # 核心框架（menu 菜单TUI / editor 内置编辑器 / utils / config...）
├── modules/           # 26+ 功能模块（01-26）
├── plugins/           # 插件目录
├── tests/             # 自动化测试套件（170+ 断言）
├── config/            # 配置模板
└── docs/              # 文档
```

## 文档 | Documentation

- [安装指南](docs/INSTALL.md)
- [模块开发指南](docs/MODULES.md)
- [更新日志](docs/CHANGELOG.md)

## 许可证 | License

[MIT](LICENSE)
