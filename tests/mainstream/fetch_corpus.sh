#!/usr/bin/env bash
# ============================================================
# fetch_corpus.sh — 幂等拉取主流脚本语料到本地 corpus/（仅下载，绝不执行）
# 用法: bash tests/mainstream/fetch_corpus.sh
# ============================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS="${HERE}/corpus"
CONF="${HERE}/corpus.conf"
mkdir -p "${CORPUS}"

while IFS='|' read -r name url category os; do
    name="$(echo "${name}" | tr -d '[:space:]')"
    url="$(echo "${url}" | tr -d '[:space:]')"
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    out="${CORPUS}/${name}.sh"
    if [[ -s "${out}" ]]; then
        echo "[skip] ${name} 已存在 ($(wc -l < "${out}") 行)"
    else
        echo "[fetch] ${name} <- ${url}"
        if curl -fsSL --max-time 30 -o "${out}" "${url}"; then
            echo "        OK ($(wc -l < "${out}") 行) -> ${out}"
        else
            echo "        FAIL 下载失败: ${name}" >&2
        fi
    fi
    # 记录校验和，便于复现与变更检测
    [[ -s "${out}" ]] && sha256sum "${out}" > "${out}.sha256"
done < "${CONF}"
echo "语料目录: ${CORPUS}"
