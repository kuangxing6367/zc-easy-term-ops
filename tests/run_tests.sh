#!/bin/bash
# ============================================================
# 文件：tests/run_tests.sh
# 功能：ZETOPS 自动化测试套件（语法 / 接口 / 单元 / 安全 / 菜单 / CLI）
# 用法：bash tests/run_tests.sh
# 说明：全部为只读/临时文件测试，不修改系统；失败不中断，最后汇总
# ============================================================

ZETOPS_ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d 2>/dev/null || echo /tmp)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# ---- 断言工具 ----
# check_run <描述> <命令...>：命令退出码为 0 则 PASS
check_run() {
    local desc="$1"
    shift
    if ( set +e; "$@" ) >"${TMPDIR_TEST}/out" 2>"${TMPDIR_TEST}/err"; then
        PASS=$((PASS + 1)); echo "  PASS: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (exit=$?)"
        sed 's/^/        | /' "${TMPDIR_TEST}/err" | head -5
    fi
}

# check_true <描述> <命令...>：命令退出码为 0 则 PASS（用于布尔函数）
# 注意：run_tests.sh 因 source core/logger.sh 继承 set -e，子 shell 裸调用
#       返回非零会直接终止脚本，必须用 if 条件吸收退出码
check_true() {
    local desc="$1"
    shift
    local rc=0
    if ( set +e; "$@" ) >/dev/null 2>&1; then
        rc=0
    else
        rc=1
    fi
    if (( rc == 0 )); then
        PASS=$((PASS + 1)); echo "  PASS: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (rc=${rc})"
    fi
}

# check_false <描述> <命令...>：命令退出码非 0 则 PASS（用于布尔函数取反）
check_false() {
    local desc="$1"
    shift
    local rc=0
    if ( set +e; "$@" ) >/dev/null 2>&1; then
        rc=0
    else
        rc=1
    fi
    if (( rc != 0 )); then
        PASS=$((PASS + 1)); echo "  PASS: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (rc=${rc})"
    fi
}

# check_eq <描述> <期望> <实际>
check_eq() {
    local desc="$1" exp="$2" act="$3"
    if [[ "${exp}" == "${act}" ]]; then
        PASS=$((PASS + 1)); echo "  PASS: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (exp=[${exp}] act=[${act}])"
    fi
}

# check_contains <描述> <文本> <子串>
check_contains() {
    local desc="$1" hay="$2" needle="$3"
    if [[ "${hay}" == *"${needle}"* ]]; then
        PASS=$((PASS + 1)); echo "  PASS: ${desc}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (缺少 [${needle}])"
    fi
}

echo "======================================================"
echo "ZETOPS 自动化测试套件  版本一致性目标: 1.5.2"
echo "根目录: ${ZETOPS_ROOT}"
echo "======================================================"

# ---------- 1. 全部脚本 bash -n 语法检查 ----------
echo ""
echo "[1] bash -n 语法检查"
syntax_ok=0
syntax_bad=0
while IFS= read -r f; do
    if bash -n "${f}" 2>/dev/null; then
        syntax_ok=$((syntax_ok + 1))
    else
        syntax_bad=$((syntax_bad + 1))
        echo "  FAIL: 语法错误 ${f}"
    fi
done < <(find "${ZETOPS_ROOT}" -name '*.sh' -type f)
echo "  PASS: ${syntax_ok} 个脚本语法通过"
if (( syntax_bad > 0 )); then
    FAIL=$((FAIL + syntax_bad))
else
    PASS=$((PASS + 1))
fi

# ---------- 2. 模块/插件接口完整性 ----------
echo ""
echo "[2] 模块/插件接口完整性"
mod_bad=0
while IFS= read -r f; do
    for fn in module_name module_short module_description module_menu module_execute; do
        grep -qE "^${fn}[ =(]" "${f}" || { echo "  FAIL: ${f} 缺少 ${fn}"; mod_bad=$((mod_bad + 1)); }
    done
