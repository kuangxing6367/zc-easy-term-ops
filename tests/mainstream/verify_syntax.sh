#!/usr/bin/env bash
# ============================================================
# verify_syntax.sh — 主流脚本语法验证编排器
# 两层验证：
#   L0 解析对齐: 真 bash `bash -n` 必须通过（ground truth）；
#               若设置 OUR_SHELL，则额外用其 --check 解析同一文件，要求同过。
#   L1 语法面:   调用 scan_features.sh 提取语料使用的 bash 语法特性。
# 用法:
#   OUR_SHELL=./target/release/zbash bash tests/mainstream/verify_syntax.sh
#   (不设置 OUR_SHELL 时仅做真 bash 解析 + 语法面提取)
# ============================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CORPUS="${HERE}/corpus"
CONF="${HERE}/corpus.conf"
OUR_SHELL="${OUR_SHELL:-}"

bash --version >/dev/null 2>&1 || { echo "需要 bash" >&2; exit 1; }

echo "=========================================="
echo " ZETOPS 主流脚本语法验证"
echo " 真 bash : $(bash --version | head -1)"
echo " OUR_SHELL: ${OUR_SHELL:-<未设置，仅真bash解析+语法面>}"
echo "=========================================="

# 确保语料已拉取
bash "${HERE}/fetch_corpus.sh" >/dev/null

PASS=0; FAIL=0
echo
echo "[L0] 解析对齐 (bash -n 必须通过)"
while IFS='|' read -r name url category os; do
    name="$(echo "${name}" | tr -d '[:space:]')"
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    f="${CORPUS}/${name}.sh"
    [[ -f "${f}" ]] || { echo "  SKIP ${name} (无语料)"; continue; }
    if bash -n "${f}" 2>/dev/null; then
        echo "  PASS bash -n : ${name} ($(wc -l < "${f}") 行)"
        PASS=$((PASS+1))
        if [[ -n "${OUR_SHELL}" ]]; then
            if "${OUR_SHELL}" --check "${f}" >/dev/null 2>&1; then
                echo "  PASS ${OUR_SHELL##*/} --check : ${name}"
                PASS=$((PASS+1))
            else
                echo "  FAIL ${OUR_SHELL##*/} --check : ${name}"
                FAIL=$((FAIL+1))
            fi
        fi
    else
        echo "  FAIL bash -n : ${name} (真 bash 都无法解析！)"
        FAIL=$((FAIL+1))
    fi
done < "${CONF}"

echo
echo "[L1] 语法面提取 (主流语料 + 本项目)"
bash "${HERE}/scan_features.sh" --aggregate \
    "${CORPUS}"/*.sh \
    "${ROOT}/install.sh" \
    "${ROOT}/core/main.sh" \
    "${ROOT}/core/utils.sh" \
    "${ROOT}/core/editor.sh" 2>/dev/null | sed 's/^/  /'

echo
echo "[L2] 执行对齐 (OS 无关 snippet，需 OUR_SHELL 才生效)"
if [[ -n "${OUR_SHELL}" ]]; then
    bash "${HERE}/run_snippets.sh"
else
    echo "  OUR_SHELL 未设置，跳过。等 Rust shell 就绪后："
    echo "    OUR_SHELL=./target/release/zbash bash tests/mainstream/run_snippets.sh"
fi

echo
echo "=========================================="
echo " L0 解析: PASS=${PASS} FAIL=${FAIL}"
echo "=========================================="
