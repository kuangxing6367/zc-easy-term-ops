#!/bin/bash
# ============================================================
# 文件：install.sh
# 功能：ZETOPS 一键安装脚本（环境检测 / 依赖安装 / 软链接 / 初始化）
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-05
# 用法：sudo bash install.sh [--prefix /opt/zc-easy-term-ops] [--uninstall]
# ============================================================
set -euo pipefail

# 默认安装目录
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/zc-easy-term-ops}"
DO_UNINSTALL=0

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) INSTALL_PREFIX="$2"; shift 2 ;;
        --uninstall) DO_UNINSTALL=1; shift ;;
        --help|-h)
            echo "用法: sudo bash install.sh [--prefix DIR] [--uninstall]"
            echo "  --prefix DIR   指定安装目录（默认 /opt/zc-easy-term-ops）"
            echo "  --uninstall    卸载 ZETOPS（询问是否保留配置/日志）"
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
# 卸载模式（--uninstall）
# ------------------------------------------------------------
if [[ "${DO_UNINSTALL}" == "1" ]]; then
    install_echo "开始卸载 ZETOPS ..."
    SYMLINK="/usr/local/bin/zetops"
    local_ans=""

    # 删除软链接
    if [[ -L "${SYMLINK}" || -f "${SYMLINK}" ]]; then
        rm -f "${SYMLINK}"
        install_ok "已删除软链接 ${SYMLINK}"
    else
        install_echo "软链接 ${SYMLINK} 不存在，跳过"
    fi

    # 删除安装目录
    if [[ -d "${INSTALL_PREFIX}" ]]; then
        rm -rf "${INSTALL_PREFIX}"
        install_ok "已删除安装目录 ${INSTALL_PREFIX}"
    else
        install_echo "安装目录 ${INSTALL_PREFIX} 不存在，跳过"
    fi

    # 询问是否删除配置目录
    if [[ -d "${HOME}/.zetops" ]]; then
        echo -n "[INSTALL] 是否删除配置目录 ~/.zetops? [y/N]: "
        read -r local_ans || local_ans="n"
        if [[ "${local_ans}" == "y" || "${local_ans}" == "Y" ]]; then
            rm -rf "${HOME}/.zetops"
            install_ok "已删除配置目录 ~/.zetops"
        else
            install_echo "保留配置目录 ~/.zetops"
        fi
    fi

    # 询问是否删除日志目录
    if [[ -d "/var/log/zetops" ]]; then
        echo -n "[INSTALL] 是否删除日志目录 /var/log/zetops? [y/N]: "
        read -r local_ans || local_ans="n"
        if [[ "${local_ans}" == "y" || "${local_ans}" == "Y" ]]; then
            rm -rf /var/log/zetops
            install_ok "已删除日志目录 /var/log/zetops"
        else
            install_echo "保留日志目录 /var/log/zetops"
        fi
    fi

    # 清理锁文件
    rm -f /var/run/zetops.lock 2>/dev/null || true

    echo ""
    install_ok "ZETOPS 卸载完成"
    exit 0
fi

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

# 临时禁用可能有问题的第三方源（如不支持当前发行版的 Docker CE 源）
BROKEN_SOURCES=""
if command -v apt-get >/dev/null 2>&1 && [[ ${#NEED_INSTALL[@]} -gt 0 ]]; then
    for list_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "${list_file}" ]] || continue
        if grep -qE 'docker|docker-ce' "${list_file}" 2>/dev/null; then
            BROKEN_SOURCES="${BROKEN_SOURCES} ${list_file}"
            mv "${list_file}" "${list_file}.bak" 2>/dev/null || true
            install_echo "临时禁用: ${list_file}"
        fi
    done
fi

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
# 恢复被临时禁用的源
restore_broken_sources() {
    for bak_file in ${BROKEN_SOURCES}; do
        [[ -f "${bak_file}.bak" ]] && mv "${bak_file}.bak" "${bak_file}" 2>/dev/null || true
    done
}
trap restore_broken_sources EXIT
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
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude '.git' --exclude 'install.sh' --exclude 'install-online.sh' \
            "${SCRIPT_DIR}/" "${INSTALL_PREFIX}/"
    else
        (cd "${SCRIPT_DIR}" && tar cf - --exclude='./.git' --exclude='./install.sh' --exclude='./install-online.sh' .) | \
            (cd "${INSTALL_PREFIX}" && tar xf -)
    fi
fi
chmod -R a+rX "${INSTALL_PREFIX}"
chmod +x "${INSTALL_PREFIX}"/core/*.sh "${INSTALL_PREFIX}"/modules/*.sh \
         "${INSTALL_PREFIX}"/plugins/*.sh "${INSTALL_PREFIX}"/zetops 2>/dev/null || true
install_ok "项目文件就绪"

# ------------------------------------------------------------
# 4. 创建软链接（/usr/local/bin/zetops -> zetops 脚本）
# ------------------------------------------------------------
SYMLINK="/usr/local/bin/zetops"
install_echo "创建软链接 ${SYMLINK} -> ${INSTALL_PREFIX}/zetops"
# 先删除旧的软链接或文件
rm -f "${SYMLINK}" 2>/dev/null || true
# 确保目标目录存在
mkdir -p /usr/local/bin
# 创建软链接
ln -sf "${INSTALL_PREFIX}/zetops" "${SYMLINK}"
# 验证软链接
if [[ -L "${SYMLINK}" && -f "${SYMLINK}" ]]; then
    chmod +x "${SYMLINK}"
    install_ok "软链接创建完成: ${SYMLINK} -> $(readlink ${SYMLINK})"
else
    install_err "软链接创建失败，请手动检查: ls -la ${SYMLINK}"
    exit 1
fi

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
install_echo "如需卸载：sudo bash install.sh --uninstall"
