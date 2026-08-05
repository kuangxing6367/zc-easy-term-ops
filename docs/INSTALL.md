# 安装指南 | Installation Guide

## 环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Debian / Ubuntu / CentOS / RHEL / Rocky / Alma / Fedora / openSUSE |
| 权限 | root（或 sudo） |
| Shell | Bash 4+ |
| 网络 | 可访问外网（安装依赖、下载软件包） |

## 一键安装

```bash
# 下载项目并进入目录
git clone <你的仓库地址> zc-easy-term-ops
cd zc-easy-term-ops

# 一键安装（默认安装到 /opt/zc-easy-term-ops）
sudo bash install.sh

# 指定安装目录
sudo bash install.sh --prefix /data/tools/zetops
```

### install.sh 自动完成以下操作

1. **检测系统环境**：发行版、内核版本、系统架构
2. **检查并安装依赖**：`awk/sed/grep/date/tput/rsync` 等；网络工具 `curl` 或 `wget` 至少其一
3. **复制项目到安装目录**（默认 `/opt/zc-easy-term-ops`）
4. **创建软链接** `/usr/local/bin/zetops` → `core/main.sh`
5. **初始化配置**：生成 `~/.zetops/zetops.conf`（用户配置）和 `~/.zetops/api.conf`（API 节点）
6. **创建日志目录** `/var/log/zetops/`

## 启动

```bash
# 全局命令（安装后）
zetops

# 仓库内直接运行
./zetops

# 单独执行某个模块（可选）
bash modules/04_database.sh
```

## 配置文件

### ~/.zetops/zetops.conf（用户配置）

```ini
LOG_DIR="/var/log/zetops"
BACKUP_DIR="/data/backup"
MYSQL_VERSION="8.0"
DOCKER_REGISTRY="docker.io"
```

### ~/.zetops/api.conf（API 节点）

所有外部数据（镜像源列表、NTP 服务器、Docker 安装脚本、软件包下载地址、配置模板）均从 API 节点动态获取，**不硬编码**：

```ini
API_BASE_URL="https://your.api.node/v1"
API_TIMEOUT=10
```

| 接口路径 | 用途 |
|---|---|
| `mirrors/list?distro=xxx` | 软件源镜像列表 |
| `ntp/servers` | NTP 时间服务器列表 |
| `docker/install-script` | Docker 安装脚本地址 |
| `proxy/squid.conf` 等 | 代理服务配置模板 |
| `tomcat/download?version=xx` | Tomcat 下载地址 |

> 未配置 API 时，各模块自动回退到内置官方默认源。

## 卸载

```bash
rm -rf /opt/zc-easy-term-ops /usr/local/bin/zetops ~/.zetops
```