done < <(find "${ZETOPS_ROOT}/modules" -name '*.sh' -type f)
while IFS= read -r f; do
    for fn in plugin_name plugin_menu plugin_execute; do
        grep -qE "^${fn}[ =(]" "${f}" || { echo "  FAIL: ${f} 缺少 ${fn}"; mod_bad=$((mod_bad + 1)); }
    done
done < <(find "${ZETOPS_ROOT}/plugins" -name '*.sh' -type f)
if (( mod_bad > 0 )); then FAIL=$((FAIL + mod_bad)); else PASS=$((PASS + 1)); echo "  PASS: 全部模块/插件接口完整"; fi

# ---------- 3. 颜色变量定义 ----------
echo ""
echo "[3] 核心颜色变量定义"
for c in COLOR_RESET COLOR_BOLD COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_GRAY; do
    if grep -qE "^[[:space:]]*${c}=" "${ZETOPS_ROOT}/core/logger.sh"; then
        PASS=$((PASS + 1)); echo "  PASS: ${c} 已定义"
    else
        echo "  FAIL: logger.sh 缺少 ${c}"; FAIL=$((FAIL + 1))
    fi
done

# ---------- 4. 版本一致性 ----------
echo ""
echo "[4] 版本一致性 (1.5.2)"
VER_CFG=$(grep -E '^ZETOPS_VERSION=' "${ZETOPS_ROOT}/core/config.sh" | head -1 | cut -d= -f2 | tr -d '"')
VER_EXAMPLE=$(grep -E '^ZETOPS_VERSION=' "${ZETOPS_ROOT}/config/zetops.conf.example" | head -1 | cut -d= -f2 | tr -d '"')
check_eq "config.sh 版本" "1.5.2" "${VER_CFG}"
check_eq "conf.example 版本" "1.5.2" "${VER_EXAMPLE}"
grep -q "## \[1.5.2\]" "${ZETOPS_ROOT}/docs/CHANGELOG.md" && { PASS=$((PASS + 1)); echo "  PASS: CHANGELOG 含 [1.5.2]"; } || { FAIL=$((FAIL + 1)); echo "  FAIL: CHANGELOG 缺少 [1.5.2]"; }

# ---------- 5. conf 模板可解析 ----------
echo ""
echo "[5] conf 模板可解析"
if ( set +e; bash -n "${ZETOPS_ROOT}/config/zetops.conf.example" ) 2>/dev/null; then
    PASS=$((PASS + 1)); echo "  PASS: conf.example 语法正确"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: conf.example 语法错误"
fi

# ---------- 6-9. 模块单元测试（AI 解析/意图/安全/菜单） ----------
echo ""
echo "[6] 加载核心库与 AI 模块"
# shellcheck source=/dev/null
source "${ZETOPS_ROOT}/core/logger.sh"
# shellcheck source=/dev/null
source "${ZETOPS_ROOT}/core/utils.sh"
# shellcheck source=/dev/null
source "${ZETOPS_ROOT}/core/config.sh"
# shellcheck source=/dev/null
source "${ZETOPS_ROOT}/core/menu.sh"
# shellcheck source=/dev/null
source "${ZETOPS_ROOT}/modules/13_ai_assistant.sh"
# 库文件内部会 set -euo pipefail，此处显式关闭 errexit 避免断言失败中断
set +e
# 抑制 INFO/WARNING 日志（log_info/log_warning 输出到 stdout 会污染断言捕获）
LOG_LEVEL=ERROR
PASS=$((PASS + 1)); echo "  PASS: 库加载完成"

echo ""
echo "[7] AI 工具调用解析"
r1=$(mktemp); cat >"${r1}" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_service_status","arguments":"{\"service\":\"nginx\"}"}}]}}]}
EOF
if ai_llm_parse_tool_calls "${r1}" 2>/dev/null; then
    check_eq "解析 tool name" "get_service_status" "${AI_TOOL_NAME}"
    check_eq "提取参数 service" "nginx" "$(ai_tool_arg service "${AI_TOOL_ARGS_RAW}")"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: 解析失败"; fi
