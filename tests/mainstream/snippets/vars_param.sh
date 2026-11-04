#!/usr/bin/env bash
# 变量 + 参数展开
name="world"
echo "hello ${name}"
default="${UNSET_VAR:-fallback}"
echo "default=${default}"
val=""
echo "empty_plus=${val:+set}"
echo "len=${#name}"
text="hello.world"
echo "strip=${text%.*}"
