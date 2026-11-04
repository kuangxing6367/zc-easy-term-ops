#!/usr/bin/env bash
# ============================================================
# scan_features.sh — 提取 bash 脚本使用的"语法特性面"
# 用途: 定义 Rust bash 兼容 shell 必须覆盖的目标语法集
# 实现: 单进程 awk 扫描（避免大量 grep 子进程在 cygwin 下不稳定）
# 用法:
#   bash scan_features.sh file1.sh [file2 ...]        # 逐文件人类可读报告
#   bash scan_features.sh --aggregate f1 f2 ...        # 跨文件汇总（按特性求和）
#   bash scan_features.sh --machine f1                 # 仅输出 FEAT|标签|次数
# 说明: 统计"出现该语法的行数"，衡量语法面的使用强度，非精确出现次数。
# ============================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWK="${HERE}/scan.awk"
[[ -f "${AWK}" ]] || { echo "缺少 ${AWK}" >&2; exit 2; }

# 标签 -> 分组（用于人类可读报告的章节）
section_of() {
    case "$1" in
        if/then|elif|else/fi|for|while|until|case/esac|select|function*) echo A ;;
        "[[ ]]"*|"[ ]"*|"(( ))"*|let|=~*|-f/-d/-z*) echo B ;;
        '${VAR}'*|'${!VAR}'*|'${#VAR}'*) echo C ;;
        declare*|\$\{arr*|arr\[idx\]*) echo D ;;
        '$('*|*反引号*|\<\(\>*|\>\(\>*|\<\<\<*) echo E ;;
        '>'|'>>'|'<'|'2>'|'2>&1'|'&>'|'<<'*) echo F ;;
        local|source|read|printf|mapfile|eval|exec|trap|set|export|unset|shift|getopts|declare|typeset|alias|enable) echo G ;;
        *) echo H ;;
    esac
}

format_human() {
    # 读取 FEAT|label|count 行，按章节分组打印
    local cur="" sec label cnt
    while IFS='|' read -r _ label cnt; do
        sec="$(section_of "${label}")"
        if [[ "${sec}" != "${cur}" ]]; then
            cur="${sec}"
            case "${sec}" in
                A) echo "[A] 流程控制" ;; B) echo "[B] 条件 / 测试" ;; C) echo "[C] 参数展开" ;;
                D) echo "[D] 数组" ;; E) echo "[E] 替换 / 子 shell" ;; F) echo "[F] 重定向" ;;
                G) echo "[G] 内建命令(builtins)" ;; H) echo "[H] 其它语法" ;;
            esac
        fi
        printf '  %-28s %s\n' "${label}" "${cnt}"
    done
}

scan_file() { awk -f "${AWK}" "$1"; }

aggregate() {
    local tmp=".zetops_scan_$$.tmp"
    : > "${tmp}"
    for f in "$@"; do
        [[ -f "${f}" ]] || continue
        scan_file "${f}" >> "${tmp}"
    done
    echo "===== 语法面汇总 ($# 个文件) ====="
    awk -F'|' '$1=="FEAT"{ s[$2]+=$3 } END{ for(k in s) printf "  %-28s %s\n", k, s[k] }' "${tmp}"
    rm -f "${tmp}"
}

# ---- 入口 ----
MODE="human"
[[ "${1:-}" == "--machine" ]] && { MODE="machine"; shift; }
[[ "${1:-}" == "--aggregate" ]] && { shift; aggregate "$@"; exit $?; }
if [[ $# -eq 0 ]]; then echo "用法: bash $0 [--aggregate|--machine] file ..." >&2; exit 1; fi

if [[ "${MODE}" == "machine" ]]; then
    for f in "$@"; do scan_file "${f}"; done
else
    for f in "$@"; do
        [[ -f "${f}" ]] || { echo "缺少文件: ${f}" >&2; continue; }
        echo "========================================"
        echo "FILE: ${f}"
        echo "LINES: $(wc -l < "${f}")"
        echo "----------------------------------------"
        scan_file "${f}" | format_human
        echo
    done
fi
