# scan.awk — 单进程扫描 bash 脚本的语法特性面
# 用法: awk -f scan.awk file.sh
# 输出: FEAT|标签|次数  （每行一个特性，供聚合/格式化）
# 说明: 统计"出现该语法的行数"，衡量语法面使用强度，非精确出现次数。
BEGIN {
    # [A] 流程控制
    p["if/then"]="\\<if\\>"
    p["elif"]="\\<elif\\>"
    p["else/fi"]="\\<else\\>|\\<fi\\>"
    p["for"]="\\<for\\>"
    p["while"]="\\<while\\>"
    p["until"]="\\<until\\>"
    p["case/esac"]="\\<case\\>|\\<esac\\>"
    p["select"]="\\<select\\>"
    p["function 定义"]="^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\\(\\)[ \t]*\\{|^[ \t]*function[ \t]+"
    # [B] 条件 / 测试
    p["[[ ]] 关键字测试"]="\\[\\["
    p["[ ] 测试"]="(^|[^[])[\\[][[:space:]]"
    p["(( )) 算术"]="\\(\\("
    p["let"]="\\<let\\>"
    p["=~ 正则"]="=~"
    p["-f/-d/-z 文件测试"]="\\<-[fdezxn]\\>"
    # [C] 参数展开
    p["${VAR}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}"
    p["${VAR:-默认}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*:-"
    p["${VAR:=赋值}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*:="
    p["${VAR:+存在}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*:\\+"
    p["${VAR:偏移:长度}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*:[0-9]"
    p["${VAR#/## 去头}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*#"
    p["${VAR%/%% 去尾}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*%"
    p["${VAR/pat/rep}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*\\/"
    p["${!VAR} 间接引用"]="\\$\\{![A-Za-z_][A-Za-z0-9_]*\\}"
    p["${#VAR} 长度"]="\\$\\{#[A-Za-z_][A-Za-z0-9_]*\\}"
    # [D] 数组
    p["declare -a/-A"]="declare[[:space:]]+-[aA]\\>"
    p["${arr[@]}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*\\[@\\]\\}"
    p["${arr[*]}"]="\\$\\{[A-Za-z_][A-Za-z0-9_]*\\[\\*\\]\\}"
    p["${#arr[@]} 长度"]="\\$\\{#[A-Za-z_][A-Za-z0-9_]*\\[@\\]\\}"
    p["arr[idx]="]="\\[[0-9]+\\]="
    # [E] 替换 / 子 shell
    p["$(...) 命令替换"]="\\$\\("
    p["`...` 反引号"]="`"
    p["<(...) 进程替换"]="<\\("
    p[">(...) 进程替换"]=">\\("
    p["<<< here-string"]="<<<"
    # [F] 重定向
    p[">"]="(^|[^>])>[^>=]"
    p[">>"]=">>"
    p["<"]="(^|[^<])<[^<(]"
    p["2>"]="2>"
    p["2>&1"]="2>&1"
    p["&>"]="&>"
    p["<< heredoc"]="<<"
    # [G] 内建命令
    p["local"]="\\<local\\>"
    p["source"]="\\<source\\>"
    p["read"]="\\<read\\>"
    p["printf"]="\\<printf\\>"
    p["mapfile"]="\\<mapfile\\>"
    p["eval"]="\\<eval\\>"
    p["exec"]="\\<exec\\>"
    p["trap"]="\\<trap\\>"
    p["set"]="\\<set\\>"
    p["export"]="\\<export\\>"
    p["unset"]="\\<unset\\>"
    p["shift"]="\\<shift\\>"
    p["getopts"]="\\<getopts\\>"
    p["declare"]="\\<declare\\>"
    p["typeset"]="\\<typeset\\>"
    p["alias"]="\\<alias\\>"
    p["enable"]="\\<enable\\>"
    # [H] 其它
    p["管道"]="[|]"
    p["管道|&"]="[|]&"
    p["后台 &"]="[[:space:]]&[[:space:]]*$"
    p["$(()) 算术展开"]="\\$\\(\\("
}
{
    for (k in p) { if ($0 ~ p[k]) c[k]++ }
}
END {
    for (k in c) printf "FEAT|%s|%d\n", k, c[k]
}