rm -f "${r1}"

r2=$(mktemp); cat >"${r2}" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_2","type":"function","function":{"name":"get_logs","arguments":"{\"service\":\"mysql\",\"lines\":30}"}}]}}]}
EOF
ai_llm_parse_tool_calls "${r2}" 2>/dev/null
check_eq "裸数字提取 lines" "30" "$(ai_tool_arg lines "${AI_TOOL_ARGS_RAW}")"
rm -f "${r2}"

r3=$(mktemp); cat >"${r3}" <<'EOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_3","type":"function","function":{"name":"run_command","arguments":"{\"command\":\"grep -q \\\"error\\\" /var/log/nginx/error.log\"}"}}]}}]}
EOF
ai_llm_parse_tool_calls "${r3}" 2>/dev/null
check_eq "内嵌引号命令提取" 'grep -q "error" /var/log/nginx/error.log' "$(ai_tool_arg command "${AI_TOOL_ARGS_RAW}")"
rm -f "${r3}"

echo ""
echo "[8] AI 意图识别顺序"
declare -A intent_cases=(
  ["nginx 502 bad gateway 怎么办"]="web_error"
  ["服务器突然502了"]="web_error"
  ["nginx 配置检查一下"]="nginx_conf"
  ["帮我检查下 nginx 语法"]="nginx_conf"
  ["apache 配置文件有没有问题"]="nginx_conf"
  ["查看一下 mysql 日志"]="log_issue"
  ["分析下日志里的报错"]="log_issue"
  ["帮我做个全面体检"]="diag_all"
  ["整体诊断一下服务器"]="diag_all"
  ["健康检查"]="diag_all"
  ["服务器挂了"]="service_down"
  ["磁盘满了"]="disk_full"
  ["cpu 占用 100% 了"]="high_cpu"
  ["内存不够用 oom"]="high_memory"
  ["网络不通了"]="network_issue"
  ["docker 容器一直重启"]="docker_issue"
  ["mysql 连不上了"]="mysql_issue"
  ["端口 3306 不通"]="port_blocked"
  ["今天天气怎么样"]="unknown"
)
for k in "${!intent_cases[@]}"; do
    got=$(ai_parse_intent "${k}" 2>/dev/null)
    check_eq "意图 [${k}]" "${intent_cases[$k]}" "${got}"
done

echo ""
echo "[9] AI 命令安全层"
check_true "危险命令 rm -rf / 被拦截" ai_is_dangerous "rm -rf /"
check_true "危险命令 dd 写盘被拦截" ai_is_dangerous "dd if=/dev/zero of=/dev/sda"
check_true "危险命令 mkfs 被拦截" ai_is_dangerous "mkfs.ext4 /dev/sdb"
check_true "危险命令 iptables -F 被拦截" ai_is_dangerous "iptables -F"
check_true "危险命令 kill -9 1 被拦截" ai_is_dangerous "kill -9 1"
check_true "只读命令 ls 无需确认" ai_is_readonly "ls -la"
check_true "只读命令 df 无需确认" ai_is_readonly "df -h"
check_true "只读命令 echo 无需确认" ai_is_readonly "echo hi"
check_true "只读命令 systemctl status 无需确认" ai_is_readonly "systemctl status nginx"
# 写命令需确认：ai_is_readonly 应返回非 0
check_false "写命令 systemctl restart 需确认" ai_is_readonly "systemctl restart nginx"
check_false "写命令 sed -i 需确认" ai_is_readonly "sed -i s/x/y/ f"
# 确认流（用写命令 touch，避免命中 echo 只读白名单）
out=$(echo "n" | ai_tool_dispatch run_command "{\"command\":\"touch ${TMPDIR_TEST}/cancel_test\"}" 2>/dev/null)
check_contains "确认流 n 取消" "${out}" "取消"
[[ -e "${TMPDIR_TEST}/cancel_test" ]] && { FAIL=$((FAIL + 1)); echo "  FAIL: 取消后仍生成了文件"; } || { PASS=$((PASS + 1)); echo "  PASS: 取消后未生成文件"; }
out=$(echo "y" | ai_tool_dispatch run_command "{\"command\":\"touch ${TMPDIR_TEST}/exec_test\"}" 2>/dev/null)
[[ -e "${TMPDIR_TEST}/exec_test" ]] && { PASS=$((PASS + 1)); echo "  PASS: 确认流 y 执行成功"; } || { FAIL=$((FAIL + 1)); echo "  FAIL: 确认流 y 未执行 [${out}]"; }

