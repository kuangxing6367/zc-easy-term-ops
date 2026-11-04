#!/bin/bash
# ============================================================
# 文件：install-online.sh
# 功能：ZETOPS 一键在线安装（从 GitHub 拉取源码 -> 自动执行安装）
# 作者：zc 团队
# 版本：1.0.0
# 日期：2026-08-07
#
# 用法一（服务器可直连 GitHub）：
#     sudo bash install-online.sh
# 用法二（无法直连 GitHub，用加速镜像）：
#     sudo ZETOPS_GITHUB_MIRROR="https://ghfast.top/" bash install-online.sh
# 用法三（一键管道安装，免下载脚本）：
#     curl -fsSL "https://ghfast.top/https://raw.githubusercontent.com/kuangxing6367/zc-easy-term-ops/main/install-online.sh" \
#       | sudo ZETOPS_GITHUB_MIRROR="https://ghfast.top/" bash
#
# 环境变量：
#   INSTALL_PREFIX          安装目录（默认 /opt/zc-easy-term-ops）
#   ZETOPS_GITHUB_MIRROR    GitHub 加速镜像前缀（留空=直连）
# ============================================================
set -euo pipefail

# ---- 参数 ----
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/zc-easy-term-ops}"
ZETOPS_REPO_OWNER="${ZETOPS_REPO_OWNER:-kuangxing6367}"
ZETOPS_REPO_NAME="${ZETOPS_REPO_NAME:-zc-easy-term-ops}"
ZETOPS_UPDATE_BRANCH="${ZETOPS_UPDATE_BRANCH:-main}"
ZETOPS_GITHUB_MIRROR="${ZETOPS_GITHUB_MIRROR:-}"

# ---- 简易日志 ----
say()   { echo -e "\033[1;34m[INSTALL]\033[0m $1"; }
ok()    { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; }

cleanup() { [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; }
trap cleanup EXIT INT TERM

# ------------------------------------------------------------
# 1. 环境检测
# ------------------------------------------------------------
say "检测系统环境 ..."
if [[ "$(id -u)" -ne 0 ]]; then
    err "请使用 root 权限运行: sudo bash install-online.sh"
    exit 1
fi
for c in bash curl tar; do
    command -v "${c}" >/dev/null 2>&1 || { err "缺少必要命令: ${c}"; exit 1; }
done
say "发行版: $(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo unknown) | 架构: $(uname -m)"

# ------------------------------------------------------------
# 2. 拉取源码压缩包
# ------------------------------------------------------------
TARBALL_URL="${ZETOPS_GITHUB_MIRROR}https://github.com/${ZETOPS_REPO_OWNER}/${ZETOPS_REPO_NAME}/archive/refs/heads/${ZETOPS_UPDATE_BRANCH}.tar.gz"
say "下载源码: ${TARBALL_URL}"
TMP_DIR=$(mktemp -d)
TARBALL="${TMP_DIR}/zetops.tar.gz"
if ! curl -fsSL --connect-timeout 20 --max-time 180 -o "${TARBALL}" "${TARBALL_URL}"; then
    err "下载失败。"
    err "  - 若服务器无法直连 GitHub，请使用镜像重试："
    err "      sudo ZETOPS_GITHUB_MIRROR=\"https://ghfast.top/\" bash install-online.sh"
    err "  - 或先到厂商看是否网络/代理问题"
    exit 1
fi
if [[ ! -s "${TARBALL}" ]]; then
    err "下载结果为空文件，请检查网络或镜像可用性"
    exit 1
fi
SIZE=$(du -h "${TARBALL}" | cut -f1)
say "下载完成 (${SIZE})，解压中 ..."
tar xzf "${TARBALL}" -C "${TMP_DIR}"
SRC_DIR=$(find "${TMP_DIR}" -maxdepth 2 -name install.sh -printf '%h\n' -quit)
if [[ -z "${SRC_DIR}" ]]; then
    err "源码中未找到 install.sh，解压内容异常"
    exit 1
fi

# ------------------------------------------------------------
# 3. 调用仓库自带安装脚本（依赖/复制/软链接/初始化）
# ------------------------------------------------------------
say "开始正式安装（目标目录: ${INSTALL_PREFIX}）..."
INSTALL_PREFIX="${INSTALL_PREFIX}" bash "${SRC_DIR}/install.sh" --prefix "${INSTALL_PREFIX}"

# ------------------------------------------------------------
# 4. 完成
# ------------------------------------------------------------
echo ""
ok "一键安装完成！直接输入 zetops 启动工具箱"