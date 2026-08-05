#!/bin/bash
# ============================================================
# 文件：install.sh
# 功能：ZETOPS 一键安装脚本（环境检测 / 依赖安装 / 软链接 / 初始化）
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 用法：sudo bash install.sh [--prefix /opt/zc-easy-term-ops]
# ============================================================
set -euo pipefail

# 默认安装目录
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/zc-easy-term-ops}"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) INSTALL_PREFIX="$2"; shift 2 ;;
        --help|-h)
            echo "用法: sudo bash install.sh [--prefix /opt/zc-easy-term-ops]"
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# ---- 简易日志（安装阶段独立实现，避免依赖 core） ----
install_echo() { echo -e "\033[1;34m[INSTALL]\033[0m $1"; }
install_ok()   { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
install_err()  { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; }

# ------------------------------------------------------------
# 1. 检测系统环境
# ------------------------------------------------------------
install_echo "检测系统环境 ..."
if [[ "$(id -u)" -ne 0 ]]; then
    install_err "请使用 root 权限运行: sudo bash install.sh"
    exit 1
fi

OS_ID="unknown"
if [[ -f /etc/os-release ]]; then
    OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi
KERNEL_VERSION=$(uname -r)
ARCH=$(uname -m)
install_echo "发行版: ${OS_ID} | 内核: ${KERNEL_VERSION} | 架构: ${ARCH}"

# ------------------------------------------------------------
# 2. 检查并安装必需依赖
# ------------------------------------------------------------
install_echo "检查必需依赖（awk/sed/grep/curl/wget/tput/rsync ...）..."
NEED_INSTALL=()
for c in awk sed grep date dirname; do
    command -v "${c}" >/dev/null 2>&1 || NEED_INSTALL+=("${c}")
done
# 网络工具：curl 或 wget 至少其一
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    NEED_INSTALL+=(curl)
fi
# 建议工具（非必须）
for c in tput rsync unzip; do
    command -v "${c}" >/dev/null 2>&1 || NEED_INSTALL+=("${c}")
done

if [[ ${#NEED_INSTALL[@]} -gt 0 ]]; then
    install_echo "需要安装缺失依赖: ${NEED_INSTALL[*]}"
    PM=""
    command -v apt-get >/dev/null 2>&1 && PM=apt
    command -v dnf >/dev/null 2>&1 && PM=dnf
    command -v yum >/dev/null 2>&1 && PM=yum
    command -v zypper >/dev/null 2>&1 && PM=zypper
    command -v apk >/dev/null 2>&1 && PM=apk
    case "${PM}" in
        apt)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED_INSTALL[@]}"
            ;;
        dnf|yum)
            "${PM}" install -y "${NEED_INSTALL[@]}"
            ;;
        zypper)
            zypper --non-interactive install "${NEED_INSTALL[@]}"
            ;;
        apk)
            apk add --no-cache "${NEED_INSTALL[@]}"
            ;;
        *)
            install_err "未识别的包管理器，请手动安装: ${NEED_INSTALL[*]}"
            exit 1
            ;;
    esac
    install_ok "依赖安装完成"
else
    install_ok "依赖齐全，无需安装"
fi

# ------------------------------------------------------------
# 3. 复制项目到安装目录
# ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_echo "安装目录: ${INSTALL_PREFIX}"
mkdir -p "${INSTALL_PREFIX}"

if [[ "${SCRIPT_DIR}" == "${INSTALL_PREFIX}" ]]; then
    install_echo "已在安装目录中，跳过复制"
else
    install_echo "复制项目文件到 ${INSTALL_PREFIX} ..."
    # rsync 优先，否则用 tar 管道（避免覆盖自定义配置）
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude '.git' --exclude 'install.sh' \
            "${SCRIPT_DIR}/" "${INSTALL_PREFIX}/"
    else
        (cd "${SCRIPT_DIR}" && tar cf - --exclude='./.git' --exclude='./install.sh' .) | \
            (cd "${INSTALL_PREFIX}" && tar xf -)
    fi
fi
chmod -R a+rX "${INSTALL_PREFIX}"
chmod +x "${INSTALL_PREFIX}"/core/*.sh "${INSTALL_PREFIX}"/modules/*.sh \
         "${INSTALL_PREFIX}"/plugins/*.sh "${INSTALL_PREFIX}"/zetops 2>/dev/null || true
install_ok "项目文件就绪"

# ------------------------------------------------------------
# 4. 创建软链接（/usr/local/bin/zetops -> core/main.sh）
# ------------------------------------------------------------
SYMLINK="/usr/local/bin/zetops"
install_echo "创建软链接 ${SYMLINK} -> ${INSTALL_PREFIX}/core/main.sh"
ln -sf "${INSTALL_PREFIX}/core/main.sh" "${SYMLINK}"
chmod +x "${SYMLINK}"
install_ok "软链接创建完成"

# ------------------------------------------------------------
# 5. 初始化配置目录与日志目录
# ------------------------------------------------------------
install_echo "初始化配置目录 ~/.zetops/ ..."
mkdir -p "${HOME}/.zetops"
if [[ ! -f "${HOME}/.zetops/zetops.conf" ]]; then
    cp "${INSTALL_PREFIX}/config/zetops.conf.example" "${HOME}/.zetops/zetops.conf"
    install_echo "已生成配置文件 ~/.zetops/zetops.conf"
fi
if [[ ! -f "${HOME}/.zetops/api.conf" ]]; then
    cp "${INSTALL_PREFIX}/config/api.conf.example" "${HOME}/.zetops/api.conf"
    install_echo "已生成 API 配置文件 ~/.zetops/api.conf（请按需填写 API_BASE_URL）"
fi

install_echo "创建日志目录 /var/log/zetops/ ..."
mkdir -p /var/log/zetops
chmod 755 /var/log/zetops 2>/dev/null || true

# ------------------------------------------------------------
# 6. 完成提示
# ------------------------------------------------------------
echo ""
install_ok "=============================================="
install_ok " ZETOPS 安装成功！"
install_ok " 安装目录: ${INSTALL_PREFIX}"
install_ok " 命令入口: zetops（已软链接到 /usr/local/bin/zetops）"
install_ok " 配置文件: ~/.zetops/zetops.conf"
install_ok " API 配置: ~/.zetops/api.conf"
install_ok " 日志文件: /var/log/zetops/zetops.log"
install_ok "=============================================="
echo ""
install_echo "现在直接输入 zetops 即可启动工具箱"
install_echo "如需卸载：rm -rf ${INSTALL_PREFIX} ${SYMLINK} ~/.zetops"