echo ""
echo "[10] 菜单渲染与鼠标映射"
_TUI_OPT_ROW_OPT=()
for f in "${ZETOPS_ROOT}"/modules/*.sh; do register_module "$f"; done
for f in "${ZETOPS_ROOT}"/plugins/*.sh; do register_plugin "$f"; done
_tui_capture _ui_module_list >"${TMPDIR_TEST}/grid" 2>/dev/null
check_contains "主菜单网格渲染" "$(cat "${TMPDIR_TEST}/grid")" "系统初始化与优化"
check_contains "主菜单网格渲染(右列)" "$(cat "${TMPDIR_TEST}/grid")" "安全基线加固"
check_eq "鼠标左列映射 row0" "1" "$(_tui_row_to_opt 0 10)"
check_eq "鼠标右列映射 row0" "14" "$(_tui_row_to_opt 0 50)"
check_eq "鼠标越界行返回空" "" "$(_tui_row_to_opt 999 10)"
# 双列网格右列起始列：渲染时左列占 _TUI_LCOL_W=22 列，右列从 _TUI_RIGHT_COL=30 开始；
# 点击分界必须与渲染列一致（旧硬编码 col<40 会让 14-27 右列点不到）
_TUI_LCOL_W=22
_TUI_RIGHT_COL=30
check_eq "双列分界 col29 归左列" "1" "$(_tui_row_to_opt 0 29)"
check_eq "双列分界 col30 归右列" "14" "$(_tui_row_to_opt 0 30)"
check_eq "键盘输入 0" "0" "$(echo '0' | get_user_choice 26 2>/dev/null)"
check_eq "键盘输入 q" "q" "$(echo 'q' | get_user_choice 26 2>/dev/null)"
check_eq "非法输入回退" "5" "$(printf 'abc\n5\n' | get_user_choice 26 2>/dev/null)"

# [10b] 鼠标两段式点击（点击=选中，再点/回车=确认；mock 事件源，测完恢复真实函数）
# 关键：真实终端一次点击 = SGR 按下(M)+释放(m) 两个事件，释放按钮号被置 3（btn=3）
#       get_user_choice 只认 btn==0，故一次点击仅选中不进入——否则会退化成"点一次就进"
echo ""
echo "[10b] 鼠标两段式点击（含 SGR 按下/释放对）"
EV_FILE_T="$(mktemp)"
_TUI_OPT_ROW_OPT[10]="5"
_tui_read_event_real="$(declare -f _tui_read_event)"
_tui_read_event() {
    local line=""
    if [[ -s "${EV_FILE_T}" ]]; then
        IFS= read -r line < "${EV_FILE_T}"
        tail -n +2 "${EV_FILE_T}" > "${EV_FILE_T}.tmp" 2>/dev/null && mv "${EV_FILE_T}.tmp" "${EV_FILE_T}"
        printf '%s' "${line}"
    else
        printf 'line:q'
    fi
    return 0
}
_tui_mouse_on(){ return 0; }
_tui_mouse_off(){ return 0; }
_tui_redraw_menu(){ :; }
# 一次点击（按下+释放）+ 二次点击（按下+释放）→ 二次确认
printf 'mouse:0,1,10\nmouse:3,1,10\nmouse:0,1,10\nmouse:3,1,10\n' > "${EV_FILE_T}"
check_eq "一次点击仅选中，二次点击确认" "5" "$(get_user_choice 26 2>/dev/null)"
# 一次点击（按下+释放）+ 回车 → 确认选中
printf 'mouse:0,1,10\nmouse:3,1,10\nline:\n' > "${EV_FILE_T}"
check_eq "一次点击后回车确认" "5" "$(get_user_choice 26 2>/dev/null)"
# 仅一次点击（按下+释放），无后续 → 事件耗尽走 q，验证"一次点击不会进入"
printf 'mouse:0,1,10\nmouse:3,1,10\n' > "${EV_FILE_T}"
check_eq "仅一次点击不进入(返回q)" "q" "$(get_user_choice 26 2>/dev/null)"
printf 'line:7\n' > "${EV_FILE_T}"
check_eq "键盘数字直接进入" "7" "$(get_user_choice 26 2>/dev/null)"
eval "${_tui_read_event_real}"
rm -f "${EV_FILE_T}" "${EV_FILE_T}.tmp"

echo ""
echo "[10c] _tui_read_event SGR 按下/释放解析"
r=$(printf '\033[<0;10;5M' | { _tui_read_event stdin 2>/dev/null; })
check_eq "SGR 按下(M) 解析" "mouse:0,10,5" "${r}"
r=$(printf '\033[<0;10;5m' | { _tui_read_event stdin 2>/dev/null; })
check_eq "SGR 释放(m) 按钮号+3" "mouse:3,10,5" "${r}"
r=$(printf '\033[M\x20\x21\x22' | { _tui_read_event stdin 2>/dev/null; })
# X10：ESC[M 后三个字节各 +32；\x20->btn0 \x21->x1 \x22->y2
check_eq "X10 按下解析" "mouse:0,1,2" "${r}"

echo ""
echo "[11] CLI 协议"
check_run "--version" "${ZETOPS_ROOT}/core/main.sh" --version
check_run "--help" "${ZETOPS_ROOT}/core/main.sh" --help
check_run "--list" "${ZETOPS_ROOT}/core/main.sh" --list
check_run "--run 15 2 (CPU 信息)" "${ZETOPS_ROOT}/core/main.sh" --run 15 2
check_run "--run 短名 hardware_info 3" "${ZETOPS_ROOT}/core/main.sh" --run hardware_info 3
( set +e; "${ZETOPS_ROOT}/core/main.sh" --run 999 1 >/dev/null 2>&1 ); rc=$?
check_eq "--run 无效模块退出码" "1" "${rc}"
( set +e; "${ZETOPS_ROOT}/core/main.sh" --bogus >/dev/null 2>&1 ); rc=$?
check_eq "未知参数退出码" "1" "${rc}"

echo ""
echo "[12] backup_file 单元测试"
printf 'test=1\n' >"${TMPDIR_TEST}/bk.conf"
bk_out=$(backup_file "${TMPDIR_TEST}/bk.conf" 2>/dev/null)
check_eq "备份返回路径" "0" "$?"
[[ -f "${bk_out}" ]] && { PASS=$((PASS + 1)); echo "  PASS: 备份文件已生成"; } || { FAIL=$((FAIL + 1)); echo "  FAIL: 备份文件未生成 [${bk_out}]"; }
check_eq "备份内容一致" "$(cat "${TMPDIR_TEST}/bk.conf")" "$(cat "${bk_out}")"
( set +e; backup_file "${TMPDIR_TEST}/missing.conf" >/dev/null 2>&1 ); rc=$?
check_eq "备份不存在文件退出码" "1" "${rc}"

# ---------- 13. 文件管理器宽度计算 / 截断 / SGR 坐标（locale 无关） ----------
echo ""
echo "[13] 文件管理器宽度计算与 SGR 坐标（C locale 下验证）"
# shellcheck source=/dev/null
source "${ZETOPS_ROOT}/modules/20_file_manager.sh"
export LC_ALL=C LANG=C
check_eq "fm_str_w 中文按 2 列" "4" "$(fm_str_w '返回')"
check_eq "fm_str_w 含括号宽度" "6" "$(fm_str_w '[返回]')"
check_eq "fm_str_w 混合宽度" "6" "$(fm_str_w 'ab中文')"
check_eq "fm_str_clip 贴边截断" "中文…" "$(fm_str_clip '中文文件' 5)"
check_eq "fm_str_clip 不超宽原样" "中文文件" "$(fm_str_clip '中文文件' 20)"
check_eq "fm_str_clip 边界正好放满原样" "中文文件" "$(fm_str_clip '中文文件' 8)"
# SGR 坐标整数化：与 fm_read_sgr 相同算法（剥离非数字字节后三段解析）
sgr_int() {
    local buf="$1" b="" x="" y="" tmp=""
    tmp="${buf//[^0-9;]/}"
    b="${tmp%%;*}"; tmp="${tmp#*;}"
    x="${tmp%%;*}"; tmp="${tmp#*;}"
    y="${tmp%%;*}"
    [[ "${b}" =~ ^[0-9]+$ ]] || b=0
    [[ "${x}" =~ ^[0-9]+$ ]] || x=0
    [[ "${y}" =~ ^[0-9]+$ ]] || y=0
    printf '%s %s %s' "$((b + 0))" "$((x + 0))" "$((y + 0))"
}
check_eq "SGR 正常解析" "0 15 10" "$(sgr_int '0;15;10')"
check_eq "SGR 尾随分号" "0 15 10" "$(sgr_int '0;15;10;')"
check_eq "SGR 异常字节夹带" "0 15 10" "$(sgr_int 'a0b;1x5;1y0')"
check_eq "SGR 缺段" "0 0 0" "$(sgr_int '0;')"

# ---------- 13b. 文件管理器 ../ 上级入口与危险操作防护 ----------
echo ""
echo "[13b] 文件管理器 ../ 上级入口与防护"
TMP_FM="$(mktemp -d)"
mkdir -p "${TMP_FM}/subdir"
FM_PWD="${TMP_FM}"; FM_CURSOR=0; FM_OFFSET=0; FM_WINH=20; FM_LEN=0; FM_LIST=(); FM_MARKED=(); FM_STATUS_MSG=""
fm_refresh_list
check_eq "列表首项为上级目录 .." "D|..|$(dirname "${TMP_FM}")" "${FM_LIST[0]}"
check_true "fm_cur_is_parent 识别 .." fm_cur_is_parent
FM_CURSOR=1
check_false "普通项非上级目录" fm_cur_is_parent
FM_CURSOR=0
fm_toggle_mark
check_eq "标记 ../ 被拒绝" "0" "${#FM_MARKED[@]}"
fm_clip_set "copy"
check_eq "复制 ../ 被拒绝" "" "${FM_CLIP_MODE:-}"
rm -rf "${TMP_FM}"

# ---------- 13c. PID 锁（单实例 + stale 过期清理） ----------
echo ""
echo "[13c] PID 锁：单实例防并发 + 过期锁自动清理"
# shellcheck source=/dev/null
source "${ZETOPS_ROOT}/core/main.sh"
LOCK_FILE="${TMPDIR_TEST}/zetops_test.lock"
rm -f "${LOCK_FILE}"
check_true "PID 锁：首次加锁成功" check_lock
check_false "PID 锁：存活实例占用被拒绝" check_lock
printf '999999\n' > "${LOCK_FILE}"
check_true "PID 锁：过期 PID 自动清理后加锁成功" check_lock
check_eq "PID 锁：锁文件记录当前 PID" "$$" "$(cat "${LOCK_FILE}")"
# cleanup 应释放锁（删除锁文件）；用 _LOCK_OWNED 保护不误删他人锁
rm -f "${LOCK_FILE}"

# ---------- 汇总 ----------
echo ""
echo "======================================================"
echo "测试结果: PASS=${PASS}  FAIL=${FAIL}"
echo "======================================================"
(( FAIL > 0 )) && exit 1 || exit 0