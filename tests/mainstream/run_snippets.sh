#!/usr/bin/env bash
# ============================================================
# run_snippets.sh — 执行对齐：OS 无关 bash snippet 在真 bash 与 OUR_SHELL 间 diff
# 仅测"语法执行结果"，不依赖任何 Linux 系统命令。
# 用法: OUR_SHELL=./target/release/zbash bash tests/mainstream/run_snippets.sh
# ============================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNIP="${HERE}/snippets"
OUR_SHELL="${OUR_SHELL:-}"
[[ -n "${OUR_SHELL}" ]] || { echo "需设置 OUR_SHELL" >&2; exit 1; }

PASS=0; FAIL=0
for s in "${SNIP}"/*.sh; do
    name="$(basename "${s}")"
    # 真 bash 执行（隔离环境）
    b_out="$($(command -v bash) "${s}" 2>&1)"; b_rc=$?
    # OUR_SHELL 执行
    o_out="$("${OUR_SHELL}" "${s}" 2>&1)"; o_rc=$?
    if [[ "${b_out}" == "${o_out}" && "${b_rc}" == "${o_rc}" ]]; then
        echo "  PASS 对齐: ${name}"
        PASS=$((PASS+1))
    else
        echo "  FAIL 对齐: ${name}"
        echo "    bash  (rc=${b_rc}): ${b_out}"
        echo "    ours  (rc=${o_rc}): ${o_out}"
        FAIL=$((FAIL+1))
    fi
done
echo "snippet 执行对齐: PASS=${PASS} FAIL=${FAIL}"
