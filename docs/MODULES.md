# 模块开发指南 | Module Development Guide

本指南说明如何为 ZETOPS 开发新模块或插件。

## 一、核心库 API（模块可安全调用）

| 文件 | 函数 | 说明 |
|---|---|---|
| `core/logger.sh` | `log_info/log_success/log_warning/log_error/log_debug "消息"` | 彩色日志 + 落盘 `/var/log/zetops/zetops.log`，格式 `[时间] [级别] [模块] 内容` |
| `core/utils.sh` | `check_command <cmd>` | 命令存在返回 0 |
| | `check_root` | 检查 root 权限 |
| | `get_distro / get_arch / detect_pkg_manager` | 发行版 / 架构 / 包管理器探测 |
| | `install_pkg <pkg...>` | 按包管理器自动安装 |
| | `is_installed <pkg>` | 判断已安装 |
| | `validate_ip <ip>` / `validate_port <port>` | IP / 端口校验 |
| | `confirm_action <描述>` | 危险操作二次确认（输入 yes 或 CONFIRM） |
| | `show_spinner <描述>` / `stop_spinner` | 耗时操作旋转动画 |
| | `press_enter` / `read_input <变量> <提示> <默认>` | 交互输入工具 |
| | `backup_file <路径>` | 统一备份入口：生成 `${路径}.bak.<时间戳>` 副本并输出备份路径（修改任何配置文件前必须先调用，失败返回非零） |
| `core/config.sh` | `load_config` / `get_config_value <key> <默认>` | 加载/读取 `~/.zetops/zetops.conf` |
| | `load_api_config` | 加载 `~/.zetops/api.conf` |
| | `api_fetch <路径>` | 从 API 节点获取外部数据 |

## 二、模块统一接口（必须实现）

每个模块文件 `modules/<序号>_<名称>.sh` 必须包含：

```bash
#!/bin/bash
set -euo pipefail

module_name="系统初始化与优化"          # 显示名称
module_short="system_init"             # 短名（日志/菜单用）
module_version="1.0.0"                 # 版本号

module_description() {                 # 模块描述
    echo "一句话描述模块功能"
}

module_menu() {                        # 子菜单渲染
    echo " 1. 功能A"
    echo " 2. 功能B"
    echo " 0. 返回主菜单"
}

module_execute() {                     # 执行入口（参数为子菜单选项）
    local choice=$1
    case $choice in
        1) system_update ;;
        2) time_sync ;;
        0) return 0 ;;
        *) log_error "无效选项" ;;
    esac
}
```

> **菜单行格式**：`module_menu` 每行必须以 `  N. 描述` 开头（如 `" 1. 功能A"`），TUI 鼠标点击依赖该前缀定位选项（`_tui_capture` 解析行首 `N.`）；数字即该选项号，`module_execute` 收到的就是它。

## 三、CLI 与 TUI 双协议兼容

模块菜单项除 TUI 交互外，还可被 CLI 非交互执行：

```bash
zetops --run <模块序号|短名> <选项号>
zetops --run 15 2            # 模块15 第2项
zetops --run ai_assistant 1  # 按短名
```

执行时环境注入 `ZETOPS_NONINTERACTIVE=1` 且 stdin 接 `/dev/null`，模块需遵循：

- 交互输入一律用 `read_input <变量> <提示> <默认>`（非交互自动取默认值），不要裸用 `read`
- 危险操作确认用 `confirm_action`（非交互下自动拒绝并提示）
- `press_enter` 在 stdin 非终端时立即返回，不会卡住

## 四、编码规范

- `#!/bin/bash` + `set -euo pipefail`
- 文件头注释：作者、功能、版本、日期
- **所有注释用中文**，关键术语标注英文缩写（如 安全套接层(SSL)）
- 变量：全局大写（`LOG_DIR`），局部小写（`new_hostname`），必须 `local` 声明
- 函数命名：`模块前缀_动词_名词`（如 `mysql_create_db`、`nginx_reload_config`）
- 危险操作（删除/清空/格式化/重置）必须 `confirm_action`
- 端口/IP/路径输入必须校验
- 建议通过 ShellCheck 检查：`shellcheck modules/01_system_init.sh`

## 五、模块独立执行

每个模块尾部已包含独立执行保护，可单独运行：

```bash
bash modules/01_system_init.sh
```

## 六、插件开发

1. 命名：`plugins/<序号>_<名称>.sh`
2. 主菜单自动扫描 `plugins/` 目录并动态加载
3. 必须实现：

```bash
plugin_name="我的插件"          # 插件显示名
plugin_menu() { ... }           # 插件子菜单
plugin_execute() { local c=$1; case $c in ... esac; }   # 执行入口
```

4. 示例参考：`plugins/example_plugin.sh`

## 七、API 扩展

模块如需外部数据（镜像源/NTP/模板），统一通过 `api_fetch <路径>` 获取，不要硬编码地址。参考 `~/.zetops/api.conf` 与 `core/config.sh`。
