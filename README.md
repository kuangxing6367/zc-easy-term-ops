# zc-easy-term-ops - 交互式Linux运维全能工具箱 | Interactive Linux Ops Toolkit

**关键词 (Keywords):** Linux运维, 一键部署, Nginx, Docker, MySQL, iptables, 防火墙管理, 代理设置, Python环境, 数据库备份, SSH安全加固, Fail2ban, 容器管理, 监控告警, 运维工具, Shell脚本, 自动化运维

一个**模块化、可维护、可扩展**的交互式 Linux 运维工具箱（ZETOPS）。通过多级菜单实现系统初始化、软件源切换、Web 服务、数据库、容器、防火墙、网络诊断、监控、备份、密码管理、CI/CD 等常用运维场景的一键操作，**能诊断、能修复、可二次开发**。

---

## 一键安装 | Quick Install

```bash
# 方式一：直接运行（推荐）
sudo bash <(curl -sL https://raw.githubusercontent.com/kuangxing6367/zc-easy-term-ops/main/install.sh)

# 方式二：克隆后运行
git clone https://github.com/kuangxing6367/zc-easy-term-ops.git
cd zc-easy-term-ops
sudo bash install.sh
```

安装完成后，输入 `zetops` 即可启动工具箱。

## 使用方式 | Usage

```bash
zetops              # 启动交互式 TUI
zetops --help       # 查看帮助
zetops --list       # 列出所有模块
zetops --version    # 查看版本
```

## 目录结构 | Structure

```
zc-easy-term-ops/
├── install.sh         # 一键安装脚本
├── zetops             # 主程序入口
├── core/              # 核心框架
├── modules/           # 功能模块
├── plugins/           # 插件目录
├── tests/             # 测试套件
├── config/            # 配置模板
└── docs/              # 文档
```

## 文档 | Documentation

- [安装指南](docs/INSTALL.md)
- [模块开发指南](docs/MODULES.md)
- [更新日志](docs/CHANGELOG.md)

## 许可证 | License

[MIT](LICENSE)
